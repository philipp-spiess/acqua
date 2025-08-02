#!/bin/bash

echo "Starting SSH Aquarium server..."
./ssh-aquarium &
SERVER_PID=$!

sleep 2

echo "Server started with PID $SERVER_PID"
echo "You can now connect with: ssh -p 1234 localhost"
echo ""
echo "Press Ctrl+C to stop the server"

trap "kill $SERVER_PID 2>/dev/null; exit" INT TERM

wait $SERVER_PID