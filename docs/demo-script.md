# Polaris AI Platform — Recorded Demo Walkthrough Script (Phase 20)

A ~12–15 minute screen-recorded walkthrough. Every command below is real and already exists in this repo
— nothing here is staged or faked for the recording. Run it against the target machine (Darya), `polaris-dev`.
Each section gives what to say, then the exact command(s) to run and what the real output should show.

## 0. Setup (before recording)

- Make sure the platform is healthy first, off camera: `make verify-dev`. If anything fails, fix it before
  recording — the whole point of this project is that what's on screen is real.
- Open two terminals side by side: one for commands, one idle (or a split pane) for `watch`-style status checks.
- Have Grafana open in a browser tab (`make obs-grafana`, http://localhost:3000), and optionally the Argo
  Rollouts dashboard too (`make rollout-dashboard`, http://localhost:3100) — a visual, live view of the canary
  stepping through weights that's worth cutting to during section 3.

## 1. Intro (30–45s)

**Say:** "This is Polaris, a local AI platform I built from scratch across 20 phases to demonstrate DevOps,
observability and platform engineering skills — Kubernetes, GitOps, progressive delivery, real failure
injection, all running on my own machine, no GPU, no paid cloud. Everything you'll see in the next few minutes
is real: real cluster, real Prometheus alerts, real git commits. Nothing is simulated for this recording."

**Show:** `README.md`'s phase table scrolling briefly, then `docs/capstone.md`.

## 2. The platform, healthy (1–2 min)

**Say:** "Here's the baseline — a FastAPI AI service behind a gateway, serving a real local LLM through Ollama,
fully observed."

```bash
make verify-dev
```

**Show:** all checks passing (rollout status, health, readyz, a real non-empty AI answer, structured logs).

**Switch to Grafana.** Show the main dashboard: request rate, latency percentiles, pod resource usage, recent
logs — point out these are real numbers from real traffic, not a static screenshot.

## 3. Progressive delivery: a canary rollout (3–4 min)

**Say:** "ai-service deploys as an Argo Rollouts canary, not a plain Deployment. Every new version runs at 50%
traffic, gets analyzed against real Prometheus metrics — success rate and p95 latency — and only then promotes
to 100%. Let's watch a good version go through, then a bad one get caught."

```bash
make canary-demo-good ARGS="--env dev"
make rollout-status
```

**Show:** the Rollout stepping through `setWeight: 50` → `AnalysisRun` → `setWeight: 100`, `AnalysisRun` reaching
`Successful` off real `ai_requests_total`/`ai_chat_duration_seconds` data. Cut to the Argo Rollouts dashboard
(`localhost:3100`) if it's open — it shows the weight step visually.

```bash
make canary-demo-bad ARGS="--env dev"
make rollout-status
```

**Say:** "Now the bad path — this points the service at an unreachable backend port on dev, or past the real
SLI failure threshold on staging/prod. Watch the canary get stuck at 50%, analysis go Inconclusive or Failed,
and traffic never reach 100%."

**Show:** the `AnalysisRun` failing/inconclusive, the Rollout paused. Then recover — three ways exist
(`canary-demo-promote` skips straight to 100%, `canary-demo-retry` re-runs the analysis, `canary-demo-abort`
rolls back to the previous stable version); promote is the one to show here since the underlying issue (the
bad backend) is about to be fixed by the next good deploy anyway:

```bash
make canary-demo-promote ARGS="--env dev"
make rollout-status
```

## 4. Failure engineering: a real regression, caught and reverted (4–5 min)

**Say:** "This is the part I'm proudest of — three fault-injection scenarios, each one a genuinely different
failure mode, each one actually run against this real cluster, not just described. Here's one: a tenant
rate-limit regression."

```bash
make failure-demo-tenant-inject ARGS=--push
make obs-alerts-status
```

**Say:** "That just committed a real regression to git — acme's rate limit burst dropped to 1 — and GitOps auto-
synced it to the cluster. Watch the `GatewayTenantRateLimited` alert go from nothing, to pending, to firing,
over the next couple of minutes, off Prometheus's own real `ALERTS` time series."

**Show:** `make obs-alerts-status` (or the Alertmanager UI via `make obs-alertmanager`) showing the alert
transition. Optionally send real traffic against acme's tenant to show requests actually getting rate-limited.

**Say:** "And the recovery is the same path a real on-call engineer would use: git revert, not a manual kubectl
patch."

```bash
make failure-demo-tenant-revert ARGS=--push
make obs-alerts-status
```

**Show:** the alert clearing back to nothing, confirmed via the same real time series.

## 5. (Optional, time permitting) Scenario 3: a stuck canary, recovered via GitOps (2–3 min)

**Say:** "The third scenario breaks a canary a different way — a nonexistent image tag, the kind of mistake a
bad GitOps commit can actually produce."

```bash
make failure-demo-image-break ENV=dev ARGS=--push
make rollout-status
```

**Show:** the Rollout stuck, pods failing to pull the image, `AIServiceCrashLooping` firing.

```bash
make failure-demo-image-revert ENV=dev ARGS=--push
make rollout-status
make canary-demo-promote ARGS="--env dev"
```

**Show:** the real tag restored, the Rollout recovering, promoted to `Healthy`.

## 6. Close (30–45s)

**Say:** "Everything you just saw — the canary logic, the two fault levers, the alerts, the recovery paths — is
documented honestly in this repo: every ADR, every real bug found along the way, every phase that's still
genuinely in progress rather than rounded up to done. Thanks for watching."

**Show:** `docs/capstone.md`'s "What makes this credible" section, then the repo's top-level README.

## Notes for recording

- Run Scenario 2 (section 4) live — the pending→firing transition takes about two real minutes (the
  `PrometheusRule`'s `for: 2m` window), which is a natural, honest pause to narrate over rather than cut.
- If time is short, cut section 5 (Scenario 3) entirely rather than rushing it — sections 1–4 alone already
  demonstrate build, observe, deploy-progressively, break, detect and recover.
- Every command here is copy-pasted from this repo's own Makefile/scripts, not reworded for the recording —
  if a target name ever changes, update this script in the same commit.
