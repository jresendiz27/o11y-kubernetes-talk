#!/usr/bin/env bash
set -euo pipefail
echo "Stopping existing cluster..."
minikube stop 2> /dev/null || true
echo "Starting minikube cluster with Docker driver and Calico CNI..."

minikube start -n 3 \
  --apiserver-port=6443 \
  --driver=docker

echo "Enabling addons..."
minikube addons enable metrics-server
minikube addons enable storage-provisioner
minikube addons enable registry

echo ""
echo "Cluster status:"
minikube status

echo ""
echo "Nodes:"
kubectl get nodes

echo ""
echo "Cluster is ready!"