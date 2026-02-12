start_cluster:
	sh bin/start_minikube.sh

GIT_SHA := $(shell git rev-parse --short HEAD)
DEPLOY_ENV ?= development
FAILURE_RATE ?= 0.15
MIN_DELAY_SECONDS ?= 2
MAX_DELAY_SECONDS ?= 5

wipe_namespace:
	kubectl delete namespace o11y-k8s-talk

apply_postgres:
	kubectl apply -f k8s-infra/postgres_database.yml

apply_sign_in_service:
	kubectl apply -f sign-in-service/k8s-infra/deployment.yml

apply_notifications_service:
	kubectl apply -f notifications-service/k8s-infra/deployment.yml

git_sha:
	@echo $(GIT_SHA)

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

enable_docker_registry:
	kubectl port-forward -n kube-system service/registry 5000:80

enable_docker_registry_bg:
	@mkdir -p tmp
	@if [ -f tmp/registry-port-forward.pid ] && kill -0 "$$(cat tmp/registry-port-forward.pid)" 2>/dev/null; then \
		echo "Registry port-forward already running (pid: $$(cat tmp/registry-port-forward.pid))"; \
	else \
		echo "Starting registry port-forward in background..."; \
		nohup kubectl port-forward -n kube-system service/registry 5000:80 > tmp/registry-port-forward.log 2>&1 & \
		echo $$! > tmp/registry-port-forward.pid; \
		echo "Registry port-forward started (pid: $$(cat tmp/registry-port-forward.pid))"; \
	fi

setup_volumes_path:
	@for node in $$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do \
  	 	echo "Creating directory on node: $$node"; \
  		minikube ssh -n "$$node" "sudo mkdir -p /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/ && sudo chmod 777 /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/"; \
  	done; \
  	echo "Directories created on all nodes"

demo_up: start_cluster enable_docker_registry_bg setup_volumes_path apply_postgres docker-build-sign-in docker-push-sign-in docker-build-notifications docker-push-notifications apply_notifications_service apply_sign_in_service
	@echo "Deploying SHA: $(GIT_SHA)"
	kubectl -n o11y-k8s-talk set image deployment/notifications-service notifications-service=localhost:5000/notifications-service:$(GIT_SHA)
	kubectl -n o11y-k8s-talk set image deployment/sign-in-service sign-in-service=localhost:5000/sign-in-service:$(GIT_SHA)
	kubectl -n o11y-k8s-talk set env deployment/notifications-service \
		OTEL_RESOURCE_ATTRIBUTES="service.version=$(GIT_SHA),vcs.revision=$(GIT_SHA),deployment.environment=$(DEPLOY_ENV)" \
		FAILURE_RATE="$(FAILURE_RATE)" \
		MIN_DELAY_SECONDS="$(MIN_DELAY_SECONDS)" \
		MAX_DELAY_SECONDS="$(MAX_DELAY_SECONDS)"
	kubectl -n o11y-k8s-talk set env deployment/sign-in-service \
		OTEL_RESOURCE_ATTRIBUTES="service.version=$(GIT_SHA),vcs.revision=$(GIT_SHA),deployment.environment=$(DEPLOY_ENV)"
	kubectl -n o11y-k8s-talk rollout status deployment/notifications-service
	kubectl -n o11y-k8s-talk rollout status deployment/sign-in-service