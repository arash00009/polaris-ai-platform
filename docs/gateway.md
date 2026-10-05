# API gateway

Covers **Phase 12**: `ai-gateway`, a new FastAPI service in front of `ai-service` that
authenticates every request, derives the caller's tenant from its API key (never from the request
body), enforces a per-tenant rate limit and daily quota, and propagates request IDs and W3C
`traceparent` end to end. `docs/architecture.md` section 18's exact "Done when" wording for this
phase: *"Gateway with auth, per-tenant rate limit, request IDs, error handling (streaming if
practical)."*

**Verified state: written and unit-tested in the sandbox only — not yet run against a real
cluster.** `app/gateway` is a brand-new package (43 tests, 95.98 % coverage, `ruff check`/`ruff
format --check` both clean) exercised entirely against `httpx.MockTransport` fakes; no Docker
daemon, `helm` binary or cluster exists in this sandbox (confirmed: `docker info` fails, `helm` is
not installed, and `get.helm.sh` is blocked by this sandbox's egress proxy with HTTP 403), so the
container image, the Helm templates' rendered output, and the gateway's behaviour against a real
`ai-service` are all reviewed but not yet built/rendered/run for real. That is this phase's
target-machine step — see section 7 below for the exact commands. One genuine bug *was* found and
fixed by actually running this phase's own test suite (section 6), consistent with every earlier
phase's "verify, don't assume" discipline.

## 1. Architecture

```
                    polaris-<env> namespace
Client ──▶ Ingress ──▶ ai-gateway (new) ──▶ ai-service ──▶ Model backend
 (API key,               auth, tenant                       (mock / Ollama)
  traceparent)           derivation, rate                  │
                         limit, quota,                      │
                         request-id/                        │
                         traceparent                         │
                         propagation                          ▼
                             │                          OTel Collector
                             └──────────────────────────────▶ (traces/logs,
                                                                both services)
```

`ai-gateway` is a second Deployment/Service/ConfigMap/Secret/NetworkPolicy/ServiceMonitor in the
**same** Helm chart and release as `ai-service` (`helm/ai-platform/`), gated by a new
`gateway.enabled` boolean — the same "prove it in one environment first" pattern as
`POLARIS_OTEL_ENABLED` (Phase 9) and `POLARIS_BACKEND=openai_compat` (Phase 11). Only
`values-dev.yaml` turns it on; `values-staging.yaml`/`values-prod.yaml` are untouched, so this
phase changes nothing about those two environments' already-verified behaviour. When
`gateway.enabled` is `false` (the shared default), `ingress.yaml` and `networkpolicy.yaml` both
fall back to their pre-Phase-12 behaviour exactly — `ai-service` stays directly exposed, as it has
been since Phase 4.

`ai-gateway`'s pods carry their own, deliberately distinct `app.kubernetes.io/name: ai-gateway`
label (new `ai-platform.gatewayName`/`gatewaySelectorLabels`/`gatewayLabels` Helm helpers,
`_helpers.tpl`), never built on top of `ai-platform.name`/`selectorLabels`. `ai-service`'s own
Deployment selector is `app.kubernetes.io/name: ai-service` (from `values.yaml`'s
`nameOverride: "ai-service"`, not the chart's own default name) and is immutable on every
already-applied release since Phase 4/5 — giving the gateway a label set that could overlap it
would make `helm upgrade` fail outright or make two Deployments fight over the same pods. The two
values can't actually collide today, but a dedicated helper keeps that guarantee explicit and
reviewable rather than implicit in a `values.yaml` string nobody is required to keep distinct (see
ADR-30).

## 2. What changed

### 2.1 `app/gateway` (new package)

A second, independently deployable Python service — `src/gateway/` — deliberately **not** a
shared library with `app/ai_service`: no shared import exists anywhere in this repo (by design,
`docs/architecture.md` Part D), so a change to one service's code or config can never silently
alter the other's. A handful of config fields (`log_level`, `log_format`, `environment`,
`otel_*`) are intentionally duplicated from `ai_service/config.py` for the same reason.

| Module | Role |
|--------|------|
| `config.py` | `Settings` (env prefix `GATEWAY_`): upstream URL/timeout, the API-key→tenant map (`SecretStr`, never logged), rate-limit/quota numbers, log/OTel settings. Validates the keys map is a JSON object, every key ≥16 characters, every tenant id matches `ai_service`'s own `TENANT_ID_PATTERN`. |
| `schemas.py` | `ErrorResponse`/`ErrorDetail`/`ErrorBody` — the same shape as `ai_service`'s own error envelope, so a client cannot tell a gateway rejection from a service rejection by response shape alone; `StatusResponse` for `/healthz`/`/readyz`. |
| `auth.py` | `ApiKeyStore`: resolves an API key to a tenant id using `hmac.compare_digest` per candidate (constant-time comparison — a plain `==` loop would leak key-prefix-match timing). |
| `ratelimit.py` | `TokenBucketLimiter` (per-minute rate + burst, starts full) and `DailyQuota` (a fixed UTC calendar-day window) — both explicitly labelled **LOCAL/DEMONSTRATION** in their own module docstring: in-memory, per-pod state, lost on restart and multiplied by replica count. The **production equivalent** is a Redis-backed shared limiter (e.g. a Lua-scripted token bucket) — named, not built. |
| `logging_setup.py` / `telemetry.py` | Near-verbatim copies of `ai_service`'s own modules (`SERVICE_NAME = "ai-gateway"`), reusing the same span/log attribute allow-list from `docs/architecture.md` section 6 rather than inventing a gateway-specific subset. |
| `main.py` | `create_app()`: the middleware chain (request id → auth → tenant-mismatch check → rate limit → quota → proxy) and the one proxied route, `POST /v1/chat`. |

### 2.2 The `/v1/chat` request pipeline (`main.py`)

Exactly `docs/architecture.md` section 7's sequence diagram, implemented:

1. Resolve the caller's tenant from `x-api-key` via `ApiKeyStore.resolve()` — **401** `unauthorized`
   if the key is missing or unknown.
2. If the request body also carries a `tenant_id` field, compare it against the
   gateway-resolved tenant — **403** `tenant_mismatch` on a mismatch. A body that is missing,
   malformed or has no `tenant_id` field is never rejected here (`_tenant_id_in_body()` returns
   `None` on anything it cannot parse, by design) — full body validation stays `ai-service`'s job,
   same division of responsibility as before this phase.
3. Check `TokenBucketLimiter.allow(tenant_id)` — **429** `rate_limited` with a `Retry-After: 1`
   header on rejection.
4. Check `DailyQuota.allow(tenant_id)` — **429** `quota_exceeded`.
5. Forward the raw body to `ai-service` over `httpx`, stripping hop-by-hop headers
   (`connection`, `keep-alive`, `transfer-encoding`, `content-length`, `host`) and, critically,
   **`x-api-key` itself** — the gateway's own credential never reaches the upstream service.
   `x-request-id` and `x-tenant-id` are set from the gateway-resolved values, not whatever (if
   anything) the client sent.
6. `httpx.TimeoutException` → **504** `upstream_timeout`; any other `httpx.RequestError` → **502**
   `upstream_unreachable`. Otherwise the upstream's status, body and headers pass through
   unchanged.

`GET /healthz` has no upstream dependency (gateway-process liveness only). `GET /readyz` checks
`ai-service`'s own `/healthz` with `GATEWAY_READY_TIMEOUT_S` — **503** `not_ready` if it cannot be
reached.

### 2.3 Cross-service trace propagation (closing a Phase 10 gap)

Phase 10's own module docstring named this explicitly: *"Cross-service trace propagation...
explicitly deferred to Phase 12 — `ai_service` is still the only service in this project."* This
phase closes it with `opentelemetry-instrumentation-httpx`, wired into `main.py`'s `lifespan()`:

```python
if settings.otel_enabled:
    HTTPXClientInstrumentor().instrument_client(app.state.http_client)
```

**Per-client**, not the global `HTTPXClientInstrumentor().instrument()` form — see section 6 below
for why, and why that choice is a better design, not just a test-compatibility workaround.

### 2.4 The first real Kubernetes Secret in this project

Every earlier phase has gone through Phase 12 without ever needing a true Kubernetes `Secret` —
`ai-service` has none. The API-key→tenant map is this project's first: a plain `Secret` (type
`Opaque`, `stringData`), applied by a direct `helm upgrade --install` for dev only, **deliberately
bypassing GitOps (Argo CD)** so a cleartext key is never committed to the separate `polaris-gitops`
repository. It is **not** wired into Sealed Secrets — that is Phase 15's scope (ADR-30 names this
gap explicitly, same "name it, don't fake it" discipline as every other documented-not-built
item in this project).

