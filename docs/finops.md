# FinOps: cost and usage attribution

Covers **Phase 13**: tenant-labelled request/token/inference-time counters in `ai_service` and
`ai-gateway`, an OpenCost install reading the existing Prometheus for cluster resource cost, a
local illustrative rate card, and a Grafana dashboard that combines the two into a per-tenant
cost estimate. `docs/architecture.md` section 18's exact "Done when" wording for this phase:
*"Tenant → requests → resources → *estimated* cost dashboard; OpenCost evaluated."*

**Verified state: built and tested in the sandbox; target-machine verification pending.** Every
line of new application code (the four counters, §2.1) runs under both services' own real test
suites — `app/ai_service` grew from 151 to 159 tests (99.21 % coverage), `app/gateway` from 43 to
51 (96.07 % coverage), both still above the project's 95 % gate, both confirmed with `make
app-check`/`make gateway-check`. The infrastructure half (the OpenCost Helm install, the
dashboard actually showing real numbers) has **not** been run against a real cluster — there is
no cluster or `helm` binary in this sandbox, same constraint every previous phase's bootstrap
script already documents. Two specific things are named as open gaps rather than guessed at; see
§4 and §6.

## 1. Architecture

```
ai-gateway (polaris-dev)              ai_service (polaris-dev)         model-serving
┌───────────────────────┐             ┌───────────────────────┐       ┌─────────────┐
│ ai_gateway_requests_   │             │ ai_requests_total      │       │   Ollama    │
│  total{tenant_id,      │   proxy     │  {tenant_id,model,     │ HTTP  │  (Phase 11) │
│   outcome} ────────────┼─────────────┼─► outcome}            │──────►│             │
│  (every outcome: auth, │             │ ai_tokens_total        │       └──────┬──────┘
│   mismatch, rate-limit,│             │  {tenant_id,model,kind}│              │
│   quota, upstream fail,│             │ ai_inference_seconds_  │      cAdvisor│kube-state-metrics
│   proxied)             │             │  total{tenant_id,model}│              │
└───────────┬────────────┘             └───────────┬────────────┘              │
            │ scrape (/metrics)                    │ scrape (/metrics)         │
            └──────────────────┬────────────────────┴───────────────────────────┘
                                ▼
                    Prometheus (Phase 9, 'observability')
                                │                              ┌─────────────┐
                                │◄─────── reads cAdvisor /──────┤  OpenCost   │
                                │         kube-state-metrics    │ ('finops' ns)│
                                │                                │ + local rate │
                                │                                │   card       │
                                │         node_cpu_hourly_cost,  └─────────────┘
                                │         container_cpu_allocation, ...
                                ▼
                    Grafana 'Polaris FinOps' dashboard (finops-dashboard.json)
                    tenant cost = tenant's counter share × OpenCost's namespace cost estimate
