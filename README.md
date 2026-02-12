# o11y-kubernetes-talk
Repository from KCD Talk: "Del caos a la claridad: construyendo observabilidad en Kubernetes paso a paso", February 2026

### Brief

In many many many moments, k8s feels like a black box: Services randomly failing, disappearing pods, latency across services, getting 504 http errors randomly ... And to be fully screwed, logs with sensitive information.

Across this talk, we will combine Linkerd, Alloy, Prometheus, Loki, Grafana and OTEL to build and understand the basic observability stack for k8s environments, aiming to troubleshoot problems and understand the heart of monitoring and observability.

### Install the o11y stack on Minikube

This repo includes Helm values under `k8s-infra/o11y/` to install:
- kube-prometheus-stack (Prometheus + Grafana)
- Loki (logs backend)
- Tempo (traces backend)
- Grafana Alloy (OTLP receiver + Kubernetes logs pipeline)
- Linkerd (service mesh) via CLI

#### One-time prerequisites (on your machine)

- Install `helm`
- Install `linkerd` CLI
- Have a running Minikube cluster (this repo has `make start_cluster`)

#### Install stack (step by step)

```bash
make o11y_up
make linkerd_up
make linkerd_inject
```

#### Deploy demo services (build/push/apply)

```bash
make demo_up FAILURE_RATE=0.30
```

#### Open Grafana

```bash
make o11y_port_forward
```

Then open `http://localhost:3000` (user/pass: `admin` / `admin`).

#### Notes

- Apps send OTLP to `otel-collector:4318` in `o11y-k8s-talk`. We create an `ExternalName` service (`k8s-infra/o11y/otel-collector-externalname.yaml`) that maps `otel-collector` -> `alloy.monitoring.svc.cluster.local` so you don't need to change app manifests.