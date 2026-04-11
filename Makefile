.PHONY: help start_cluster wipe_namespace apply_postgres apply_notifications_service apply_sign_in_service docker_build_notifications docker_push_notifications docker_build_sign_in docker_push_sign_in stop_cluster destroy_cluster enable_docker_registry_port_forward setup_volumes_path helm_repos o11y_up o11y_down enable_o11y_port_forward linkerd_up linkerd_inject demo_up

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

start_cluster: # Start minikube cluster
	sh bin/start_minikube.sh

wipe_namespace: # Wipe o11y-k8s-talk namespace (Destructive!!)
	kubectl delete namespace o11y-k8s-talk

apply_postgres: # Apply postgres stateful set and configurations
	kubectl apply -f k8s-infra/postgres_database.yml

first_time_setup_cluster: start_cluster setup_volumes_path apply_postgres o11y_up linkerd_up linkerd_inject # Start the demo cluster the first time
	@echo "Overall cluster started"

stop_cluster: # Stop minikube cluster
	minikube stop

destroy_cluster: # Destroy minikube cluster
	minikube delete

setup_volumes_path: # Configure volume path for persistent volume claim (in all minikube nodes)
	# this is required for cluster-mode to be able to mount postgres and loki storage, we don't fully own which node will receive the statefulset so we create all the routes for all the nodes
	@for node in $$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do \
  	 	echo "Creating directory on node: $$node"; \
  		minikube ssh -n "$$node" "sudo mkdir -p /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/ && sudo chmod 777 /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/"; \
  		minikube ssh -n "$$node" "sudo mkdir -p /tmp/hostpath-provisioner/monitoring/storage-loki-0/ && sudo chmod 777 /tmp/hostpath-provisioner/monitoring/storage-loki-0/"; \
  	done; \
  	echo "Directories created on all nodes"

#  Services

apply_sign_in_service: # Apply mock sign-in service
	kubectl apply -f sign-in-service/k8s-infra/deployment.yml

apply_notifications_service: # Apply mock notifications-service
	kubectl apply -f notifications-service/k8s-infra/deployment.yml

docker_build_notifications: # Docker build notifications-service
	docker build -t notifications-service:latest notifications-service
	docker tag notifications-service:latest localhost:5000/notifications-service:latest
	docker tag notifications-service:latest localhost:5000/notifications-service:$(GIT_SHA)

docker_push_notifications: # Docker push notifications service to minikube registry
	docker push localhost:5000/notifications-service:latest
	docker push localhost:5000/notifications-service:$(GIT_SHA)

docker_build_sign_in: # Docker build sign-in
	docker build -t sign-in-service:latest sign-in-service
	docker tag sign-in-service:latest localhost:5000/sign-in-service:latest
	docker tag sign-in-service:latest localhost:5000/sign-in-service:$(GIT_SHA)

docker_push_sign_in: # Docker push sign-in service to minikube registry
	docker push localhost:5000/sign-in-service:latest
	docker push localhost:5000/sign-in-service:$(GIT_SHA)

## O11Y Stack

helm_repos: # Add prometheus, grafana and grafana community helm repositories
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add grafana-community https://grafana-community.github.io/helm-charts
	helm repo update

