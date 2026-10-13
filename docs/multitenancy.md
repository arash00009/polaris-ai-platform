# Multi-tenancy: three real tenants, three real tiers

Covers **Phase 14**: three tenants calling through `ai-gateway`, each on a genuinely different,
*configured* rate-limit/quota tier — not three `tenant_id` strings sharing one flat default,
which is all Phase 12 ever built. `docs/architecture.md` section 18's exact "Done when" wording
for this phase: *"Three tenants with quotas, limits, attributed telemetry and cost."*

**Confirmed on the target machine, 2026-10-13.** `app/gateway`'s suite (51 → 64 tests, 96.51 %
coverage, `ruff check`/`ruff format --check` clean) was already green in the sandbox; the real
run on Darya additionally found and fixed three genuine target-machine bugs (none of them in
`gateway/ratelimit.py`/`config.py` themselves — see `docs/troubleshooting.md`'s Phase 14 section
for all of them) before `make tenants-smoke` produced its first real, trustworthy result:
**acme (42) > demo (23) > globex (9)** survived requests before each tenant's own configured
burst limit (40/20/5) tripped a real `429` — the exact ordering `values-dev.yaml`'s
`GATEWAY_TENANT_LIMITS_JSON` configures, observed against the live gateway, not asserted from a
unit test. `make verify-dev` also passes end-to-end, including a real proxied `/v1/chat` answer
(`latency_ms` seen as high as ~77 000 under load — see §5's note on the real model's latency).
See §5 for the exact steps and real findings, and ADR-32 for the full design record.

## 1. What this phase actually adds

Attributed telemetry and cost were **already done by Phase 13** (ADR-31): every request flowing
through `ai_service`/`ai-gateway` has always been counted under its real `tenant_id`, and the
FinOps dashboard already slices cost by tenant. Nothing about resolving a flat vs. a per-tenant
limit changes what a request gets labelled with, so that half of this phase's "Done when" line
needed no new code at all — see `docs/finops.md`.

The genuine gap, named by ADR-30's own "Revisit when" column the moment Phase 12 shipped, was the
"quotas, limits" half: every tenant got the identical `GATEWAY_RATE_LIMIT_PER_MINUTE`/
`GATEWAY_RATE_LIMIT_BURST`/`GATEWAY_QUOTA_PER_DAY` numbers, regardless of who they were. This
phase closes exactly that gap, and nothing else — see ADR-32.

## 2. The three tenants

| Tenant | Tier | Rate (req/min) | Burst | Daily quota | Configured via |
|--------|------|----------------|-------|--------------|-----------------|
| `demo` | standard | 60 *(flat default)* | 20 *(flat default)* | 2000 *(flat default)* | No entry in `GATEWAY_TENANT_LIMITS_JSON` — deliberately, so `helm-smoke`'s existing contract check (which calls `demo`) keeps working unchanged |
| `acme` | premium | 120 (2×) | 40 (2×) | 5000 (2.5×) | `values-dev.yaml`'s `GATEWAY_TENANT_LIMITS_JSON` |
| `globex` | trial | 10 (1/6) | 5 (1/6) | 200 (1/10) | `values-dev.yaml`'s `GATEWAY_TENANT_LIMITS_JSON` |

These three are dev-only, matching `values-dev.yaml`'s own existing scope (it is the only
environment with `gateway.enabled: true` — see ADR-30). `values-staging.yaml`/`values-prod.yaml`
are untouched.

## 3. Architecture: `TenantLimits`, one abstraction shared by both limiters

```
GATEWAY_TENANT_LIMITS_JSON ──► Settings.tenant_limits_json ──► TenantLimits.from_settings()
                                                                        │
                        ┌───────────────────────────────────────────────┤
                        ▼                                               ▼
              TokenBucketLimiter                                  DailyQuota
      (resolves capacity/rate ONCE,                     (resolves limit fresh on
       at bucket creation — a bucket's                   every call — a config
       capacity can't sensibly change                    change takes effect
       mid-flight)                                        without waiting for the
                                                           UTC day to roll over)
```

`TenantLimits` (`gateway/ratelimit.py`) is constructed once in `main.py`'s lifespan and passed by
reference to both limiter classes, replacing the Phase 12 design where each read the three flat
settings fields directly. A tenant with no entry in the overrides map falls back to the existing
flat `GATEWAY_RATE_LIMIT_*`/`GATEWAY_QUOTA_*` defaults — `demo`'s behaviour is unchanged.

