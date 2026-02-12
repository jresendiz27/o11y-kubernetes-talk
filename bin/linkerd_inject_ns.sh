#!/usr/bin/env bash
set -euo pipefail

APP_NS="${1:-o11y-k8s-talk}"

echo "Enabling Linkerd injection on namespace: ${APP_NS}"
kubectl annotate namespace "${APP_NS}" linkerd.io/inject=enabled --overwrite

echo "Restarting workloads in namespace to get sidecars..."
kubectl -n "${APP_NS}" rollout restart deployment

echo "Done. Verify with:"
echo "  kubectl -n ${APP_NS} get pods"