## 3. Repository layout (new/changed)

```
app/gateway/
├── Dockerfile                          # multi-stage, non-root uid/gid 10002 (ai-service uses 10001)
├── pyproject.toml / requirements*.txt  # a separate package, pinned independently of ai_service
├── src/gateway/{config,schemas,auth,ratelimit,logging_setup,telemetry,main}.py
└── tests/{conftest,fakes,test_main,test_auth,test_ratelimit,test_config,test_telemetry}.py

helm/ai-platform/templates/
├── gateway-deployment.yaml / gateway-service.yaml / gateway-configmap.yaml
├── gateway-secret.yaml                 # stringData: GATEWAY_API_KEYS_JSON
├── gateway-networkpolicy.yaml / gateway-servicemonitor.yaml
└── _helpers.tpl                        # + ai-platform.gatewayName/gatewaySelectorLabels/gatewayLabels

deploy/platform/gateway/
└── api-keys.dev.example.json           # committed template, obviously-fake key; real files are gitignored

scripts/build/gateway-image.sh          # info/pin/build/run/check/push/scan/sbom/publish, mirrors image.sh
```

`scripts/deploy/helm.sh` gained `gateway_enabled_for()`/`gateway_api_keys_json_for()` and now
passes `--set gateway.image.*`/`--set-string gateway.apiKeysJson=...` to `lint`/`template`/`apply`
whenever the target environment has the gateway on; `cmd_logs` can select `ai-gateway` pods
(`make helm-logs-dev ARGS=gateway`); `cmd_smoke` adds a step verifying `POST /v1/chat` with no API
key returns 401 when the gateway is enabled. The `Makefile` gained a full `gateway-*`/
`gateway-image-*` target block mirroring the existing `app-*`/`image-*` ones.