## 4. Configuration: `GATEWAY_TENANT_LIMITS_JSON`

A JSON object, one key per tenant with an override, each value itself an object with any subset
of `rate_limit_per_minute`/`rate_limit_burst`/`quota_per_day` (an omitted key falls back to the
flat default for that one number only — a tenant can override just its burst and keep the flat
rate/quota, for example). Validated strictly at startup (`gateway/config.py`'s
`_tenant_limits_must_be_well_formed`), applying ADR-23's own lesson that a config value which
silently "looks configured" but isn't is worse than a loud rejection:

- every key must be a valid `tenant_id` (`ai_service/schemas.py`'s own `TENANT_ID_PATTERN`);
- every override must be a JSON object, never a list or scalar;
- **unknown keys are rejected, not ignored** — a misspelled `rate_limit_brust` fails startup
  instead of silently never applying;
- every value must be an integer within the same bounds (`≥1`, generous upper bounds) the flat
  settings fields already enforce — `bool` is explicitly rejected too (Python's `bool` is a
  subclass of `int`, and `true`/`false` are not valid limits).

It is plain config (`gateway.config` in `values.yaml`/`values-dev.yaml`), **not** a `Secret` like
`GATEWAY_API_KEYS_JSON` — tier numbers are not credentials. `values.yaml`'s shared default is
`"{}"` (every tenant gets the flat defaults — this phase's starting point, unchanged for
staging/prod); `values-dev.yaml` carries the real three-tier JSON above, wrapped across source
lines with a YAML folded block scalar (`>-`) so the long JSON string stays readable — confirmed,
in the sandbox, by parsing the exact folded text with `yaml.safe_load` then `json.loads` before
committing it.

`deploy/platform/gateway/api-keys.dev.example.json` (the committed, gitignored-by-pattern
template for the real, local `api-keys.dev.local.json`) now lists all three tenants instead of
one.

## 5. Installing and verifying (confirmed on the target machine, 2026-10-13)

```bash
make gateway-check                                   # local venv: lint + 64 tests + 96.51 % coverage
make gateway-image-build && make gateway-image-check  # rebuild the image (config.py/ratelimit.py/main.py changed)

# Provision the real tenants (this file is gitignored — never commit it):
cp deploy/platform/gateway/api-keys.dev.example.json deploy/platform/gateway/api-keys.dev.local.json
# edit it: delete "_readme", replace all three example keys with real ones, one per tenant:
#   python3 -c "import secrets; print('sk-' + secrets.token_urlsafe(24))"

make helm-lint-dev && make helm-template-dev          # chart renders with the new tenant-limits config
make gateway-image-push                               # push the rebuilt image to the local k3d registry
make gitops-bump-dev ARGS=--push                       # polaris-dev is GitOps-managed since Phase 8 (ADR-08) —
                                                        # same path Phase 12/13 used, not a direct helm upgrade
make tenants-smoke                                     # NEW this phase: proves acme > demo > globex for real
make verify-dev                                        # unchanged Phase 7 checks, confirming nothing regressed
```

`make tenants-smoke` (`scripts/verify/tenant-tiers.sh`) hammers each tenant's own `/v1/chat`
through the real ingress until it 429s, counts how many requests survived first, and asserts the
three counts are ordered `acme > demo > globex` — the one check this phase adds that
`helm-smoke`'s existing contract check (auth, health, the chat shape) does not already cover.

**Real result, Darya, 2026-10-13:** `acme (42) > demo (23) > globex (9)` — matching the configured
bursts (40/20/5) exactly, each tenant's own real `429` reached before its attempt budget ran out.

Three genuine, target-machine-only bugs were found and fixed before this result was trustworthy —
full detail in `docs/troubleshooting.md`'s Phase 14 section:

1. `api-keys.dev.local.json` had never actually been edited from its placeholder content (still
   had the `_readme` key and `sk-REPLACE-ME-...` example strings), which crash-looped the gateway
   with a pydantic `ValidationError` ("API key is shorter than 16 characters") until it was
   regenerated with real keys.
2. `scripts/verify/post-deploy.sh`'s `check_ai_answer()` predates the gateway (Phase 7) and was
   never taught that Phase 12's `ingress.yaml` routes dev's *entire* host — including `/v1/chat` —
   through `ai-gateway`, not `ai-service`, once `gateway.enabled: true`. Every run since Phase 12
   shipped was silently 401ing; unrelated to this phase's own code, just never caught before now.
3. `scripts/verify/tenant-tiers.sh`'s `survival_count()` hardcoded `--max-time 10`, inherited from
   before Phase 11 put a real (~20–80s/request, occasionally more under load) Ollama model behind
   every allowed request. Every *survived* request looked identical to a curl timeout rather than
   a `200`, so the burst test never actually measured anything real. Fixed by raising the timeout
   to the same ~90–95s ceiling `ai-service`/`ai-gateway` themselves use — the accepted tradeoff is
   that a full, honest run can now take several minutes, worst case 10+ for acme's burst of 40,
   because this still hammers sequentially and each surviving request pays the real model's
   latency. Chosen over shrinking the attempt budgets and weakening the assertion to a relative
   ordering within a smaller window, so this still proves an actually-observed `429` per tier.

One more thing worth naming, not a bug: running `make verify-dev` immediately after
`make tenants-smoke` can make `verify-dev`'s own single `/v1/chat` check time out (`504`) even
with the timeout fix above — the burst test just fired dozens of real inference requests at
Ollama's one CPU-bound pod, and the next request can queue behind that backlog long enough to
exceed `ai-service`/`ai-gateway`'s own ~90–95s timeout. Confirmed on Darya: two consecutive `504`s
immediately after a `tenants-smoke` run, pod healthy (no restarts, normal CPU/memory) throughout;
retrying once more succeeded with `latency_ms: 77010.3`. No code fix — this is an ordering/timing
fact about sharing one small local model between two verification scripts, not a defect in
either one.

## 6. Named, not built: Kafka and hard isolation

`docs/architecture.md`'s own requirement-coverage matrix names this phase's production
equivalent for a usage/audit trail explicitly: *"Kafka — Documented — 14 — Usage/audit event
stream in production."* A real deployment would stream every gateway decision (auth outcome,
rate-limit/quota verdict, proxied request) as an event onto a Kafka topic per tenant, giving an
immutable audit log independent of Prometheus' own retention window. Nothing like that is built
here — `ai_gateway_requests_total` (Phase 13) already carries the same `tenant_id`/`outcome`
information as a Prometheus counter, which is sufficient for this project's own dashboard and
demonstration needs, and stands in for the event stream without claiming to be one.

