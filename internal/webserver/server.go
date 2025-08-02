package webserver

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/acuqa/ssh-aquarium/internal/aquarium"
)

type Server struct {
	port        int
	server      *http.Server
	aquariumMgr *aquarium.Manager
}

func New(port int, aquariumMgr *aquarium.Manager) *Server {
	return &Server{
		port:        port,
		aquariumMgr: aquariumMgr,
	}
}

func (s *Server) Start() error {
	mux := http.NewServeMux()
	
	// Health check endpoint
	mux.HandleFunc("/health", s.healthHandler)
	
	// Root endpoint with fish count and connection info
	mux.HandleFunc("/", s.rootHandler)
	
	s.server = &http.Server{
		Addr:    fmt.Sprintf(":%d", s.port),
		Handler: mux,
	}
	
	log.Printf("Starting web server on port %d", s.port)
	return s.server.ListenAndServe()
}

func (s *Server) Stop() error {
	if s.server == nil {
		return nil
	}
	
	log.Println("Stopping web server...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	return s.server.Shutdown(ctx)
}

func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"status": "ok", "timestamp": "%s"}`, time.Now().UTC().Format(time.RFC3339))
}

func (s *Server) rootHandler(w http.ResponseWriter, r *http.Request) {
	fishCount := s.getFishCount()
	
	w.Header().Set("Content-Type", "text/html")
	w.WriteHeader(http.StatusOK)
	
	html := fmt.Sprintf(`<!DOCTYPE html>
<html>
<head>
    <title>SSH Aquarium</title>
    <style>
        body { font-family: monospace; margin: 40px; background: #001122; color: #66ccff; }
        h1 { color: #88ddff; }
        pre { background: #002244; padding: 20px; border-radius: 8px; color: #aaffaa; }
        .fish-count { font-size: 1.2em; margin: 20px 0; }
    </style>
</head>
<body>
    <h1>🐠 SSH Aquarium</h1>
    <div class="fish-count">Fish swimming in the aquarium: %d</div>
    <p>To connect and see the fish:</p>
    <pre>ssh acqua.fly.dev</pre>
</body>
</html>`, fishCount)
	
	fmt.Fprint(w, html)
}

func (s *Server) getFishCount() int {
	if s.aquariumMgr == nil {
		return 0
	}
	return s.aquariumMgr.GetFishCount()
}