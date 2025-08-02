package aquarium

import (
	"fmt"
	"log"
	"math/rand"
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
	aquarium      *Aquarium
}

type Aquarium struct {
	FloorTileID     int
	StartTime       time.Time
	FloorRendered   bool
	LastStatusUpdate time.Time
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
	Username string
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

func (m *Manager) AddConnection(stream ConnectionStream, username string) uint64 {
	connID := m.connCounter.Add(1)
	
	conn := &Connection{
		ID:       connID,
		Stream:   stream,
		FishIDs:  make([]uint64, 0, 100),
		Username: username,
	}
	
	m.mu.Lock()
	m.connections[connID] = conn
	isFirst := len(m.connections) == 1
	m.mu.Unlock()
	
	// If first connection, create aquarium
	if isFirst {
		now := time.Now()
		m.aquarium = &Aquarium{
			FloorTileID:      rand.Intn(6), // Random floor tile 0-5
			StartTime:        now,
			FloorRendered:    false,
			LastStatusUpdate: now,
		}
		log.Printf("Created new aquarium with floor tile %d", m.aquarium.FloorTileID)
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
	
	// Stop animation and destroy aquarium if no more connections
	if len(m.connections) == 0 && m.animationStop != nil {
		log.Printf("Destroying aquarium - no more connections")
		close(m.animationStop)
		m.animationWg.Wait()
		m.animationStop = nil
		m.termConfig = nil
		m.aquarium = nil
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
		fish := NewFish(fishID, connID, termPixelWidth, termPixelHeight, m.termConfig.CellWidth, m.termConfig.CellHeight, conn.Username)
		
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
	
	// Render floor (once) and status bar (1 FPS) if aquarium exists
	m.mu.Lock()
	aquarium := m.aquarium
	renderStatus := false
	
	if aquarium != nil {
		// Render floor tiles only once
		if !aquarium.FloorRendered {
			m.renderFloor(updateBuf, termConfig, aquarium)
			aquarium.FloorRendered = true
		}
		
		// Check if we should render status bar (1 FPS = every 1 second)
		now := time.Now()
		if now.Sub(aquarium.LastStatusUpdate) >= time.Second {
			renderStatus = true
			aquarium.LastStatusUpdate = now
		}
	}
	m.mu.Unlock()
	
	// Render status bar only when needed (1 FPS)
	if renderStatus {
		m.renderStatus(updateBuf, termConfig, aquarium)
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

func (m *Manager) GetAquarium() *Aquarium {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.aquarium
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

func (m *Manager) renderFloor(buf *UpdateBuffer, config *TerminalConfig, aquarium *Aquarium) {
	// Floor tiles are rendered at the second-to-last row (leaving one row for status)
	floorRow := config.Rows - 1
	
	// Floor tile rendering - repeat across the width
	// Each floor tile image is 48x48 pixels (from 3x2 grid split)
	tilePixelSize := 48
	tileWidth := (tilePixelSize + config.CellWidth - 1) / config.CellWidth
	tileHeight := (tilePixelSize + config.CellHeight - 1) / config.CellHeight
	
	// Ensure floor tiles don't extend into status bar row
	// If tile height > 1, we need to position floor higher to avoid overlap
	if tileHeight > 1 {
		floorRow = config.Rows - tileHeight
	}
	
	// Calculate how many tiles we need to cover the width
	tilesNeeded := (config.Columns + tileWidth - 1) / tileWidth
	
	// Floor image IDs start at 10 (after fish images 1,2)
	floorImageID := 10 + aquarium.FloorTileID
	
	for i := 0; i < tilesNeeded; i++ {
		col := i*tileWidth + 1
		if col <= config.Columns {
			placementID := uint64(1000 + i) // Unique placement IDs for floor tiles
			buf.AddFloorTilePlacement(floorRow, col, floorImageID, placementID, tileWidth, tileHeight)
		}
	}
}

func (m *Manager) renderStatus(buf *UpdateBuffer, config *TerminalConfig, aquarium *Aquarium) {
	// Status bar at the last row
	statusRow := config.Rows
	
	// Clear the status row first
	for i := 1; i <= config.Columns; i++ {
		buf.AddClearCell(statusRow, i)
	}
	
	// Get current fish data for username positioning
	m.mu.RLock()
	fishData := make([]*Fish, 0, len(m.fish))
	for _, fish := range m.fish {
		fishData = append(fishData, fish)
	}
	m.mu.RUnlock()
	
	// Render usernames under fish positions
	for _, fish := range fishData {
		// Calculate fish center position in terminal cells
		fishCenterX := fish.PosX + ImagePixelWidth/2
		fishCol := int(fishCenterX/float64(config.CellWidth)) + 1
		
		// Truncate username if needed and center it under the fish
		username := fish.Username
		if len(username) > 12 { // Limit username length to prevent overlap
			username = username[:12]
		}
		
		// Center username under fish
		usernameStartCol := fishCol - len(username)/2
		if usernameStartCol < 1 {
			usernameStartCol = 1
		}
		if usernameStartCol + len(username) - 1 > config.Columns {
			usernameStartCol = config.Columns - len(username) + 1
			if usernameStartCol < 1 {
				usernameStartCol = 1
				// Truncate further if terminal is very narrow
				if len(username) > config.Columns {
					username = username[:config.Columns]
				}
			}
		}
		
		buf.AddStatusText(statusRow, usernameStartCol, username)
	}
	
	// Calculate connected duration
	duration := time.Since(aquarium.StartTime)
	durationStr := formatDuration(duration)
	
	// Position duration text on the right side, ensuring it doesn't overlap usernames
	statusCol := config.Columns - len(durationStr) + 1
	if statusCol < 1 {
		statusCol = 1
	}
	
	buf.AddStatusText(statusRow, statusCol, durationStr)
}

func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%.0fs", d.Seconds())
	} else if d < time.Hour {
		return fmt.Sprintf("%.0fm", d.Minutes())
	} else {
		return fmt.Sprintf("%.0fh", d.Hours())
	}
}