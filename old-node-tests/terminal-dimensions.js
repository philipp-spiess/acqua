#!/usr/bin/env node

function getTerminalPixelDimensions() {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error('Timeout - terminal may not support pixel queries'))
    }, 3000)

    // Set raw mode to capture escape sequences
    process.stdin.setRawMode(true)
    process.stdin.resume()
    
    let buffer = ''
    let responses = []

    const dataHandler = (data) => {
      buffer += data.toString()
      
      // Look for window size response: ESC[4;height;widtht
      const windowMatch = buffer.match(/\x1b\[4;(\d+);(\d+)t/)
      if (windowMatch && !responses.find(r => r.type === 'window')) {
        responses.push({
          type: 'window',
          height: parseInt(windowMatch[1]),
          width: parseInt(windowMatch[2])
        })
      }
      
      // Look for character cell size response: ESC[6;height;widtht  
      const cellMatch = buffer.match(/\x1b\[6;(\d+);(\d+)t/)
      if (cellMatch && !responses.find(r => r.type === 'cell')) {
        responses.push({
          type: 'cell',
          height: parseInt(cellMatch[1]),
          width: parseInt(cellMatch[2])
        })
      }
      
      // We got at least one response, resolve
      if (responses.length > 0) {
        clearTimeout(timeout)
        process.stdin.removeListener('data', dataHandler)
        process.stdin.setRawMode(false)
        process.stdin.pause()
        resolve(responses)
      }
    }

    process.stdin.on('data', dataHandler)

    // Query window size in pixels: ESC[14t
    process.stdout.write('\x1b[14t')
    
    // Query character cell size in pixels: ESC[16t  
    process.stdout.write('\x1b[16t')
  })
}

async function main() {
  const cols = process.stdout.columns
  const rows = process.stdout.rows
  
  console.log(`Terminal: ${cols}x${rows} characters`)
  
  try {
    const responses = await getTerminalPixelDimensions()
    
    responses.forEach(response => {
      if (response.type === 'window') {
        console.log(`Window: ${response.width}x${response.height} pixels`)
        
        if (cols && rows) {
          const charW = Math.round(response.width / cols)
          const charH = Math.round(response.height / rows) 
          console.log(`Character cell: ${charW}x${charH} pixels`)
          
          // Detect potential HiDPI by checking if dimensions seem doubled
          const isHiDPI = charW > 20 || charH > 40
          if (isHiDPI) {
            const realCharW = Math.round(charW / 2)
            const realCharH = Math.round(charH / 2)
            const realWindowW = Math.round(response.width / 2)
            const realWindowH = Math.round(response.height / 2)
            
            console.log('HiDPI/Retina detected - calculating real pixels:')
            console.log(`Real window: ${realWindowW}x${realWindowH} pixels`)
            console.log(`Real character cell: ${realCharW}x${realCharH} pixels`)
          }
        }
      }
      
      if (response.type === 'cell') {
        console.log(`Cell size: ${response.width}x${response.height} pixels`)
      }
    })
    
  } catch (error) {
    console.log('Terminal does not support pixel dimension queries')
    console.log('(This is normal for many terminals including Ghostty)')
  }
}

main()