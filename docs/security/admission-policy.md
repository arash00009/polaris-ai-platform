# Admission policy: Kyverno verifies Cosign signatures (Phase 15 session 2)

**Status: written and shellchecked in the sandbox, 2026-10-15 — not yet confirmed on the target
machine.** See ADR-36 for the full decision record; this document is the operational guide — what
the policy actually enforces, how to install and test it, and exactly what gap it does and does
not close today.

## 1. What this adds

A `ClusterPolicy` (Kyverno's own CRD) that rejects any Pod whose image matches
`ghcr.io/<owner>/<repo>/ai-service` unless Cosign can verify a real signature from this
repository's own `.github/workflows/ci.yml`, running on `main` (ADR-35's keyless signing is what
that signature actually is). This is the in-cluster half of "prove the image came from this
project's own CI, not from somewhere else" — Cosign's own `verify` (ADR-35 §4) is the
command-line half; this is what makes the check happen automatically, for every Pod, without
anyone having to remember to run it by hand.

## 2. Installing and applying it

```bash
make cluster-up           # if not already up
make kyverno-install      # installs Kyverno (4 controllers) into its own 'kyverno' namespace
make kyverno-apply-policy # renders the policy with THIS repo's real owner/repo, applies it
make kyverno-status       # Helm release, pods, the ClusterPolicy's own status
```

`kyverno-apply-policy` resolves this repository's real `owner/repo` string the same way
`scripts/build/image.sh`'s own `ghcr_owner_repo()` does (from `$GITHUB_REPOSITORY` or the git
`origin` remote), substitutes it into
`deploy/platform/kyverno/policies/verify-ai-service-images.yaml.tmpl`, and pipes the result
straight into `kubectl apply -f -` — the rendered YAML is **never** written to a file on disk and
never committed. This is a deliberate choice, made after Phase 15 session 1's own real bug (a
hand-pasted ciphertext value and a duplicate-top-level-YAML-key mistake, both caught before they
shipped — see `docs/troubleshooting.md`): a resolved value that could go stale or get mistyped if
pasted by hand simply never exists as a file to paste into, here.

## 3. The real, named gap: this does not (yet) check what `polaris-dev` actually runs

`docs/security/image-signing.md` §5 names this already, from the signing side; stating it again
here, from the policy side, because it is the single most important thing to understand about
what this ADR actually proves: `polaris-dev`/`-staging`/`-prod` pull every image from
`registry.localhost:5000/...`, the k3d cluster's own local registry — never from
`ghcr.io/<owner>/<repo>/ai-service`. The policy's own `imageReferences` glob only ever matches the
GHCR path (deliberately — matching anything broader risked the policy trying, and failing, to
verify a signature for an image that was genuinely never signed, breaking the existing, working
local dev pipeline for every single deploy). The practical result: **today, this policy has
nothing to actually enforce against in the real, running cluster** — every Pod `helm-apply-dev`
creates pulls from the local registry, which the glob does not match at all, so the webhook
simply has nothing to say about them, one way or the other.

This is not a bug in the policy — it is an accurate reflection of an architecture choice made all
the way back in Phase 5 (build and deploy locally, without needing network access to GHCR for
every iteration) that this phase was never scoped to change. It is named here, honestly, rather
than quietly left for someone to discover later by noticing the policy "isn't doing anything."

### What this phase demonstrates instead

`make kyverno-verify-demo REF=<a real signed GHCR digest>` proves the policy mechanism itself
works correctly — admits a genuinely signed image, rejects one that is not — against two
throwaway `Pod`s in the `default` namespace, created and deleted by the script, that reference
the GHCR path directly (not anything `polaris-dev` itself runs):

1. **Positive case**: the real digest a signed CI `publish` run produced (ADR-35) — must be
   admitted.
2. **Negative case**: the same real repository path, at a digest one hex character away from the
   real one (so it is guaranteed to be a real-looking reference that was never pushed, let alone
   signed, without needing to already know any specific prior unsigned tag's name) — must be
   rejected by the admission webhook itself, not merely fail later with `ImagePullBackOff`.

### What would actually close this gap (not done, deliberately out of this session's scope)

Wiring `polaris-dev`'s own `helm-apply-dev` to deploy the real, signed GHCR image instead of a
local-registry retag — e.g. a new `gitops-bump-dev`-shaped step that runs after a real CI publish
and points `image.repository`/`image.tag` at the GHCR digest for that environment. This is a
materially bigger change to this project's deploy model (today, every environment can be stood
up and iterated on with zero network access to GHCR at all) than anything else in Phase 15, named
as a deliberate "Revisit when" in ADR-36 rather than attempted inside this already-large session.

## 4. Uninstalling

```bash
make kyverno-uninstall   # removes the ClusterPolicy and Kyverno itself
```

Removing Kyverno removes admission-time enforcement for every Pod cluster-wide, not only the
images this one policy names — named plainly in the script's own uninstall warning, the same way
`sealed-secrets.sh uninstall`'s warning names what removing that controller does.

## 5. Target-machine verification — sequenced after signing, not independently of it