```

Two signal families, both already flowing into the same Prometheus, combined only at query
time, in Grafana — no new application code joins them, and no recording rule caches the join
(see §4 for why that is a deliberate, not merely convenient, choice).

## 2. What changed

### 2.1 Four new Prometheus counters (new)

| Metric | Where | Labels | Recorded |
|---|---|---|---|
| `ai_requests_total` | `ai_service/telemetry.py` (`FinOpsMetrics`) | `tenant_id`, `model`, `outcome` (`success`\|`backend_timeout`\|`backend_error`) | Every `/v1/chat` call that reached this service, every outcome |
| `ai_tokens_total` | same | `tenant_id`, `model`, `kind` (`prompt`\|`completion`) | Success only, and only when the backend actually reported that count |
| `ai_inference_seconds_total` | same | `tenant_id`, `model` | Success only — the handler's own measured wall-clock latency, in seconds |
| `ai_gateway_requests_total` | `gateway/telemetry.py` | `tenant_id`, `outcome` (`unauthorized`\|`tenant_mismatch`\|`rate_limited`\|`quota_exceeded`\|`upstream_timeout`\|`upstream_unreachable`\|`proxied`) | Every `/v1/chat` call the gateway handled, every outcome |

All four are plain `Counter`s, registered on the same per-app `CollectorRegistry` each service's
`setup_telemetry()` already builds for the generic `prometheus-fastapi-instrumentator` metrics —
never a second registry and never the process-global default one (the exact Phase 9 regression
`telemetry.py`'s own module docstring already documents: a shared global registry silently
serves only the first app instance built in a process). Unconditional, like `/metrics` itself —
never gated on `POLARIS_OTEL_ENABLED`/`GATEWAY_OTEL_ENABLED`, which only gate tracing/logging.

`model="unknown"`/`tenant_id="unknown"` appear deliberately in a few failure paths (a backend
timeout has no `GenerateResult` to read a real model name from; an unauthorized gateway request
never resolved a tenant at all) — named placeholders, not missing data. A `tenant_mismatch` is
counted under the tenant the API key actually resolved to, never the tenant claimed in the
request body — counting the claimed value would let anyone pollute another tenant's cost series
just by naming it in a request.

See ADR-31 for the full reasoning, and `app/ai_service/tests/test_finops_metrics.py` /
`app/gateway/tests/test_finops_metrics.py` for the real tests (both read the actual `/metrics`
exposition text, the same way Prometheus itself would scrape it).

### 2.2 OpenCost (new)

`deploy/platform/finops/` — a Helm install (`opencost-charts/opencost`) into its own `finops`
namespace, reading the Phase 9 Prometheus for cAdvisor/kube-state-metrics data
(`opencost-values.yaml`'s `opencost.prometheus.internal.*`) rather than bringing a second
monitoring stack. `OPENCOST_CHART_VERSION` in `versions.env` is deliberately left **empty** —
the same "resolve for real, then pin" two-step Loki/Tempo already use (Phase 9), since
OpenCost's own chart repo is the same unreachable-from-this-sandbox `*.github.io` page category.

### 2.3 The local rate card (new)

`opencost-values.yaml`'s `opencost.customPricing` block (`provider: custom`, since there is no
cloud billing API for an on-prem k3d cluster to call) — confirmed as the documented, correct
mechanism from OpenCost's own on-prem configuration docs, not guessed. The numbers themselves
(`CPU: 0.03`, `RAM: 0.004`, `storage: 0.0001`, all $/hour) are explicitly illustrative, loosely
anchored to a small on-demand cloud VM's blended per-vCPU/GB price — **not** real electricity or
cloud costs, and every dashboard panel built from them says so in its own title.

### 2.4 The Grafana dashboard (new)

`deploy/platform/finops/dashboards/finops-dashboard.json` (regenerate the ConfigMap with `make
finops-dashboard-configmap` after editing it — same generator pattern as Phase 9's
`ai-service-dashboard.json`). Seven panels: a top text panel repeating the ESTIMATE warning,
requests/tokens/inference-time by tenant (real counters, no rate card involved), namespace-level
estimated hourly cost from OpenCost, and the two tenant-attribution panels described in §4.

## 3. Installing (target machine)

```bash
make obs-install          # if not already running (Phase 9) -- OpenCost reads its Prometheus
make finops-install       # installs OpenCost into the 'finops' namespace, applies the dashboard
make finops-status        # Helm release + pod status
make finops-ui            # port-forward the OpenCost UI to http://localhost:9090
```

If the dashboard's cost panels show no data, check, in this order: (1) the Prometheus Service
name `opencost-values.yaml` assumes (`kubectl -n observability get svc`, §6); (2) whether
Prometheus itself is scraping OpenCost's own `/metrics` back out at all (§6); (3) whether any
real `/v1/chat` traffic has happened yet (the counter panels need traffic; the cost panels need
both traffic and OpenCost's own allocation metrics to be non-zero).

## 4. Cost-attribution methodology, exactly

`docs/architecture.md` section 11's cost model, worked out as real PromQL rather than left as
prose:

**Model-serving cost, by inference-seconds share** (one tenant's fraction of all inference time,
times OpenCost's own estimate for the whole `model-serving` namespace):

```promql
(
  sum(rate(ai_inference_seconds_total{namespace="polaris-dev"}[1h])) by (tenant_id)
  /
  scalar(sum(rate(ai_inference_seconds_total{namespace="polaris-dev"}[1h])))
)
*
scalar(
  sum(container_cpu_allocation{namespace="model-serving"}) * avg(node_cpu_hourly_cost)
  + (sum(container_memory_allocation_bytes{namespace="model-serving"}) / 1024 / 1024 / 1024)
    * avg(node_ram_hourly_cost)
)
```

**Gateway/service cost, by request share** (the identical shape, substituting the gateway's own
counter — and only its `outcome="proxied"` requests, since a rejected request never actually
reached `ai_service` and cost it nothing — for the namespace both services share, `polaris-dev`):

```promql
(
  sum(rate(ai_gateway_requests_total{namespace="polaris-dev",outcome="proxied"}[1h])) by (tenant_id)
  /
  scalar(sum(rate(ai_gateway_requests_total{namespace="polaris-dev",outcome="proxied"}[1h])))
)
*
scalar(
  sum(container_cpu_allocation{namespace="polaris-dev"}) * avg(node_cpu_hourly_cost)
  + (sum(container_memory_allocation_bytes{namespace="polaris-dev"}) / 1024 / 1024 / 1024)
    * avg(node_ram_hourly_cost)
)
```

Both live only in the dashboard JSON (`finops-dashboard.json`), not in application code or a
Prometheus recording rule — the join is cheap enough to compute at query time on a dashboard
that refreshes every 30s, and keeping it there means the methodology is visible by opening the
dashboard's own panel editor, not hidden inside a rule file nobody browsing Grafana would think
to check.

### Notional per-1000-token showback (documented, not built)

`docs/architecture.md` section 11 calls this "optional." The formula, if a tenant's total
estimated hourly cost (the two panels above, summed) is divided by that tenant's token volume:

```
showback_per_1k_tokens(tenant) =
    (model_serving_cost(tenant) + gateway_service_cost(tenant))
    / (sum(rate(ai_tokens_total{tenant_id=tenant}[1h])) / 1000)
