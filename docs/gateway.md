# API gateway

Covers **Phase 12**: `ai-gateway`, a new FastAPI service in front of `ai-service` that
authenticates every request, derives the caller's tenant from its API key (never from the request
body), enforces a per-tenant rate limit and daily quota, and propagates request IDs and W3C
`traceparent` end to end. `docs/architecture.md` section 18's exact "Done when" wording for this
phase: *"Gateway with auth, per-tenant rate limit, request IDs, error handling (streaming if
practical)."*

**Verified state: confirmed on the target machine, 2026-10-05/07.** `app/gateway` (43 tests,
95.98 % coverage, `ruff check`/`ruff format --check` both clean) was built, pushed, deployed
through GitOps, and exercised against the real cluster: authentication (401), tenant-mismatch
rejection (403, ADR-18's design), per-tenant rate limiting (429 with `Retry-After`, burst=20
confirmed exactly), a genuinely successful proxied chat (200, real latency, real body), and one
real distributed trace in Tempo spanning both services with correct parent/child span linkage all
matched the design. Three real bugs were found and fixed along the way — one in the sandbox before
the target-machine run (section 6), two only found once this phase actually ran against a real
cluster (section 7.1) — plus one genuine, still-open GitOps limitation that is now named rather
than silently worked around forever (section 7.2). See section 7 for the full, honest accounting.

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

## 5. Installing and verifying (target machine — confirmed)

```bash
make gateway-install && make gateway-check          # local venv: lint + 43 tests + coverage gate
make gateway-image-build && make gateway-image-check # build the image, verify non-root/probes/auth/logs

cp deploy/platform/gateway/api-keys.dev.example.json deploy/platform/gateway/api-keys.dev.local.json
# edit api-keys.dev.local.json: delete the "_readme" key, replace the example key with a real one
# (python3 -c "import secrets; print('sk-' + secrets.token_urlsafe(24))"), gitignored by name

make helm-lint-dev && make helm-template-dev         # chart renders with gateway.enabled=true
make gateway-image-push                              # push to the local k3d registry
make gitops-bump-dev ARGS=--push                     # NOT make helm-apply-dev -- polaris-dev has been
                                                      # GitOps-managed (server-side apply) since Phase 8,
                                                      # so a direct helm upgrade --install now conflicts
                                                      # with argocd-controller's field ownership (the same
                                                      # class of conflict Phase 11's troubleshooting section
                                                      # already named); only the gateway's one real Secret
                                                      # (section 2.4) is still applied directly, separately
make helm-smoke-dev                                  # now includes a no-API-key → 401 check
```

Every command above ran for real on the target machine. One correction to this section's own
original plan, found while actually running it: `make helm-apply-dev` was the documented path when
this section was first written, but `polaris-dev` has been GitOps-managed since Phase 8 — the real
run used `scripts/gitops/bump-image-tag.sh --push` (via `make gitops-bump-dev`) instead, exactly
the same lesson Phase 11's own troubleshooting section already recorded for a config-only change.
See `docs/troubleshooting.md`'s Phase 12 section for the two real bugs this surfaced in
`bump-image-tag.sh` and `scripts/deploy/helm.sh` themselves, both fixed and re-confirmed.

## 6. One real bug, found in the sandbox by actually running the test suite

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

## 7. Target-machine verification (real)

### 7.1 Two more real bugs, found only by running this phase against a real cluster

Neither of these could have been caught by `httpx.MockTransport` fakes — both needed a real Helm
install and a real Argo CD render to surface:

- **`helm upgrade --install --set-string gateway.apiKeysJson=<raw JSON>` silently corrupted the
  value.** Helm's `--set`/`--set-string` strvals mini-language parses its argument as its own small
  grammar; unescaped `{`, `}`, `"`, `:` in a JSON blob are structural to that grammar, not passed
  through literally. The live Secret decoded to `["sk-...": "demo"]`, not `{"sk-...": "demo"}`, and
  the gateway 500'd every request with a pydantic `ValidationError`. Fixed by switching
  `scripts/deploy/helm.sh`'s `gateway_api_keys_json_for()` to return a file *path* and the call
  site to `--set-file` instead of `--set-string` — `--set-file` passes raw bytes through untouched.
- **Argo CD's own render of `ai-platform-dev` failed: `gateway.image.tag is required`.**
  `scripts/gitops/bump-image-tag.sh` had never been taught about the gateway — it only ever wrote
  `ai-service`'s own tag into `environments/<env>/image.yaml`. Fixed by extending the script with
  gateway-aware `gateway_version()`/`gateway_enabled_for()`/`need_pushed_gateway()`, which append a
  `gateway: {image: {...}}` block when the target environment turns the gateway on.

Full root-cause detail, the exact fix commits, and the confirm commands for both are in
`docs/troubleshooting.md`'s Phase 12 section.

### 7.2 A genuine, still-open GitOps limitation — named, not hidden

`apps/dev-app.yaml`'s Argo CD `Application` carries an `ignoreDifferences` entry for the
`ai-gateway-api-keys` Secret (`jsonPointers: [/data, /stringData]`), intended to let the chart's
`"{}"` placeholder and the real, directly-applied Secret content coexist without `selfHeal`
fighting the real value. **Tested twice on the real cluster, independently, and confirmed not to
work**: the entry is genuinely present on the live `Application` object's `spec`, `status`, *and*
its `last-applied-configuration` annotation both times — this is not a typo or a sync that never
picked up the change — and `selfHeal` still reverts the Secret's `stringData` back to `"{}"` on the
next reconciliation regardless.

