package connection

import (
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"sync"
	"time"

	"github.com/acuqa/ssh-aquarium/internal/aquarium"
	"golang.org/x/crypto/ssh"
)

type Handler struct {
	channel     ssh.Channel
	aquarium    *aquarium.Manager
	connID      uint64
	username    string
	termType    string
	termColumns int
	termRows    int
	cellWidth   int
	cellHeight  int
	mu          sync.Mutex
	running     bool
	done        chan struct{}
}

type streamWrapper struct {
	channel ssh.Channel
}

func (s *streamWrapper) Write(data []byte) error {
	_, err := s.channel.Write(data)
	return err
}

func (s *streamWrapper) Close() error {
	return s.channel.Close()
}

func New(channel ssh.Channel, aquarium *aquarium.Manager, username string) *Handler {
	return &Handler{
		channel:     channel,
		aquarium:    aquarium,
		username:    username,
		termColumns: 80,
		termRows:    24,
		cellWidth:   8,  // default
		cellHeight:  16, // default
		done:        make(chan struct{}),
	}
}

func (h *Handler) ID() uint64 {
	return h.connID
}

func (h *Handler) SetTerminal(termType string, columns, rows uint32) {
	h.mu.Lock()
	defer h.mu.Unlock()
	
	h.termType = termType
	h.termColumns = int(columns)
	h.termRows = int(rows)
}

func (h *Handler) Resize(columns, rows uint32) {
	h.mu.Lock()
	defer h.mu.Unlock()
	
	h.termColumns = int(columns)
	h.termRows = int(rows)
	
	// TODO: Update aquarium terminal config
}

func (h *Handler) Start() {
	h.mu.Lock()
	if h.running {
		h.mu.Unlock()
		return
	}
	h.running = true
	h.mu.Unlock()
	
	// Add connection to aquarium
	stream := &streamWrapper{channel: h.channel}
	h.connID = h.aquarium.AddConnection(stream, h.username)
	
	log.Printf("Connection %d: Starting session", h.connID)
	
	// Setup terminal
	h.setupTerminal()
	
	// Detect terminal cell size and init (must be done before input handling)
	h.detectTerminalAndInit()
	
	// Handle input
	go h.handleInput()
}

func (h *Handler) Close() {
	h.mu.Lock()
	if !h.running {
		h.mu.Unlock()
		return
	}
	h.running = false
	h.mu.Unlock()
	
	close(h.done)
	
	// Remove connection from aquarium
	h.aquarium.RemoveConnection(h.connID)
	
	// Cleanup terminal
	h.cleanupTerminal()
	
	// Send exit status and close channel to properly terminate SSH session
	h.channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0}) // Exit code 0
	h.channel.Close()
}

func (h *Handler) setupTerminal() {
	// Hide cursor
	h.channel.Write([]byte("\x1b[?25l"))
	// Enable mouse click reporting
	h.channel.Write([]byte("\x1b[?1000h"))
	// Enable mouse drag reporting
	h.channel.Write([]byte("\x1b[?1002h"))
	// Clear screen
	h.channel.Write([]byte("\x1b[2J"))
}

func (h *Handler) cleanupTerminal() {
	// Disable mouse reporting
	h.channel.Write([]byte("\x1b[?1000l"))
	h.channel.Write([]byte("\x1b[?1002l"))
	// Show cursor
	h.channel.Write([]byte("\x1b[?25h"))
	// Clear screen
	h.channel.Write([]byte("\x1b[2J"))
	// Final message
	h.channel.Write([]byte("\r\nAquarium session ended.\r\n"))
}

func (h *Handler) detectTerminalAndInit() {
	log.Printf("Starting terminal detection for connection %d (cols=%d, rows=%d)", h.connID, h.termColumns, h.termRows)
	
	// Query terminal size in pixels
	h.channel.Write([]byte("\x1b[14t"))
	
	// Try to read response with timeout
	responseChan := make(chan []int, 1)
	go func() {
		dims := h.readTerminalResponse()
		responseChan <- dims
	}()
	
	select {
	case dims := <-responseChan:
		if len(dims) == 2 {
			pixelWidth := dims[0]
			pixelHeight := dims[1]
			
			h.mu.Lock()
			if h.termColumns > 0 && h.termRows > 0 {
				h.cellWidth = pixelWidth / h.termColumns
				h.cellHeight = pixelHeight / h.termRows
			}
			h.mu.Unlock()
			
			log.Printf("Terminal detection successful:")
			log.Printf("  Terminal: %dx%d characters", h.termColumns, h.termRows)
			log.Printf("  Window: %dx%d pixels", pixelWidth, pixelHeight)
			log.Printf("  Cell size: %dx%d pixels", h.cellWidth, h.cellHeight)
		}
	case <-time.After(2 * time.Second):
		log.Printf("Terminal detection timeout, using default cell size: %dx%d", h.cellWidth, h.cellHeight)
	}
	
	// Initialize aquarium
	h.initializeAquarium()
}

