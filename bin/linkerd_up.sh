#!/usr/bin/env bash
set -euo pipefail

NAMESPACE_LINKERD="${NAMESPACE_LINKERD:-linkerd}"

if ! command -v linkerd >/dev/null 2>&1; then
  echo "linkerd CLI not found. Install it first (https://linkerd.io/2/getting-started/)." >&2
  exit 1
fi

if kubectl describe namespace linkerd; then
  echo "Linkerd namespace already set, skipping"
  exit 0
else
  echo "Installing API Gateway CRDs prior installing Linkerd"
  kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

  echo "Running linkerd preflight checks..."
  linkerd version
  linkerd check --pre

  echo "Installing Linkerd CRDs..."
  linkerd --set proxyInit.runAsRoot=true install --crds | kubectl apply -f -

  echo "Installing Linkerd control-plane..."
  linkerd --set proxyInit.runAsRoot=true install | kubectl apply -f -

  echo "Waiting for Linkerd to become ready..."
  linkerd check

  echo "Linkerd installed in namespace: ${NAMESPACE_LINKERD}"
fi
