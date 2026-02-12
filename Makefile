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
	$(MAKE) -C notifications-service docker-build

docker-push-notifications:
	$(MAKE) -C notifications-service docker-push

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