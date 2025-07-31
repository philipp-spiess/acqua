# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SSH Aquarium is an Elixir application that provides a collaborative fish aquarium accessible via SSH. Users connect to the SSH server and interact with animated fish using mouse clicks. The application uses the Kitty graphics protocol for displaying fish images and supports real-time multi-user interaction.

## Development Commands

- **Install dependencies**: `mix deps.get`
- **Compile project**: `mix compile`  
- **Run the SSH server**: `mix run --no-halt`
- **Run tests**: `mix test`
- **Connect to aquarium**: `ssh -p 1234 localhost`

## Architecture

### Core Components

The application follows OTP supervision patterns with these key modules:

- **`SshAquarium.Application`**: Main application supervisor that starts and manages child processes
- **`SshAquarium.SshServer`**: GenServer that configures the SSH server on port 1234
- **`SshAquarium.SharedAquarium`**: Central GenServer managing fish state, animations, and multi-user coordination
- **`SshAquarium.ShellHandler`**: SSH shell handler using the esshd library for incoming connections
- **`SshAquarium.KittyGraphics`**: Kitty graphics protocol implementation for rendering fish images

### Data Flow

1. SSH connections are handled by `esshd` library configured in `config/config.exs`
2. `ShellHandler.on_shell/4` is called for each new connection
3. Each connection registers as a viewer with `SharedAquarium`
4. `SharedAquarium` runs a 60 FPS animation loop broadcasting frames to all viewers
5. Mouse events are captured and processed for fish interaction

### Key Features

- **Fish Animation**: 100 fish per connection with physics (bouncing, bobbing, bubbles)
- **Multi-user Support**: Shared aquarium state with connection ownership system
- **Mouse Interaction**: Click detection with fish ownership validation
- **Kitty Graphics**: PNG fish images rendered using Kitty terminal protocol
- **Process Isolation**: Each SSH connection runs in its own process

## Configuration

- SSH server configuration in `config/config.exs`
- Default port: 1234
- SSH keys stored in `ssh_keys/` directory
- Fish images: `fish.png` (left-facing), `fish-right.png` (right-facing)

## Dependencies

- **esshd**: SSH daemon library for Elixir
- Requires Elixir 1.18+ and Erlang/OTP 28+
- Terminal must support Kitty graphics protocol

## File Structure

- `lib/ssh_aquarium/application.ex`: OTP application setup
- `lib/ssh_aquarium/shared_aquarium.ex`: Core aquarium state management (~429 lines)
- `lib/ssh_aquarium/shell_handler.ex`: SSH connection handling  
- `lib/ssh_aquarium/kitty_graphics.ex`: Graphics protocol implementation
- `ssh_keys/`: SSH host keys for the server
- `old-node-tests/`: Legacy Node.js implementation for reference

## Notes

This is a port from a Node.js implementation. The Elixir version leverages OTP for better fault tolerance, concurrent connection handling, and process supervision compared to the callback-based Node.js version.