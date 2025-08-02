# SSH Aquarium Server - Go Implementation Specification

## Overview

This specification outlines the migration of a Node.js SSH server that creates a shared virtual aquarium to Go. The server allows multiple users to connect via SSH and view animated fish swimming in a shared terminal environment. Each connection spawns 100 fish, and users can interact with their own fish through mouse clicks.

## Current Node.js Implementation Analysis

### Core Features
- **SSH Server**: Listens on port 1234 with RSA host key authentication
- **Shared State**: Multiple viewers can connect simultaneously and see the same aquarium
- **Fish Animation**: 60 FPS animation with realistic physics and movement
- **Kitty Graphics Protocol**: Renders PNG fish images using terminal graphics
- **Mouse Interaction**: Click detection for fish interaction (direction changes, bubbles)
- **Terminal Detection**: Automatic cell size detection for proper pixel positioning
- **Connection Management**: Ownership tracking, cleanup on disconnect

### Performance Characteristics
- 60 FPS animation loop (16.66ms intervals)
- 100 fish per connection
- Real-time mouse event processing
- Concurrent connection handling
- Shared state management across multiple terminals

## Go Architecture Design

### Package Structure

```
acuqa-go/
├── main.go                    # Entry point and server setup
├── internal/
│   ├── server/
│   │   ├── ssh.go            # SSH server implementation
│   │   ├── session.go        # SSH session management
│   │   └── auth.go           # Authentication handlers
│   ├── aquarium/
│   │   ├── aquarium.go       # Core aquarium state management
│   │   ├── fish.go           # Fish entity and physics
│   │   ├── animator.go       # Animation loop and rendering
│   │   └── bubble.go         # Bubble system
│   ├── terminal/
│   │   ├── terminal.go       # Terminal detection and utilities
│   │   ├── kitty.go          # Kitty Graphics Protocol implementation
│   │   └── mouse.go          # Mouse event parsing
│   └── connection/
│       ├── manager.go        # Connection lifecycle management
│       └── viewer.go         # Individual viewer state
├── assets/
│   ├── fish.png             # Left-facing fish image
│   └── fish-right.png       # Right-facing fish image
└── ssh_keys/
    └── host_key_rsa_4096    # SSH host key
```

### Core Data Structures

#### Aquarium State
```go
type Aquarium struct {
    mu              sync.RWMutex
    viewers         map[string]*Viewer
    fish            map[int]*Fish
    terminalConfig  *TerminalConfig
    animationTicker *time.Ticker
    fishCounter     int64
    running         bool
    broadcast       chan []byte
}

type TerminalConfig struct {
    Columns    int
    Rows       int
    CellWidth  int
    CellHeight int
}
```

#### Fish Entity
```go
type Fish struct {
    ID          int
    OwnerID     string
    PX, PY      float64    // Position in pixels
    DX, DY      float64    // Velocity in pixels per frame
    BobbingTime float64
    Bubbles     []*Bubble
    PlacementID int
    mu          sync.RWMutex
}

type Bubble struct {
    X, Y     float64
    Char     rune
    Age      int
    PrevCol  int
    PrevRow  int
}
```

#### Connection Management
```go
type Viewer struct {
    ID       string
    Session  ssh.Session
    Terminal ssh.Pty
    FishIDs  []int
    Active   bool
    mu       sync.RWMutex
}

type ConnectionManager struct {
    mu      sync.RWMutex
    viewers map[string]*Viewer
    counter int64
}
```

## Go Concurrency Patterns

### 1. Goroutine Architecture

```
Main Goroutine
├── SSH Server Listener
├── Animation Loop Goroutine
├── Broadcast Goroutine
└── Per-Connection Goroutines
    ├── Input Handler (mouse events, ctrl+c)
    ├── Terminal Writer
    └── Connection Lifecycle Manager
```

### 2. Channel-Based Communication