Likewise, `docs/architecture.md` line 674 caps this phase's isolation claim deliberately:
*"Multi-tenant concepts — Demonstrated — Logical tenancy, not hard isolation."* No
namespace-per-tenant, Kubernetes `ResourceQuota`, or `NetworkPolicy` change was made — every
tenant's pods are the same shared `ai-gateway`/`ai_service` Deployments in `polaris-dev`, exactly
as before this phase. The three tiers are enforced entirely at the application layer, inside one
process, for one simple reason: this project has no per-tenant namespace to attach a
Kubernetes-level control to, and building one just to say "hard isolation" would misrepresent
what Phase 14 actually demonstrates.

## 7. Known limitations, honestly

- **Still per-pod, in-memory, lost on restart** — unchanged from Phase 12 (ADR-30). `TenantLimits`
  changes *which* numbers a tenant's bucket/quota uses, not *where* that state lives. The
  production equivalent (a Redis-backed shared limiter) is still named, not built, and is still
  gated on `gateway.replicaCount` ever rising above `1` — it has not, so this is not a new gap
  introduced by this phase, only one inherited unchanged.
- **No per-tenant daily-quota exhaustion test against the real cluster** — same deliberate scope
  decision ADR-30 already made for the flat quota, now extended to the tiered one: confirmed by
  the sandbox's own unit tests (including one full end-to-end HTTP test, §3), not by firing
  thousands of real requests at an already resource-constrained target machine.
- **Three tenants, not an arbitrary number** — adding a fourth tenant tier is a config-only change
  (`GATEWAY_TENANT_LIMITS_JSON`, plus a fourth key in `api-keys.dev.local.json`), no code change,
  but is not itself demonstrated here.
- **No Kafka audit stream, no hard (namespace-level) isolation** — both named in §6 as this
  phase's deliberate production-equivalent/scope boundary, not silent gaps.

See ADR-32 for the full design record, and `docs/troubleshooting.md`'s Phase 14 section for this
phase's real, target-machine findings in full.
