package sshserver

import (
	"fmt"
	"log"
	"net"
	"os"
	"sync"

	"github.com/acuqa/ssh-aquarium/internal/aquarium"
	"github.com/acuqa/ssh-aquarium/internal/connection"
	"golang.org/x/crypto/ssh"
)

type Server struct {
	port        int
	hostKeyPath string
	config      *ssh.ServerConfig
	listener    net.Listener
	aquarium    *aquarium.Manager
	mu          sync.Mutex
	running     bool
	wg          sync.WaitGroup
}

func New(port int, hostKeyPath string, aquarium *aquarium.Manager) (*Server, error) {
	// Load host key
	privateBytes, err := os.ReadFile(hostKeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load host key: %w", err)
	}

	private, err := ssh.ParsePrivateKey(privateBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse host key: %w", err)
	}

	// Create SSH config
	config := &ssh.ServerConfig{
		// Allow any user/password for demo purposes
		PasswordCallback: func(c ssh.ConnMetadata, pass []byte) (*ssh.Permissions, error) {
			log.Printf("User %s connected", c.User())
			return &ssh.Permissions{}, nil
		},
		// Also allow any public key
		PublicKeyCallback: func(c ssh.ConnMetadata, pubKey ssh.PublicKey) (*ssh.Permissions, error) {
			log.Printf("User %s connected with public key", c.User())
			return &ssh.Permissions{}, nil
		},
	}
	config.AddHostKey(private)

	return &Server{
		port:        port,
		hostKeyPath: hostKeyPath,
		config:      config,
		aquarium:    aquarium,
	}, nil
}

func (s *Server) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return fmt.Errorf("server already running")
	}

	// Start listening
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", s.port))
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	s.listener = listener
	s.running = true

	// Start accept loop
	s.wg.Add(1)
	go s.acceptLoop()

	return nil
}

func (s *Server) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return
	}

	s.running = false
	if s.listener != nil {
		s.listener.Close()
	}

	s.wg.Wait()
}

func (s *Server) acceptLoop() {
	defer s.wg.Done()

	for {
		conn, err := s.listener.Accept()
		if err != nil {
			s.mu.Lock()
			running := s.running
			s.mu.Unlock()
			
			if !running {
				return
			}
			log.Printf("Failed to accept connection: %v", err)
			continue
		}

		// Handle connection in goroutine
		go s.handleConnection(conn)
	}
}

func (s *Server) handleConnection(netConn net.Conn) {
	defer netConn.Close()

	// Perform SSH handshake
	sshConn, chans, reqs, err := ssh.NewServerConn(netConn, s.config)
	if err != nil {
		log.Printf("Failed to handshake: %v", err)
		return
	}
	defer sshConn.Close()

	// Get username from connection
	username := sshConn.User()

	// Discard global requests
	go ssh.DiscardRequests(reqs)

	// Handle channels
	for newChannel := range chans {
		if newChannel.ChannelType() != "session" {
			newChannel.Reject(ssh.UnknownChannelType, "unknown channel type")
			continue
		}

		channel, requests, err := newChannel.Accept()
		if err != nil {
			log.Printf("Could not accept channel: %v", err)
			continue
		}

		// Handle session in goroutine
		go s.handleSession(channel, requests, username)
	}
}

func (s *Server) handleSession(channel ssh.Channel, requests <-chan *ssh.Request, username string) {
	defer channel.Close()

	// Create connection handler
	conn := connection.New(channel, s.aquarium, username)
	defer conn.Close()
	
	log.Printf("User '%s' started aquarium session", username)

	// Handle requests
	for req := range requests {
		switch req.Type {
		case "pty-req":
			// Parse terminal info
			termLen := req.Payload[3]
			termType := string(req.Payload[4 : 4+termLen])
			
			w, h, ok := parsePtyRequest(req.Payload)
			if ok {
				log.Printf("PTY request: terminal=%s, size=%dx%d", termType, w, h)
				conn.SetTerminal(termType, w, h)
			} else {
				log.Printf("Failed to parse PTY request")
			}
			
			if req.WantReply {
				req.Reply(true, nil)
			}

		case "shell":
			if req.WantReply {
				req.Reply(true, nil)
			}
			
			// Start aquarium session
			log.Printf("Connection %d: Starting session", conn.ID())
			conn.Start()

		case "window-change":
			w, h, ok := parseWindowChange(req.Payload)
			if ok {
				conn.Resize(w, h)
			}
			
			if req.WantReply {
				req.Reply(true, nil)
			}

		default:
			if req.WantReply {
				req.Reply(false, nil)
			}
		}
	}
}

func parsePtyRequest(payload []byte) (width, height uint32, ok bool) {
	if len(payload) < 8 {
		return 0, 0, false
	}
	
	termLen := payload[3]
	offset := 4 + int(termLen)
	
	if len(payload) < offset+16 {
		return 0, 0, false
	}
	
	width = uint32(payload[offset])<<24 | uint32(payload[offset+1])<<16 | uint32(payload[offset+2])<<8 | uint32(payload[offset+3])
	height = uint32(payload[offset+4])<<24 | uint32(payload[offset+5])<<16 | uint32(payload[offset+6])<<8 | uint32(payload[offset+7])
	
	return width, height, true
}

func parseWindowChange(payload []byte) (width, height uint32, ok bool) {
	if len(payload) < 8 {
		return 0, 0, false
	}
	
	width = uint32(payload[0])<<24 | uint32(payload[1])<<16 | uint32(payload[2])<<8 | uint32(payload[3])
	height = uint32(payload[4])<<24 | uint32(payload[5])<<16 | uint32(payload[6])<<8 | uint32(payload[7])
	
	return width, height, true
}