```go
type AquariumChannels struct {
    // Animation system
    animationTick   chan time.Time
    fishUpdate      chan *Fish
    
    // Broadcasting
    broadcast       chan []byte
    viewerJoin      chan *Viewer
    viewerLeave     chan string
    
    // Mouse interaction
    mouseEvent      chan MouseEvent
    
    // Cleanup
    shutdown        chan struct{}
}

type MouseEvent struct {
    ViewerID string
    X, Y     int
    Button   int
}
```

### 3. Worker Pool for Fish Updates

```go
// Process fish updates concurrently
type FishWorkerPool struct {
    workers    int
    fishChan   chan *Fish
    resultChan chan FishUpdate
    wg         sync.WaitGroup
}

func (p *FishWorkerPool) ProcessFish(fish []*Fish) []FishUpdate {
    // Distribute fish across workers for parallel processing
    // Each worker handles physics, collision detection, bubble updates
}
```

## Implementation Details

### 1. SSH Server Setup

```go
func NewSSHServer(hostKeyPath string, port int) *SSHServer {
    config := &ssh.ServerConfig{
        NoClientAuth: true, // Allow any connection (demo mode)
        // Or implement proper auth:
        // PasswordCallback: authenticatePassword,
        // PublicKeyCallback: authenticatePublicKey,
    }
    
    hostKey, err := loadHostKey(hostKeyPath)
    if err != nil {
        log.Fatal(err)
    }
    config.AddHostKey(hostKey)
    
    return &SSHServer{
        config:   config,
        port:     port,
        aquarium: NewAquarium(),
    }
}
```

### 2. Terminal Detection with Timeouts

```go
func (t *Terminal) DetectCellSize(session ssh.Session) (*TerminalConfig, error) {
    // Send escape sequence to query terminal size
    session.Write([]byte("\x1b[14t"))
    
    // Use context with timeout for response
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    
    response := make(chan *TerminalConfig, 1)
    go func() {
        config := t.parseTerminalResponse(session)
        select {
        case response <- config:
        case <-ctx.Done():
        }
    }()
    
    select {
    case config := <-response:
        return config, nil
    case <-ctx.Done():
        return &TerminalConfig{
            Columns: 80, Rows: 24,
            CellWidth: 8, CellHeight: 16, // Fallback values
        }, nil
    }
}
```

### 3. High-Performance Animation Loop

```go
func (a *Aquarium) StartAnimation() {
    ticker := time.NewTicker(16666 * time.Microsecond) // ~60 FPS
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            start := time.Now()
            
            // Process all fish updates in parallel
            fishUpdates := a.processAllFish()
            
            // Generate render commands
            renderData := a.generateRenderCommands(fishUpdates)
            
            // Broadcast to all viewers
            a.broadcastToViewers(renderData)
            
            // Performance monitoring
            elapsed := time.Since(start)
            if elapsed > 15*time.Millisecond {
                log.Printf("Animation frame took %v (>15ms)", elapsed)
            }
            
        case <-a.shutdown:
            return
        }
    }
}
```

### 4. Efficient Broadcasting

```go
type Broadcaster struct {
    viewers map[string]chan []byte
    mu      sync.RWMutex
}

func (b *Broadcaster) Broadcast(data []byte) {
    b.mu.RLock()
    defer b.mu.RUnlock()
    
    // Use sync.WaitGroup for concurrent writes
    var wg sync.WaitGroup
    
    for viewerID, ch := range b.viewers {
        wg.Add(1)
        go func(id string, channel chan []byte) {
            defer wg.Done()
            
            select {
            case channel <- data:
            case <-time.After(100 * time.Millisecond):
                log.Printf("Broadcast timeout for viewer %s", id)
                // Mark viewer as slow/disconnected
            }
        }(viewerID, ch)
    }
    
    wg.Wait()
}
```

### 5. Memory-Efficient Fish Management

```go
type FishPool struct {
    pool sync.Pool
}

func NewFishPool() *FishPool {
    return &FishPool{
        pool: sync.Pool{
            New: func() interface{} {
                return &Fish{
                    Bubbles: make([]*Bubble, 0, 10), // Pre-allocate bubble slice
                }
            },
        },
    }
}

func (p *FishPool) Get() *Fish {
    return p.pool.Get().(*Fish)
}

func (p *FishPool) Put(fish *Fish) {
    // Reset fish state
    fish.Bubbles = fish.Bubbles[:0] // Keep slice capacity
    p.pool.Put(fish)
}
```

