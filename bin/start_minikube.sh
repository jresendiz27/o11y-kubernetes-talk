#!/usr/bin/env bash
set -euo pipefail
echo "Stopping existing cluster..."
minikube stop 2> /dev/null || true
echo "Starting minikube cluster with Docker driver and Calico CNI..."

minikube start -n 3 \
  --cni=calico --apiserver-port=6443 \
  --driver=docker

echo "Waiting for Calico to be ready..."
kubectl wait --for=condition=ready pods -l k8s-app=calico-node -n kube-system --timeout=300s

echo "Enabling addons..."
minikube addons enable metrics-server
minikube addons enable storage-provisioner

echo ""
echo "Cluster status:"
minikube status

echo ""
echo "Nodes:"
kubectl get nodes

echo ""
echo "Cluster is ready!"