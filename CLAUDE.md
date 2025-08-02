# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a high-performance SSH server written in Go that creates a shared virtual aquarium where multiple users can connect via SSH and view animated fish using the Kitty Graphics Protocol. It's a migration from a Node.js implementation with significant performance improvements.

## Build and Development Commands

### Build and Run
```bash
# Build the binary
make build

# Build and run server
make run

# Run directly with go run (development)
make dev

# Run with debug mode (1 FPS instead of 60 FPS)
./run-server.sh --debug

# Build manually
go build -o ssh-aquarium cmd/ssh-aquarium/main.go
```

### Testing
```bash
# Integration testing script
./test-simple.sh [--debug]

# Manual testing (keeps server running)
./test.sh

# Connect to test server
ssh -p 1234 localhost
```

### Development
```bash
# Run server with custom options
./ssh-aquarium -port 1234 -web-port 8080 -host-key ./ssh_keys/host_key_rsa_4096 [-debug]

# Check server status via web interface
curl http://localhost:8080
```

## Architecture Overview

### Core Components
- **Entry Point**: `cmd/ssh-aquarium/main.go` - Main application entry point
- **Aquarium Manager**: `internal/aquarium/manager.go` - Central state coordinator running 60 FPS animation loop
- **Fish System**: `internal/aquarium/fish.go` - Individual fish entities with physics simulation
- **SSH Server**: `internal/sshserver/server.go` - SSH protocol implementation with PTY handling
- **Connection Handler**: `internal/connection/handler.go` - Session lifecycle and terminal setup
- **Web Server**: `internal/webserver/server.go` - HTTP status endpoint

### Key Architectural Patterns
- **Concurrent Design**: Separate goroutines for each SSH connection and animation loop
- **Manager Pattern**: Central `aquarium.Manager` coordinates all state with thread-safe access
- **Interface Abstraction**: `ConnectionStream` interface separates aquarium logic from transport
- **Event-Driven**: 60 FPS ticker drives animation updates, mouse events trigger fish interactions

### Technical Features
- **Kitty Graphics Protocol**: PNG image rendering for fish sprites in terminal
- **Real-time Animation**: 60 FPS fish movement with physics simulation
- **Mouse Interaction**: Click detection to change fish direction
- **Multi-user Support**: Concurrent SSH connections sharing the same aquarium state

## Dependencies

Go module: `github.com/acuqa/ssh-aquarium`
Required Go version: 1.21+

Key dependencies:
- `golang.org/x/crypto` - SSH protocol implementation
- `golang.org/x/sys` - System calls
- `golang.org/x/term` - Terminal utilities

## Testing Notes

Currently no formal unit tests exist (`*_test.go` files). Testing is done via:
- Integration scripts (`test-simple.sh`, `test.sh`)
- Manual SSH connections
- Debug mode for slower animation inspection

When adding tests, focus on:
- Fish physics and collision detection
- Connection handling and cleanup
- Terminal detection and setup
- Multi-connection scenarios

## Development Environment

### Required Assets
- `fish.png` and `fish-right.png` - Fish sprite images
- `ssh_keys/host_key_rsa_4096` - SSH host key (4096-bit RSA)

### Terminal Requirements
Client must support Kitty Graphics Protocol (Kitty, WezTerm, Konsole)

### Debug Mode
Use `--debug` flag for 1 FPS animation speed during development

## Configuration

### Default Ports
- SSH: 1234
- Web: 8080

### Authentication
Demo mode allows any SSH credentials (both password and public key auth supported)

## Deployment

### Local Development
Use `make dev` or `./run-server.sh` for quick iteration

### Production
- Docker: Multi-stage build with Alpine Linux
- Fly.io: Configuration in `fly.toml`
- Requires proper SSH host key generation for production