o11y_up: helm_repos # Configure and up the o11y stack
	kubectl create namespace $(O11Y_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		-n $(O11Y_NS) -f k8s-infra/o11y/kube-prometheus-stack.values.yaml
	helm upgrade --install loki grafana/loki \
		-n $(O11Y_NS) -f k8s-infra/o11y/loki.values.yaml
	helm upgrade --install tempo grafana-community/tempo \
		-n $(O11Y_NS) -f k8s-infra/o11y/tempo.values.yaml
	helm upgrade --install alloy grafana/alloy \
		-n $(O11Y_NS) -f k8s-infra/o11y/alloy.values.yaml \
		--set-file alloy.configMap.content=k8s-infra/o11y/alloy.config.alloy
	kubectl apply -f k8s-infra/o11y/otel-collector-externalname.yaml

o11y_down: # Stop the o11y stack
	helm uninstall alloy -n $(O11Y_NS) || true
	helm uninstall tempo -n $(O11Y_NS) || true
	helm uninstall loki -n $(O11Y_NS) || true
	helm uninstall kube-prometheus-stack -n $(O11Y_NS) || true

## Port Forwards

enable_port_forwards: enable_o11y_port_forward enable_docker_registry_port_forward enable_alloy_port_forward enable_linkerd_viz_port_forward
	@echo "Enabled port forward for registry and grafana"

enable_docker_registry_port_forward: # Enable docker-registry connection to background process
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

enable_o11y_port_forward: # Enable port-forward for grafana
	@echo "----------"
	@echo "Attempting to enable minikube port-forward (Grafana)"
	@mkdir -p tmp
	@if [ -f tmp/grafana-port-forward.pid ] && kill -0 "$$(cat tmp/grafana-port-forward.pid)" 2> /dev/null; then \
		echo "Grafana port-forward already running (pid: $$(cat tmp/grafana-port-forward.pid))"; \
	else \
		echo "Starting Grafana port-forward in background..."; \
		nohup kubectl port-forward -n $(O11Y_NS) svc/kube-prometheus-stack-grafana 3000:80 > tmp/grafana-port-forward.log 2>&1 & \
		echo $$! > tmp/grafana-port-forward.pid; \
		echo "Grafana port-forward started (pid: $$(cat tmp/grafana-port-forward.pid))"; \
	fi
	@echo "----------"

enable_alloy_port_forward:
	@echo "-----------"
	@echo "Attempting to enable minikube port-forward (alloy)"
	@mkdir -p tmp
	@if [ -f tmp/alloy-port-forward.pid ] && kill -0 "$$(cat tmp/alloy-port-forward.pid)" 2> /dev/null; then \
  		echo "Alloy port-forward already running (pid: $$(cat tmp/alloy-port-forward.pid))"; \
	else \
	  echo "Starting alloy port-forward in background ..."; \
	  nohup kubectl port-forward -n $(O11Y_NS) svc/alloy 12345:12345 > tmp/alloy-port-forward.log 2>&1 & \
	  echo $$! > tmp/alloy-port-forward.pid; \
	  echo "Alloy port-forward started (pid: $$(cat tmp/alloy-port-forward.pid))"; \
	fi
	@echo "-----------"

enable_linkerd_viz_port_forward:
	@echo "-----------"
	@echo "Attempting to enable minikube port-forward (linkerd-viz)"
	@mkdir -p tmp
	@if [ -f tmp/linkerd-viz-port-forward.pid ] && kill -0 "$$(cat tmp/linkerd-viz-port-forward.pid)" 2> /dev/null; then \
  		echo "Linkerd-Viz already running (pid: $$(cat tmp/linkerd-viz-port-forward.pid))"; \
	else \
		echo "Starting linkerd-viz port-forward in background ..."; \
		nohup kubectl port-forward -n linkerd-viz services/web 8084:8084 > tmp/linkerd-viz-port-forward.log 2>&1 & \
		echo $$! > tmp/linkerd-viz-port-forward.pid; \
		echo "Linkerd-viz port-forward started (pid: $$(cat tmp/linkerd-viz-port-forward.pid))"; \
    fi

reload_alloy:
	helm upgrade --install alloy grafana/alloy -n monitoring -f k8s-infra/o11y/alloy.values.yaml --set-file alloy.configMap.content=k8s-infra/o11y/alloy.config.alloy
	kubectl rollout restart -n $(O11Y_NS) daemonset/alloy
	kubectl rollout status -n $(O11Y_NS) daemonset/alloy

linkerd_up: # Start linkerd service mesh
	bash bin/linkerd_up.sh

linkerd_inject: # Enable Linkerd inject to o11y-k8s-talk namespace
	bash bin/linkerd_inject_ns.sh o11y-k8s-talk

demo_up: docker_build_sign_in docker_push_sign_in docker_build_notifications docker_push_notifications apply_notifications_service apply_sign_in_service
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