## Kitty Graphics Protocol Implementation

### 1. Image Upload with Chunking

```go
type KittyGraphics struct {
    chunkSize int
}

func (k *KittyGraphics) UploadImage(w io.Writer, data []byte, imageID int) error {
    base64Data := base64.StdEncoding.EncodeToString(data)
    
    for i := 0; i < len(base64Data); i += k.chunkSize {
        end := i + k.chunkSize
        if end > len(base64Data) {
            end = len(base64Data)
        }
        
        chunk := base64Data[i:end]
        isFirst := i == 0
        hasMore := end < len(base64Data)
        
        var cmd string
        if isFirst {
            cmd = fmt.Sprintf("a=t,f=100,i=%d,m=%d,q=1", imageID, boolToInt(hasMore))
        } else {
            cmd = fmt.Sprintf("m=%d", boolToInt(hasMore))
        }
        
        if _, err := fmt.Fprintf(w, "\x1b_G%s;%s\x1b\\", cmd, chunk); err != nil {
            return err
        }
    }
    return nil
}
```

### 2. Efficient Image Placement

```go
func (k *KittyGraphics) PlaceImage(w io.Writer, opts PlacementOptions) error {
    // Batch cursor movement and image placement
    cmd := fmt.Sprintf(
        "\x1b[%d;%dH\x1b_Ga=p,i=%d,p=%d,c=%d,r=%d,C=1,X=%d,Y=%d,q=1\x1b\\",
        opts.Row, opts.Col, opts.ImageID, opts.PlacementID,
        opts.Width, opts.Height, opts.XOffset, opts.YOffset,
    )
    
    _, err := w.Write([]byte(cmd))
    return err
}
```

## Performance Optimizations

### 1. Connection Pool Management

```go
type ConnectionPool struct {
    maxConnections int
    activeCount    int64
    semaphore     chan struct{}
}

func NewConnectionPool(max int) *ConnectionPool {
    return &ConnectionPool{
        maxConnections: max,
        semaphore:     make(chan struct{}, max),
    }
}

func (p *ConnectionPool) Acquire() bool {
    select {
    case p.semaphore <- struct{}{}:
        atomic.AddInt64(&p.activeCount, 1)
        return true
    default:
        return false // Pool exhausted
    }
}
```

### 2. Memory Pool for Render Commands

```go
type RenderCommandPool struct {
    pool sync.Pool
}

func (p *RenderCommandPool) GetBuffer() *bytes.Buffer {
    buf := p.pool.Get().(*bytes.Buffer)
    buf.Reset()
    return buf
}

func (p *RenderCommandPool) PutBuffer(buf *bytes.Buffer) {
    if buf.Cap() < 64*1024 { // Don't pool overly large buffers
        p.pool.Put(buf)
    }
}
```

### 3. Spatial Partitioning for Mouse Collision

```go
type SpatialGrid struct {
    cellSize int
    grid     map[GridCoord][]*Fish
    mu       sync.RWMutex
}

func (g *SpatialGrid) GetNearbyFish(x, y float64) []*Fish {
    coord := GridCoord{
        X: int(x) / g.cellSize,
        Y: int(y) / g.cellSize,
    }
    
    g.mu.RLock()
    defer g.mu.RUnlock()
    
    var nearby []*Fish
    for dx := -1; dx <= 1; dx++ {
        for dy := -1; dy <= 1; dy++ {
            cell := GridCoord{coord.X + dx, coord.Y + dy}
            nearby = append(nearby, g.grid[cell]...)
        }
    }
    return nearby
}
```

## Error Handling and Resilience

### 1. Graceful Degradation

