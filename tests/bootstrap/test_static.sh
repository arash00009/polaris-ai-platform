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

printf '\nPASSED=%d  FAILED=%d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
