# Image signing: Cosign keyless, via GitHub Actions OIDC (Phase 15 session 2)

**Status: written and shellchecked in the sandbox, 2026-10-15 — not yet confirmed on the target
machine, and the target-machine confirmation step for THIS phase is unlike every previous one in
this project: it needs a real GitHub Actions run, not a command on Darya.** See ADR-35 for the
full decision record; this document is the operational guide — what gets signed, how, and how to
check it yourself.

## 1. What this adds

`docs/security/image-scan.md` has said plainly, since Phase 6, "the image is not
signature-verified or signed." This closes that gap for `ai-service`'s GHCR publish: the exact
image digest `.github/workflows/ci.yml`'s `publish` job pushes is signed, in the same job,
immediately after the push, using Cosign's **keyless** mode — no private key is generated,
stored, rotated, or can leak, because there is no long-lived key at all. The job instead asks the
GitHub Actions runtime for a short-lived OIDC token identifying exactly this workflow run (repo,
ref, workflow file), trades it with the public Fulcio certificate authority for a short-lived
signing certificate, signs with that, and publishes the signature alongside the image on GHCR and
a record of it to the public Rekor transparency log. The certificate itself — not a long-lived
key anyone has to protect — is what later verification checks against.

## 2. What actually changed

- `scripts/build/image.sh`'s `cmd_publish` now captures the digest `docker push` reports and
  prints it on its own line, `GHCR_IMAGE_DIGEST=ghcr.io/<owner>/<repo>/ai-service@sha256:<digest>`
  — signing happens against this exact digest, never a mutable tag (a tag can be retargeted after
  signing; a digest cannot).
- `.github/workflows/ci.yml`'s `publish` job gained `permissions: id-token: write` (the one new
  permission this phase needs — without it the Actions runtime refuses to issue the OIDC token
  and `cosign sign` fails outright, loudly, not silently), a step installing `cosign` the same
  way `gitleaks`/`actionlint` already are elsewhere in this file (`install-tools.sh --only cosign`
  — not the `sigstore/cosign-installer` marketplace action, to keep one, already-audited
  tool-install path for every pinned binary in this project rather than adding a second one for
  just this tool), and a final `cosign sign --yes <digest>` step.
- `versions.env` gained `COSIGN_VERSION`/`COSIGN_SHA256_AMD64`/`COSIGN_SHA256_ARM64`, and
  `scripts/bootstrap/install-tools.sh`/`scripts/lib/common.sh` both gained `cosign` support, the
  same way every other pinned binary in this project does.
- A new `scripts/verify/cosign-verify.sh` (`make cosign-verify DIGEST=...`) lets Darya confirm a
  real, published image's signature independently of CI's own log — the target-machine-side half
  of checking this actually works.

## 3. Why keyless, not a stored signing key

A long-lived key (`cosign generate-key-pair`, the key stored as a GitHub Actions secret) was the
alternative and is the more commonly-seen tutorial pattern — rejected here because it reintroduces
exactly the class of problem this whole phase exists to close: a secret that must be generated,
stored safely, rotated, and can leak. Keyless signing needs none of that; the trust anchor is "a
real GitHub Actions run of this exact repository's `ci.yml`, on `main`," verified cryptographically
through Fulcio/Rekor's own public infrastructure, not a secret this project has to manage at all.
This is also the direction Sigstore's own tooling and the broader ecosystem (`slsa-framework`,
GitHub's own documentation) actively steer toward for exactly this reason.

## 4. Verifying it yourself

```bash
# From a real GitHub Actions run's log, or from a local `make image-publish`:
# find the line GHCR_IMAGE_DIGEST=ghcr.io/<owner>/<repo>/ai-service@sha256:<digest>

make cosign-verify DIGEST=ghcr.io/<owner>/<repo>/ai-service@sha256:<digest>
# or directly:
cosign verify \
  --certificate-identity "https://github.com/<owner>/<repo>/.github/workflows/ci.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "ghcr.io/<owner>/<repo>/ai-service@sha256:<digest>"
```

A successful verify prints the certificate's claims (repo, workflow, ref, the exact run) and the
Rekor log entry. A tampered or unsigned image, or a digest that was never actually signed, fails
closed with a clear error — never a silent pass.

## 5. The real, named gap: what the running cluster actually pulls from

`helm/ai-platform/values.yaml`'s `image.repository` (and `gateway.image.repository`) point at
`registry.localhost:5000/...` — the k3d cluster's own local registry, not GHCR — for every
environment, dev included. This has been true since Phase 5 and nothing in this session changes
it: `scripts/deploy/helm.sh`'s `cmd_apply` always builds and pushes to the local registry, never
to GHCR, and `polaris-dev`/`-staging`/`-prod` have never pulled a GHCR image at all.

That means the image this session signs (the GHCR copy) and the image `polaris-dev` actually runs
(the local-registry copy) are two different registry references to, in practice, the same
content (the GHCR copy is a retag of the exact build the local registry already has, never a
rebuild) — but Cosign's signature is an artifact stored alongside the GHCR copy specifically, not
something the local registry has any knowledge of. Kyverno, which only ever looks for a
signature at the same registry an image reference actually points to, has nothing to check for
an image pulled from `registry.localhost:5000`. **This phase does not change that, and does not
claim to**: see `docs/security/admission-policy.md` §3 for exactly what this means for Kyverno's
own scope, and ADR-36's "Revisit when" for the larger change (wiring dev's own deployment to pull
from GHCR after a real publish) that would actually close it.

## 6. Target-machine verification — sequenced differently from every previous phase

Every previous phase's "confirm on the target machine" step has meant: run a command on Darya.
This one cannot start there. Keyless signing needs the GitHub Actions OIDC token the `publish`
job's runtime issues — nothing Darya's local k3d/manual-build workflow can produce, and nothing
the sandbox this was written in can produce either. The real sequence is:

1. Push this commit to a branch, open or update a PR, and merge to `main` (or push directly to
   `main`) — a real GitHub Actions run of the updated `ci.yml` is what actually exercises
   signing, for the first time in this project's history on a GitHub-hosted runner rather than
   Darya's own machine.
2. Confirm the `publish` job's `cosign sign` step succeeded in that run's own log — the digest it
   signed is printed in the "Capture the published digest for signing" step's output.
3. **Then**, from Darya (or anywhere with network access and `cosign` installed): `make
   cosign-verify DIGEST=<that digest>`, confirming independently, outside CI's own log, that the
   signature really verifies.
4. Only after step 3 succeeds does `docs/security/admission-policy.md`'s own `verify-demo` have a
   real signed digest to demonstrate against.
