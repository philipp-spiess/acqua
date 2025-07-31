# SSH Aquarium (Elixir Implementation)

A collaborative fish aquarium accessible via SSH, rewritten in Elixir from the original Node.js implementation.

## Features

- **SSH Server**: Custom SSH server using Erlang's `:ssh` module
- **Fish Animation**: Real-time animated fish using the Kitty graphics protocol
- **Multi-User**: Multiple users can connect simultaneously and interact with fish
- **Mouse Interaction**: Click on fish to make them change direction and spawn bubbles
- **Collaborative**: All users see the same shared aquarium state

## Architecture

### Modules

- **`SshAquarium.SshServer`**: Main SSH server GenServer that manages the daemon
- **`SshAquarium.SshShell`**: Handles individual SSH shell connections
- **`SshAquarium.SharedAquarium`**: Manages shared aquarium state and fish animations
- **`SshAquarium.KittyGraphics`**: Implements Kitty graphics protocol for fish rendering

### Key Features of the Elixir Version

- **OTP Supervision**: Proper supervision tree with fault tolerance
- **Concurrent Handling**: Each SSH connection runs in its own process
- **Shared State**: Centralized aquarium state with real-time broadcasting
- **Terminal Protocol**: Full support for mouse events and Kitty graphics

## Requirements

- Elixir 1.18+
- Erlang/OTP 28+
- Terminal with Kitty graphics protocol support (like Kitty terminal)

## Installation & Running

1. **Install dependencies:**
   ```bash
   mix deps.get
   ```

2. **Compile the project:**
   ```bash
   mix compile
   ```

3. **Run the SSH server:**
   ```bash
   mix run --no-halt
   ```

4. **Connect to the aquarium:**
   ```bash
   ssh -p 1234 localhost
   ```

## Usage

- **Mouse Clicks**: Click on fish to interact with them (only your own fish)
- **Ctrl+C**: Disconnect from the aquarium
- **Multiple Connections**: Open multiple terminal windows and connect simultaneously

## Technical Implementation

### SSH Connection Flow
1. User connects via SSH to port 1234
2. `SshAquarium.SshShell.start_shell/3` is called for each connection
3. Shell process handles SSH protocol messages and user input
4. Connection is registered with `SharedAquarium` for broadcasting

### Fish Animation System
1. Each connection spawns 100 fish in the shared aquarium
2. `SharedAquarium` runs an animation timer at ~60 FPS
3. Fish positions are updated with physics (bouncing, bobbing)
4. Animation frames are broadcast to all connected viewers
5. Fish are rendered using Kitty graphics protocol

### Mouse Interaction
1. Mouse events are captured from SSH input stream
2. Click coordinates are converted to fish collision detection
3. Users can only interact with their own fish (ownership system)
4. Fish respond by changing direction and spawning bubbles

## Files

- **SSH Keys**: `ssh_keys/` directory contains host keys for the SSH server
- **Fish Images**: `fish.png` and `fish-right.png` for left/right facing fish
- **Source**: All Elixir source code in `lib/ssh_aquarium/`

## Differences from Node.js Version

1. **Fault Tolerance**: Elixir's OTP provides better error handling and recovery
2. **Concurrency**: Native actor model vs callback-based concurrency
3. **Process Isolation**: Each connection runs in an isolated process
4. **Supervision**: Automatic restart of failed components
5. **Type Safety**: Better pattern matching and error handling

