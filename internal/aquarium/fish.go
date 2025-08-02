package aquarium

import (
	"math"
	"math/rand"
)

const (
	ImagePixelWidth  = 64
	ImagePixelHeight = 36
	BobbingAmplitude = 12
	BobbingFrequency = 4.8  // bobbing cycles per second (was 0.08 * 60fps)
	BubbleSpawnRate  = 0.06 // bubbles per second (was 0.001 * 60fps)
	BubbleSpeed      = 240.0 // pixels per second (was 4.0 * 60fps)
)

type Fish struct {
	ID          uint64
	OwnerID     uint64
	PlacementID uint64
	PosX        float64
	PosY        float64
	VelX        float64
	VelY        float64
	BobbingTime float64
	Bubbles     []*Bubble
	LastImageID int
	BubblesToClear []struct{ Row, Col int }
	Username    string
	Color       string
}

type Bubble struct {
	X       float64
	Y       float64
	Char    string
	Age     int
	PrevCol int
	PrevRow int
}

func NewFish(id, ownerID uint64, termWidth, termHeight, cellWidth, cellHeight int, username, color string) *Fish {
	// Reserve space for floor tiles and status bar
	// Floor tiles are 48x48 pixels, so they might take more than 1 row
	tilePixelSize := 48
	tileHeight := (tilePixelSize + cellHeight - 1) / cellHeight
	floorHeight := tileHeight * cellHeight
	statusHeight := cellHeight
	usableHeight := termHeight - floorHeight - statusHeight
	
	return &Fish{
		ID:          id,
		OwnerID:     ownerID,
		PlacementID: id,
		PosX:        rand.Float64() * float64(termWidth-ImagePixelWidth),
		PosY:        rand.Float64() * float64(usableHeight-ImagePixelHeight),
		VelX:        (rand.Float64() - 0.5) * 4.8 * float64(cellWidth),  // pixels per second (was 0.08 * 60fps)
		VelY:        (rand.Float64() - 0.5) * 1.2 * float64(cellHeight), // pixels per second (was 0.02 * 60fps)
		BobbingTime: rand.Float64() * 100,
		Bubbles:     make([]*Bubble, 0),
		Username:    username,
		Color:       color,
	}
}

func (f *Fish) Update(config *TerminalConfig, deltaTime float64) {
	termPixelWidth := float64(config.Columns * config.CellWidth)
	termPixelHeight := float64(config.Rows * config.CellHeight)
	
	// Reserve space for floor tiles and status bar
	// Floor tiles are 48x48 pixels, so they might take more than 1 row
	tilePixelSize := 48.0
	tileHeight := (tilePixelSize + float64(config.CellHeight) - 1) / float64(config.CellHeight)
	floorHeight := tileHeight * float64(config.CellHeight)
	statusHeight := float64(config.CellHeight)
	usableHeight := termPixelHeight - floorHeight - statusHeight
	
	// Update position with delta time scaling
	f.PosX += f.VelX * deltaTime
	f.PosY += f.VelY * deltaTime
	
	// Wall bouncing
	if f.PosX+ImagePixelWidth > termPixelWidth {
		f.VelX = -math.Abs(f.VelX)
		f.PosX = termPixelWidth - ImagePixelWidth
	} else if f.PosX < 0 {
		f.VelX = math.Abs(f.VelX)
		f.PosX = 0
	}
	
	// Prevent fish from touching the floor (keep fish in usable area)
	if f.PosY+ImagePixelHeight > usableHeight {
		f.VelY = -math.Abs(f.VelY)
		f.PosY = usableHeight - ImagePixelHeight
	} else if f.PosY < 0 {
		f.VelY = math.Abs(f.VelY)
		f.PosY = 0
	}
	
	// Update bobbing
	f.BobbingTime += BobbingFrequency * deltaTime
	
	// Spawn bubbles occasionally (rate per second)
	if rand.Float64() < BubbleSpawnRate * deltaTime {
		f.spawnBubble()
	}
	
	// Update bubbles
	f.updateBubbles(config, deltaTime)
}

