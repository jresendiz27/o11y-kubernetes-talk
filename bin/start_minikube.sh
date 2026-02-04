#!/usr/bin/env bash

minikube stop
minikube start -n 3 --cni=calico --apiserver-port=6443 --driver=kvm2
minikube addons enable metrics-server
minikube addons enable storage-provisioner
minikube status