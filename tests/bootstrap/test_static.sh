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
crlf="$(grep -rIl $'\r' scripts tests deploy Makefile versions.env 2>/dev/null || true)"
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

# 10. No obvious secrets or local cluster credentials committed
if grep -rIEl 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}' . --exclude-dir=.git --exclude=test_static.sh 2>/dev/null | grep -q .; then
  bad "secret-looking string found in repository"
else
  ok "no secret-looking strings found"
fi

printf '\nPASSED=%d  FAILED=%d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
