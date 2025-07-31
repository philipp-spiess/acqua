const { ShellServer, Authenticators } = require('ssh2-shell-server')
const fs = require('fs')

const PORT = 1234
const rsaKey = fs.readFileSync('./ssh_keys/host_key_rsa_4096')

// Simple shared state
const sharedAquarium = {
  viewers: new Set(),
  animationInterval: null,
  fish: new Map(), // fishId -> fish state
  terminalConfig: null
}
let connectionCounter = 0
let fishCounter = 0
const activeConnections = new Map() // connectionId -> stream

const server = new ShellServer({
  hostKeys: [rsaKey],
  port: PORT,
})

// Allow any user to connect (for demo purposes)
server.registerAuthenticator(new Authenticators.AuthenticateAny())

const broadcastToViewers = (data) => {
  sharedAquarium.viewers.forEach(connectionId => {
    const stream = activeConnections.get(connectionId)
    if (stream && stream.writable) {
      stream.write(data)
    }
  })
}

const createPoofEffect = (fish) => {
  if (!sharedAquarium.terminalConfig) return
  
  const config = sharedAquarium.terminalConfig
  
  // Simple poof effect - just show some characters at fish position briefly
  const fishCol = Math.floor((fish.pX + 32) / config.cellWidth) + 1
  const fishRow = Math.floor((fish.pY + 18) / config.cellHeight) + 1
  
  // Show poof characters around fish position
  const poofPositions = [
    { col: fishCol - 1, row: fishRow, char: '*' },
    { col: fishCol, row: fishRow, char: '💨' },
    { col: fishCol + 1, row: fishRow, char: '*' },
    { col: fishCol, row: fishRow - 1, char: '°' },
    { col: fishCol, row: fishRow + 1, char: '°' }
  ]
  
  // Show poof effect
  let poofOutput = ''
  poofPositions.forEach(pos => {
    if (pos.col >= 1 && pos.col <= config.termColumns && pos.row >= 1 && pos.row <= config.termRows) {
      poofOutput += `\x1b[${pos.row};${pos.col}H${pos.char}`
    }
  })
  broadcastToViewers(poofOutput)
  
  // Clear poof effect after a short delay
  setTimeout(() => {
    let clearOutput = ''
    poofPositions.forEach(pos => {
      if (pos.col >= 1 && pos.col <= config.termColumns && pos.row >= 1 && pos.row <= config.termRows) {
        clearOutput += `\x1b[${pos.row};${pos.col}H `
      }
    })
    broadcastToViewers(clearOutput)
    console.log('Poof effect cleared')
  }, 1000)
}

const addFish = (termColumns, termRows, cellWidth, cellHeight, ownerId) => {
  const fishId = ++fishCounter
  const termPixelWidth = termColumns * cellWidth
  const termPixelHeight = termRows * cellHeight
  
  const fish = {
    id: fishId,
    ownerId: ownerId, // Track which connection owns this fish
    pX: Math.random() * (termPixelWidth - 64),
    pY: Math.random() * (termPixelHeight - 36),
    dx: (Math.random() - 0.5) * 0.08 * cellWidth,
    dy: (Math.random() - 0.5) * 0.02 * cellHeight,
    bobbingTime: Math.random() * 100,
    bubbles: [],
    placementId: fishId
  }
  
  sharedAquarium.fish.set(fishId, fish)
  console.log(`Added fish #${fishId} (owned by connection ${ownerId}) to aquarium (total: ${sharedAquarium.fish.size})`)
  
  // Debug: Show all fish ownership
  console.log('Current fish ownership:')
  sharedAquarium.fish.forEach((f, id) => {
    console.log(`  Fish #${id} owned by connection ${f.ownerId}`)
  })
  
  return fish
}

