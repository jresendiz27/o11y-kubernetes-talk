# o11y-kubernetes-talk

KCD Guadalajara 2026: **"Del caos a la claridad: construyendo observabilidad en Kubernetes paso a paso"**

### Brief

In many moments, Kubernetes feels like a black box: services randomly failing, disappearing pods, latency across services, and to make it worse, logs full of sensitive data we shouldn't have stored.

This talk combines Linkerd, Alloy, Prometheus, Loki, Grafana, and OpenTelemetry to build a modern observability stack: metrics, logs, and traces that help detect problems fast, understand root causes, and avoid exposing PII in monitoring systems.

### Architecture

```
                     Namespaces
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │   sign-in    │  │ notifications│  │  databases    │
  │              │  │              │  │              │
  │ sign-in-svc  │──│ notif-svc    │  │ PostgreSQL   │
  │ (Go, x10)   │  │ (Python, x2) │  │ + pg-exporter│
  └──────┬───────┘  └──────┬───────┘  └──────────────┘
         │                 │
         │    OTLP (traces + logs via stdout)
         ▼                 ▼
  ┌─────────────────────────────────────────────────┐
  │                  monitoring                      │
  │                                                  │
  │  Alloy (DaemonSet)                               │
  │  ├─ OTLP receiver (gRPC 4317 / HTTP 4318)       │
  │  ├─ K8s log collection ──→ PII filtering         │
  │  └─ Forward: traces→Tempo, logs→Loki             │
  │                                                  │
  │  Prometheus ←── kube-state-metrics, node-exporter│
  │  Loki (logs) ←── Alloy                           │
  │  Tempo (traces) ←── Alloy                        │
  │  Grafana (dashboards + explore)                  │
  └─────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────┐
  │  linkerd / linkerd-viz                           │
  │  Service mesh: mTLS, golden metrics, topology    │
  └─────────────────────────────────────────────────┘
```

### Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Linkerd CLI](https://linkerd.io/2/getting-started/)
- Docker

### Quick Start (first time)

```bash
make first_time_setup_cluster    # cluster + postgres + o11y stack + linkerd
make enable_port_forwards        # grafana :3000, alloy :12345, linkerd-viz :8084, registry :5000
make demo_up FAILURE_RATE=0.30   # build, push, deploy services with 30% failure rate
```

Then open:
- **Grafana**: http://localhost:3000 (admin / admin)
- **Alloy UI**: http://localhost:12345
- **Linkerd Viz**: http://localhost:8084

### Step-by-step Setup

```bash
# 1. Start cluster
make start_cluster
make setup_volumes_path

# 2. Deploy database
make apply_postgres

# 3. Install observability stack
make o11y_up

# 4. Install service mesh
make linkerd_up
make linkerd_inject        # injects sidecars in sign-in, notifications, databases

# 5. Build and deploy services
make demo_up FAILURE_RATE=0.15

# 6. Port forwards
make enable_port_forwards
```

### Environment Variables

| Variable | Default | Used by | Description |
|----------|---------|---------|-------------|
| `FAILURE_RATE` | 0.15 | Both services | Probability of simulated failure (0.0-1.0) |
| `MIN_DELAY_SECONDS` | 2 | notifications | Minimum email processing delay |
| `MAX_DELAY_SECONDS` | 5 | notifications | Maximum email processing delay |
| `LOG_USER_DATA` | true | sign-in | Log PII fields (email, phone, name, address) |
| `NUM_GENERATORS` | 5 | sign-in | Concurrent user generator goroutines |
| `DEPLOY_ENV` | development | Both | Deployment environment label |

### PII Filtering Demo

The Alloy pipeline includes two PII filtering techniques:

1. **Pattern-based masking**: Regex rules that scan every log line for email addresses and phone numbers, replacing them with `[EMAIL_REDACTED]` / `[PHONE_REDACTED]` regardless of field names or log format.

2. **Field dropping**: Targeted rules that redact known sensitive fields like `user_address` by name.

To see the demo flow:
```bash
# 1. Logs flow with PII visible (LOG_USER_DATA=true in sign-in-service)
#    Open Grafana > Explore > Loki: {namespace="sign-in"}

# 2. PII masking is applied by Alloy before shipping to Loki
#    Search for: {namespace="sign-in"} |~ "REDACTED|EMAIL_REDACTED|PHONE_REDACTED"

# 3. Reload Alloy after config changes
make reload_alloy
```

### Cross-namespace Communication

Services use FQDNs for cross-namespace DNS resolution:
- sign-in -> `postgres.databases.svc.cluster.local` (database)
- sign-in -> `notifications-service.notifications.svc.cluster.local:8081` (email notifications)
- Both services -> `alloy.monitoring.svc.cluster.local:4318` (OTLP traces)

### Grafana Features

- **Pre-provisioned dashboard**: "KCD 2026 - Service Overview" with pod counts, CPU/memory, log volume, error rates, and PII redaction check
- **Logs-to-traces**: Click `trace_id` in Loki to open the trace in Tempo
- **Traces-to-logs**: From a Tempo trace, jump to related logs filtered by namespace/app
- **Explore**: Live LogQL and TraceQL queries for root cause analysis

### Useful Make Targets

| Target | Description |
|--------|-------------|
| `make first_time_setup_cluster` | Full setup: cluster + postgres + o11y + linkerd |
| `make demo_up` | Build, push, and deploy both services |
| `make enable_port_forwards` | Background port-forwards for all UIs |
| `make reload_alloy` | Apply Alloy config changes and restart |
| `make o11y_up` | Install/upgrade the full o11y stack |
| `make o11y_down` | Tear down the o11y stack |
| `make linkerd_inject` | Inject Linkerd sidecars in all namespaces |
| `make wipe_namespace` | Delete all demo namespaces (destructive) |
| `make destroy_cluster` | Delete the entire minikube cluster |

### Resources

- [Cloud Observability in Action - Michael Hausenblas (Manning)](https://www.manning.com/books/cloud-observability-in-action)
- [Grafana Alloy documentation](https://grafana.com/docs/alloy/)
- [OpenTelemetry documentation](https://opentelemetry.io/docs/)
