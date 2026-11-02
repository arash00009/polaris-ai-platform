# Progressive delivery: an Argo Rollouts canary for ai-service

Covers **Phase 18**: `docs/architecture.md`'s own "Done when" wording for this phase is *"Version
A → B canary with analysis; failed B rolls back automatically."* See ADR-39 for the full design
record, including the real metric gap this phase found and fixed (no latency histogram existed
before this phase) and why the canary steps are 50% → analysis → 100%, not a finer staircase.

**Status: real progress confirmed on the target machine (Darya), 2026-10-30, with one genuine
gap found and fixed along the way — the canary itself has not yet promoted or rolled back for
real.** The one-time Deployment→Rollout migration (§6) and a real Argo Rollouts controller
install (`make rollout-install`) both completed cleanly against `polaris-staging`. Running
`canary-demo.sh --good` against it surfaced a real, previously undiscovered gap: with
`serviceMonitor.enabled: false` (Phase 9/ADR-27's original dev-only scoping), Prometheus never
discovered `ai-service` in `polaris-staging` at all, so the `AnalysisTemplate`'s two metrics
always queried an empty series — the `AnalysisRun` sat `Paused`/`Inconclusive` for over an hour
regardless of how much real k6 traffic was sent. Fixed by turning `serviceMonitor.enabled: true`
on for `values-staging.yaml`/`values-prod.yaml` too (ADR-39's Decision has the full reasoning for
why this doesn't reopen ADR-27's separate OTel-traces/logs scoping). A second real gap,
unrelated to metrics: `canary-demo.sh`'s own `helm upgrade --reuse-values` needed
`--force-conflicts` (Argo CD owns `polaris-staging`'s ConfigMap fields via server-side apply,
and helm v4's own SSA mode refuses to overwrite a field it doesn't own without that flag) — the
same flag `scripts/deploy/helm.sh` already carries for this exact reason since Phase 15, just
never carried into this phase's own script until it hit the conflict for real. Both fixes are
in; a real canary actually promoting to `Healthy` or aborting to `Degraded` with the metrics fix
in place is the next target-machine step. This sandbox still has no `helm` binary, no Docker
daemon and no cluster, so none of this can be re-confirmed here — only on Darya.

## 1. What changed, and why a histogram had to come first

`ai-service`'s Kubernetes resource is now a `Rollout` (`argoproj.io/v1alpha1`), not a
`Deployment` — every pod-spec field (securityContext, probes, resources, the `checksum/config`
annotation) is unchanged from Phase 5; only `apiVersion`/`kind` and `spec.strategy` are new. The
gateway stays a plain `Deployment` — converting a second component before the first is proven on
a real cluster would be the same ahead-of-need building this project has repeatedly declined
elsewhere.

Designing the `AnalysisTemplate` surfaced a real gap before any YAML was written: reading
`telemetry.py`/`main.py` directly (not assuming the library's own docs) showed
`Instrumentator(registry=registry).instrument(app)` is called with no `.add(...)` chained onto
it, so prometheus-fastapi-instrumentator's generic `http_requests_total`/
`http_request_duration_seconds` metrics are never actually produced by this app. The only real
signals were the three Phase 13 FinOps counters — and `ai_inference_seconds_total` is a running
total, incremented only on success, which cannot produce a percentile. `docs/architecture.md`
section 9's SLI table explicitly wants p95 latency "used both for dashboards and for rollout
gating" — a proven need, not scope creep. `ai_chat_duration_seconds` (a `Histogram`, labeled only
by `outcome`) now fills it, observed on every outcome including the two failure paths, which
previously never measured latency at all.

## 2. The canary, step by step

| Step | What happens |
|---|---|
| 1. `setWeight: 50` | Argo Rollouts scales the canary ReplicaSet so it holds roughly half the Rollout's pods. Without a `trafficRouting` plugin (Traefik is not one Argo Rollouts natively weights traffic through), the "basic canary" approximates a weight by pod *count*, not actual request routing — at `replicaCount: 2` (dev/staging) or `3` (prod), a requested 20% step would round to 0 or 1 pod anyway, i.e. silently become 0% or 50%. 50% is the one step these real replica counts can actually produce honestly. |
| 2. `analysis` (blocking) | `ai-service-canary-analysis` runs for `count: 3` samples at `interval: 1m` (3 minutes minimum) against two metrics — see §3. The Rollout does not proceed past this step until the `AnalysisRun` finishes. |
| 3a. Analysis passes | `setWeight: 100` — full promotion. |
| 3b. Analysis fails | The Rollout aborts (`status.abort: true`, `status.phase: Degraded`) and traffic returns to the previous, stable ReplicaSet automatically — no human action, no `AnalysisTemplate` told in advance which revision is "bad." |

## 3. The AnalysisTemplate's two metrics

Both query the real, already-running Prometheus
(`kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090` — confirmed for real
during Phase 17's target-machine verification, not guessed):

- **`success-rate`**: `sum(increase(ai_requests_total{outcome="success"}[5m])) /
  sum(increase(ai_requests_total[5m]))`, gated at `>= 0.99` — `docs/architecture.md` section 9's
  availability SLI (non-5xx ÷ all responses), read off the real `outcome` label Phase 13 already
  produces, not a generic HTTP status-code metric this app does not expose (see §1).
- **`latency-p95`**: `histogram_quantile(0.95, sum(rate(ai_chat_duration_seconds_bucket[5m])) by
  (le))`, gated against a threshold baked in per environment at Helm-render time:
  `values-dev.yaml` sets `5` seconds (the real Ollama-CPU backend dev runs), `values-staging.yaml`/
  `values-prod.yaml` set `0.3` seconds (the mock backend). Getting this backwards in either
  direction would make the gate meaningless — too loose and a real regression passes, too tight
  (the mock threshold against the real Ollama backend) and every dev canary would auto-rollback
  on normal latency.

Both metrics define an explicit `successCondition` *and* `failureCondition`
(`len(result) > 0 && result[0] >= 0.99` / `len(result) > 0 && result[0] < 0.99`, and the
equivalent `<=`/`>` pair for latency) rather than a `successCondition` alone — checked against
Argo Rollouts' own documented behaviour (not assumed): with only a `successCondition`, an empty
Prometheus result (no traffic yet) evaluates that condition false and scores the measurement
`Failed`, exactly the wrong outcome for a canary nobody has sent traffic to yet. With both
conditions defined, an empty result matches neither and is scored `Inconclusive` instead
(bounded by `inconclusiveLimit: 2`). `scripts/load/chat-load.js` (§4) exists so this case stays
rare in practice, not as the only safeguard against it.

**A real "empty result" trap this phase's own target-machine run hit, distinct from the
no-traffic-yet case above:** both queries also come back empty, for as long as the environment
runs, if Prometheus never discovers `ai-service` there in the first place — not because no
traffic arrived, but because `serviceMonitor.enabled` was `false`. That is exactly what happened
against `polaris-staging` on 2026-10-30 (confirmed for real: `Paused`/`Inconclusive` for over an
hour, with real k6 traffic running the whole time). `values-staging.yaml`/`values-prod.yaml` now
set `serviceMonitor.enabled: true` for this reason (ADR-39's Decision has the full record) — the
`inconclusiveLimit` safeguard above is for a canary nobody has reached yet with real traffic,
not for an environment Prometheus was never watching to begin with; no `successCondition`/
`failureCondition` pair can tell those two "empty result" cases apart from the query side alone.

## 4. k6: the first real use of this project's own toolchain list

`docs/architecture.md`'s Phase 1 toolchain list has named k6 since this project's very first
phase; nothing before Phase 18 had a concrete need for sustained synthetic traffic against a
live endpoint while metrics are judged in real time, so it stayed unused until now.
`scripts/load/chat-load.js` is deliberately small — four prompts already proven against
`MockBackend` (reused from `eval/golden_dataset.json`, Phase 17, not invented again), a
configurable target URL/Host header/tenant id, a `check()` that only logs to k6's own summary
(the authoritative pass/fail signal is the `AnalysisTemplate`, not this script's exit code). It
is not a load-testing suite — the proven need is "keep `ai_requests_total`/
`ai_chat_duration_seconds` moving during the analysis window," nothing more.

## 5. A real run in the sandbox (no cluster needed for this part)

`chat-load.js` was run for real against a locally-started `ai_service` (`uvicorn`, `MockBackend`,
no Docker, no cluster — the same thing `make app-run` does):

```
$ k6 run --vus 2 --duration 10s scripts/load/chat-load.js
...
checks_total.......: 20      1.991272/s
checks_succeeded...: 100.00% 20 out of 20
checks_failed......: 0.00%   0 out of 20
✓ status is 200 or a declared ai_service error (504/502)
```

And the metrics it drove, confirmed for real on the same running process:

```
$ curl -s http://127.0.0.1:8000/metrics | grep -E "ai_requests_total|ai_chat_duration_seconds_count"
ai_requests_total{model="mock-1",outcome="success",tenant_id="canary-demo"} 20.0
ai_chat_duration_seconds_count{outcome="success"} 20.0
```

Exactly the real signals the `AnalysisTemplate` would query — this proves the traffic-generation
and metric-emission halves of the mechanism for real; only the Argo Rollouts controller itself
and a real canary promoting/aborting need a cluster this sandbox does not have.

## 6. The one-time migration this chart version needs

Every `polaris-dev`/`-staging`/`-prod` namespace already has a real `Deployment` named
`ai-service` from Phase 4/5 onward, and Kubernetes has no in-place way to change an existing
object's `kind`. `helm upgrade` to this chart version renders a `Rollout` where a `Deployment` of
the same name used to be — Helm's own release diffing deletes the old `Deployment` and creates
the new `Rollout` (not a conflict, since they are different API resources), but the cleanest
sequence, run **once per environment**, the first time this chart version is applied:

```
kubectl delete deployment ai-service -n <namespace> --cascade=orphan
helm upgrade ai-platform-<env> helm/ai-platform -f helm/ai-platform/values-<env>.yaml ...
```

`--cascade=orphan` leaves the already-running ReplicaSet/Pods in place rather than deleting them;
the new `Rollout` adopts them by label selector, so there is no brief full-recreate gap.
**Confirmed for real against `polaris-staging`, 2026-10-30:** the orphan-delete and `helm
upgrade` both completed cleanly. One unrelated, pre-existing gap surfaced in the same run and
was fixed on the spot, not papered over: `polaris-staging`'s Helm release had lost its ownership
metadata at some earlier point — the exact risk ADR-23 already named for `make deploy-delete` —
so `helm upgrade --install` refused to adopt the namespace and, one error at a time, every
existing resource in it (`ConfigMap`, `Service`, `Ingress`, `PodDisruptionBudget`, both
`NetworkPolicy`s). Re-adopted in one pass with `kubectl label`/`annotate` (ADR-23's own pattern,
scoped to names matching `ai-service`) rather than fixed resource-by-resource via repeated
`helm install` failures. Not yet exercised against `polaris-dev`/`polaris-prod`.

## 7. Running the real canary demo

```
make rollout-install                 # once: installs the Argo Rollouts controller
make tools-install ARGS="--only k6"
make tools-install ARGS="--only kubectl-argo-rollouts"

make canary-demo-good ARGS="--env staging"   # expect: Healthy at 100% weight
make canary-demo-bad  ARGS="--env staging"   # expect: Degraded, auto-rolled-back
```

`--bad` is refused against `--env dev`: dev runs the real Ollama backend
(`OpenAICompatBackend`), which has no `mock_failure_rate`-style knob — see ADR-39's Decision for
why a "bad dev canary" is left to Phase 19's fuller failure-engineering work instead of invented
here. `--good`/`--bad` against `staging`/`prod` both work because those environments already run
`MockBackend` (confirmed by `tests/bootstrap/test_static.sh`'s own existing checks) and (since
2026-10-30) have `serviceMonitor.enabled: true` so the `AnalysisTemplate` can actually see their
metrics — see §3's "empty result" trap and ADR-39's Decision.

Running `--good` against `polaris-staging` for real, before the `serviceMonitor` fix above,
surfaced a second real, unrelated gap: the command's own `helm upgrade --reuse-values` failed
outright with a server-side-apply field-ownership conflict against `argocd-controller` (Phase 8
puts every environment under Argo CD management, and helm v4's own default SSA mode refuses to
write a field another controller already owns). `scripts/deploy/helm.sh`'s `cmd_apply` has
carried `--force-conflicts` for exactly this reason since Phase 15 — this script's own `helm
upgrade` calls never did, until they hit the conflict for real. Fixed in both `cmd_good` and
`cmd_bad`.

## What this does not give you

No eval score in the gate: Phase 17's `polaris_eval_score` is deliberately not wired into this
`AnalysisTemplate` yet. ADR-38 named this phase as the forcing function for that, but "the
forcing function has arrived" and "the metric is actually ready to gate on" are different claims
— the Pushgateway only ever holds the last pushed value, not a live-enough signal for a
multi-minute analysis loop without a scheduled, repeated eval run (a `CronJob`, not built yet).
No gateway canary: only `ai-service` is a `Rollout` this phase. No fault injection beyond
`MockBackend`'s existing `mock_failure_rate`/`mock_latency_ms` knobs: a real, dev-specific,
Ollama-backend failure scenario is Phase 19's job, not this one's.

## Target-machine verification

**Confirmed for real (Darya, 2026-10-30):** `make rollout-install` (a real Argo Rollouts
controller install, `polaris-staging`); the one-time `kubectl delete deployment ai-service
--cascade=orphan` migration (§6, `polaris-staging`); `make helm-apply-staging` rendering a real
`Rollout` and reaching `STATUS: deployed`.

**Not yet confirmed:** a real `make canary-demo-good` actually reaching `Healthy` at 100%
weight, and a real `make canary-demo-bad` actually aborting to `Degraded` with automatic
rollback — both fixes above (`serviceMonitor.enabled`, `--force-conflicts`) are in, but the
canary itself has not yet been re-run against them; the migration/controller-install steps
against `polaris-dev`/`polaris-prod` specifically. This sandbox has no `helm` binary, no Docker
daemon and no cluster — confirmed the same way every earlier Kubernetes-facing phase in this
project has been: only a real run on Darya proves it.

## Revisit when

A scheduled, repeated `make eval-run` (ADR-38's own "Revisit when") makes `polaris_eval_score` a
live-enough signal to add as this `AnalysisTemplate`'s third metric; or Phase 19's
failure-engineering work needs a "bad dev canary" scenario against the real Ollama backend, at
which point a `dev`-specific fault-injection lever would need designing; or the gateway's own
canary becomes a proven need rather than a hypothetical one. See ADR-39 for the full record.
