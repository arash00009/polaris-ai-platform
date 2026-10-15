# Network policy: ingress (Phase 4/5/9/12) and egress (Phase 15)

**Status: confirmed on the target machine, 2026-10-15, at the "did not break anything under
real load" level** — `helm-apply-dev` rolled out cleanly with egress default-deny live,
`make verify-dev`/`make tenants-smoke` both passed. **Not yet done:** the dedicated,
per-rule negative test in §5 below has not actually been run for real yet — see ADR-34 for the
full decision record and exactly what that gap does and does not mean. The ingress rules this
document also describes were confirmed on the target machine in Phase 4 and have been unchanged
since.

## 1. What changed, and what did not

Through Phase 14, every `NetworkPolicy` in this project only ever set `policyTypes: ["Ingress"]`
— egress from every pod was completely unrestricted, named plainly in `values.yaml`'s own
comment rather than left implicit. Phase 15 adds egress default-deny for `ai-service` and
`ai-gateway`, with an explicit allow-list for exactly what each one actually calls out to.
`model-serving`'s own `NetworkPolicy` (Ollama) is deliberately **not** touched this phase — see
§4.

## 2. The allow-list, and why each rule exists

| From | To | Port | Why |
|------|----|------|-----|
| `ai-service` | `kube-system` (DNS) | 53/UDP+TCP | Every workload needs this; without it nothing else resolves. |
| `ai-service` | `model-serving` namespace | 11434 | Reaches Ollama when `POLARIS_BACKEND=openai_compat` (dev only). A no-op when the mock backend is in use — nothing on that path ever originates the connection. |
| `ai-service` | `observability` namespace | 4317, 4318 | OTLP export to the Collector when `POLARIS_OTEL_ENABLED=true` (dev only). Same no-op reasoning when off. |
| `ai-gateway` | `kube-system` (DNS) | 53/UDP+TCP | Same as above. |
| `ai-gateway` | `ai-service` (same namespace, pod selector) | 8000 | Its one upstream — every proxied `/v1/chat` request. |
| `ai-gateway` | `observability` namespace | 4317, 4318 | OTLP export when `GATEWAY_OTEL_ENABLED=true`. |

Four separate rules per Deployment, never one combined "allow everything these two need" rule —
each is independently reviewable, and none can accidentally widen another the way a single
merged `namespaceSelector` list could.

## 3. Rollout and verification (target-machine steps)

```bash
make helm-apply-dev     # networkPolicy.egress.enabled is already true in values-dev.yaml
make verify-dev         # exercises the real /v1/chat path end to end — would catch a blocked egress rule immediately
make tenants-smoke      # same, under real sustained load
```

A mistake in this policy fails loudly, not silently: if `ai-service` cannot reach
`model-serving`, every chat request times out or 5xxs, and `verify-dev`'s own `ai-answer` check
catches it the same way it already catches a genuinely slow or unhealthy Ollama backend. There
is no scenario where a wrong egress rule passes verification by accident.

## 4. Named gap: `model-serving`'s own egress is unchanged

Ollama's egress needs span *pull* time — DNS plus HTTPS to a model/image registry (already
worked around once for a real, confirmed DNS failure from k3d's own agent nodes; see
`docs/troubleshooting.md`'s Phase 11 section and `OLLAMA_IMAGE_REGISTRY` in `versions.env`) — not
a small, fully-enumerable allow-list the way `ai-service`'s three destinations are. Hardening
this without first confirming exactly what pull-time egress the target machine's own network
path actually requires risked breaking an already-verified phase for a gap this document can
name honestly instead. Revisit together with ADR-34's own "Revisit when."

## 5. Testing that a policy actually blocks something (optional, manual)

To confirm the default-deny is doing anything at all (not just that the allowed paths still
work — a policy that accidentally allows everything would pass §3's checks too), run a quick
negative test from inside the namespace once egress is live:

```bash
kubectl --context k3d-polaris -n polaris-dev run egress-test --rm -it --restart=Never \
  --image=busybox -- wget -T 3 -O- http://example.com
```

This should time out or fail to resolve/connect (depending on whether it is DNS or the HTTPS
egress itself that is blocked) — `example.com` is not on any allow-list above. If it succeeds,
the default-deny is not actually in effect and the rollout needs investigating before trusting
§3's own checks as sufficient (they prove the *allowed* paths work; they cannot, by themselves,
prove nothing *extra* is also allowed).
