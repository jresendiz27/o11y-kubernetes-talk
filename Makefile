start_cluster:
	sh bin/start_minikube.sh

apply_postgres:
	kubectl apply -f k8s-infra/postgres_database.yml

stop_cluster:
	minikube stop

destroy_cluster:
	minikube destroy
	