#!/bin/bash

# Simple test that connects and sends commands

# Check if --debug flag is passed
DEBUG_FLAG=""
if [ "$1" = "--debug" ]; then
    DEBUG_FLAG="--debug"
    echo "Running in debug mode (1 fish, 1 FPS)"
fi

echo "Building server..."
go build -o ssh-aquarium cmd/ssh-aquarium/main.go || exit 1

echo "Starting server..."
./ssh-aquarium $DEBUG_FLAG > server.log 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start:"
    cat server.log
    exit 1
fi

echo "Server running with PID $SERVER_PID"

# Cleanup function
cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}
trap cleanup EXIT

# Test connection
echo "Connecting to server..."
# Use expect if available, otherwise use ssh directly
if command -v expect >/dev/null 2>&1; then
    expect -c "
        spawn ssh -p 1234 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost
        expect {
            \"password:\" { send \"test\\r\" }
            \"Are you sure\" { send \"yes\\r\"; exp_continue }
            timeout { exit 1 }
        }
        expect {
            timeout { exit 0 }
            eof { exit 0 }
        }
    " > /dev/null 2>&1 &
else
    # Direct SSH with auto-accept
    echo "test" | ssh -tt -p 1234 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PasswordAuthentication=yes \
        localhost > /dev/null 2>&1 &
fi

CLIENT_PID=$!

# Wait for connection to establish
sleep 5

echo ""
echo "=== Server Log ==="
cat server.log

# Keep server running for manual testing
echo ""
echo "Server is still running. Connect with: ssh -p 1234 localhost"
echo "Press Ctrl+C to stop"
wait