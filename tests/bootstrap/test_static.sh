#!/usr/bin/env bash
# tests/bootstrap/test_static.sh
# Static checks that need no Docker and no cluster. Safe to run anywhere (and in CI later).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "$SCRIPT_DIR/../../scripts/lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT" || exit 1

PASSED=0
FAILED=0
ok()  { log_ok "$1"; PASSED=$((PASSED + 1)); }
bad() { log_fail "$1"; FAILED=$((FAILED + 1)); }

# 1. Shell syntax
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax ok: $f"; else bad "syntax error: $f"; fi
done < <(find scripts tests -name '*.sh' -type f | sort)

# 2. Scripts are executable
while IFS= read -r f; do
  if [[ -x "$f" ]]; then ok "executable: $f"; else bad "not executable (chmod +x): $f"; fi
done < <(find scripts tests -name '*.sh' -type f ! -path 'scripts/lib/*' | sort)

# 3. No CRLF line endings (breaks bash: 'bad interpreter: /usr/bin/env: bash\r')
crlf="$(grep -rIl $'\r' --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir='*.egg-info' scripts tests deploy app Makefile versions.env 2>/dev/null || true)"
if [[ -z "$crlf" ]]; then ok "no CRLF line endings"; else bad "CRLF line endings in: $crlf"; fi

