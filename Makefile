start_cluster:
	sh bin/start_minikube.sh

GIT_SHA := $(shell git rev-parse --short HEAD)

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
	$(MAKE) -C notifications-service docker-build

docker-push-notifications:
	$(MAKE) -C notifications-service docker-push

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

setup_volumes_path:
	@for node in $$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do \
  	 	echo "Creating directory on node: $$node"; \
  		minikube ssh -n "$$node" "sudo mkdir -p /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/ && sudo chmod 777 /tmp/hostpath-provisioner/o11y-k8s-talk/postgres-pvc/"; \
  	done; \
  	echo "Directories created on all nodes"