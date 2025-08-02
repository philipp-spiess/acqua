#!/bin/bash

DEBUG=""
if [ "$1" = "--debug" ]; then
    DEBUG="--debug"
    echo "Running in debug mode"
fi

echo "Building..."
go build -o ssh-aquarium cmd/ssh-aquarium/main.go || exit 1

echo "Starting server..."
./ssh-aquarium $DEBUG