# Observability

Covers **Phase 9**: metrics, logs and traces for `ai_service`, and the platform that collects, stores and displays them (kube-prometheus-stack, Loki, Tempo, the OTel Collector, one Grafana dashboard). Phase 10 (trace/log attribute curation, log↔trace correlation, cross-service trace propagation) is explicitly out of scope here — see `docs/architecture.md`'s roadmap and this phase's own guide for the boundary.

**Verified state:** the application layer (`app/ai_service/src/ai_service/telemetry.py`) is genuinely exercised in the sandbox — 141 unit tests, 99.27 % coverage, three real bugs found and fixed by running the code (see `docs/troubleshooting.md` and ADR-27). The platform layer (four Helm releases, the Grafana dashboard, `scripts/bootstrap/observability.sh`) is statically checked (196 checks in `make test`, every manifest's YAML validated, every values-file key checked against the real upstream chart schema) but **has not yet been installed on a real cluster** — the sandbox has no cluster and cannot reach `*.github.io`. Do not treat anything in sections 3–5 below as confirmed until it has actually run on the target machine; update this document with real output once it has, the same way `docs/deployment.md` records Phase 1–5's target-machine results.

## 1. Architecture

```
ai_service (FastAPI)
  ├─ GET /metrics ─────────────► Prometheus (kube-prometheus-stack) ─► Grafana
  └─ OTLP (traces + logs) ─────► OTel Collector ──┬─► Tempo (traces) ─► Grafana
       http://otel-collector    :4318/v1/traces    └─► Loki (logs)   ─► Grafana
       .observability.svc      :4318/v1/logs
       .cluster.local:4318
```

Metrics take the scrape path (`ai_service` exposes `/metrics`; Prometheus, via a `ServiceMonitor`, pulls from it) — matching ADR-06. Traces and logs take the push path (`ai_service` sends OTLP batches to the Collector, which fans them out to Tempo and Loki respectively) — also ADR-06. Grafana is the one place all three come together, provisioned with Prometheus, Loki and Tempo as datasources by `kube-prometheus-stack-values.yaml`.

Everything in this phase lives in its own `observability` namespace, separate from `polaris-dev`/`polaris-staging`/`polaris-prod`. `ai_service`'s `NetworkPolicy` gained one ingress rule this phase, scoped to that namespace only, so Prometheus can reach `/metrics`.

## 2. `ai_service` instrumentation

### 2.1 Metrics — always on

`GET /metrics` (Prometheus text format) is exposed unconditionally by `setup_telemetry()`, using `prometheus-fastapi-instrumentator` with a private `CollectorRegistry()` per app instance (never `prometheus_client`'s process-global registry — sharing it caused real cross-test collisions during development, see `docs/troubleshooting.md`). It costs nothing extra when nobody scrapes it, and needs no configuration.

Cardinality-safe by construction, matching ADR-20's existing discipline against unbounded label values:

| Metric | Labels | Notes |
|--------|--------|-------|
| `http_requests_total` | `handler`, `method`, `status` | `handler` is the matched route template (`/v1/chat`), never the raw path; unmatched routes get `handler="none"`, not the raw, unbounded path. `status` is grouped (`2xx`/`4xx`/`5xx`), not the raw code |
| `http_request_duration_seconds` (histogram) | `handler`, `method` | Used for the dashboard's p50/p95/p99 panels via `histogram_quantile` |

`/metrics` and `/healthz`/`/readyz` are all logged at `DEBUG` by the existing access logger (ADR-20) — probe traffic does not clutter `INFO`-level logs.

### 2.2 Traces and logs — opt-in

Off by default (`POLARIS_OTEL_ENABLED=false`). When enabled, `setup_telemetry()` builds a `TracerProvider` and a `LoggerProvider`, each tagged with a `Resource` (`service.name=ai-service`, `service.version`, `deployment.environment`), and exports both over OTLP/HTTP to the Collector, batched (`BatchSpanProcessor`/`BatchLogRecordProcessor` — a slow or unreachable collector never slows a request; verified directly by `test_requests_are_not_slowed_by_an_unreachable_collector`).

Two decisions worth knowing before touching this code, both explained in full in ADR-27:

- The OTel log handler attaches to the `"ai_service"` logger, never the root logger. Attaching to root creates a real, reproducible loop where a failed export's own warning gets logged right back through the same handler.
- Neither provider is installed as the process-global OTel default (`set_tracer_provider`/`set_logger_provider` are never called) — both are passed explicitly to `FastAPIInstrumentor.instrument_app()` and `LoggingHandler()` instead, because the global is settable only once per process and `create_app()` runs many times (every test, and in principle more than once in a long-lived process too).

### 2.3 Configuration (`POLARIS_*`, `app/ai_service/src/ai_service/config.py`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `POLARIS_ENVIRONMENT` | `local` | Free text, becomes the `deployment.environment` resource attribute on every trace/log (`dev`/`staging`/`prod` in the Helm chart's per-environment values) |
| `POLARIS_OTEL_ENABLED` | `false` | Turns on OTLP trace/log export. Metrics (`/metrics`) are unaffected by this flag — always on |
| `POLARIS_OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.observability.svc.cluster.local:4318` | Base URL; `/v1/traces` and `/v1/logs` are appended per signal |
| `POLARIS_OTEL_EXPORTER_TIMEOUT_S` | `3.0` | Per-export timeout (max 10s), passed to both exporters. Bounds provider shutdown against an unreachable collector to roughly 3s per provider instead of the SDK's own ~10s default — see ADR-27 for the real timing measurement behind this default |

Try it locally: `POLARIS_OTEL_ENABLED=true POLARIS_OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 make app-run` against a Collector reachable at that address (for example, port-forwarded from the cluster once Section 3 below is installed).

## 3. Installing the platform (target machine)

Cluster must already be up (`make cluster-up`). All commands below go through `scripts/bootstrap/observability.sh` (`make obs-*` wrappers) — the same "no manual `kubectl`/`helm` command outside a script" convention every earlier phase's bootstrap scripts follow.

```bash
make obs-install               # namespace, kube-prometheus-stack, dashboard ConfigMap, Loki, Tempo, OTel Collector
make obs-status                # helm list -n observability + pod status
make obs-password               # Grafana admin password
make obs-grafana                # port-forward Grafana to http://localhost:3000
make obs-dashboard-configmap    # regenerate the dashboard ConfigMap from dashboards/ai-service-dashboard.json
make obs-uninstall              # removes all four releases, the dashboard ConfigMap and the namespace
```

`make obs-install` prints the actually-resolved Loki and Tempo chart versions after installing (see Section 5) — read that output and pin `LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION` in `versions.env` in a follow-up commit; do not guess at them beforehand.

**Turning scraping and export on for `ai-service`.** `helm/ai-platform/values.yaml` defaults `serviceMonitor.enabled` and `config.POLARIS_OTEL_ENABLED` to `false` in every environment. Only `values-dev.yaml` turns both on. **Install the observability stack first** (`make obs-install`), confirm the `ServiceMonitor` CRD exists (`kubectl get crd servicemonitors.monitoring.coreos.com`), and only then apply or sync `polaris-dev` — applying it in the wrong order fails with `no matches for kind "ServiceMonitor"`. This ordering hazard, and why the defaults are split this way instead of turned on everywhere, is ADR-27.

`values-staging.yaml`/`values-prod.yaml` deliberately do not enable either flag this phase — the stack is proved in `polaris-dev` only in this delivery.

## 4. The dashboard

`deploy/platform/observability/dashboards/ai-service-dashboard.json` (Grafana UID `polaris-ai-service`), provisioned automatically by kube-prometheus-stack's Grafana sidecar via a `ConfigMap` labelled `grafana_dashboard: "1"` — no manual import step. Seven panels, all scoped to `namespace="polaris-dev"` (the only environment wired up this phase):

| Panel | Source | Query shape |
|-------|--------|-------------|
| Request rate by route | Prometheus | `sum(rate(http_requests_total[5m])) by (handler, method)` |
| Error rate (4xx+5xx / total) | Prometheus | Ratio of grouped-status counters |
| Latency p50/p95/p99 | Prometheus | `histogram_quantile` over `http_request_duration_seconds_bucket` |
| Pod restarts | Prometheus (kube-state-metrics) | `kube_pod_container_status_restarts_total{container="ai-service"}` |
| Pod CPU usage | Prometheus (cAdvisor/kubelet) | `rate(container_cpu_usage_seconds_total[5m])` |
| Pod memory (working set) | Prometheus (cAdvisor/kubelet) | `container_memory_working_set_bytes` |
| Recent logs | Loki | `{service_name="ai-service"}` — the Loki label OTLP's `service.name` resource attribute maps to |

`ai-service-dashboard-configmap.yaml` embeds the JSON verbatim; edit the `.json` file, never the ConfigMap directly, and regenerate with `make obs-dashboard-configmap` (`tests/bootstrap/test_static.sh` fails the build if the two drift).

## 5. Known limitations, honestly

- **Partially run on the target machine (2026-09-24).** `kube-prometheus-stack` installed cleanly (`STATUS: deployed`, all four pods `Running`). Loki, Tempo, the OTel Collector and `ai-platform-dev`'s own rollout with observability enabled are not yet confirmed — a real Loki chart-usage bug (`deploymentMode`, see `docs/troubleshooting.md`) blocked the run before it reached them, and the run ended with `make obs-uninstall`, so the next attempt starts from a clean namespace. Treat everything past "kube-prometheus-stack installs" as "expected to work", not "confirmed to work", until this document is updated again with real output.
- **`LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION` are deliberately unpinned.** Both charts moved to a new, fast-moving upstream repository (`grafana-community/helm-charts`) during 2026; a version pinned from a single fetch during this project's development was already shown to disagree with a fetch made minutes later. `make obs-install` prints the real, resolved version — pin it from that output, not from this document.
- **`polaris-staging`/`polaris-prod` are not wired up.** `serviceMonitor.enabled`/`POLARIS_OTEL_ENABLED` stay `false` there this phase (ADR-27); extending Section 3's install to those environments is future work, not a bug.
- **Resource requests/limits are still Phase 3's estimate.** Phase 9 makes the real data to fix that *possible* (Prometheus + cAdvisor/kubelet metrics, now queryable) — it does not, by itself, replace the guessed numbers. That still needs a human reading real Grafana panels under real load.
- **No trace/log correlation, no cross-service propagation, no attribute curation.** That is Phase 10's explicit scope, not this phase's — the OTel SDK calls here are enough to get spans and structured logs into Tempo/Loki, not to make them maximally useful together yet.

See ADR-27 for the full reasoning behind every default and simplification named above, `docs/troubleshooting.md`'s Phase 9 section for the real bugs found while building this (and the ones anticipated but not yet observed on a live cluster), and `docs/component-qa.md`'s Phase 9 section for the six-question interview answers on both the application instrumentation and the platform itself.
