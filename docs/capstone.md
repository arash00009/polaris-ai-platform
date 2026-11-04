# Polaris AI Platform — Capstone (Phases 0–20)

## What this is

Polaris is a local, free/open-source, production-inspired AI Systems / DevOps platform, built as a technical
portfolio for DevOps, AI Systems Engineer, MLOps, Platform Engineering and Observability job applications. It
is modeled on the requirements of a real-world AI Systems Engineer / DevOps & Observability job description,
runs entirely on one Windows machine behind WSL2/k3d (no GPU, no paid cloud), and was built strictly phase by
phase, each one only started deliberately and each one verified for real before being called done. It does not
claim years of production experience it does not have — the goal is to show the ability to build, operate,
break and explain this kind of system hands-on, and to name every real gap honestly rather than paper over it.

## The build, phase by phase

**Foundation (0–5).** Architecture and roadmap (`docs/architecture.md`); a local dev platform on WSL2/k3d with
its own registry; a FastAPI `ai_service` with a swappable model backend; containerization with Trivy scanning
and an SBOM; raw Kubernetes manifests (Deployment/Service/Ingress/PDB/NetworkPolicy); one Helm chart rendering
three environments (`dev`/`staging`/`prod`).

**Delivery pipeline (6–8).** A real GitHub Actions CI pipeline (lint, test, secret scan, dependency audit,
workflow lint, build/scan/SBOM, GHCR publish); a continuous-verification script run against every environment
after every deploy; GitOps with a genuinely separate Argo CD application repository (`polaris-gitops`), with
self-healing confirmed live.

**Observability (9–10).** The full LGTM-adjacent stack — Prometheus + Grafana (`kube-prometheus-stack`), Loki,
Tempo, an OpenTelemetry Collector — wired into `ai_service` for metrics, logs *and* traces, with real data
confirmed in all three; then a dedicated pass curating which span/log attributes actually leave the process,
and confirming log↔trace correlation for real against a live request.

**AI-specific platform (11–14).** Real model serving against a live, in-cluster Ollama instance (not a mock);
a second FastAPI service, `ai-gateway`, in front of it for auth, per-tenant rate limiting/quota and cross-service
trace propagation; tenant-attributed cost telemetry plus an OpenCost install for shared-resource cost allocation;
and finally three real tenant tiers with their own configured limits, not just a flat default.

**Hardening and lifecycle (15–17).** Supply-chain security — Sealed Secrets and a default-deny egress
NetworkPolicy confirmed on the real cluster, keyless Cosign image signing and a Kyverno admission policy written
and shellchecked but still awaiting a real GitHub Actions run to confirm end to end; a Git-based AI-governance
manifest exposing declared vs. actual model/prompt/deployment/config versions on every response; and a custom
evaluation harness scoring a golden dataset against the live service, pushed to Prometheus via a Pushgateway.

**Operating it for real (18–20).** Progressive delivery — `ai-service` converted from a plain Deployment to an
Argo Rollouts canary gated on a real Prometheus `AnalysisTemplate`; failure engineering — three independent,
deliberately different fault levers (a broken dev model backend, a real gateway config regression, a stuck
canary on a nonexistent image tag), each one injected, alerted on and recovered for real on the target machine;
and this capstone, the final demonstration tying all twenty phases together.

## What makes this credible, not a tutorial followed

Two disciplines run through all twenty phases: *every piece of infrastructure needs a proven need* (OpenCost
over Kubecost, Sealed Secrets over Vault, a Git manifest over MLflow — each decision recorded in its own ADR,
never just asserted), and *verify, don't guess* — nothing is called done until it has actually been run against
a real cluster on the target machine, not just reasoned about or tested in a sandbox. That second discipline is
what turned this project into something closer to real operations experience than a tutorial: running the real
thing against a real cluster surfaced genuine bugs no amount of local-only verification could have caught —

- Phase 6: a script silently never committed to git since Phase 3, because an unanchored `.gitignore` pattern
  matched it at any depth — found only because an independent GitHub Actions checkout doesn't have local
  working-tree state to hide behind.
- Phase 7: a chart with no `checksum/config` annotation, so a deliberate failure-injection test found nothing
  wrong — because the injected change never actually reached a running pod.
- Phase 9: five real installation bugs across three target-machine runs — a Loki chart option that silently
  leaves other replica targets at their default, rollout timeouts too short for this network, a now-required
  Helm value, a Grafana memory limit too low for its own newer storage subsystem.
- Phase 11: the cluster's own nodes couldn't resolve Docker Hub (a real DNS failure, not the risk originally
  flagged), and a cold model load measured 50.5 seconds against a 30-second timeout.
- Phase 12: `helm --set-string` silently corrupting a JSON secret value, and a deploy script that had never been
  taught about the gateway's own image tag.
- Phase 15: confirmed, not just theorized, that Argo CD's `ignoreDifferences` does not stop `selfHeal` from
  reverting a real Secret back to its chart placeholder.
- Phases 18 & 19 (the same class of bug, found independently twice): work applied to disk but never committed
  to git left Argo CD quietly running a stale `Deployment` behind a canary for 46+ hours, and a near-identical
  dirty-working-tree gap blocked a GitOps recovery script until it was fixed for real.
- Phase 19: Prometheus's `rate()` function structurally cannot see a brand-new time series whose entire rise
  happens inside one scrape interval — found by watching a real alert fail to fire, not by reading documentation.

Every one of these is written up honestly in `docs/troubleshooting.md` and the relevant ADR, not quietly patched
and forgotten.

## Honest current status

Not everything is finished, and this project's own discipline is to say so plainly rather than round up:

- **Phase 1** (local dev platform) is still *in progress* — the cluster and smoke test are verified, but a
  final re-run of `make doctor`/`make test`/`make smoke` after the latest fixes is still pending.
- **Phase 15** (security/supply chain) is *in progress* — Sealed Secrets and the egress NetworkPolicy are
  confirmed for real; Cosign signing and the Kyverno admission policy are written and shellchecked but not yet
  confirmed, since that needs a real GitHub Actions OIDC run, and no environment has ever actually deployed a
  GHCR-pulled (vs. local-registry) image for the policy to enforce against.
- **Phase 18**'s own status line still reads "not yet confirmed: the canary itself actually promoting or rolling
  back" — but Phase 19's own real runs (Scenario 1's `canary-demo-bad`/`-promote` cycle, and Scenario 3's
  revert-then-promote cycle) have since confirmed exactly that, for real, on Darya. Phase 18's README row and
  `docs/progressive-delivery.md` have not yet been updated to reflect this — a known, named follow-up, not a
  gap papered over.
- Scope decisions are named, not hidden: no GPU-backed model serving (Ollama/CPU only), no hard multi-tenancy
  isolation (logical tiers only), no streaming responses, no shared Redis-backed rate limiter, no automatic
  rollback demonstrated under real load (only analysis-gated promotion), and daily quota was never driven to
  real exhaustion against a live cluster.

## Where to go deeper

- `README.md` — the full, phase-by-phase account with every verification date and real finding
- `docs/adr/README.md` — 25 ADRs (ADR-16 through ADR-40) recording every real decision and trade-off
- `docs/component-qa.md` — a standard Problem/Why/Failure/Scale/Security/Cloud review for every phase
- `docs/troubleshooting.md` — the running log of every real bug found and how it was fixed
- `docs/demo-script.md` — a live walkthrough script for a recorded demonstration (Phase 20)
