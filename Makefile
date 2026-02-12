.PHONY: help start_cluster wipe_namespace apply_postgres apply_notifications_service apply_sign_in_service docker-build-notifications docker-push-notifications docker-build-sign-in docker-push-sign-in stop_cluster destroy_cluster enable_docker_registry_bg setup_volumes_path helm_repos o11y_up o11y_down o11y_port_forward linkerd_up linkerd_inject demo_up

GIT_SHA := $(shell git rev-parse --short HEAD)
DEPLOY_ENV ?= development
FAILURE_RATE ?= 0.15
MIN_DELAY_SECONDS ?= 2
MAX_DELAY_SECONDS ?= 5
O11Y_NS ?= monitoring

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

start_cluster:
	sh bin/start_minikube.sh

wipe_namespace:
	kubectl delete namespace o11y-k8s-talk

apply_postgres:
	kubectl apply -f k8s-infra/postgres_database.yml

apply_sign_in_service:
	kubectl apply -f sign-in-service/k8s-infra/deployment.yml

apply_notifications_service:
	kubectl apply -f notifications-service/k8s-infra/deployment.yml

docker-build-notifications:
	docker build -t notifications-service:latest notifications-service
	docker tag notifications-service:latest localhost:5000/notifications-service:latest
	docker tag notifications-service:latest localhost:5000/notifications-service:$(GIT_SHA)

docker-push-notifications:
	docker push localhost:5000/notifications-service:latest
	docker push localhost:5000/notifications-service:$(GIT_SHA)

docker-build-sign-in:
	docker build -t sign-in-service:latest sign-in-service
	docker tag sign-in-service:latest localhost:5000/sign-in-service:latest
	docker tag sign-in-service:latest localhost:5000/sign-in-service:$(GIT_SHA)

docker-push-sign-in:
	docker push localhost:5000/sign-in-service:latest
	docker push localhost:5000/sign-in-service:$(GIT_SHA)

stop_cluster:
	minikube stop

destroy_cluster:
	minikube delete

enable_docker_registry_bg:
	echo "----------"
	echo "Attempting to enable minikube port-forward (Container Registry)"
	@mkdir -p tmp
	@if [ -f tmp/registry-port-forward.pid ] && kill -0 "$$(cat tmp/registry-port-forward.pid)" 2>/dev/null; then \
		echo "Registry port-forward already running (pid: $$(cat tmp/registry-port-forward.pid))"; \
	else \
		echo "Starting registry port-forward in background..."; \
		nohup kubectl port-forward -n kube-system service/registry 5000:80 > tmp/registry-port-forward.log 2>&1 & \
		echo $$! > tmp/registry-port-forward.pid; \
		echo "Registry port-forward started (pid: $$(cat tmp/registry-port-forward.pid))"; \
	fi
	echo "----------"

setup_volumes_path:
	@for node in $$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do \
  	 	echo "Creating directory on node: $$node"; \
  		minikube ssh -n "$$node" "sudo mkdir -p /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/ && sudo chmod 777 /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/"; \
  	done; \
  	echo "Directories created on all nodes"

helm_repos:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add grafana-community https://grafana-community.github.io/helm-charts
	helm repo update

o11y_up: helm_repos
	kubectl create namespace $(O11Y_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		-n $(O11Y_NS) -f k8s-infra/o11y/kube-prometheus-stack.values.yaml
	helm upgrade --install loki grafana/loki \
		-n $(O11Y_NS) -f k8s-infra/o11y/loki.values.yaml
	helm upgrade --install tempo grafana-community/tempo \
		-n $(O11Y_NS) -f k8s-infra/o11y/tempo.values.yaml
	helm upgrade --install alloy grafana/alloy \
		-n $(O11Y_NS) -f k8s-infra/o11y/alloy.values.yaml
	kubectl apply -f k8s-infra/o11y/otel-collector-externalname.yaml

o11y_down:
	helm uninstall alloy -n $(O11Y_NS) || true
	helm uninstall tempo -n $(O11Y_NS) || true
	helm uninstall loki -n $(O11Y_NS) || true
	helm uninstall kube-prometheus-stack -n $(O11Y_NS) || true

o11y_port_forward:
	@echo "Grafana: http://localhost:3000 (admin/admin)"
	kubectl -n $(O11Y_NS) port-forward svc/kube-prometheus-stack-grafana 3000:80

linkerd_up:
	bash bin/linkerd_up.sh

linkerd_inject:
	bash bin/linkerd_inject_ns.sh o11y-k8s-talk

demo_up: start_cluster setup_volumes_path apply_postgres enable_docker_registry_bg docker-build-sign-in docker-push-sign-in docker-build-notifications docker-push-notifications apply_notifications_service apply_sign_in_service
	@echo "Deploying SHA: $(GIT_SHA)"
	kubectl -n o11y-k8s-talk set image deployment/notifications-service notifications-service=localhost:5000/notifications-service:$(GIT_SHA)
	kubectl -n o11y-k8s-talk set image deployment/sign-in-service sign-in-service=localhost:5000/sign-in-service:$(GIT_SHA)
	kubectl -n o11y-k8s-talk set env deployment/notifications-service \
		OTEL_RESOURCE_ATTRIBUTES="service.version=$(GIT_SHA),vcs.revision=$(GIT_SHA),deployment.environment=$(DEPLOY_ENV)" \
		FAILURE_RATE="$(FAILURE_RATE)" \
		MIN_DELAY_SECONDS="$(MIN_DELAY_SECONDS)" \
		MAX_DELAY_SECONDS="$(MAX_DELAY_SECONDS)"
	kubectl -n o11y-k8s-talk set env deployment/sign-in-service \
		OTEL_RESOURCE_ATTRIBUTES="service.version=$(GIT_SHA),vcs.revision=$(GIT_SHA),deployment.environment=$(DEPLOY_ENV)" \
		FAILURE_RATE="$(FAILURE_RATE)"
	kubectl -n o11y-k8s-talk rollout status deployment/notifications-service
	kubectl -n o11y-k8s-talk rollout status deployment/sign-in-service