const fs = require('fs');
const os = require('os');

// --- Kitty Graphics Protocol Helpers ---

const kittyCommand = (payload) => {
  process.stdout.write(`\x1b_G${payload}\x1b\\`);
};

const uploadImage = (data, imageId) => {
  const base64Data = data.toString('base64');
  const chunkSize = 4096;
  let currentPos = 0;

  while (currentPos < base64Data.length) {
    const chunk = base64Data.slice(currentPos, currentPos + chunkSize);
    const isFirst = currentPos === 0;
    const moreChunks = (currentPos + chunkSize) < base64Data.length;

    let command;
    if (isFirst) {
      command = `a=t,f=100,i=${imageId},m=${moreChunks ? 1 : 0},q=1`;
    } else {
      command = `m=${moreChunks ? 1 : 0}`;
    }
    
    kittyCommand(`${command};${chunk}`);
    currentPos += chunkSize;
  }
};

const placeImage = (imageId, placementId, { col, row, width, height, xOffset = 0, yOffset = 0 }) => {
    // Move cursor to the cell where the top-left of the image should be anchored
    process.stdout.write(`\x1b[${Math.round(row)};${Math.round(col)}H`);
    // Use C=1 to prevent the cursor from moving, which gives us full control
    kittyCommand(`a=p,i=${imageId},p=${placementId},c=${width},r=${height},C=1,X=${Math.round(xOffset)},Y=${Math.round(yOffset)},q=1`);
}

const deletePlacement = (imageId, placementId) => {
    kittyCommand(`a=d,d=i,i=${imageId},p=${placementId},q=1`);
}

const clearScreen = () => {
    process.stdout.write('\x1b[2J');
}

// --- Helper to get terminal cell size ---
function getCellSize() {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      process.stdin.removeListener('data', onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      reject(new Error('Terminal did not report cell size in time.'));
    }, 1000);

    const onData = (data) => {
      // Response for CSI 16 t is ESC [ 6 ; height ; width t
      const match = data.toString().match(/\x1b\[6;(\d+);(\d+)t/);
      if (match) {
        clearTimeout(timeout);
        process.stdin.removeListener('data', onData);
        process.stdin.setRawMode(false);
        process.stdin.pause();
        resolve({ height: parseInt(match[1], 10), width: parseInt(match[2], 10) });
      }
    };
    
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on('data', onData);
    process.stdout.write('\x1b[16t');
  });
}


// --- Main Animation Logic ---