```

Not built as a dashboard panel this phase: stacking a third division on top of two cost numbers
that are themselves unverified against a real cluster (§6) risked producing a confident-looking
but meaningless figure. Worth adding once §6's two gaps are closed for real.

## 5. Configuration

No new `POLARIS_*`/`GATEWAY_*` environment variables — the four counters are unconditional, the
same as `/metrics` itself (§2.1). The only new configuration surface is
`deploy/platform/finops/opencost-values.yaml` (the Prometheus pointer and the rate card, both
§2.2/§2.3) and `versions.env`'s two new `OPENCOST_*` entries.

## 6. Known limitations, honestly

- **The Prometheus Service name OpenCost is pointed at is inferred, not confirmed.**
  `opencost-values.yaml`'s `serviceName: kube-prometheus-stack-prometheus` follows the standard
  Helm `fullnameOverride` convention applied to `kube-prometheus-stack-values.yaml`'s own
  `fullnameOverride: kube-prometheus-stack` — but there is no cluster in this sandbox to run
  `kubectl -n observability get svc` against and confirm it for real. If `make finops-install`
  shows no data, this is the first thing to check and, if wrong, correct in that file.
- **Whether Prometheus scrapes OpenCost's own cost-allocation metrics back out is unconfirmed.**
  OpenCost's own docs point at a separate chart (`prometheus-community/prometheus-opencost-
  exporter`) for this, not a flag on the `opencost` chart installed here. Guessing a values key
  was judged riskier than leaving this as a named, explicit target-machine step (`helm show
  values opencost-charts/opencost`, then decide whether that second chart is needed).
- **The rate card is illustrative, not real.** Every panel built from it says "(ESTIMATE)" in
  its own title and the dashboard's `description` repeats the warning — but if this dashboard is
  ever shown to someone who did not read this file, the numbers could be mistaken for a real
  bill. Worth a louder in-UI warning (an annotation banner, say) if this dashboard is ever
  shown outside this project's own development loop.
- **Tenant attribution never accounts for idle/shared cost beyond CPU/RAM allocation.**
  `pv_hourly_cost` (persistent volumes — the model-serving PVC from Phase 11) and any
  node-level overhead `nodeExporter: false` (Phase 9, ADR-27) would otherwise have surfaced are
  not attributed to any tenant at all. Named here, not silently absorbed into one tenant's
  number or quietly dropped from the total.
- **The showback formula (§4) is documented, not dashboarded** — see §4 for why.
- **No real cluster has run any of this.** `make finops-install`, the dashboard rendering real
  non-zero numbers, and the two gaps above are this phase's target-machine step, same as every
  previous phase's own handoff — see `docs/troubleshooting.md`'s Phase 13 section for exactly
  what to check first.