const handleMouseClick = (sequence, termColumns, termRows, clickerConnectionId) => {
  if (!sharedAquarium.terminalConfig) return
  
  const button = sequence.charCodeAt(3) - 32
  const mouseCol = sequence.charCodeAt(4) - 32
  const mouseRow = sequence.charCodeAt(5) - 32
  
  console.log(`Mouse click: button=${button}, col=${mouseCol}, row=${mouseRow}`)
  
  // Check if click is on any fish (only left click)
  if (button === 0) {
    const mouseX = (mouseCol - 1) * sharedAquarium.terminalConfig.cellWidth
    const mouseY = (mouseRow - 1) * sharedAquarium.terminalConfig.cellHeight
    
    console.log(`Click position in pixels: (${mouseX}, ${mouseY})`)
    
    const bubbleChars = ['°', 'o', 'O', '•']
    let foundCollision = false
    
    // Check collision with each fish, but only allow clicking your own fish
    sharedAquarium.fish.forEach(fish => {
      console.log(`Checking fish #${fish.id} at (${fish.pX}, ${fish.pY}) owned by ${fish.ownerId}`)
      if (mouseX >= fish.pX && mouseX <= fish.pX + 64 &&
          mouseY >= fish.pY && mouseY <= fish.pY + 36) {
        
        foundCollision = true
        console.log(`HIT: Fish #${fish.id} collision detected`)
        
        // Only allow clicking your own fish
        if (fish.ownerId !== clickerConnectionId) {
          console.log(`BLOCKED: Connection ${clickerConnectionId} tried to click fish #${fish.id} owned by ${fish.ownerId}`)
          return
        }
        
        console.log(`ALLOWED: Connection ${clickerConnectionId} clicking their own fish #${fish.id}`)
        
        console.log(`Fish #${fish.id} clicked at (${mouseX}, ${mouseY})`)
        
        // Clear current placement before changing direction (like animate-fish.js)
        const hasRightFish = fs.existsSync('fish-right.png')
        const currentImageId = fish.dx > 0 && hasRightFish ? 2 : 1
        const deleteCommand = `\x1b_Ga=d,d=i,i=${currentImageId},p=${fish.placementId},q=1\x1b\\`
        broadcastToViewers(deleteCommand)
        
        // Spawn bubbles when clicked (like animate-fish.js)
        for (let i = 0; i < 3; i++) {
          fish.bubbles.push({
            x: fish.pX + 32 + (Math.random() - 0.5) * 20, // slight random spread
            y: fish.pY - 2 - i * 5, // staggered vertically
            char: bubbleChars[Math.floor(Math.random() * bubbleChars.length)],
            age: 0,
            prevCol: null,
            prevRow: null
          })
        }
        
        // Random direction change (like animate-fish.js)
        const angles = [90, 180, 260]
        const randomAngle = angles[Math.floor(Math.random() * angles.length)]
        const radians = (randomAngle * Math.PI) / 180
        
        // Rotate velocity vector
        const newDx = fish.dx * Math.cos(radians) - fish.dy * Math.sin(radians)
        const newDy = fish.dx * Math.sin(radians) + fish.dy * Math.cos(radians)
        
        fish.dx = newDx
        fish.dy = newDy
      }
    })
    
    if (!foundCollision) {
      console.log(`No collision found for click at (${mouseX}, ${mouseY})`)
    }
  }
}

