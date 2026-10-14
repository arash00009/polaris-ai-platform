# Secrets management: Sealed Secrets, closing the GitOps gap

**Status: written and static-tested in the sandbox, 2026-10-13 — not yet confirmed on the target
machine.** See ADR-33 for the full decision record; this document is the operational guide —
how to install the controller, seal a real secret, and what Sealed Secrets does and does not
protect against.

## 1. The gap this closes

Phase 12 (`ai-gateway`) gave this project its first real Kubernetes `Secret`:
`GATEWAY_API_KEYS_JSON`, the api-key-to-tenant map. It could not be committed to
`polaris-gitops` in cleartext, so it was applied directly with `helm upgrade --install`,
deliberately bypassing GitOps for that one resource (ADR-30). That created a real, confirmed
problem: `polaris-dev` has been GitOps-managed (Argo CD, `selfHeal: true`) since Phase 8, and
`selfHeal` does not know this one Secret is special. An `ignoreDifferences` entry was tried and
tested twice against the live cluster — both times correctly configured, both times `selfHeal`
reverted the Secret's real content back to the chart's `"{}"` placeholder anyway. ADR-30 named
the real fix rather than keep fighting the symptom: make the *committed* state itself safe, so
`selfHeal` reverting to it is correct, not a bug.

Sealed Secrets does exactly that. A `SealedSecret` custom resource holds ciphertext that only the
sealed-secrets controller's own private key (which never leaves its namespace) can decrypt. The
ciphertext is safe to commit, safe to let Argo CD sync and self-heal, and safe to read in a pull
request — unlike the plaintext it was sealed from.

## 2. How it fits together

```
deploy/platform/gateway/api-keys.dev.local.json   (plaintext, gitignored, real tenant keys)
                 │
                 │  scripts/deploy/seal-gateway-secret.sh dev
                 ▼
         kubectl create secret ... --dry-run=client -o yaml   (plain Secret, in a temp file only)
                 │
                 │  kubeseal --cert <controller's public key>
                 ▼
         a SealedSecret's spec.encryptedData.GATEWAY_API_KEYS_JSON   (ciphertext — SAFE to commit)
                 │
                 │  pasted into helm/ai-platform/values-dev.yaml's gateway.apiKeysSealed
                 ▼
helm/ai-platform/templates/gateway-sealedsecret.yaml renders the SealedSecret
                 │
                 │  kubectl apply / Argo CD sync (ordinary GitOps, no bypass needed any more)
                 ▼
     sealed-secrets controller (sealed-secrets namespace) decrypts with its private key
                 │
                 ▼
        a plain Secret named ai-gateway-api-keys materialises in polaris-dev
                 │
                 ▼
          ai-gateway's envFrom reads it exactly as before (templates/gateway-deployment.yaml
          is unchanged — from ai-gateway's own point of view, nothing is different)
```

`templates/gateway-secret.yaml` (the Phase 12 plain Secret) and `templates/
gateway-sealedsecret.yaml` (this phase's SealedSecret) are mutually exclusive, gated by
`sealedSecrets.enabled`. Exactly one renders for a given environment; never both.

## 3. Installing and sealing (target-machine steps)

```bash
make sealed-secrets-install         # installs the controller into its own 'sealed-secrets' namespace
make sealed-secrets-status          # confirms the Deployment is Ready and the SealedSecret CRD exists
make gateway-seal ENV=dev           # seals deploy/platform/gateway/api-keys.dev.local.json for real
```

The last command prints two lines to paste into `helm/ai-platform/values-dev.yaml` (uncomment the
block that file's own Phase 15 comment describes, and fill in the real ciphertext — never type one
from guesswork). Then:

```bash
git add helm/ai-platform/values-dev.yaml
git commit -m "Phase 15: seal the real gateway API keys (ADR-33)"
git push
make helm-apply-dev                 # or let Argo CD sync it — either is now safe
```

Confirm the gateway still authenticates correctly afterwards — `make verify-dev` and `make
tenants-smoke` both exercise the real `x-api-key` path and would catch a sealing mistake
immediately (a wrong namespace or wrong controller key fails closed: the controller cannot
decrypt it, no Secret materialises, every request 401s — loud, not silent).

## 4. Rotating a key

Sealing is not stateful — re-run `make gateway-seal ENV=dev` any time
`api-keys.dev.local.json` changes (a new tenant, a rotated key) and paste the new ciphertext over
the old one in `values-dev.yaml`. The old ciphertext becomes inert the moment the new one is
applied; nothing needs to be explicitly revoked.

## 5. What this does and does not protect against, honestly

- **Protects:** a committed `SealedSecret` leaking (a public repo, a careless `git log -p`, a
  leaked `polaris-gitops` clone) — the ciphertext is useless without the controller's private key.
  This is the entire, narrow problem Sealed Secrets solves.
- **Does not protect:** anyone with real access to the cluster (kubectl access to the
  `sealed-secrets` namespace, or to `polaris-dev` where the decrypted Secret ends up) can still
  read the plaintext — Sealed Secrets moves *where* the secret is exposed (from "the git history"
  to "the cluster, same as any other Secret"), it does not make the value itself any less
  sensitive once decrypted. Anyone who can forge a request to the controller's own unseal
  endpoint, or exfiltrate its private key, can decrypt *any* SealedSecret this cluster has ever
  accepted for namespaces it watches — the private key is the single point of trust this whole
  scheme rests on, named plainly rather than glossed over.
- **Does not protect:** against the controller itself being compromised, or its own namespace
  (`sealed-secrets`, Pod Security `baseline`, not yet `restricted`) being under-hardened relative
  to what it actually needs to be.
- **Production equivalent:** External Secrets Operator or Vault, both of which keep the actual
  secret material in an external store rather than inside the cluster's own etcd/controller at
  all — a real, meaningful difference this project names (`docs/architecture.md` section 14) but
  does not build, since both need an external backend outside this project's "no paid cloud, no
  extra backend" constraint.