```go
func (a *Aquarium) HandleViewerError(viewerID string, err error) {
    log.Printf("Viewer %s error: %v", viewerID, err)
    
    // Try to recover from transient errors
    if isTransientError(err) {
        a.retryViewerOperation(viewerID)
        return
    }
    
    // For permanent errors, clean up gracefully
    a.RemoveViewer(viewerID)
}

func isTransientError(err error) bool {
    return strings.Contains(err.Error(), "broken pipe") ||
           strings.Contains(err.Error(), "connection reset")
}
```

### 2. Resource Cleanup

```go
func (a *Aquarium) Shutdown() {
    a.mu.Lock()
    defer a.mu.Unlock()
    
    if !a.running {
        return
    }
    
    a.running = false
    close(a.shutdown)
    
    // Stop animation
    if a.animationTicker != nil {
        a.animationTicker.Stop()
    }
    
    // Close all viewer connections
    for _, viewer := range a.viewers {
        viewer.Close()
    }
    
    // Clear all fish
    a.fish = make(map[int]*Fish)
}
```

## Configuration

### Environment Variables
```bash
SSH_PORT=1234
SSH_HOST_KEY_PATH=./ssh_keys/host_key_rsa_4096
MAX_CONNECTIONS=100
FISH_PER_CONNECTION=100
ANIMATION_FPS=60
LOG_LEVEL=info
```

### Runtime Tuning
```go
type Config struct {
    SSHPort            int           `env:"SSH_PORT" default:"1234"`
    SSHHostKeyPath     string        `env:"SSH_HOST_KEY_PATH" default:"./ssh_keys/host_key_rsa_4096"`
    MaxConnections     int           `env:"MAX_CONNECTIONS" default:"100"`
    FishPerConnection  int           `env:"FISH_PER_CONNECTION" default:"100"`
    AnimationFPS       int           `env:"ANIMATION_FPS" default:"60"`
    WorkerPoolSize     int           `env:"WORKER_POOL_SIZE" default:"4"`
    BroadcastTimeout   time.Duration `env:"BROADCAST_TIMEOUT" default:"100ms"`
    TerminalTimeout    time.Duration `env:"TERMINAL_TIMEOUT" default:"2s"`
}
```

## Testing Strategy

### 1. Load Testing
- Simulate multiple concurrent SSH connections
- Test with varying numbers of fish (100-1000 per connection)
- Measure memory usage and CPU utilization
- Verify 60 FPS maintenance under load

### 2. Integration Testing
- SSH connection lifecycle (connect, interact, disconnect)
- Mouse event handling accuracy
- Terminal size detection across different terminals
- Kitty Graphics Protocol compliance

### 3. Performance Benchmarks
- Animation loop latency
- Fish physics calculation throughput
- Memory allocation patterns
- Network I/O efficiency

## Migration Benefits

### Go-Specific Advantages
1. **Concurrency**: Goroutines provide lightweight concurrency for handling many connections
2. **Performance**: Compiled binary with lower memory footprint and better CPU utilization
3. **Type Safety**: Strong typing prevents runtime errors common in dynamic languages
4. **Standard Library**: Built-in SSH package and excellent networking support
5. **Memory Management**: Garbage collector with better performance characteristics than Node.js
6. **Cross-Platform**: Single binary deployment across different platforms

### Expected Performance Improvements
- **Memory Usage**: 50-70% reduction compared to Node.js
- **CPU Efficiency**: 30-50% better CPU utilization
- **Latency**: Lower animation frame jitter and more consistent timing
- **Concurrent Connections**: Support for 2-3x more simultaneous connections
- **Startup Time**: Faster cold start compared to Node.js process

## Implementation Timeline

1. **Phase 1** (Week 1): Core SSH server and basic connection handling
2. **Phase 2** (Week 1): Aquarium state management and fish entities
3. **Phase 3** (Week 2): Animation loop and physics engine
4. **Phase 4** (Week 2): Kitty Graphics Protocol implementation
5. **Phase 5** (Week 3): Mouse interaction and terminal detection
6. **Phase 6** (Week 3): Performance optimization and testing
7. **Phase 7** (Week 4): Documentation and deployment preparation

This specification provides a comprehensive roadmap for migrating the Node.js SSH aquarium to Go while leveraging Go's concurrency strengths and achieving better performance characteristics.