func (h *Handler) readTerminalResponse() []int {
	buf := make([]byte, 1024)
	responseBuffer := ""
	
	for {
		n, err := h.channel.Read(buf)
		if err != nil {
			if err != io.EOF {
				log.Printf("Terminal response read error: %v", err)
			}
			return nil
		}
		
		responseBuffer += string(buf[:n])
		log.Printf("Terminal response buffer: %q", responseBuffer)
		
		// Look for terminal size response: ESC[4;height;widtht
		re := regexp.MustCompile(`\x1b\[4;(\d+);(\d+)t`)
		if matches := re.FindStringSubmatch(responseBuffer); matches != nil {
			pixelHeight := 0
			pixelWidth := 0
			fmt.Sscanf(matches[1], "%d", &pixelHeight)
			fmt.Sscanf(matches[2], "%d", &pixelWidth)
			
			log.Printf("Detected terminal size: %dx%d pixels", pixelWidth, pixelHeight)
			return []int{pixelWidth, pixelHeight}
		}
		
		// Prevent buffer from growing too large
		if len(responseBuffer) > 100 {
			return nil
		}
	}
}

func (h *Handler) initializeAquarium() {
	h.mu.Lock()
	config := &aquarium.TerminalConfig{
		Columns:    h.termColumns,
		Rows:       h.termRows,
		CellWidth:  h.cellWidth,
		CellHeight: h.cellHeight,
	}
	h.mu.Unlock()
	
	log.Printf("Initializing aquarium with config: %dx%d chars, %dx%d pixels per cell", 
		config.Columns, config.Rows, config.CellWidth, config.CellHeight)
	
	// If first connection, set terminal config and start animation
	if h.aquarium.GetTerminalConfig() == nil {
		log.Printf("First connection - setting terminal config and starting animation")
		h.aquarium.SetTerminalConfig(config)
		h.aquarium.StartAnimation()
	} else {
		log.Printf("Additional connection - using existing aquarium config")
	}
	
	// Upload fish images
	h.uploadImages()
	
	// Add fish for this connection
	fishAdded := h.aquarium.AddFish(h.connID, 1)
	
	log.Printf("Connection %d initialized with %d fish", h.connID, len(fishAdded))
}

func (h *Handler) uploadImages() {
	// Upload left-facing fish
	if data, err := os.ReadFile("fish.png"); err == nil {
		h.uploadImage(data, 1)
	} else {
		log.Printf("Warning: Could not load fish.png: %v", err)
	}
	
	// Upload right-facing fish (or use left if not available)
	if data, err := os.ReadFile("fish-right.png"); err == nil {
		h.uploadImage(data, 2)
	} else if data, err := os.ReadFile("fish.png"); err == nil {
		h.uploadImage(data, 2)
	}
	
	// Upload floor tiles (image IDs 10-15)
	for i := 0; i < 6; i++ {
		filename := fmt.Sprintf("floor_%d.png", i)
		if data, err := os.ReadFile(filename); err == nil {
			h.uploadImage(data, 10+i)
		} else {
			log.Printf("Warning: Could not load %s: %v", filename, err)
		}
	}
}

func (h *Handler) uploadImage(data []byte, imageID int) {
	base64Data := base64.StdEncoding.EncodeToString(data)
	chunkSize := 4096
	
	for i := 0; i < len(base64Data); i += chunkSize {
		chunk := base64Data[i:min(i+chunkSize, len(base64Data))]
		isFirst := i == 0
		hasMore := i+chunkSize < len(base64Data)
		
		var command string
		if isFirst {
			command = fmt.Sprintf("a=t,f=100,i=%d,m=%d,q=1", imageID, btoi(hasMore))
		} else {
			command = fmt.Sprintf("m=%d", btoi(hasMore))
		}
		
		h.channel.Write([]byte(fmt.Sprintf("\x1b_G%s;%s\x1b\\", command, chunk)))
	}
}

func (h *Handler) handleInput() {
	buf := make([]byte, 256)
	
	for {
		select {
		case <-h.done:
			return
		default:
			n, err := h.channel.Read(buf)
			if err != nil {
				if err != io.EOF {
					log.Printf("Read error: %v", err)
				}
				h.Close()
				return
			}
			
			if n > 0 {
				h.processInput(buf[:n])
			}
		}
	}
}

func (h *Handler) processInput(data []byte) {
	// Handle Ctrl+C
	if len(data) == 1 && data[0] == 0x03 {
		log.Printf("Connection %d: Ctrl+C detected, closing", h.connID)
		h.Close()
		return
	}
	
	// Handle Ctrl+D (EOF)
	if len(data) == 1 && data[0] == 0x04 {
		log.Printf("Connection %d: Ctrl+D detected, closing", h.connID)
		h.Close()
		return
	}
	
	// Handle 'q' to quit
	if len(data) == 1 && (data[0] == 'q' || data[0] == 'Q') {
		log.Printf("Connection %d: 'q' detected, closing", h.connID)
		h.Close()
		return
	}
	
	// Handle mouse events (ESC[M...)
	if len(data) >= 6 && data[0] == 0x1b && data[1] == '[' && data[2] == 'M' {
		button := int(data[3]) - 32
		col := int(data[4]) - 32
		row := int(data[5]) - 32
		
		h.aquarium.HandleMouseClick(h.connID, button, col, row)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}