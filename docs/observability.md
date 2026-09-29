# Observability

Covers **Phase 9** (metrics, logs and traces for `ai_service`, and the platform that collects, stores and displays them: kube-prometheus-stack, Loki, Tempo, the OTel Collector, one Grafana dashboard) and **Phase 10** (OpenTelemetry: curating what Phase 9's spans/logs actually carry down to `docs/architecture.md` section 6's allow-list, deliberate log↔trace correlation, cardinality documented — section 5 below). Cross-service trace propagation, the remaining piece of Phase 10's roadmap line, stays out of scope until Phase 12's gateway exists — see ADR-28.

**Verified state, Phase 9: confirmed on the target machine, 2026-09-25.** All three observability signals — metrics, logs and traces — were confirmed with real data flowing end to end (a real `/v1/chat` request, its structured logs in Loki, its trace in Tempo, matching `trace_id`s across all three). The Grafana dashboard was opened and checked against real data: six of seven panels populated correctly, and the seventh (error rate) correctly showed no data since no 4xx/5xx traffic had occurred yet — not a bug. Five real bugs were found and fixed on the target machine across five real sessions (2026-09-24/25); the full evidence trail (commands run, real output, what was wrong and why) is in `docs/troubleshooting.md`, and the reasoning behind every default is in ADR-27. Two small, non-blocking observations remain open and are listed in section 6 below.

**Verified state, Phase 10: verified in the sandbox, not yet re-confirmed on the target machine.** `app/ai_service`'s test suite (145 tests, up from 141; 98.74 % coverage; ruff clean) genuinely exercises every claim this document makes about curated attributes and correlation — each one was captured from a real (patched-exporter) test run, not read off documentation. See ADR-28 for the full record, including a real SDK-version-specific finding (attribute mutation after `Span.end()` does not work the way the obvious approach assumes) that was caught by testing rather than assumed. What is still open: re-confirming the curated attribute set against a real Tempo/Loki on the target machine, the same "sandbox first, target machine confirms" order every earlier phase has followed.

The platform layer (four Helm releases, the Grafana dashboard, `scripts/bootstrap/observability.sh`) is unchanged by Phase 10 and remains as Phase 9 left it, confirmed on the target machine (section 3 below).

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

### 2.4 What a span/log actually carries (Phase 10)

Section 5 below covers this in full; in short, `setup_telemetry()` now curates every exported span down to `docs/architecture.md` section 6's allow-list (`tenant_id`, `request_id`, `model`, `endpoint`, `http.status_code`, `latency_ms`, `prompt_tokens`, `completion_tokens` — `model_version`/`prompt_version` are allow-listed but never set, a documented gap) before Phase 9's own `OTLPSpanExporter` ever sees it, and the same `LOG_FIELDS` allow-list that already governed stdout now also governs what reaches Loki.

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

`ai-service-dashboard-configmap.yaml` embeds the JSON verbatim; edit the `.json` file, never the ConfigMap directly, and regenerate with `make obs-dashboard-configmap` (`tests/bootstrap/test_static.sh` fails the build if the two drift). No panel shows traces yet (out of this seven-panel scope) — traces were confirmed separately, direct against Tempo's own query API (`docs/troubleshooting.md`, Phase 9).

## 5. Phase 10: attribute curation, log↔trace correlation, cardinality

Full design record: ADR-28. This section is the practical "what changed, what it looks like now" summary.

### 5.1 Span attributes

Before this phase, a span for `POST /v1/chat` carried whatever FastAPI's/OpenTelemetry's auto-instrumentation puts on by default — confirmed for real from a trace pulled out of Tempo during Phase 9 development: `http.status_code`, but also `http.url`, `net.peer.ip`, `net.peer.port`, `http.user_agent`, none of which are on `docs/architecture.md` section 6's allow-list (`net.peer.ip` specifically sits on the "Never, unless explicitly justified" side of it). `_FilteringSpanExporter` (`telemetry.py`) now rebuilds every finished span with only the allow-listed names before `OTLPSpanExporter` ever sees it. After this phase, the same span carries exactly:

| Attribute | Source |
|-----------|--------|
| `tenant_id` | Set explicitly in `main.py`'s `/v1/chat` handler — nothing HTTP-level knows about it |
| `request_id` | Same |
| `model` | Set on success, from the backend's own answer |
| `endpoint` | Renamed from the auto-instrumentation's `http.route` (already cardinality-safe: the route template, not the raw path) |
| `http.status_code` | Auto-instrumentation; kept as-is, already spelled the way the allow-list spells it |
| `latency_ms` | Set explicitly, on success |
| `prompt_tokens` / `completion_tokens` | Set explicitly, on success, when the backend reports them |
| `model_version` / `prompt_version` | **Allow-listed, never set.** No source of truth exists yet — `BackendResult` has no version field beyond the model name, and there is no prompt-template system. Documented here rather than faked; see ADR-28 |

