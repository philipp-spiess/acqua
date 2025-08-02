package aquarium

import (
	"log"
	"sync"
	"sync/atomic"
	"time"
)

type Manager struct {
	mu            sync.RWMutex
	fish          map[uint64]*Fish
	connections   map[uint64]*Connection
	termConfig    *TerminalConfig
	animationStop chan struct{}
	animationWg   sync.WaitGroup
	fishCounter   atomic.Uint64
	connCounter   atomic.Uint64
	debugMode     bool
	lastUpdate    time.Time
}

type TerminalConfig struct {
	Columns    int
	Rows       int
	CellWidth  int
	CellHeight int
}

type Connection struct {
	ID       uint64
	Stream   ConnectionStream
	FishIDs  []uint64
	mu       sync.Mutex
}

type ConnectionStream interface {
	Write([]byte) error
	Close() error
}

func NewManager() *Manager {
	return &Manager{
		fish:        make(map[uint64]*Fish),
		connections: make(map[uint64]*Connection),
	}
}

func (m *Manager) SetDebugMode(debug bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.debugMode = debug
}

func (m *Manager) AddConnection(stream ConnectionStream) uint64 {
	connID := m.connCounter.Add(1)
	
	conn := &Connection{
		ID:      connID,
		Stream:  stream,
		FishIDs: make([]uint64, 0, 100),
	}
	
	m.mu.Lock()
	m.connections[connID] = conn
	isFirst := len(m.connections) == 1
	m.mu.Unlock()
	
	// If first connection, we'll start animation after terminal detection
	if isFirst {
		// Animation will be started by connection handler after terminal detection
	}
	
	return connID
}

func (m *Manager) RemoveConnection(connID uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	conn, exists := m.connections[connID]
	if !exists {
		return
	}
	
	// Remove fish owned by this connection
	for _, fishID := range conn.FishIDs {
		if fish, ok := m.fish[fishID]; ok {
			// Trigger poof effect before removal
			m.createPoofEffect(fish)
			delete(m.fish, fishID)
		}
	}
	
	delete(m.connections, connID)
	
	// Stop animation if no more connections
	if len(m.connections) == 0 && m.animationStop != nil {
		close(m.animationStop)
		m.animationWg.Wait()
		m.animationStop = nil
		m.termConfig = nil
		m.fishCounter.Store(0)
	}
}

func (m *Manager) SetTerminalConfig(config *TerminalConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.termConfig = config
}

func (m *Manager) GetTerminalConfig() *TerminalConfig {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.termConfig
}

func (m *Manager) AddFish(connID uint64, count int) []uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	conn, exists := m.connections[connID]
	if !exists || m.termConfig == nil {
		return nil
	}
	
	// Always spawn only 1 fish per connection
	count = 1
	
	fishIDs := make([]uint64, 0, count)
	termPixelWidth := m.termConfig.Columns * m.termConfig.CellWidth
	termPixelHeight := m.termConfig.Rows * m.termConfig.CellHeight
	
	for i := 0; i < count; i++ {
		fishID := m.fishCounter.Add(1)
		fish := NewFish(fishID, connID, termPixelWidth, termPixelHeight, m.termConfig.CellWidth, m.termConfig.CellHeight)
		
		m.fish[fishID] = fish
		conn.FishIDs = append(conn.FishIDs, fishID)
		fishIDs = append(fishIDs, fishID)
	}
	
	return fishIDs
}

func (m *Manager) StartAnimation() {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	if m.animationStop != nil {
		return // Already running
	}
	
	m.animationStop = make(chan struct{})
	m.animationWg.Add(1)
	m.lastUpdate = time.Now()
	
	go m.animationLoop()
}

func (m *Manager) animationLoop() {
	defer m.animationWg.Done()
	
	// Use 1 FPS in debug mode, 30 FPS otherwise
	interval := 33333333 * time.Nanosecond // ~30 FPS
	m.mu.RLock()
	debugMode := m.debugMode
	stopChan := m.animationStop
	m.mu.RUnlock()
	
	if debugMode {
		interval = time.Second // 1 FPS
		log.Printf("Animation loop starting in debug mode (1 FPS)")
	} else {
		log.Printf("Animation loop starting in normal mode (30 FPS)")
	}
	
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	
	for {
		select {
		case <-stopChan:
			log.Printf("Animation loop received stop signal")
			return
		case <-ticker.C:
			m.updateAndBroadcast()
		}
	}
}

