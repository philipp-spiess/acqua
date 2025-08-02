package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/acuqa/ssh-aquarium/internal/aquarium"
	"github.com/acuqa/ssh-aquarium/internal/sshserver"
	"github.com/acuqa/ssh-aquarium/internal/webserver"
)

func main() {
	port := flag.Int("port", 1234, "SSH server port")
	webPort := flag.Int("web-port", 8080, "Web server port")
	hostKeyPath := flag.String("host-key", "./ssh_keys/host_key_rsa_4096", "Path to SSH host key")
	debug := flag.Bool("debug", false, "Debug mode (1 fish, 1 FPS)")
	flag.Parse()

	// Create aquarium manager
	aquariumMgr := aquarium.NewManager()
	if *debug {
		aquariumMgr.SetDebugMode(true)
	}
	
	// Create SSH server
	server, err := sshserver.New(*port, *hostKeyPath, aquariumMgr)
	if err != nil {
		log.Fatalf("Failed to create SSH server: %v", err)
	}

	// Create web server
	webSrv := webserver.New(*webPort, aquariumMgr)

	// Start SSH server
	if err := server.Start(); err != nil {
		log.Fatalf("Failed to start SSH server: %v", err)
	}

	// Start web server in goroutine
	go func() {
		if err := webSrv.Start(); err != nil {
			log.Printf("Web server error: %v", err)
		}
	}()

	log.Printf("SSH aquarium server listening on port %d", *port)
	log.Printf("Web server listening on port %d", *webPort)
	log.Println("Connect with: ssh -p", *port, "localhost")
	log.Println("(Any username/password will work)")
	log.Printf("Web interface: http://localhost:%d", *webPort)

	// Wait for interrupt signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("\nShutting down server...")
	
	// Start shutdown in goroutine with timeout
	done := make(chan struct{})
	go func() {
		server.Stop()
		webSrv.Stop()
		aquariumMgr.Stop()
		close(done)
	}()
	
	// Wait for shutdown or force exit
	select {
	case <-done:
		log.Println("Server stopped gracefully")
	case <-time.After(5 * time.Second):
		log.Println("Shutdown timeout - forcing exit")
		os.Exit(1)
	}
}