`env`/`deployment_version` (the allow-list's other two names) are not span attributes — they are the `deployment.environment`/`service.version` `Resource` attributes Phase 9 already attaches to every span and log a provider exports (see 5.3).

### 5.2 Log attributes

`logging_setup.py`'s `LOG_FIELDS` already kept stdout safe from Phase 9 onward. Before this phase, OpenTelemetry's `LoggingHandler` read a log record's raw `extra` fields directly, with no knowledge of that list — a value the stdout formatter silently dropped could still have reached Loki over OTLP undetected. `_LogAttributeAllowlistFilter` now attaches the exact same `LOG_FIELDS` tuple to the OTel log handler, so one allow-list governs both paths. The only fields present on an exported log record that are not in `LOG_FIELDS` are `code.file.path`/`code.function.name`/`code.line.number`, added automatically by OpenTelemetry itself after the filter runs — standard source-location metadata, not application data, left uncurated on purpose (ADR-28).

### 5.3 Log↔trace correlation

Already worked from Phase 9 onward, as a side effect of `LoggingHandler` reading the active OTel span context (this is how the real Loki↔Tempo correlation in `docs/troubleshooting.md`'s Phase 9 section happened, before this phase touched anything). This phase makes it deliberate: a dedicated test (`test_log_records_reaching_otel_are_correlated_with_their_span`) pins it down, and `TraceContextFilter` (`logging_setup.py`) now stamps the same `trace_id`/`span_id` onto **stdout** log lines too — not only the copy that reaches Loki — so `kubectl logs` alone, without going through Loki first, is enough to find the matching trace in Tempo. Present only while `POLARIS_OTEL_ENABLED=true` and a span is actually active; silently absent otherwise (confirmed by `test_stdout_logs_carry_trace_id_only_while_otel_is_enabled_and_a_span_is_active`).

### 5.4 Cardinality, documented

`docs/architecture.md` section 9's rule: a metric *label* creates one time series per unique value combination, so only bounded-cardinality values belong there; unbounded values belong in logs/traces instead, where a new value per request is normal and expected.

| | Bounded (safe as a metric label) | Unbounded (trace/log attribute only) |
|---|---|---|
| Already in this codebase | `handler` (route template, not raw path — section 2.1 above), grouped `status` (`2xx`/`4xx`/`5xx`, not the raw code), `method` | `request_id`, `trace_id`/`span_id`, `tenant_id` (small today, but not metric-label-bounded by construction — see below) |
| Why | A fixed, small set of route templates and status classes — Prometheus's own cardinality stays flat as traffic grows | A new value on every request (`request_id`/`trace_id`) or, for `tenant_id`, a value this service does not itself bound (nothing stops a new tenant onboarding tomorrow) |

`tenant_id` is worth calling out specifically: it is on the *span/log* allow-list (section 6 of `docs/architecture.md`), never on the *metric label* allow-list (section 9), and this codebase already respects that split — `http_requests_total`/`http_request_duration_seconds` (section 2.1 above) carry no `tenant_id` label, confirmed by reading `telemetry.py`'s `Instrumentator()` call, which only ever gets `handler`/`method`/`status` from `prometheus-fastapi-instrumentator`'s own defaults. If a future phase adds a *metrics* answer to "requests per tenant", it needs a small, explicitly bounded label (a capped list of known tenant slugs, not the raw field), not simply reusing `tenant_id` as a label — that would be exactly the unbounded-cardinality mistake section 9 warns against.

## 6. Known limitations, honestly

- **All four observability Helm releases confirmed on the target machine, across five real sessions (2026-09-24/25).** Every real bug found while installing and using the stack, and its fix, is in `docs/troubleshooting.md`'s Phase 9 section; the reasoning behind every default is ADR-27. `ai-platform-dev`'s rollout with observability enabled, and the Grafana dashboard showing real data, are both confirmed (section 4 above) — this is no longer "expected to work", it is "confirmed to work, with the exact evidence trail".
- **Two small, non-blocking observations from that confirmation remain open**, both in `docs/troubleshooting.md`'s Phase 9 section: a Grafana pod restart with `Exit Code: 2` (not the earlier, since-fixed OOMKilled issue), plausibly a liveness-probe timeout during an unusually slow cold start — not re-observed since, pod stable for 7+ minutes at the time; and a handful of sparse OTLP span-export timeout warnings in `ai_service`'s own logs, confirmed not systemic (the specific trace checked got through fine), but not fully root-caused either.
- **`LOKI_CHART_VERSION`/`TEMPO_CHART_VERSION`**, per `docs/troubleshooting.md`, are pinned as of the confirmed install (Loki `18.13.5`, Tempo `3.0.0`) — re-resolve from a real `helm list -n observability` before trusting these numbers far into the future; both charts live on a fast-moving upstream repository.
- **`polaris-staging`/`polaris-prod` are not wired up.** `serviceMonitor.enabled`/`POLARIS_OTEL_ENABLED` stay `false` there (ADR-27); extending Section 3's install to those environments is future work, not a bug.
- **Resource requests/limits are still Phase 3's estimate**, except Grafana's own memory limit (raised 256Mi→512Mi after a real, confirmed OOMKilled loop — `docs/troubleshooting.md`). Phase 9 makes the real data to fix the rest *possible* (Prometheus + cAdvisor/kubelet metrics, now queryable) — it does not, by itself, replace the remaining guessed numbers. That still needs a human reading real Grafana panels under real load.
- **Cross-service trace propagation is not attempted.** `ai_service` is still the only service in this project until Phase 12's gateway exists (`telemetry.py`'s own comment says so, and ADR-28 keeps it that way deliberately) — there is nothing to propagate a trace *across* yet.
- **`model_version`/`prompt_version` are allow-listed but never populated** (section 5.1 above) — no source of truth exists yet for either.
- **Phase 10's attribute curation is verified in the sandbox, not yet re-confirmed on the target machine** against a real Tempo/Loki — the next real step for this phase.

See ADR-27/ADR-28 for the full reasoning behind every default and simplification named above, `docs/troubleshooting.md`'s Phase 9 section for the real bugs found while building and confirming this, and `docs/component-qa.md`'s Phase 9 and Phase 10 sections for the six-question interview answers.
