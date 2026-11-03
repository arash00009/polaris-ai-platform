# Failure engineering: three real failures, three different detection/recovery paths

Phase 19's "Done when" line (`docs/architecture.md` section 18): *"Each injected failure is
detected by observability and handled by CI/CD + GitOps, with evidence."* The MVP tier asks for
three scenarios specifically (section A3). This phase deliberately does **not** build one
generic "chaos tool" and run it three times — the point, named in `docs/architecture.md`'s own
build-vs-buy table (`Failure demo` → "Scripted fault injection (`scripts/demo/`)", not "game
days, chaos engineering"), is that each scenario proves a *different* real gap in what Phase 18
already built, not three repeats of the same mechanism with different knobs.

## 1. Why three different scenarios, not one failure type three times

Phase 18 (ADR-39) proved one thing well: an Argo Rollouts `AnalysisTemplate` querying
`ai_requests_total`/`ai_chat_duration_seconds` catches a bad canary on `ai-service` in
`staging`/`prod` and rolls it back automatically. Reading that mechanism closely enough to build
this phase surfaced three real, distinct gaps it cannot cover on its own:

1. **`dev` had no fault-injection lever at all.** `canary-demo.sh --bad` refused `--env dev`
   outright (ADR-39's Decision) — `dev` runs the real Ollama backend
   (`OpenAICompatBackend`), not `MockBackend`, so `config.POLARIS_MOCK_FAILURE_RATE` does
   nothing there. The *mechanism* (the Rollout, the `AnalysisTemplate`) already exists in `dev`
   since Phase 18 shipped it everywhere — only the "make it actually fail" lever was missing.
2. **`ai-gateway` is a plain `Deployment`, not a `Rollout`.** ADR-39 deliberately did not convert
   it ("the gateway stays a plain Deployment"). Nothing gates a gateway config change before it
   reaches 100% of traffic — a tenant-limits regression (Phase 14) can break a real tenant's
   traffic and `ai-service`'s own metrics (what the `AnalysisTemplate` queries) never see it: the
   request never reaches `ai-service` once the gateway itself has rejected it.
3. **A canary ReplicaSet whose pods never become Ready never gets analysed in the first place.**
   The `AnalysisTemplate` only has something to measure once real traffic reaches the canary
   pods. A pod stuck in `ImagePullBackOff`/`CrashLoopBackOff` carries zero traffic, so
   `ai_requests_total`/`ai_chat_duration_seconds` see nothing wrong — the Rollout just sits
   "Progressing" indefinitely, which looks identical to a slow, healthy rollout to anything
   watching only those two metrics.

Each scenario below closes exactly one of these, with its own detection signal and its own
recovery path — not the same alert and the same `git revert` three times.

## 2. Scenario 1 — a real dev canary failure (closes ADR-39's named gap)

`canary-demo.sh --bad --env dev` now points `config.POLARIS_OPENAI_BASE_URL` at an unreachable
port (`19999`, not Ollama's real `11434`) on the exact same real Service DNS name
(`ollama.model-serving.svc.cluster.local`) instead of refusing outright. `OpenAICompatBackend
.generate()` already catches `httpx.RequestError` (connection refused) and raises `BackendError`
— the same `outcome=backend_error` series the `AnalysisTemplate`'s `success-rate` metric already
queries, with no new application code. Detection and recovery are **both already proven** by
Phase 18: the Rollout aborts on its own, the stable `ReplicaSet` (still pointed at the real
Ollama) keeps serving. This scenario's whole point is proving the *dev-specific lever* works,
not a new mechanism.

```
make canary-demo-bad ARGS="--env dev"      # expect: Degraded, auto-rolled-back, exactly like staging/prod
# revert: helm upgrade ai-platform-dev helm/ai-platform --namespace polaris-dev --kube-context k3d-polaris \
#   --reuse-values --set config.POLARIS_OPENAI_BASE_URL=http://ollama.model-serving.svc.cluster.local:11434/v1 --force-conflicts
```

## 3. Scenario 2 — a gateway regression the canary cannot see, recovered through git + CI/CD + GitOps

`scripts/demo/tenant-regression.sh --inject --env dev [--push]` regresses `acme`'s
`rate_limit_burst` in `helm/ai-platform/values-dev.yaml`'s `config.GATEWAY_TENANT_LIMITS_JSON`
from `40` to `1` (keeping `rate_limit_per_minute` at `120`, so this degrades under sustained
traffic rather than failing every single request immediately — the realistic shape of a tuning
regression, not an obvious outage). It then **commits that change directly to this repository**
and, with `--push`, pushes it — ADR-26 already established that Argo CD's dev `Application`
auto-syncs `polaris-ai-platform`'s `helm/ai-platform` chart and values directly (Source 1 of its
multi-source definition); no `polaris-gitops` touch is needed for a config-only change like this
one.

A new `PrometheusRule` (`GatewayTenantRateLimited`, `deploy/platform/observability/
alerting-rules.yaml`) fires when `ai_gateway_requests_total{outcome="rate_limited"}` sustains
more than 0.05 req/s for a tenant for 2 minutes — a signal `ai-service`'s Rollout has no way to
see, because the gateway rejects the request before `ai-service` ever receives it.

Recovery is `scripts/demo/tenant-regression.sh --revert --env dev [--push]`: a real `git revert`
of the exact injected commit, pushed the same way, synced by Argo CD the same way — the literal
CI/CD-validates-it, GitOps-deploys-it loop this scenario exists to prove, deliberately not the
direct `helm upgrade --set` shortcut `canary-demo.sh`'s own demos use for speed.

```
make failure-demo-tenant-inject ARGS=--push   # acme's burst drops to 1; watch with:
make failure-demo-tenant-status                # or: make obs-alerts-status
make failure-demo-tenant-revert ARGS=--push   # git-revert through CI/CD + GitOps; alert should clear
```

## 4. Scenario 3 — a canary stuck on a bad image tag, recovered by re-running existing GitOps tooling

`scripts/demo/break-image-tag.sh <env> [GITOPS_DIR] [--push]` writes a deliberately nonexistent
image tag (the real current tag plus a `-phase19-fault-injected-does-not-exist` suffix) into
`polaris-gitops`'s `environments/<env>/image.yaml` — the exact file `scripts/gitops/
bump-image-tag.sh` normally writes a real, already-pushed tag into. Argo CD syncs it like any
other change; the new canary `ReplicaSet`'s pod(s) can never pull the image, so they never
become `Ready`, so the `AnalysisTemplate` never starts analysing them at all.

A second new `PrometheusRule` (`AIServiceCrashLooping`) fires on
`kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull
|CrashLoopBackOff"} == 1` for `ai-service` containers across every `polaris-*` namespace — a
real kube-state-metrics Gauge (confirmed against its own upstream docs before writing this rule,
not assumed), already scraped since Phase 9, that distinguishes "stuck because nothing is wrong
yet" from "stuck because it will never succeed."

Recovery deliberately reuses `scripts/gitops/bump-image-tag.sh` **as-is** — no new revert logic
was written for this scenario: that script already writes back the real, current,
already-registry-verified tag and refuses to write one that is not actually pushed (ADR-26's own
`need_pushed` guard), which is exactly undoing this script's fault injection.

```
make failure-demo-image-break ENV=staging ARGS=--push     # ai-service's tag becomes unpullable
# watch: kubectl-argo-rollouts -n polaris-staging get rollout ai-service --watch
#    or: make obs-alerts-status   (once AIServiceCrashLooping's 2m "for" window has elapsed)
make failure-demo-image-revert ENV=staging ARGS=--push    # re-runs bump-image-tag.sh for real
```

## 5. Alertmanager: really on, nothing pages anyone

Alertmanager was deliberately `enabled: false` through Phase 18 — the stack's own values file
said so, honestly, because nothing defined an alert rule yet. This phase turns it on for real
(`deploy/platform/observability/kube-prometheus-stack-values.yaml`) and adds the two
`PrometheusRule` resources above (`alerting-rules.yaml`, applied separately from the Helm
release itself, the same pattern the Grafana dashboard ConfigMap already uses — picked up by
Prometheus because `ruleSelector`/`ruleNamespaceSelector` are broadened to `{}`, mirroring the
same broadening `serviceMonitorSelector` already got in Phase 9/18).

Named plainly rather than glossed over: the `config.route`/`config.receivers` block is a no-op
`"null"` receiver. Alertmanager really evaluates both rules and really tracks each alert's
Pending/Firing/Resolved lifecycle — `make obs-alerts-status` queries its real `/api/v2/alerts`
API for evidence — but nothing pages an actual human. There is no on-call system in this
project to page, and wiring a Slack/PagerDuty integration nobody receives would be exactly the
kind of unverifiable claim this project avoids elsewhere (the FinOps rate card, the eval-score
Pushgateway). Revisit if a later phase adds a real notification channel.

## What this does not give you

No chaos-engineering tool (Litmus, Chaos Mesh): three scripted, specific fault levers, not
random/generalized fault injection — `docs/architecture.md`'s own build-vs-buy table already
named this choice. No fourth scenario for a resource-exhaustion failure (OOMKill, CPU
throttling): `ai_inference_seconds_total`/`kube_pod_container_status_restarts_total` could
support one, but three real, distinct gaps were already found without needing to invent a
fourth. No automatic recovery for Scenario 2/3: both are a real, scripted `git revert`/tag
rewrite a person (or a future automation) still has to run — this phase proves the path works,
not that it fires itself. Scenario 2 only runs against `dev` (the one environment
`gateway.enabled` is true, Phase 12) — not a gap, a scope this phase inherited from Phase 12/18.

## 6. Scenario 1 — confirmed for real on Darya (2026-11-01/02), with three real findings this design did not anticipate

`make canary-demo-bad ARGS="--env dev"` was run for real. The canary pod did fail — but the path
to that failure, and what it took to resolve, surfaced three real gaps, not the one this scenario
was written to prove.

**Finding 1 — the failure mode is a readiness *timeout*, not a clean refusal, and it crash-loops
the pod rather than just failing requests.** The pod's own logs show repeated `"reason":
"readiness check timed out"` (not `connection refused`) against the deliberately-wrong port —
`check_ready()`'s own backend check hangs until it times out rather than failing fast. Over
~46 hours this produced 26 container restarts (`kubectl describe pod` confirmed `Liveness probe
failed: ... context deadline exceeded`, not just `Readiness`). The canary `ReplicaSet` stayed
`Healthy` by Argo Rollouts' own accounting throughout — a flapping, restarting pod can still
read as "the ReplicaSet is fine" at that level.

**Finding 2 (the big one) — a stray, ArgoCD-managed `Deployment/ai-service` was running in
parallel with the Rollout for 46+ hours, diluting the Service's endpoints four-way instead of
two-way.** `kubectl get endpoints ai-service` showed 4 pod IPs, not 2: the Rollout's
stable+canary pods, *and* two pods from a `Deployment/ai-service` neither `make helm-apply-dev`
nor this project's current chart renders at all. Root cause, confirmed rather than assumed: Phase
18's chart work (`rollout.yaml` replacing `deployment.yaml`, `analysistemplate.yaml`,
`canary-demo.sh`'s `--promote/--retry/--abort`, all of ADR-39) had been built and verified
locally on Darya across several real target-machine sessions, but **never actually committed or
pushed** — `git log` on Darya showed `HEAD` and `origin/main` both still sitting at the Phase 17
commit (`ffb47ae`), with all of Phase 18 as uncommitted working-tree changes. `make
helm-apply-dev` renders Darya's local working tree (so the Rollout worked fine when run by
hand); Argo CD's `ai-platform-dev` Application syncs `origin/main` (`targetRevision: main`),
which still had the old `deployment.yaml` and no `rollout.yaml` at all. Both controllers managed
the same namespace, the same `app.kubernetes.io/name=ai-service` selector, and the same
`ai-service-config` ConfigMap — which is also why the Deployment's own, otherwise-healthy pods
started crash-looping too: they mounted the same ConfigMap `canary-demo-bad` had just pointed at
the broken port. Fixed for real: committing and pushing Phase 18 (`cc4d667`) let Argo CD's own
`selfHeal`/`prune` (confirmed already `true`) remove the stray `Deployment` permanently once it
synced the new revision — confirmed via `kubectl get deployment ai-service` returning
`NotFound` and `.status.resources` no longer listing it.

**Finding 3 — the `AnalysisTemplate`'s "empty result → `Inconclusive`" design (ADR-39's Decision,
deliberate) is correct, but it means *any* deploy with no traffic source reliably gets stuck,
not just a broken one.** Confirmed twice in the same session: the broken canary above sat
`Paused`/`Inconclusive` for 36+ hours (all three measurements returned `value: '[]'` — an empty
Prometheus result, because the canary never received enough traffic to produce even one sample
of `ai_requests_total`). Then, immediately after the GitOps fix above, Argo CD's own image-tag
automation triggered a *second*, completely organic canary (revision 3, a perfectly healthy
pod, `ready:1/1`, no restarts) — and it **also** went `Inconclusive`, for the same reason: nobody
ran `canary-demo.sh` for it, so no k6 traffic (and no real traffic, in a local dev cluster) ever
reached it. This is not a bug — it is exactly the behavior `analysistemplate.yaml`'s own header
comment designed on purpose, to avoid scoring a brand-new canary `Failed` before it has had a
chance to receive any traffic. The operational consequence worth naming plainly: **any Argo
CD-triggered deploy of `ai-service` in this environment that isn't run through
`canary-demo.sh` has no traffic source of its own and will predictably pause `Inconclusive`,
needing a human to run `canary-demo-promote`/`-retry`/`-abort`** — which is exactly what
resolved it here (`make canary-demo-promote ARGS="--env dev"` → `✔ Healthy`).

**Two smaller, real gaps found and fixed along the way:** `scripts/verify/canary-demo.sh`'s
`--promote`/`--retry`/`--abort` modes (added for ADR-39's own Inconclusive finding) existed in
the script but the matching `Makefile` targets had only ever been added in a sandbox copy, never
delivered to Darya — `make canary-demo-abort` failed with `No rule to make target` until patched
for real here. And `kubectl -n observability get prometheusrules` showed only the built-in
`kube-prometheus-stack-*` rules — `GatewayTenantRateLimited`/`AIServiceCrashLooping` (section 4/5
above) have never actually been applied to `polaris-dev` (`make obs-alerts-apply` not yet run),
named here rather than assumed working.

## Target-machine verification

**Scenario 1: confirmed for real on Darya, 2026-11-01/02 — see section 6 above for what was
actually found, which is broader than this scenario's own fault lever.** Scenario 2
(`tenant-regression.sh`) and Scenario 3 (`break-image-tag.sh`), and applying
`alerting-rules.yaml`/turning on Alertmanager, are **still only written and shellchecked in the
sandbox** — they have not yet been delivered to or run on Darya at all. Confirming that
Alertmanager actually installs, that both `PrometheusRule`s are actually discovered, and that
Scenarios 2 and 3 actually fire and recover for real against a live cluster remains open, the
same "real cluster is the only real proof" discipline every earlier phase has followed.

## Revisit when

A later phase adds a real on-call/notification integration (Alertmanager's `"null"` receiver
stops being honest the moment something actually depends on being paged); Scenario 2 is worth
extending to `staging`/`prod` once the gateway is proven there too (Phase 12/18's own scope, not
this phase's); or a resource-exhaustion scenario becomes a proven need rather than a
hypothetical fourth case. See ADR-40 for the full decision record.