This is now accepted as a real, confirmed limitation of `ignoreDifferences` against this specific
resource/field combination in this Argo CD version, not a configuration mistake to keep chasing.
The workaround used for testing — pausing `ai-platform-dev`'s `syncPolicy.automated` for the
duration, re-applying the real Secret, then **always restoring automated sync afterward** — is
exactly that: a workaround, not a fix, and it must never be left in place permanently (it silently
disables GitOps self-heal for the whole environment, not just this one Secret). The honest, durable
fix is the one already named in section 2.4 and ADR-30: a real secret manager (Sealed Secrets,
External Secrets Operator, or Vault) in `polaris-gitops` itself, which is Phase 15's scope.

### 7.3 Full functional verification results

| Check | Result |
|-------|--------|
| No API key → 401 | `401 unauthorized`, correct error envelope |
| Valid key, body `tenant_id` mismatches the key's tenant → 403 | `403 tenant_mismatch` — ADR-18's design confirmed working on the real cluster |
| Valid key, incomplete body (missing `tenant_id`) → passed through, `ai-service`'s own 422 | Confirmed the gateway does not duplicate body validation, as designed |
| 30 concurrent requests, one tenant, `rate_limit_burst: 20` | 20 × `200`, 10 × `429 rate_limited`, each with `Retry-After: 1` present on the wire |
| Valid key, valid tenant, warm backend → real chat | `200`, real `response`/`model`/`request_id`/`latency_ms` body, matching `ChatResponse` exactly |
| Cross-service trace propagation | One real trace in Tempo (`GET /api/traces/<traceId>`) with `ai-service`'s root span's `parentSpanId` equal to `ai-gateway`'s own span id — real W3C trace-context propagation, not just matching ids in logs |
| Daily quota (`quota_per_day: 2000`) | **Not driven to real exhaustion.** Deliberately not fired 2,000 times at an already resource-constrained host for a check that shares the identical `_error_response(429, ...)` code path the rate-limit test above already proved end-to-end, just gated by a different counter/threshold. Confirmed by code review and the sandbox's own unit tests only — a deliberate scope decision, named here rather than silently skipped |
| Streaming (SSE) | Not attempted — scoped "if practical" in the roadmap, and `ai-service`'s own `/v1/chat` is not a streaming endpoint yet (unchanged from section 6 of the architecture doc) |

A cosmetic, non-functional observation along the way: a proxied `200` response carries two `Date`
headers on the wire — one added by uvicorn for the gateway's own response, one copied through from
`ai-service`'s forwarded headers (`Date` is not in `main.py`'s `_DO_NOT_FORWARD` set, unlike
`content-length`/`connection`/etc.). Harmless — no client parses a duplicate header as an error —
but worth a one-line note rather than leaving it unremarked.

### 7.4 An environmental finding, confirmed not to be a code bug

Two `504`s were seen during testing — once `ai-service`'s own `backend_timeout`, once the
gateway's own `upstream_timeout`. Both were root-caused, not just retried past: a direct call
straight to Ollama's own API, bypassing the gateway and `ai-service` entirely, measured **109.8
seconds** for the exact same cold load, on a target machine whose load average (6.15/11.71/9.67)
was running at up to ~2x its 6 cores with swap already active. Phase 11's ~50.5s cold-load
measurement (ADR-29) was real, but was taken on a quieter machine; the 90s/95s timeout margin built
from it assumed broadly similar conditions, which did not hold this time. No code change resulted
— this is a host-resource-contention finding, not a gateway or `ai-service` defect, confirmed
precisely by the fact that the two distinct 504 error codes/messages correctly told apart *which*
service's timeout fired each time. See `docs/troubleshooting.md`'s Phase 12 section for the full
evidence and the exact diagnostic commands used.

## 8. Known limitations, honestly

- **Rate limiting and quota are per-pod, in-memory, and lost on restart** (section 2.1's
  `ratelimit.py`) — multiplied by `replicaCount` (deliberately `1` for the gateway in this
  delivery, precisely to make that limitation visible rather than hidden behind an
  already-multiplied number). The production equivalent is a Redis-backed shared limiter, named
  and not built.
- **No Sealed Secrets for `GATEWAY_API_KEYS_JSON`, and `ignoreDifferences` does not protect it
  from `selfHeal` either (section 7.2) — a confirmed, open gap, not a silently accepted one.**
  Phase 15's scope.
- **Daily quota was not driven to real exhaustion against the cluster** (section 7.3) — confirmed
  by code review and unit tests only, a deliberate scope decision given the identical code path
  rate limiting already proved live.
- **Streaming (SSE) and an Envoy Gateway evaluation are both scoped "if practical" / optional in
  this phase's own roadmap line, and are not attempted** — `ai-service`'s `/v1/chat` itself is not
  a streaming endpoint yet, so there is nothing for the gateway to stream through.
- **No authentication on the gateway→`ai-service` hop itself** — relies entirely on the
  `NetworkPolicy` restricting ingress to `ai-service` to only the gateway's pods when
  `gateway.enabled` (section 1). A compromised pod inside the same namespace could still reach
  `ai-service` directly; this is the same trust boundary every earlier phase in this project has
  drawn at the namespace/`NetworkPolicy` level, not a new gap introduced here.
- **A duplicate `Date` response header on every proxied response** (section 7.3) — cosmetic only.

See ADR-30 for the full reasoning behind every default and simplification named above, and
`docs/troubleshooting.md`'s Phase 12 section for every real bug and finding from both the sandbox
and the target machine.