func (f *Fish) Render(buf *UpdateBuffer, config *TerminalConfig) {
	// Clear any bubbles that went off-screen
	for _, toClear := range f.BubblesToClear {
		buf.AddClearCell(toClear.Row, toClear.Col)
	}
	f.BubblesToClear = f.BubblesToClear[:0] // Clear the slice
	
	// Calculate bobbing offset (triangular wave: 0, 6, 12, 6, 0, 6, 12, 6...)
	bobbingOffset := 0.0
	step := int(f.BobbingTime) % 4
	switch step {
	case 0:
		bobbingOffset = 0                    // 0 pixels
	case 1:
		bobbingOffset = BobbingAmplitude / 2 // 6 pixels
	case 2:
		bobbingOffset = BobbingAmplitude     // 12 pixels
	case 3:
		bobbingOffset = BobbingAmplitude / 2 // 6 pixels
	}
	
	finalY := f.PosY + bobbingOffset
	col := int(f.PosX/float64(config.CellWidth)) + 1
	xOffset := int(f.PosX) % config.CellWidth
	row := int(finalY/float64(config.CellHeight)) + 1
	yOffset := int(finalY) % config.CellHeight
	
	// Render bubbles
	for _, bubble := range f.Bubbles {
		// Clear previous bubble position
		if bubble.PrevCol > 0 && bubble.PrevRow > 0 {
			buf.AddClearCell(bubble.PrevRow, bubble.PrevCol)
		}
		
		// Draw bubble at new position
		bubbleCol := int(bubble.X/float64(config.CellWidth)) + 1
		bubbleRow := int(bubble.Y/float64(config.CellHeight)) + 1
		
		if bubbleCol >= 1 && bubbleCol <= config.Columns && bubbleRow >= 1 && bubbleRow <= config.Rows {
			buf.AddText(bubbleRow, bubbleCol, bubble.Char)
			bubble.PrevCol = bubbleCol
			bubble.PrevRow = bubbleRow
		}
	}
	
	// Determine image ID based on direction
	imageID := 1 // left-facing
	if f.VelX > 0 {
		imageID = 2 // right-facing
	}
	
	// Delete old placement if image ID changed (like Node.js)
	if f.LastImageID != 0 && f.LastImageID != imageID {
		buf.AddDeletePlacement(f.LastImageID, f.PlacementID)
	}
	f.LastImageID = imageID
	
	// Calculate cell dimensions for image
	imageCellWidth := (ImagePixelWidth + config.CellWidth - 1) / config.CellWidth
	imageCellHeight := (ImagePixelHeight + config.CellHeight - 1) / config.CellHeight
	
	// Add fish placement command
	buf.AddFishPlacement(row, col, imageID, f.PlacementID, imageCellWidth, imageCellHeight, xOffset, yOffset)
}

func (f *Fish) CheckCollision(mouseX, mouseY int) bool {
	// Calculate bobbing offset (same as in Render)
	bobbingOffset := 0.0
	step := int(f.BobbingTime) % 4
	switch step {
	case 0:
		bobbingOffset = 0                    // 0 pixels
	case 1:
		bobbingOffset = BobbingAmplitude / 2 // 6 pixels
	case 2:
		bobbingOffset = BobbingAmplitude     // 12 pixels
	case 3:
		bobbingOffset = BobbingAmplitude / 2 // 6 pixels
	}
	
	// Use the actual rendered position (including bobbing)
	finalY := f.PosY + bobbingOffset
	
	return mouseX >= int(f.PosX) && mouseX <= int(f.PosX)+ImagePixelWidth &&
		mouseY >= int(finalY) && mouseY <= int(finalY)+ImagePixelHeight
}

func (f *Fish) OnClick() {
	// Spawn bubbles
	bubbleChars := []string{"°", "o", "O", "•"}
	for i := 0; i < 3; i++ {
		bubble := &Bubble{
			X:    f.PosX + 32 + (rand.Float64()-0.5)*20,
			Y:    f.PosY - 2 - float64(i*5),
			Char: bubbleChars[rand.Intn(len(bubbleChars))],
			Age:  0,
		}
		f.Bubbles = append(f.Bubbles, bubble)
	}
	
	// Random direction change
	angles := []float64{90, 180, 260}
	randomAngle := angles[rand.Intn(len(angles))]
	radians := randomAngle * math.Pi / 180
	
	// Rotate velocity vector
	newVelX := f.VelX*math.Cos(radians) - f.VelY*math.Sin(radians)
	newVelY := f.VelX*math.Sin(radians) + f.VelY*math.Cos(radians)
	
	f.VelX = newVelX
	f.VelY = newVelY
}

func (f *Fish) spawnBubble() {
	bubbleChars := []string{"°", "o", "O", "•"}
	bubble := &Bubble{
		X:    f.PosX + ImagePixelWidth/2,
		Y:    f.PosY - 2,
		Char: bubbleChars[rand.Intn(len(bubbleChars))],
		Age:  0,
	}
	f.Bubbles = append(f.Bubbles, bubble)
}

func (f *Fish) updateBubbles(config *TerminalConfig, deltaTime float64) {
	// Update bubbles and remove old ones
	activeBubbles := make([]*Bubble, 0, len(f.Bubbles))
	
	for _, bubble := range f.Bubbles {
		bubble.Y -= BubbleSpeed * deltaTime
		bubble.Age++
		
		// Keep bubble if still on screen (remove when Y < 0, like Node.js)
		if bubble.Y >= 0 {
			activeBubbles = append(activeBubbles, bubble)
		} else {
			// Store position to clear when bubble goes off screen
			if bubble.PrevCol > 0 && bubble.PrevRow > 0 {
				f.BubblesToClear = append(f.BubblesToClear, struct{ Row, Col int }{bubble.PrevRow, bubble.PrevCol})
			}
		}
	}
	
	f.Bubbles = activeBubbles
}