const startSharedFishAnimation = (termColumns, termRows, cellWidth, cellHeight) => {
  console.log('Starting multi-fish aquarium animation...')
  
  // Store terminal config for mouse clicks
  sharedAquarium.terminalConfig = {
    termColumns,
    termRows,
    cellWidth,
    cellHeight
  }
  
  // Set up all viewers first
  sharedAquarium.viewers.forEach(connectionId => {
    const stream = activeConnections.get(connectionId)
    if (stream) {
      stream.write('\x1b[?25l') // Hide cursor
      stream.write('\x1b[?1000h') // Enable mouse click reporting
      stream.write('\x1b[?1002h') // Enable mouse drag reporting
      clearScreen(stream)
      
      // Upload images to each viewer
      try {
        const imageLeftData = fs.readFileSync('fish.png')
        uploadImage(stream, imageLeftData, 1)
        if (fs.existsSync('fish-right.png')) {
          const imageRightData = fs.readFileSync('fish-right.png')
          uploadImage(stream, imageRightData, 2)
        } else {
          uploadImage(stream, imageLeftData, 2)
        }
      } catch (error) {
        console.error('Error loading images:', error)
      }
    }
  })

  // Animation constants
  const termPixelWidth = termColumns * cellWidth
  const termPixelHeight = termRows * cellHeight
  const imageIdLeft = 1
  const imageIdRight = 2
  const imagePixelWidth = 64
  const imagePixelHeight = 36
  const imageCellWidth = Math.ceil(imagePixelWidth / cellWidth)
  const imageCellHeight = Math.ceil(imagePixelHeight / cellHeight)
  const bubbleChars = ['°', 'o', 'O', '•']
  const bubbleSpeed = 4.0
  const bobbingAmplitude = 12
  const bobbingFrequency = 0.08
  const bubbleSpawnRate = 0.001
  let hasRightFish = fs.existsSync('fish-right.png')

  // Animation loop for all fish
  sharedAquarium.animationInterval = setInterval(() => {
    if (sharedAquarium.viewers.size === 0) return

    let output = ''

    // Update each fish
    sharedAquarium.fish.forEach(fish => {
      const previousImageId = fish.dx > 0 && hasRightFish ? imageIdRight : imageIdLeft

      // Update position
      fish.pX += fish.dx
      fish.pY += fish.dy

      // Wall bouncing
      if (fish.pX + imagePixelWidth > termPixelWidth) {
        fish.dx = -Math.abs(fish.dx)
        fish.pX = termPixelWidth - imagePixelWidth
      } else if (fish.pX < 0) {
        fish.dx = Math.abs(fish.dx)
        fish.pX = 0
      }

      if (fish.pY + imagePixelHeight > termPixelHeight) {
        fish.dy = -Math.abs(fish.dy)
        fish.pY = termPixelHeight - imagePixelHeight
      } else if (fish.pY < 0) {
        fish.dy = Math.abs(fish.dy)
        fish.pY = 0
      }

      // Bobbing
      fish.bobbingTime += bobbingFrequency
      const bobbingOffset = Math.floor(fish.bobbingTime) % 2 === 0 ? 0 : bobbingAmplitude

      const finalY = fish.pY + bobbingOffset
      const col = Math.floor(fish.pX / cellWidth) + 1
      const xOffset = fish.pX % cellWidth
      const row = Math.floor(finalY / cellHeight) + 1
      const yOffset = finalY % cellHeight

      // Spawn bubbles occasionally
      if (Math.random() < bubbleSpawnRate) {
        fish.bubbles.push({
          x: fish.pX + imagePixelWidth / 2,
          y: finalY - 2,
          char: bubbleChars[Math.floor(Math.random() * bubbleChars.length)],
          age: 0,
          prevCol: null,
          prevRow: null
        })
      }

      // Update and render bubbles for this fish
      fish.bubbles = fish.bubbles.filter(bubble => {
        if (bubble.prevCol && bubble.prevRow) {
          output += `\x1b[${bubble.prevRow};${bubble.prevCol}H `
        }
        
        bubble.y -= bubbleSpeed
        bubble.age++
        
        if (bubble.y < 0) return false
        
        const bubbleCol = Math.floor(bubble.x / cellWidth) + 1
        const bubbleRow = Math.floor(bubble.y / cellHeight) + 1
        
        if (bubbleCol >= 1 && bubbleCol <= termColumns && bubbleRow >= 1 && bubbleRow <= termRows) {
          output += `\x1b[${bubbleRow};${bubbleCol}H${bubble.char}`
          bubble.prevCol = bubbleCol
          bubble.prevRow = bubbleRow
        }
        
        return true
      })
      
      const currentImageId = fish.dx > 0 && hasRightFish ? imageIdRight : imageIdLeft

      // Delete previous image placement when direction changes (like animate-fish.js)
      if (currentImageId !== previousImageId) {
        output += `\x1b_Ga=d,d=i,i=${previousImageId},p=${fish.placementId},q=1\x1b\\`
      }

      // Render this fish
      output += `\x1b[${Math.round(row)};${Math.round(col)}H`
      output += `\x1b_Ga=p,i=${currentImageId},p=${fish.placementId},c=${imageCellWidth},r=${imageCellHeight},C=1,X=${Math.round(xOffset)},Y=${Math.round(yOffset)},q=1\x1b\\`
    })

    // Broadcast all updates
    if (output) {
      broadcastToViewers(output)
    }

  }, 16.66) // ~60 FPS
}