## 4. Configuration (`GATEWAY_*`)

| Variable | Default | `values-dev.yaml` | Meaning |
|----------|---------|--------------------|---------|
| `GATEWAY_UPSTREAM_BASE_URL` | `http://ai-service:80` | (unchanged) | Same-namespace short DNS name — gateway and `ai-service` are always deployed into the same `polaris-<env>` namespace |
| `GATEWAY_UPSTREAM_TIMEOUT_S` | `95.0` | `95` | Must stay ≥ `ai-service`'s own `POLARIS_BACKEND_TIMEOUT_S` (Phase 11: `90` in dev) plus a margin — a shorter gateway timeout would 504 while `ai-service` is still legitimately waiting on a cold model load |
| `GATEWAY_API_KEYS_JSON` | `"{}"` | from `deploy/platform/gateway/api-keys.dev.local.json` (gitignored) via `--set-string` | API key → tenant id map; empty means every request gets 401 — fails closed, never open |
| `GATEWAY_RATE_LIMIT_PER_MINUTE` | `60` | (unchanged) | Token-bucket refill rate, per tenant |
| `GATEWAY_RATE_LIMIT_BURST` | `20` | (unchanged) | Token-bucket capacity, per tenant |
| `GATEWAY_QUOTA_PER_DAY` | `2000` | (unchanged) | Fixed UTC-calendar-day request ceiling, per tenant |
| `GATEWAY_OTEL_ENABLED` | `false` | `true` | Per-client httpx instrumentation + OTLP export, same opt-in pattern as `ai_service`'s `POLARIS_OTEL_ENABLED` (Phase 9) |

`values.yaml`'s shared defaults keep `gateway.enabled: false`; `values-staging.yaml`/
`values-prod.yaml` are untouched by this phase.