`kyverno-install`/`kyverno-apply-policy`/`kyverno-status` need only a cluster and can be confirmed
on Darya at any time after `make cluster-up`. `kyverno-verify-demo` is different: it needs a real
signed digest as input, which only exists after `docs/security/image-signing.md`'s own
target-machine sequence (a real GitHub Actions run) has actually produced one. Confirming Kyverno
installs cleanly does not, by itself, confirm the verification mechanism actually works — only
`verify-demo`, run against a real signed digest, does that.

## 6. Real finding, 2026-10-29 — `verify-demo` failed with "no signatures found" against a genuinely signed, `cosign verify`-clean image

The first real `kyverno-verify-demo` run (digest from CI run `40250439366`, confirmed by
`make cosign-verify` to carry a valid signature — certificate identity, Rekor transparency log
entry, all checked) was rejected by the policy anyway: `verify-cosign-keyless: 'failed to verify
image ...: .attestors[0].entries[0].keyless: no signatures found'`. Ruled out in order, each by a
real test, not a guess: a crash-looping admission-controller pod (restarted the whole k3d node,
re-ran — same failure on a healthy `1/1 Running` pod); a NetworkPolicy/DNS block (a one-off debug
pod in the `kyverno` namespace reached `https://ghcr.io/v2/` with a full TLS handshake and the
normal 401 challenge — no different from Darya's own host); and a Kyverno/cosign library version
gap (Kyverno v1.19.1's own `go.mod`, read from its real GitHub source, pins `cosign/v3` v3.1.2 —
essentially the same version as the `cosign` v3.1.3 CLI that verified the image cleanly).

The real cause, found by reading Kyverno v1.19.1's actual source
(`pkg/image/verifiers/cpol/cosign/cosign.go`'s `buildCosignOptions()`):

```go
cosignOpts.ExperimentalOCI11 = opts.CosignOCI11
```

`CosignOCI11` is a real, documented `ClusterPolicy` field
(`api/kyverno/v1/image_verification_types.go`: `verifyImages[].cosignOCI11`, doc comment
"enables the experimental OCI 1.1 behaviour in cosign image verification. Defaults to false").
GHCR does not implement the native OCI 1.1 Referrers API (confirmed: `GET
.../referrers/<digest>` returns `MANIFEST_UNKNOWN`), so `cosign sign` (same version, in CI)
correctly fell back to OCI 1.1's "referrers tag schema" — a tag literally named
`sha256-<digest>`, no `.sig` suffix — confirmed to exist with a raw, manually-negotiated
registry API call (anonymous token + `GET` on that exact tag → `200`).

Setting `cosignOCI11: true` and re-applying the policy (confirmed present in the live
`ClusterPolicy` object, against a freshly-restarted, verified-healthy admission-controller pod)
**did not fix it** — identical error, identical message. That ruled out `cosignOCI11` itself,
not just the three causes above.

The actual cause came from fetching the real content of that fallback tag directly (`curl` with
a real anonymous bearer token, `Accept: application/vnd.oci.image.index.v1+json`): the one
referrer stored there carries `"artifactType": "application/vnd.dev.sigstore.bundle.v0.3+json"`
— the modern, unified **Sigstore Bundle** format (certificate, signature, and Rekor entry in one
object), which is what `cosign sign` v3.1.3 writes by default now. `cosignOCI11`'s own code
path (`pkg/cosign/verify.go`'s `verifyImageSignaturesExperimentalOCI`, in the vendored cosign
library) filters referrers by `artifactType: "sig"` — the older "simple signing" type — which
matches nothing here, errors, and (by cosign's own design: the experimental attempt's error is
never surfaced, just silently falls through) continues to the legacy `sha256-<digest>.sig` tag
path, which also fails, since that tag was never created either. Both failures produce the
identical `"no signatures found"` string from a shared helper function, which is exactly why
turning `cosignOCI11` on appeared to change nothing.

Kyverno has a *separate* code path built for precisely this format:
`pkg/image/verifiers/cpol/cosign/sigstore.go`'s `fetchBundles()`, which filters referrers by
`strings.HasPrefix(manifestDesc.ArtifactType, "application/vnd.dev.sigstore.bundle")` — a
prefix match against exactly what GHCR is storing. It only runs when `verifyImages[].type` is
set to `SigstoreBundle` (an enum alongside the default, `Cosign`, and `Notary`). The existing
`keyless.subject`/`issuer`/`rekor.url` fields are consumed identically by both code paths
(`sigstore.go`'s own `buildPolicy()`), so nothing else in the policy needed to change.

**Fix**: replaced `cosignOCI11: true` with `type: SigstoreBundle` on
`deploy/platform/kyverno/policies/verify-ai-service-images.yaml.tmpl`'s single `verifyImages[]`
entry. This is not CI-ephemeral-specific — the real, persistent `polaris-dev` cluster on Darya
is what this was tested against — and it is specific to the artifact format this cosign version
writes by default, not something `--ephemeral` or any CI-only path needs to care about. Confirm
column updated once a real `make kyverno-verify-demo` run passes with the field applied.