func (m *Manager) updateAndBroadcast() {
	// Check if we should stop first (without any locks)
	m.mu.RLock()
	stopChan := m.animationStop
	m.mu.RUnlock()
	
	if stopChan != nil {
		select {
		case <-stopChan:
			return
		default:
		}
	}

	m.mu.Lock()
	
	if len(m.connections) == 0 || m.termConfig == nil {
		m.mu.Unlock()
		return
	}
	
	// Calculate delta time
	now := time.Now()
	deltaTime := now.Sub(m.lastUpdate).Seconds() // Raw delta time in seconds
	m.lastUpdate = now
	
	// Copy data we need while holding lock
	fishData := make([]*Fish, 0, len(m.fish))
	for _, fish := range m.fish {
		fishData = append(fishData, fish)
	}
	termConfig := m.termConfig
	debugMode := m.debugMode
	
	// Copy connections for broadcasting
	connData := make([]ConnectionStream, 0, len(m.connections))
	for _, conn := range m.connections {
		connData = append(connData, conn.Stream)
	}
	
	m.mu.Unlock()
	
	// Update fish without holding lock
	updateBuf := NewUpdateBuffer()
	fishCount := 0
	for _, fish := range fishData {
		fish.Update(termConfig, deltaTime)
		fish.Render(updateBuf, termConfig)
		fishCount++
	}
	
	// Get render output
	output := updateBuf.String()
	
	// Debug logging
	if debugMode && fishCount > 0 {
		log.Printf("Animation tick: updating %d fish, output length: %d", fishCount, len(output))
	}
	
	// Broadcast to all connections
	for _, conn := range connData {
		conn.Write([]byte(output))
	}
}

func (m *Manager) HandleMouseClick(connID uint64, button, col, row int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	if m.termConfig == nil || button != 0 { // Only handle left click
		return
	}
	
	mouseX := (col - 1) * m.termConfig.CellWidth
	mouseY := (row - 1) * m.termConfig.CellHeight
	
	// Check collision with fish
	for _, fish := range m.fish {
		if fish.CheckCollision(mouseX, mouseY) {
			// Only allow clicking own fish
			if fish.OwnerID != connID {
				continue
			}
			
			fish.OnClick()
			break
		}
	}
}

func (m *Manager) createPoofEffect(fish *Fish) {
	// TODO: Implement poof effect
	// For now, we'll just log it
}

func (m *Manager) Broadcast(data []byte) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	
	for _, conn := range m.connections {
		conn.Stream.Write(data)
	}
}

func (m *Manager) GetFishCount() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.fish)
}

func (m *Manager) Stop() {
	log.Printf("Stopping aquarium manager...")
	
	m.mu.Lock()
	
	// Signal stop and wait for animation to finish
	if m.animationStop != nil {
		log.Printf("Stopping animation loop...")
		close(m.animationStop)
		m.animationStop = nil
		
		// Release lock before waiting
		m.mu.Unlock()
		
		// Wait for animation to stop with timeout
		done := make(chan struct{})
		go func() {
			m.animationWg.Wait()
			close(done)
		}()
		
		select {
		case <-done:
			log.Printf("Animation loop stopped")
		case <-time.After(2 * time.Second):
			log.Printf("Animation loop stop timeout")
		}
		
		// Reacquire lock for cleanup
		m.mu.Lock()
	}
	
	// Close all connections
	log.Printf("Closing %d connections...", len(m.connections))
	for _, conn := range m.connections {
		conn.Stream.Close()
	}
	
	// Clear state
	m.fish = make(map[uint64]*Fish)
	m.connections = make(map[uint64]*Connection)
	m.termConfig = nil
	m.fishCounter.Store(0)
	m.connCounter.Store(0)
	
	m.mu.Unlock()
	
	log.Printf("Aquarium manager stopped")
}