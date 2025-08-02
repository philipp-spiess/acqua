#!/bin/bash

# Test runner for SSH Aquarium
# This script starts the server, connects a client, and logs all output

SERVER_LOG="server.log"
CLIENT_LOG="client.log"

# Clean up any existing logs
rm -f "$SERVER_LOG" "$CLIENT_LOG"

# Kill any existing SSH aquarium processes
pkill -f ssh-aquarium 2>/dev/null

echo "Building server..."
go build -o ssh-aquarium cmd/ssh-aquarium/main.go || exit 1

echo "Starting SSH aquarium server..."
./ssh-aquarium > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start. Check server.log"
    cat "$SERVER_LOG"
    exit 1
fi

echo "Server started with PID $SERVER_PID"
echo "Server log: tail -f $SERVER_LOG"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down..."
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    echo "Server stopped"
}

trap cleanup EXIT INT TERM

# Test connection with logging
echo "Testing SSH connection..."
ssh -v -p 1234 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 localhost > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

# Wait a bit for connection
sleep 3

# Show what's happening
echo ""
echo "=== Server Log (last 20 lines) ==="
tail -20 "$SERVER_LOG"

echo ""
echo "=== Client Log (last 20 lines) ==="
tail -20 "$CLIENT_LOG"

# Keep running until interrupted
echo ""
echo "Press Ctrl+C to stop the test"
echo "You can also connect manually: ssh -p 1234 localhost"
echo ""

# Wait for interrupt
wait