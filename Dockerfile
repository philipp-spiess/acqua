FROM golang:1.24-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o ssh-aquarium cmd/ssh-aquarium/main.go

FROM alpine:latest

# Install ca-certificates for HTTPS requests
RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Copy the binary from builder
COPY --from=builder /app/ssh-aquarium .

# Copy SSH keys directory
COPY --from=builder /app/ssh_keys ./ssh_keys

# Copy fish images
COPY --from=builder /app/fish.png .
COPY --from=builder /app/fish-right.png .

# Expose the SSH port and web port
EXPOSE 1234
EXPOSE 8080

# Run the application
CMD ["./ssh-aquarium", "-port", "1234", "-web-port", "8080"]