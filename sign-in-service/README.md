# Sign-In Service

A simple Go microservice using Chi router and OpenTelemetry for distributed tracing.

## Features

- Chi router for HTTP handling
- OpenTelemetry integration for distributed tracing
- Health check endpoint
- Graceful shutdown
- Docker containerization
- Non-root user execution

## Endpoints

- `GET /health` - Health check endpoint
- `GET /` - Hello world endpoint

## Environment Variables

- `PORT` - Server port (default: 8080)
- `OTEL_EXPORTER_OTLP_ENDPOINT` - OpenTelemetry collector endpoint (default: http://localhost:4318)

## Running Locally

```bash
# Install dependencies
go mod download

# Run the service
go run main.go

# Test the service
curl http://localhost:8080/health
curl http://localhost:8080/
```

## Docker

```bash
# Build the image
docker build -t sign-in-service:latest .

# Run the container
docker run -p 8080:8080 sign-in-service:latest

# Run with OpenTelemetry collector
docker run -p 8080:8080 \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
  sign-in-service:latest
```

## Development

```bash
# Format code
go fmt ./...

# Run tests
go test ./...

# Lint code
golangci-lint run
```
