package aquarium

import (
	"fmt"
	"strings"
)

type UpdateBuffer struct {
	commands []string
}

func NewUpdateBuffer() *UpdateBuffer {
	return &UpdateBuffer{
		commands: make([]string, 0, 1000),
	}
}

func (b *UpdateBuffer) AddClearCell(row, col int) {
	b.commands = append(b.commands, fmt.Sprintf("\x1b[%d;%dH ", row, col))
}

func (b *UpdateBuffer) AddText(row, col int, text string) {
	b.commands = append(b.commands, fmt.Sprintf("\x1b[%d;%dH%s", row, col, text))
}

func (b *UpdateBuffer) AddFishPlacement(row, col, imageID int, placementID uint64, width, height, xOffset, yOffset int) {
	// Move cursor to position
	b.commands = append(b.commands, fmt.Sprintf("\x1b[%d;%dH", row, col))
	
	// Add Kitty graphics placement command
	b.commands = append(b.commands, fmt.Sprintf("\x1b_Ga=p,i=%d,p=%d,c=%d,r=%d,C=1,X=%d,Y=%d,q=1\x1b\\", 
		imageID, placementID, width, height, xOffset, yOffset))
}

func (b *UpdateBuffer) AddDeletePlacement(imageID int, placementID uint64) {
	b.commands = append(b.commands, fmt.Sprintf("\x1b_Ga=d,d=i,i=%d,p=%d,q=1\x1b\\", imageID, placementID))
}

func (b *UpdateBuffer) String() string {
	return strings.Join(b.commands, "")
}