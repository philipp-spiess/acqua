.PHONY: build run clean test

build:
	go build -o ssh-aquarium cmd/ssh-aquarium/main.go

run: build
	./ssh-aquarium

clean:
	rm -f ssh-aquarium

test:
	go test ./...

dev:
	go run cmd/ssh-aquarium/main.go