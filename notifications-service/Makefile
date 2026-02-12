.PHONY: help run lint docker-build docker-run docker-push clean deps

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Install dependencies
	pip install -r requirements.txt

run: ## Run the application locally
	python app.py

lint: ## Run linter
	python -m py_compile app.py

docker-build: ## Build Docker image
	docker build -t notifications-service:latest .

docker-run: ## Run Docker container
	docker run -p 8081:8081 --rm notifications-service:latest

docker-push: ## Tag and push to local registry
	docker tag notifications-service:latest localhost:5000/notifications-service:latest && \
	docker push localhost:5000/notifications-service:latest

clean: ## Clean Python caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name '*.pyc' -delete 2>/dev/null || true