async function main() {
  // Get terminal cell size in pixels
  let cellSize;
  try {
    cellSize = await getCellSize();
  } catch (e) {
    console.error(`Warning: ${e.message} Using an estimated cell size (8x16 pixels). For accurate positioning, please use a compatible terminal like Kitty, WezTerm, or Ghostty.`);
    cellSize = { width: 8, height: 16 };
  }
  const cellWidth = cellSize.width;
  const cellHeight = cellSize.height;

  const imageIdLeft = 1;
  const imageIdRight = 2;
  const placementId = 1;
  
  // Fixed 64x36px (2x original size)
  const imagePixelWidth = 64;
  const imagePixelHeight = 36;
  const imageCellWidth = Math.ceil(imagePixelWidth / cellWidth);
  const imageCellHeight = Math.ceil(imagePixelHeight / cellHeight);

  let termColumns = process.stdout.columns || 80;
  let termRows = process.stdout.rows || 24;
  let termPixelWidth = termColumns * cellWidth;
  let termPixelHeight = termRows * cellHeight;

  // Start position in pixels (center of screen)
  let pX = (termPixelWidth - imagePixelWidth) / 2;
  let pY = (termPixelHeight - imagePixelHeight) / 2;

  // Slower speed in pixels per frame
  let dx = 0.04 * cellWidth;
  let dy = 0.01 * cellHeight;

  // Step function bobbing variables (more noticeable)
  let bobbingTime = 0;
  const bobbingAmplitude = 12; // pixels
  const bobbingFrequency = 0.08; // steps per frame

  // Bubble system
  let bubbles = [];
  let bubbleSpawnTimer = 0;
  const bubbleSpawnRate = 0.001; // chance per frame
  const bubbleChars = ['°', 'o', 'O', '•'];
  const bubbleSpeed = 4.0; // pixels per frame

  process.stdout.on('resize', () => {
      termColumns = process.stdout.columns || 80;
      termRows = process.stdout.rows || 24;
      termPixelWidth = termColumns * cellWidth;
      termPixelHeight = termRows * cellHeight;
      clearScreen();
  });

  process.stdout.write('\x1b[?25l'); // Hide cursor
  process.stdout.write('\x1b[?1000h'); // Enable mouse click reporting
  process.stdout.write('\x1b[?1002h'); // Enable mouse drag reporting
  clearScreen();

  let hasRightFish = false;
  try {
    const imageLeftData = fs.readFileSync('fish.png');
    uploadImage(imageLeftData, imageIdLeft);

    if (fs.existsSync('fish-right.png')) {
        const imageRightData = fs.readFileSync('fish-right.png');
        uploadImage(imageRightData, imageIdRight);
        hasRightFish = true;
    } else {
        uploadImage(imageLeftData, imageIdRight);
    }
  } catch (error) {
    console.error('Error reading image files:', error.message);
    process.exit(1);
  }

  const animationInterval = setInterval(() => {
    const previousImageId = dx > 0 && hasRightFish ? imageIdRight : imageIdLeft;

    // Update position in pixels
    pX += dx;
    pY += dy;

    // Wall bouncing logic in pixels
    if (pX + imagePixelWidth > termPixelWidth) {
        dx = -Math.abs(dx);
        pX = termPixelWidth - imagePixelWidth;
    } else if (pX < 0) {
        dx = Math.abs(dx);
        pX = 0;
    }

    if (pY + imagePixelHeight > termPixelHeight) {
        dy = -Math.abs(dy);
        pY = termPixelHeight - imagePixelHeight;
    } else if (pY < 0) {
        dy = Math.abs(dy);
        pY = 0;
    }

    // Step function bobbing (ASCII art style)
    bobbingTime += bobbingFrequency;
    const bobbingOffset = Math.floor(bobbingTime) % 2 === 0 ? 0 : bobbingAmplitude;

    // Calculate cell and offset for placement with bobbing
    const finalY = pY + bobbingOffset;
    const col = Math.floor(pX / cellWidth) + 1;
    const xOffset = pX % cellWidth;
    const row = Math.floor(finalY / cellHeight) + 1;
    const yOffset = finalY % cellHeight;

    // Spawn bubbles occasionally from fish head
    if (Math.random() < bubbleSpawnRate) {
      bubbles.push({
        x: pX + imagePixelWidth / 2, // center of fish head
        y: finalY - 2, // slightly above fish
        char: bubbleChars[Math.floor(Math.random() * bubbleChars.length)],
        age: 0,
        prevCol: null,
        prevRow: null
      });
    }

    // Update and render bubbles
    bubbles = bubbles.filter(bubble => {
      // Clear previous position
      if (bubble.prevCol && bubble.prevRow) {
        process.stdout.write(`\x1b[${bubble.prevRow};${bubble.prevCol}H `);
      }
      
      bubble.y -= bubbleSpeed;
      bubble.age++;
      
      // Remove bubbles that are off screen
      if (bubble.y < 0) return false;
      
      // Calculate bubble position in terminal cells
      const bubbleCol = Math.floor(bubble.x / cellWidth) + 1;
      const bubbleRow = Math.floor(bubble.y / cellHeight) + 1;
      
      // Only draw if within terminal bounds
      if (bubbleCol >= 1 && bubbleCol <= termColumns && bubbleRow >= 1 && bubbleRow <= termRows) {
        // Move cursor and draw bubble
        process.stdout.write(`\x1b[${bubbleRow};${bubbleCol}H${bubble.char}`);
        bubble.prevCol = bubbleCol;
        bubble.prevRow = bubbleRow;
      }
      
      return true;
    });
    
    const currentImageId = dx > 0 && hasRightFish ? imageIdRight : imageIdLeft;

    if (currentImageId !== previousImageId) {
        deletePlacement(previousImageId, placementId);
    }

    // Always render fish last to ensure it overlays bubbles
    placeImage(currentImageId, placementId, {
        col,
        row,
        width: imageCellWidth,
        height: imageCellHeight,
        xOffset,
        yOffset
    });

  }, 16.66); // ~60 FPS

  // Mouse event handling
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on('data', (data) => {
    const sequence = data.toString();
    
    // Parse mouse click events (ESC[M followed by 3 bytes)
    if (sequence.startsWith('\x1b[M') && sequence.length >= 6) {
      const button = sequence.charCodeAt(3) - 32;
      const mouseCol = sequence.charCodeAt(4) - 32;
      const mouseRow = sequence.charCodeAt(5) - 32;
      
      // Check if click is on fish (button 0 = left click, 3 = release)
      if (button === 0) {
        const mouseX = (mouseCol - 1) * cellWidth;
        const mouseY = (mouseRow - 1) * cellHeight;
        
        // Check collision with fish
        if (mouseX >= pX && mouseX <= pX + imagePixelWidth &&
            mouseY >= pY && mouseY <= pY + imagePixelHeight) {
          // Clear current placement before changing direction
          const currentImageId = dx > 0 && hasRightFish ? imageIdRight : imageIdLeft;
          deletePlacement(currentImageId, placementId);
          
          // Spawn a few bubbles when clicked
          for (let i = 0; i < 3; i++) {
            bubbles.push({
              x: pX + imagePixelWidth / 2 + (Math.random() - 0.5) * 20, // slight random spread
              y: pY - 2 - i * 5, // staggered vertically
              char: bubbleChars[Math.floor(Math.random() * bubbleChars.length)],
              age: 0,
              prevCol: null,
              prevRow: null
            });
          }
          
          // Random direction change: 90, 180, or 260 degrees
          const angles = [90, 180, 260];
          const randomAngle = angles[Math.floor(Math.random() * angles.length)];
          const radians = (randomAngle * Math.PI) / 180;
          
          // Rotate velocity vector
          const newDx = dx * Math.cos(radians) - dy * Math.sin(radians);
          const newDy = dx * Math.sin(radians) + dy * Math.cos(radians);
          
          dx = newDx;
          dy = newDy;
        }
      }
    }
    
    // Handle Ctrl+C
    if (sequence === '\x03') {
      cleanup();
    }
  });

  const cleanup = () => {
    clearInterval(animationInterval);
    deletePlacement(imageIdLeft, placementId);
    if (hasRightFish) deletePlacement(imageIdRight, placementId);
    clearScreen();
    process.stdout.write('\x1b[?1000l'); // Disable mouse reporting
    process.stdout.write('\x1b[?1002l'); // Disable mouse drag reporting
    process.stdout.write('\x1b[?25h'); // Show cursor
    process.stdin.setRawMode(false);
    process.stdin.pause();
    console.log('\nAnimation stopped.');
    process.exit(0);
  };

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

main().catch(console.error);