## 5. Installing and verifying (target machine — not yet run)

```bash
make gateway-install && make gateway-check          # local venv: lint + 43 tests + coverage gate
make gateway-image-build && make gateway-image-check # build the image, verify non-root/probes/auth/logs

cp deploy/platform/gateway/api-keys.dev.example.json deploy/platform/gateway/api-keys.dev.local.json
# edit api-keys.dev.local.json: delete the "_readme" key, replace the example key with a real one
# (python3 -c "import secrets; print('sk-' + secrets.token_urlsafe(24))"), gitignored by name

make helm-lint-dev && make helm-template-dev         # chart renders with gateway.enabled=true
make gateway-image-push                              # push to the local k3d registry
make helm-apply-dev                                  # direct helm upgrade --install, bypassing GitOps
                                                      # for this one Secret (section 2.4) — same as
                                                      # Phase 11's model-serving namespace, not GitOps-owned
make helm-smoke-dev                                  # now includes a no-API-key → 401 check
```

Every command above is written and reviewed, not yet executed against a real cluster — this
section is the exact, ordered handoff for the next session on the target machine.

## 6. One real bug, found by actually running the test suite

`test_otel_enabled_propagates_traceparent_to_upstream` failed the first time this phase's own
tests were run, after using the global `HTTPXClientInstrumentor().instrument()` form: the
`traceparent` header never reached the fake upstream. Root-caused by reading the installed
library's own source: the global form patches `httpx._transports.default.{HTTPTransport,
AsyncHTTPTransport}` at the class level — and `httpx.MockTransport` (every fake upstream in this
phase's test suite) implements its own `handle_async_request()`, which never goes through those
patched classes at all.

The fix — `instrument_client(client)`/`uninstrument_client(client)`, called on
`app.state.http_client` specifically, inside `lifespan()` — is not just a test-compatibility
workaround. It is a narrower-blast-radius design than the global form: instrumenting only the one
`httpx.AsyncClient` the gateway itself constructs, rather than patching every `httpx` transport in
the process, which is exactly the "process-global instrumentation" concern `ai_service/
requirements.txt`'s own comment gives for why that instrumentor was left out of `ai_service`
entirely. All 43 tests pass with this fix, including a double-instrumentation guard test (two
otel-enabled app instances in one process).

## 7. Known limitations, honestly

- **Not yet run against a real cluster.** Everything in section 5 is written and reviewed, not
  executed — no Docker daemon, `helm` binary or cluster exists in this sandbox. This is the single
  largest gap in this phase's delivery and the next session's first job.
- **Rate limiting and quota are per-pod, in-memory, and lost on restart** (section 2.1's
  `ratelimit.py`) — multiplied by `replicaCount` (deliberately `1` for the gateway in this
  delivery, precisely to make that limitation visible rather than hidden behind an
  already-multiplied number). The production equivalent is a Redis-backed shared limiter, named
  and not built.
- **No Sealed Secrets for `GATEWAY_API_KEYS_JSON`.** Applied via a direct `helm upgrade --install`
  for dev only, outside GitOps, specifically so no cleartext key is ever committed to
  `polaris-gitops`. Phase 15's scope, not silently faked here.
- **Streaming (SSE) and an Envoy Gateway evaluation are both scoped "if practical" / optional in
  this phase's own roadmap line, and are not attempted** — `ai-service`'s `/v1/chat` itself is not
  a streaming endpoint yet, so there is nothing for the gateway to stream through.
- **No authentication on the gateway→`ai-service` hop itself** — relies entirely on the
  `NetworkPolicy` restricting ingress to `ai-service` to only the gateway's pods when
  `gateway.enabled` (section 1). A compromised pod inside the same namespace could still reach
  `ai-service` directly; this is the same trust boundary every earlier phase in this project has
  drawn at the namespace/`NetworkPolicy` level, not a new gap introduced here.

See ADR-30 for the full reasoning behind every default and simplification named above, and
`docs/troubleshooting.md`'s Phase 12 section for the real bug found while building this phase in
the sandbox.