// --- Kitty Graphics Protocol Helpers ---

const kittyCommand = (stream, payload) => {
  stream.write(`\x1b_G${payload}\x1b\\`)
}

const uploadImage = (stream, data, imageId) => {
  const base64Data = data.toString('base64')
  const chunkSize = 4096
  let currentPos = 0

  while (currentPos < base64Data.length) {
    const chunk = base64Data.slice(currentPos, currentPos + chunkSize)
    const isFirst = currentPos === 0
    const moreChunks = (currentPos + chunkSize) < base64Data.length

    let command
    if (isFirst) {
      command = `a=t,f=100,i=${imageId},m=${moreChunks ? 1 : 0},q=1`
    } else {
      command = `m=${moreChunks ? 1 : 0}`
    }
    
    kittyCommand(stream, `${command};${chunk}`)
    currentPos += chunkSize
  }
}

const placeImage = (stream, imageId, placementId, { col, row, width, height, xOffset = 0, yOffset = 0 }) => {
  // Move cursor to the cell where the top-left of the image should be anchored
  stream.write(`\x1b[${Math.round(row)};${Math.round(col)}H`)
  // Use C=1 to prevent the cursor from moving, which gives us full control
  kittyCommand(stream, `a=p,i=${imageId},p=${placementId},c=${width},r=${height},C=1,X=${Math.round(xOffset)},Y=${Math.round(yOffset)},q=1`)
}

const deletePlacement = (stream, imageId, placementId) => {
  kittyCommand(stream, `a=d,d=i,i=${imageId},p=${placementId},q=1`)
}

const clearScreen = (stream) => {
  stream.write('\x1b[2J')
}

