.PHONY: help build run test fmt lint docker-build docker-run clean

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the application
	go build -o bin/sign-in-service .

run: ## Run the application
	go run main.go

test: ## Run tests
	go test -v -race -coverprofile=coverage.out ./...

fmt: ## Format code
	go fmt ./...

lint: ## Run linter
	golangci-lint run

tidy: ## Tidy go modules
	go mod tidy

docker-build: ## Build Docker image
	docker build -t sign-in-service:latest .

docker-run: ## Run Docker container
	docker run -p 8080:8080 --rm sign-in-service:latest

clean: ## Clean build artifacts
	rm -rf bin/
	rm -f coverage.out

deps: ## Download dependencies
	go mod download

verify: fmt lint test ## Verify code (format, lint, test)