# 4. versions.env
# shellcheck source=/dev/null
source "$ROOT/versions.env"
for var in K3D_VERSION KUBECTL_VERSION HELM_VERSION; do
  val="${!var:-}"
  if [[ "$val" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "$var=$val"; else bad "$var is missing or not vX.Y.Z (got '$val')"; fi
done
if [[ "${SMOKE_IMAGE:-}" == */*:* ]]; then ok "SMOKE_IMAGE=$SMOKE_IMAGE"; else bad "SMOKE_IMAGE must look like repo/name:tag"; fi

# 5. cluster.yaml
CFG="deploy/k3d/cluster.yaml"
if grep -q '^apiVersion: k3d.io/v1alpha5$' "$CFG"; then ok "$CFG uses k3d.io/v1alpha5"; else bad "$CFG apiVersion is not k3d.io/v1alpha5"; fi
image="$(k3s_image_from_config "$CFG")"
if [[ "$image" =~ ^rancher/k3s:v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+$ ]]; then ok "k3s image pinned: $image"; else bad "k3s image not pinned as rancher/k3s:vX.Y.Z-k3sN (got '$image')"; fi
name="$(cluster_name_from_config "$CFG")"
if [[ "$name" == "polaris" ]]; then ok "cluster name: $name"; else bad "cluster name should be 'polaris' (got '$name')"; fi

# 6. Kubernetes version-skew policy: kubectl within one minor of the cluster
if [[ -n "$image" ]]; then
  k3s_minor="$(k3s_minor_from_image "$image")"
  kubectl_minor="$(semver_minor "$KUBECTL_VERSION")"
  d=$((k3s_minor - kubectl_minor)); d=${d#-}
  if [[ "$d" -le 1 ]]; then ok "kubectl 1.$kubectl_minor is within one minor of cluster 1.$k3s_minor"; else bad "kubectl 1.$kubectl_minor vs cluster 1.$k3s_minor violates version skew policy"; fi
fi

# 7. Smoke manifest and script agree on the in-cluster image reference
reg_name="$(awk '/create:/{f=1} f && /name:/{print $2; exit}' deploy/k3d/cluster.yaml)"
ref="$(grep -oE "${reg_name//./\\.}:5000/[^\" ]+" deploy/k8s-smoke/whoami.yaml | head -n1)"
if [[ -n "$reg_name" && -n "$ref" ]] && grep -q "CLUSTER_REF=\"$ref\"" scripts/bootstrap/smoke-test.sh; then
  ok "smoke manifest and script use the registry name from cluster.yaml ($ref)"
else
  bad "smoke image ref ('$ref') must start with the registry name from cluster.yaml ('$reg_name') and match CLUSTER_REF in smoke-test.sh"
fi

# 8. Host ports: parsed from cluster.yaml, numeric, and no duplicates
ingress_port="$(host_port_for deploy/k3d/cluster.yaml 80)"
if [[ "$ingress_port" =~ ^[0-9]+$ ]]; then ok "ingress host port read from cluster.yaml: $ingress_port"; else bad "cannot read the host port mapped to container port 80 from cluster.yaml (got '$ingress_port')"; fi
ports="$(host_ports_from_config deploy/k3d/cluster.yaml)"
dupes="$(sort <<<"$ports" | uniq -d)"
if [[ -n "$ports" && -z "$dupes" ]]; then ok "host ports are unique: $(tr '\n' ' ' <<<"$ports")"; else bad "host ports missing or duplicated in cluster.yaml: '$ports'"; fi

# 9. Documentation does not contradict the configuration (stale versions/ports)
k3s_min="1.$(k3s_minor_from_image "$(k3s_image_from_config deploy/k3d/cluster.yaml)")"
stale="$(grep -rnE "localhost:(8080|8443)\b" README.md docs scripts deploy 2>/dev/null | grep -v 'docs/troubleshooting.md' || true)"
if [[ -z "$stale" ]]; then ok "no stale localhost:8080/8443 references (cluster is on $k3s_min, ports from cluster.yaml)"; else bad "stale port references: $stale"; fi

# 10. Python requirements are pinned exactly (== or an include of another requirements file)
for req in app/ai_service/requirements.txt app/ai_service/requirements-dev.txt; do
  if [[ ! -f "$req" ]]; then bad "missing $req"; continue; fi
  loose="$(grep -vE '^\s*(#|$)' "$req" | grep -vE '^-r ' | grep -vE '^[A-Za-z0-9._-]+==[A-Za-z0-9.+!_-]+\s*$' || true)"
  if [[ -z "$loose" ]]; then ok "exactly pinned: $req"; else bad "not exactly pinned in $req: $loose"; fi
done

# 11. No obvious secrets or local cluster credentials committed
if grep -rIEl 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}' . --exclude-dir=.git --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir='*.egg-info' --exclude=test_static.sh 2>/dev/null | grep -q .; then
  bad "secret-looking string found in repository"
else
  ok "no secret-looking strings found"
fi

# 12. Phase 3: pinned values for the image build and the scanner
if [[ "${PYTHON_BASE_TAG:-}" =~ ^3\.12-slim-[a-z]+$ ]]; then ok "PYTHON_BASE_TAG=$PYTHON_BASE_TAG (Debian release named, no floating tag)"; else bad "PYTHON_BASE_TAG must look like 3.12-slim-<debian codename> (got '${PYTHON_BASE_TAG:-}')"; fi
for var in PYTHON_BASE_DIGEST TRIVY_IMAGE_DIGEST; do
  val="${!var-unset}"
  if [[ "$val" == "unset" ]]; then bad "$var is missing from versions.env (it may be empty, but it must exist)"
  elif [[ -z "$val" || "$val" =~ ^sha256:[0-9a-f]{64}$ ]]; then ok "$var is empty or a sha256 digest"
  else bad "$var must be empty or sha256:<64 hex characters> (got '$val')"; fi
done
if [[ "${TRIVY_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "TRIVY_VERSION=$TRIVY_VERSION"; else bad "TRIVY_VERSION must be X.Y.Z without a leading v (got '${TRIVY_VERSION:-}')"; fi
case "${TRIVY_VERSION:-}" in
  0.69.4|0.69.5|0.69.6) bad "TRIVY_VERSION=$TRIVY_VERSION is a known malicious release (GHSA-69fq-xp46-6x23)" ;;
  *) ok "TRIVY_VERSION is not one of the known malicious releases (0.69.4, 0.69.5, 0.69.6)" ;;
esac

# 13. Dockerfile: the default base image matches versions.env, no floating tags
DF="app/ai_service/Dockerfile"
if [[ ! -f "$DF" ]]; then
  bad "missing $DF"
else
  df_base="$(sed -n 's/^ARG PYTHON_IMAGE=//p' "$DF" | head -n1)"
  if [[ "$df_base" == "python:${PYTHON_BASE_TAG:-}" ]]; then ok "Dockerfile default base image matches versions.env ($df_base)"; else bad "Dockerfile ARG PYTHON_IMAGE ('$df_base') must equal python:PYTHON_BASE_TAG from versions.env ('python:${PYTHON_BASE_TAG:-}')"; fi

  bad_from="$(grep -E '^FROM ' "$DF" | grep -vE '^FROM \$\{PYTHON_IMAGE\}( AS [a-z]+)?$' || true)"
  if [[ -z "$bad_from" ]]; then ok "every FROM in the Dockerfile uses the pinned PYTHON_IMAGE argument"; else bad "FROM lines that do not use \${PYTHON_IMAGE}: $bad_from"; fi

  if grep -rnE ':latest\b' "$DF" scripts/build/image.sh >/dev/null 2>&1; then bad "a ':latest' tag is used in the Dockerfile or the image script"; else ok "no ':latest' tag in the Dockerfile or the image script"; fi

  last_user="$(grep -E '^USER ' "$DF" | tail -n1 | awk '{print $2}')"
  if [[ "$last_user" =~ ^[0-9]+(:[0-9]+)?$ && "${last_user%%:*}" != "0" ]]; then ok "the image runs as a numeric non-root user (USER $last_user)"; else bad "the last USER in the Dockerfile must be a numeric non-root id (got '$last_user')"; fi

  if grep -qE '^HEALTHCHECK ' "$DF"; then ok "the Dockerfile defines a HEALTHCHECK"; else bad "the Dockerfile has no HEALTHCHECK"; fi

  if grep -nE 'curl[^|]*\|[[:space:]]*(ba)?sh|^ADD https?://|\bsudo\b|--privileged' "$DF" >/dev/null 2>&1; then bad "the Dockerfile pipes a download into a shell, uses ADD from a URL, sudo or --privileged"; else ok "no curl|sh, remote ADD, sudo or --privileged in the Dockerfile"; fi
fi

# 14. .dockerignore keeps local state and secrets out of the build context
DI="app/ai_service/.dockerignore"
if [[ -f "$DI" ]] && grep -qxF '.venv' "$DI" && grep -qxF 'tests' "$DI" && grep -qxF '.env' "$DI"; then
  ok ".dockerignore excludes .venv, tests and .env"
else
  bad "$DI must exist and exclude .venv, tests and .env"
fi

# 15. Phase 4: the Kubernetes manifests all exist
KDIR="deploy/k8s/ai-service"
for f in namespace.yaml configmap.yaml deployment.yaml service.yaml ingress.yaml poddisruptionbudget.yaml networkpolicy.yaml; do
  if [[ -f "$KDIR/$f" ]]; then ok "$KDIR/$f exists"; else bad "missing $KDIR/$f"; fi
done

# 16. deployment.yaml still carries the placeholder image (never a resolved tag, never :latest)
DEP="$KDIR/deployment.yaml"
if [[ -f "$DEP" ]]; then
  if grep -q '__AI_SERVICE_IMAGE__' "$DEP"; then ok "deployment.yaml uses the __AI_SERVICE_IMAGE__ placeholder"; else bad "deployment.yaml must reference the __AI_SERVICE_IMAGE__ placeholder, substituted by scripts/deploy/app.sh"; fi
  if grep -qE ':latest\b' "$DEP"; then bad "deployment.yaml uses a ':latest' tag"; else ok "no ':latest' tag in deployment.yaml"; fi

  # 17. Pod-level and container-level hardening matches the Phase 3 run restrictions
  for needle in 'runAsNonRoot: true' 'runAsUser: 10001' 'readOnlyRootFilesystem: true' 'allowPrivilegeEscalation: false' 'drop: \["ALL"\]'; do
    if grep -qE -- "$needle" "$DEP"; then ok "deployment.yaml sets $needle"; else bad "deployment.yaml is missing '$needle'"; fi
  done

  # 18. Probes point at the Phase 3 endpoints
  if grep -A2 'livenessProbe' "$DEP" | grep -q 'path: /healthz'; then ok "livenessProbe uses /healthz"; else bad "livenessProbe must use /healthz"; fi
  if grep -A2 'readinessProbe' "$DEP" | grep -q 'path: /readyz'; then ok "readinessProbe uses /readyz"; else bad "readinessProbe must use /readyz"; fi

  # 19. Resource limits are declared (values are a documented estimate, not enforced here)
  if grep -q 'limits:' "$DEP" && grep -A3 'limits:' "$DEP" | grep -q 'memory:' && grep -A3 'limits:' "$DEP" | grep -q 'cpu:'; then
    ok "deployment.yaml declares resources.limits (memory and cpu)"
  else
    bad "deployment.yaml must declare resources.limits.memory and resources.limits.cpu"
  fi
else
  bad "cannot check deployment.yaml hardening: file is missing"
fi

# 20. namespace.yaml enforces the "restricted" Pod Security Standard
NS="$KDIR/namespace.yaml"
if [[ -f "$NS" ]] && grep -q 'pod-security.kubernetes.io/enforce: restricted' "$NS"; then
  ok "namespace.yaml enforces the restricted Pod Security Standard"
else
  bad "$NS must set pod-security.kubernetes.io/enforce: restricted"
fi

# 21. ingress.yaml uses Traefik and does not collide with the Phase 1 smoke test's host
ING="$KDIR/ingress.yaml"
if [[ -f "$ING" ]] && grep -q 'ingressClassName: traefik' "$ING"; then ok "ingress.yaml uses ingressClassName: traefik"; else bad "$ING must set ingressClassName: traefik"; fi
if [[ -f "$ING" ]] && grep -q 'host: whoami.localhost' "$ING"; then bad "$ING must not reuse whoami.localhost (Phase 1 smoke test)"; else ok "ingress.yaml host does not collide with the Phase 1 smoke test"; fi

# 22. scripts/deploy/app.sh and the manifests agree on the namespace
NS_FROM_SCRIPT="$(awk -F'"' '/^NAMESPACE="/{print $2; exit}' scripts/deploy/app.sh)"
ns_mismatch=""
for f in "$KDIR"/configmap.yaml "$KDIR"/deployment.yaml "$KDIR"/service.yaml "$KDIR"/ingress.yaml "$KDIR"/poddisruptionbudget.yaml "$KDIR"/networkpolicy.yaml; do
  [[ -f "$f" ]] || continue
  grep -q "namespace: $NS_FROM_SCRIPT" "$f" || ns_mismatch="$ns_mismatch $f"
done
if [[ -n "$NS_FROM_SCRIPT" && -z "$ns_mismatch" ]]; then
  ok "scripts/deploy/app.sh and every manifest use the same namespace ($NS_FROM_SCRIPT)"
else
  bad "namespace mismatch between scripts/deploy/app.sh ('$NS_FROM_SCRIPT') and:$ns_mismatch"
fi

# ---- Phase 5: Helm chart (helm/ai-platform) -------------------------------------------------
HDIR="helm/ai-platform"

# 23. Chart.yaml and every expected template file exist
if [[ -f "$HDIR/Chart.yaml" ]]; then ok "$HDIR/Chart.yaml exists"; else bad "$HDIR/Chart.yaml is missing"; fi
for f in _helpers.tpl namespace.yaml configmap.yaml deployment.yaml service.yaml ingress.yaml poddisruptionbudget.yaml networkpolicy.yaml NOTES.txt; do
  if [[ -f "$HDIR/templates/$f" ]]; then ok "$HDIR/templates/$f exists"; else bad "$HDIR/templates/$f is missing"; fi
done

# 24. values.yaml and one values-<env>.yaml per environment exist
for f in values.yaml values-dev.yaml values-staging.yaml values-prod.yaml; do
  if [[ -f "$HDIR/$f" ]]; then ok "$HDIR/$f exists"; else bad "$HDIR/$f is missing"; fi
done

# 25. every values-<env>.yaml is valid YAML and sets namespace/environment/ingress.host
if have python3; then
  for env in dev staging prod; do
    vf="$HDIR/values-$env.yaml"
    [[ -f "$vf" ]] || continue
    if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$vf')) or {}
env, ns, host = d.get('environment'), d.get('namespace'), (d.get('ingress') or {}).get('host')
assert env == '$env', f'environment must be \'$env\', got {env!r}'
assert ns == 'polaris-$env', f'namespace must be \'polaris-$env\', got {ns!r}'
assert host, 'ingress.host must be set'
" 2>/tmp/helm_values_check.err; then
      ok "$vf sets environment=$env, namespace=polaris-$env, ingress.host"
    else
      bad "$vf: $(cat /tmp/helm_values_check.err)"
    fi
  done
else
  bad "python3 not found: cannot validate $HDIR/values-*.yaml"
fi

# 26. the three ingress hosts (dev/staging/prod) are distinct from each other and from Phase 1's whoami.localhost
if have python3; then
  hosts="$(python3 -c "
import yaml
for env in ('dev', 'staging', 'prod'):
    d = yaml.safe_load(open(f'$HDIR/values-{env}.yaml')) or {}
    print((d.get('ingress') or {}).get('host', ''))
")"
  n_distinct="$(sort -u <<<"$hosts" | grep -c .)"
  if [[ "$n_distinct" -eq 3 ]] && ! grep -qx 'whoami.localhost' <<<"$hosts"; then
    ok "dev/staging/prod ingress hosts are distinct and do not collide with whoami.localhost"
  else
    bad "ingress hosts must be three distinct values, none equal to whoami.localhost (got: $(tr '\n' ' ' <<<"$hosts"))"
  fi
fi

# 27. no hardcoded namespace/environment inside templates/ (everything must come from values, unlike Phase 4's raw YAML)
if grep -rEl 'namespace: polaris-(dev|staging|prod)' "$HDIR/templates" >/dev/null 2>&1; then
  bad "a template under $HDIR/templates hardcodes a namespace instead of using {{ include \"ai-platform.namespace\" . }}"
else
  ok "no template under $HDIR/templates hardcodes a namespace"
fi

# 28. deployment.yaml never hardcodes an image reference (must come from values, no 'latest')
DTPL="$HDIR/templates/deployment.yaml"
if [[ -f "$DTPL" ]] && grep -qE 'image:\s*"?[a-zA-Z0-9.]+/.*:(latest)?"?\s*$' "$DTPL"; then
  bad "$DTPL must not hardcode an image reference or use :latest"
else
  ok "$DTPL takes its image from values (image.repository/image.tag), no :latest"
fi

# 29. deployment.yaml still carries the Phase 3/4 hardening fields, now as template lines
if [[ -f "$DTPL" ]] \
  && grep -q 'runAsNonRoot: true' "$DTPL" \
  && grep -q 'runAsUser: 10001' "$DTPL" \
  && grep -q 'readOnlyRootFilesystem: true' "$DTPL" \
  && grep -q 'drop: \["ALL"\]' "$DTPL"; then
  ok "$DTPL keeps the Phase 3/4 securityContext hardening fields"
else
  bad "$DTPL is missing one or more of: runAsNonRoot, runAsUser: 10001, readOnlyRootFilesystem, capabilities.drop: [ALL]"
fi

# 30. scripts/deploy/helm.sh and the chart agree on the registry image repository pattern
# shellcheck disable=SC2016
if grep -q 'CLUSTER_REPO="\$REG_NAME:5000/\$IMAGE_REPO"' scripts/deploy/helm.sh \
  && grep -q 'IMAGE_REPO="polaris/ai-service"' scripts/deploy/helm.sh; then
  ok "scripts/deploy/helm.sh computes the same registry image repository pattern as scripts/deploy/app.sh"
else
  bad "scripts/deploy/helm.sh's image repository computation changed unexpectedly"
fi

# ---- Phase 6: CI pipeline (.github/workflows/ci.yml, scripts/ci/) --------------------------

# 31. versions.env: Phase 6 tool pins exist and are in the right shape
for var in GITLEAKS_VERSION ACTIONLINT_VERSION; do
  val="${!var:-}"
  if [[ "$val" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "$var=$val"; else bad "$var is missing or not vX.Y.Z (got '$val')"; fi
done
for var in PIP_AUDIT_VERSION YAMLLINT_VERSION; do
  val="${!var:-}"
  if [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "$var=$val"; else bad "$var is missing or not X.Y.Z without a leading v (got '$val')"; fi
done

# 32. install-tools.sh knows how to install the two new tools, and doctor.sh checks for them
if grep -q 'install_gitleaks' scripts/bootstrap/install-tools.sh && grep -q 'install_actionlint' scripts/bootstrap/install-tools.sh; then
  ok "scripts/bootstrap/install-tools.sh installs gitleaks and actionlint"
else
  bad "scripts/bootstrap/install-tools.sh must define install_gitleaks and install_actionlint"
fi
if grep -qE 'for t in k3d kubectl helm gitleaks actionlint' scripts/bootstrap/doctor.sh; then
  ok "doctor.sh checks gitleaks and actionlint alongside k3d/kubectl/helm"
else
  bad "doctor.sh's tool-version loop must include gitleaks and actionlint"
fi

# 33. scripts/ci/*.sh exist (executability and shell syntax are already covered by checks 1-2)
for f in secrets-scan.sh deps-audit.sh workflow-lint.sh; do
  if [[ -f "scripts/ci/$f" ]]; then ok "scripts/ci/$f exists"; else bad "missing scripts/ci/$f"; fi
done

# 34. .yamllint.yml exists and relaxes line-length (GitHub Actions YAML routinely exceeds 80 cols)
if [[ -f .yamllint.yml ]] && grep -q 'line-length' .yamllint.yml; then
  ok ".yamllint.yml exists and configures line-length"
else
  bad ".yamllint.yml must exist and configure the line-length rule"
fi

# 35. .venv-ci (the throwaway venv scripts/ci/*.sh create) is gitignored.
# Accepts both the unanchored form (.venv-ci/) and the root-anchored form
# (/.venv-ci/) — the latter is what Phase 6's .gitignore fix uses, to avoid
# the same unanchored-pattern bug that once hid scripts/build/image.sh.
if grep -qxE '/?\.venv-ci/' .gitignore; then ok ".venv-ci/ is gitignored"; else bad ".gitignore must exclude .venv-ci/"; fi

# 36. scripts/build/image.sh gained a publish subcommand (GHCR) without touching push (local registry)
if grep -q 'cmd_publish' scripts/build/image.sh && grep -q 'publish) cmd_publish' scripts/build/image.sh; then
  ok "scripts/build/image.sh dispatches 'publish' to cmd_publish"
else
  bad "scripts/build/image.sh must add a 'publish' subcommand (cmd_publish)"
fi
if grep -q 'cmd_push' scripts/build/image.sh && grep -q 'REGISTRY_HOST' scripts/build/image.sh; then
  ok "scripts/build/image.sh still pushes to the local registry unchanged (cmd_push/REGISTRY_HOST)"
else
  bad "scripts/build/image.sh's existing local-registry push (cmd_push) must be unchanged"
fi
if grep -q "tr '\[:upper:\]' '\[:lower:\]'" scripts/build/image.sh; then
  ok "scripts/build/image.sh lowercases the GHCR owner/repo (GHCR requires a lowercase path)"
else
  bad "scripts/build/image.sh's cmd_publish must lowercase the owner/repo before building the GHCR image ref"
fi

# 37. Makefile: new Phase 6 targets exist and route to the right script
for tgt in ci-secrets-scan ci-deps-audit ci-workflow-lint ci-verify image-publish; do
  if grep -qE "^${tgt}:" Makefile; then ok "Makefile target: $tgt"; else bad "Makefile is missing target: $tgt"; fi
done
# shellcheck disable=SC2016
if grep -q 'install-tools.sh \$(ARGS)' Makefile; then
  ok "make tools-install passes through ARGS (for --only gitleaks / --only actionlint)"
else
  bad "Makefile's tools-install target must pass \$(ARGS) to install-tools.sh"
fi
if grep -q 'scripts/ci/\*\.sh' Makefile; then
  ok "make lint shellchecks scripts/ci/*.sh too"
else
  bad "Makefile's lint target must include scripts/ci/*.sh"
fi

# 38. .github/workflows/ci.yml exists and is valid YAML
WF=".github/workflows/ci.yml"
if [[ -f "$WF" ]]; then
  ok "$WF exists"
  if have python3 && python3 -c "import yaml; yaml.safe_load(open('$WF'))" 2>/tmp/ci_yaml_check.err; then
    ok "$WF is valid YAML"
  else
    bad "$WF is not valid YAML: $(cat /tmp/ci_yaml_check.err 2>/dev/null)"
  fi
else
  bad "missing $WF"
fi

# 39. The workflow defines every job the pipeline is supposed to have, and nothing scope-creeps
# into Phase 7/8/15/18 (signing, gitops commit, Argo CD, canary, post-deploy verification).
if [[ -f "$WF" ]]; then
  for job in lint-and-test secrets-scan deps-audit workflow-lint build-scan-deploy publish; do
    if grep -qE "^  ${job}:" "$WF"; then ok "$WF defines job: $job"; else bad "$WF is missing job: $job"; fi
  done
  # Comment lines may legitimately explain what is deliberately NOT here (see the file header);
  # only real content (job/step definitions) counts as scope creep.
  out_of_scope="$(grep -vE '^\s*#' "$WF" | grep -inE 'cosign|argo-?cd|argo ?rollouts|gitops|sealed-?secret' || true)"
  if [[ -z "$out_of_scope" ]]; then
    ok "$WF stays inside Phase 6's scope (no signing/GitOps/Argo/canary references)"
  else
    bad "$WF references something out of Phase 6's scope (belongs to a later phase): $out_of_scope"
  fi
fi

# 40. publish only runs on a push to main, and only after build-scan-deploy
if [[ -f "$WF" ]]; then
  if grep -A3 "^  publish:" "$WF" | grep -q "needs: \[build-scan-deploy\]"; then
    ok "publish job needs build-scan-deploy"
  else
    bad "publish job must declare 'needs: [build-scan-deploy]'"
  fi
  if grep -A8 "^  publish:" "$WF" | grep -q "refs/heads/main"; then
    ok "publish job is gated to the main branch"
  else
    bad "publish job must be gated with an 'if' on refs/heads/main"
  fi
fi

# 41. Every heavy/scoped step in the workflow calls a make target that also exists locally —
# nothing here is logic that only runs in CI and was never run or reviewed locally.
if [[ -f "$WF" ]]; then
  missing=""
  for tgt in lint test app-install app-check ci-secrets-scan ci-deps-audit ci-workflow-lint \
    tools-install cluster-up image-build image-check image-scan image-sbom image-push \
    helm-lint helm-apply-dev helm-smoke-dev cluster-down image-publish; do
    grep -qE "make ${tgt}\b" "$WF" || missing="$missing $tgt"
  done
  if [[ -z "$missing" ]]; then
    ok "every Phase 6 workflow step calls a make target that also exists for local use"
  else
    bad "$WF is missing a call to these make targets, or the target no longer exists:$missing"
  fi
fi

# --- Phase 7: post-deploy verification (scripts/verify/post-deploy.sh) -------------------------

# 42. scripts/verify/post-deploy.sh exists (syntax/executable already covered by checks 1-2)
VERIFY_SCRIPT="scripts/verify/post-deploy.sh"
if [[ -f "$VERIFY_SCRIPT" ]]; then ok "$VERIFY_SCRIPT exists"; else bad "$VERIFY_SCRIPT is missing"; fi

# 43. it implements all six checks the Phase 7 roadmap line names: rollout, health, readyz,
# a real AI answer, logs, metrics
if [[ -f "$VERIFY_SCRIPT" ]]; then
  missing=""
  for fn in check_rollout check_health check_ready check_ai_answer check_logs check_metrics; do
    grep -q "^${fn}()" "$VERIFY_SCRIPT" || missing="$missing $fn"
  done
  if [[ -z "$missing" ]]; then
    ok "$VERIFY_SCRIPT implements rollout, health, readyz, ai-answer, logs and metrics checks"
  else
    bad "$VERIFY_SCRIPT is missing checks:$missing"
  fi
fi

# 44. main() actually calls all six, not just defines them
if [[ -f "$VERIFY_SCRIPT" ]]; then
  main_body="$(awk '/^main\(\)/,/^}/' "$VERIFY_SCRIPT")"
  missing=""
  for fn in check_rollout check_health check_ready check_ai_answer check_logs check_metrics; do
    grep -q "$fn" <<<"$main_body" || missing="$missing $fn"
  done
  if [[ -z "$missing" ]]; then
    ok "main() calls all six checks"
  else
    bad "$VERIFY_SCRIPT defines but main() never calls:$missing"
  fi
fi

# 45. the AI-answer check looks at the actual answer content, not just that the envelope has the
# right keys (that weaker check already exists in Phase 5's helm.sh smoke)
if [[ -f "$VERIFY_SCRIPT" ]] && grep -q '\.response | length > 0' "$VERIFY_SCRIPT"; then
  ok "$VERIFY_SCRIPT checks that response.response is non-empty, not just present"
else
  bad "$VERIFY_SCRIPT must assert the AI answer itself is non-empty, not only that the field exists"
fi

# 46. the metrics check is advisory: it must never be able to fail the whole verification by
# itself, since there is no Prometheus/threshold-based analysis until Phase 9/10/18
if [[ -f "$VERIFY_SCRIPT" ]]; then
  metrics_body="$(awk '/^check_metrics\(\)/,/^}/' "$VERIFY_SCRIPT")"
  if grep -q 'record_warn' <<<"$metrics_body" && ! grep -q 'record_fail' <<<"$metrics_body"; then
    ok "check_metrics is advisory (record_warn only, never record_fail)"
  else
    bad "check_metrics must only ever record_warn, never record_fail — it has no threshold to judge against yet"
  fi
fi

# 47. every other check reports through record_pass/record_fail instead of calling die() itself,
# so one run can report every problem instead of stopping at the first (unlike helm.sh's smoke)
if [[ -f "$VERIFY_SCRIPT" ]]; then
  die_in_checks="$(awk '/^check_/{f=1} /^main\(\)/{f=0} f' "$VERIFY_SCRIPT" | grep -c '\bdie\b' || true)"
  if [[ "$die_in_checks" -eq 0 ]]; then
    ok "individual checks never call die() — all six always run, and all failures are reported together"
  else
    bad "a check_* function calls die() directly, which would stop the script before every check has run"
  fi
fi

# 48. Makefile: verify-dev/staging/prod exist and route to the right script and environment
for env in dev staging prod; do
  if grep -qE "^verify-${env}:" Makefile && grep -A1 "^verify-${env}:" Makefile | grep -q "post-deploy.sh ${env}"; then
    ok "Makefile target: verify-$env"
  else
    bad "Makefile is missing verify-$env, or it does not call post-deploy.sh $env"
  fi
done

# 49. make lint shellchecks scripts/verify/*.sh too
if grep -q 'scripts/verify/\*\.sh' Makefile; then
  ok "make lint shellchecks scripts/verify/*.sh too"
else
  bad "Makefile's lint target must include scripts/verify/*.sh"
fi

# 50. deployment.yaml carries a checksum/config annotation derived from configmap.yaml, so a
# ConfigMap-only value change (e.g. `helm upgrade --set config.X=...`) forces a new rollout
# instead of silently leaving the running pods on their old environment. Discovered missing
# during Phase 7's first real deliberate-failure test (all six verify checks kept passing
# because no pod ever restarted) -- see ADR-25 and docs/troubleshooting.md.
if [[ -f "$DTPL" ]] \
  && grep -q 'checksum/config:' "$DTPL" \
  && grep -q 'configmap.yaml' "$DTPL" \
  && grep -q 'sha256sum' "$DTPL"; then
  ok "$DTPL carries a checksum/config annotation derived from configmap.yaml"
else
  bad "$DTPL must annotate its pod template with a checksum/config hash of configmap.yaml (see ADR-25), or a ConfigMap-only change never triggers a rollout"
fi

printf '\nPASSED=%d  FAILED=%d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