server.on('session-created', ({ client, session }) => {
  session.on('stream-initialized', (stream) => {
    const connectionId = ++connectionCounter
    stream.setEncoding('utf8')
    
    // Add this viewer to our shared aquarium
    sharedAquarium.viewers.add(connectionId)
    activeConnections.set(connectionId, stream)
    
    // Get terminal dimensions
    let termColumns = stream.columns || 80
    let termRows = stream.rows || 24
    
    // Terminal detection to get proper cell size
    const detectTerminal = () => {
      return new Promise((resolve) => {
        let responseBuffer = ''
        let detectedCellWidth = 8 // fallback
        let detectedCellHeight = 16 // fallback
        
        const timeout = setTimeout(() => {
          resolve({ 
            cellWidth: detectedCellWidth, 
            cellHeight: detectedCellHeight
          })
        }, 2000)

        const dataHandler = (data) => {
          responseBuffer += data.toString()
          
          const pixelMatch = responseBuffer.match(/\x1b\[4;(\d+);(\d+)t/)
          if (pixelMatch) {
            const pixelHeight = parseInt(pixelMatch[1])
            const pixelWidth = parseInt(pixelMatch[2])
            
            detectedCellWidth = Math.round(pixelWidth / termColumns)
            detectedCellHeight = Math.round(pixelHeight / termRows)
            
            clearTimeout(timeout)
            stream.removeListener('data', dataHandler)
            resolve({ 
              cellWidth: detectedCellWidth, 
              cellHeight: detectedCellHeight
            })
          }
        }

        stream.on('data', dataHandler)
        stream.write('\x1b[14t') // Query window size in pixels
      })
    }
    
    // Get terminal info
    const termType = session.term || 'unknown'
    
    console.log(`Connection ${connectionId} joined. Total viewers: ${sharedAquarium.viewers.size}`)
    
    // If this is the first viewer, detect terminal and start animation
    if (sharedAquarium.viewers.size === 1) {
      console.log('First viewer - detecting terminal and starting animation')
      detectTerminal().then(detection => {
        const actualCellWidth = detection.cellWidth
        const actualCellHeight = detection.cellHeight
        console.log(`Detected cell size: ${actualCellWidth}x${actualCellHeight}`)
        
        // Add 100 fish for this session
        for (let i = 0; i < 100; i++) {
          addFish(termColumns, termRows, actualCellWidth, actualCellHeight, connectionId)
        }
        
        // Start animation
        startSharedFishAnimation(termColumns, termRows, actualCellWidth, actualCellHeight)
      })
    } else {
      // For additional viewers, add 100 fish and set up their terminal
      console.log('Adding 100 fish and viewer to existing aquarium')
      
      // Use existing terminal config if available
      const config = sharedAquarium.terminalConfig
      if (config) {
        for (let i = 0; i < 100; i++) {
          addFish(config.termColumns, config.termRows, config.cellWidth, config.cellHeight, connectionId)
        }
      }
      
      stream.write('\x1b[?25l') // Hide cursor
      stream.write('\x1b[?1000h') // Enable mouse click reporting
      stream.write('\x1b[?1002h') // Enable mouse drag reporting
      clearScreen(stream)
      
      // Upload images to this viewer
      try {
        const imageLeftData = fs.readFileSync('fish.png')
        uploadImage(stream, imageLeftData, 1)
        if (fs.existsSync('fish-right.png')) {
          const imageRightData = fs.readFileSync('fish-right.png')
          uploadImage(stream, imageRightData, 2)
        } else {
          uploadImage(stream, imageLeftData, 2)
        }
      } catch (error) {
        console.error('Error loading images for new viewer:', error)
      }
    }

    // Handle input (mouse events and Ctrl+C)
    stream.on('data', (data) => {
      const sequence = data.toString()
      
      // Handle Ctrl+C
      if (sequence === '\x03') {
        cleanup()
        return
      }
      
      // Handle mouse click events - forward to shared fish
      if (sequence.startsWith('\x1b[M') && sequence.length >= 6) {
        console.log(`Connection ${connectionId} sent mouse event: ${JSON.stringify(sequence)}`)
        handleMouseClick(sequence, termColumns, termRows, connectionId)
      }
    })

    const cleanup = () => {
      sharedAquarium.viewers.delete(connectionId)
      activeConnections.delete(connectionId)
      
      console.log(`Connection ${connectionId} left. Remaining viewers: ${sharedAquarium.viewers.size}`)
      
      // Find and remove fish owned by this connection with poof effect
      const fishToRemove = []
      sharedAquarium.fish.forEach(fish => {
        if (fish.ownerId === connectionId) {
          fishToRemove.push(fish)
        }
      })
      
      fishToRemove.forEach(fish => {
        console.log(`Creating poof effect for fish #${fish.id}`)
        createPoofEffect(fish)
        
        // Remove fish from aquarium first to stop normal animation
        sharedAquarium.fish.delete(fish.id)
        
        // Then delete the fish image placement 
        const deleteCommand = `\x1b_Ga=d,d=p,p=${fish.placementId},q=1\x1b\\`
        broadcastToViewers(deleteCommand)
        console.log(`Removed fish #${fish.id} (owned by disconnected connection ${connectionId})`)
      })
      
      // If no more viewers, stop the animation and clear all fish
      if (sharedAquarium.viewers.size === 0 && sharedAquarium.animationInterval) {
        console.log('Stopping aquarium animation - no more viewers')
        clearInterval(sharedAquarium.animationInterval)
        sharedAquarium.animationInterval = null
        sharedAquarium.fish.clear()
        sharedAquarium.terminalConfig = null
        fishCounter = 0 // Reset fish counter
      }
      
      stream.write('\x1b[?1000l') // Disable mouse reporting
      stream.write('\x1b[?1002l') // Disable mouse drag reporting
      stream.write('\x1b[?25h') // Show cursor
      clearScreen(stream)
      stream.write('\r\nAquarium session ended.\r\n')
      stream.end()
    }

    // Clean up when stream ends
    stream.on('end', cleanup)
    stream.on('close', cleanup)
  })
})

server.listen().then(() => {
  console.log(`SSH server listening on port ${PORT}...`)
  console.log(`Connect with: ssh -p ${PORT} localhost`)
  console.log(`(Any username/password will work)`)
}).catch((err) => {
  console.error('Failed to start SSH server:', err)
  process.exit(1)
})