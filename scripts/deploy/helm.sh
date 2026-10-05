#!/usr/bin/env bash
# scripts/deploy/helm.sh — lint, template, install/upgrade, inspect and remove the Phase 5 Helm
# release for ai-service, per environment (dev|staging|prod). Phase 12 adds ai-gateway as a
# second, optional component of the same release (see gateway_enabled_for() below) -- still one
# chart, one release per environment, not a second script.
#
# Usage: scripts/deploy/helm.sh <lint|template|apply|status|logs|smoke|uninstall> [dev|staging|prod] [--follow] [gateway]
# Normally invoked through the make targets (make helm-apply-dev, make helm-status-staging, ...).
#
# Status: written and shellchecked in the sandbox, where `helm` itself could not be installed
# (get.helm.sh is outside the sandbox's allowlisted egress) or run against a cluster (no cluster
# in the sandbox). The chart's template logic was verified with a minimal Go-template-subset
# renderer instead and semantically diffed against Phase 4's already-verified manifests — see
# docs/adr/README.md ADR-23. `helm lint`/`helm template`/`helm install` with the real binary
# (already installed by `make tools-install`, Phase 1) is the target-machine verification step,
# the same pattern as Phase 4's kubectl apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"

APP_DIR="app/ai_service"
GATEWAY_DIR="app/gateway"
CHART_DIR="helm/ai-platform"
CLUSTER_CONFIG="deploy/k3d/cluster.yaml"
IMAGE_REPO="polaris/ai-service"
GATEWAY_IMAGE_REPO="polaris/ai-gateway"
ENVIRONMENTS=(dev staging prod)
# Phase 12: deploy/platform/gateway/api-keys.<env>.local.json holds the real api_key->tenant_id
# map for that environment's gateway Secret -- gitignored, never committed (see
# helm/ai-platform/templates/gateway-secret.yaml's own comment on why this is a deliberate,
# documented exception to "dev is GitOps-managed since Phase 8"). Only dev has
# gateway.enabled: true today, so only dev's file is ever read.
GATEWAY_KEYS_DIR="deploy/platform/gateway"

# ---- computed values -----------------------------------------------------------------------
# Deliberately duplicated from scripts/build/image.sh and scripts/deploy/app.sh rather than
# shared, so a change here can never alter Phase 3/4's already-verified scripts (same reasoning
# as ADR-22).

app_version() { awk -F'"' '/^version = / {print $2; exit}' "$APP_DIR/pyproject.toml"; }
gateway_version() { awk -F'"' '/^version = / {print $2; exit}' "$GATEWAY_DIR/pyproject.toml"; }

app_revision() {
  local rev
  rev="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$rev" ]] || { printf 'unknown'; return; }
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then rev="$rev-dirty"; fi
  printf '%s' "$rev"
}

VERSION="$(app_version)"
REVISION="$(app_revision)"
TAG="$VERSION-$REVISION"
# Same git revision as ai-service's own TAG (one commit, one revision string) -- only the
# version number differs, because app/gateway/pyproject.toml versions independently of
# app/ai_service/pyproject.toml (two separate packages, see gateway/config.py's docstring).
GATEWAY_VERSION="$(gateway_version)"
GATEWAY_TAG="$GATEWAY_VERSION-$REVISION"

REG_NAME="$(awk '/create:/{f=1} f && /name:/{print $2; exit}' "$CLUSTER_CONFIG")"
[[ -n "$REG_NAME" ]] || die "Could not read the registry name from $CLUSTER_CONFIG"
CLUSTER_REPO="$REG_NAME:5000/$IMAGE_REPO"
GATEWAY_CLUSTER_REPO="$REG_NAME:5000/$GATEWAY_IMAGE_REPO"

CLUSTER_NAME="$(cluster_name_from_config "$CLUSTER_CONFIG")"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="$(host_port_for "$CLUSTER_CONFIG" 80)"

# A clearly-fake tag used only so `helm lint`/`helm template` can render without a real deploy
# (the chart's `required` guard on image.tag would otherwise fail every lint run). It is never
# used by `apply`, which always computes the real $TAG above. Reused as-is for
# gateway.image.tag too -- lint/template never check that either tag actually exists in a
# registry, so one placeholder string serves both.
LINT_TAG="0.0.0-lintonly000"

namespace_for() { printf 'polaris-%s' "$1"; }
release_for()   { printf 'ai-platform-%s' "$1"; }
host_for()      { awk '/^ingress:/{f=1} f && /host:/{gsub(/"/,"",$2); print $2; exit}' "$CHART_DIR/values-$1.yaml"; }

# Phase 12: whether values-$1.yaml turns the gateway on. Greps rather than a real YAML parse
# (same level of rigor host_for() above already uses) -- "gateway:" starts a top-level block,
# and the very next "enabled:" line inside it is the one that matters; values-dev.yaml is the
# only file where this is ever anything but empty (= false) today.
gateway_enabled_for() {
  awk '/^gateway:/{f=1; next} f && /^[a-z]/{f=0} f && /enabled:/{print $2; exit}' "$CHART_DIR/values-$1.yaml"
}

# Phase 12: the real api_key->tenant_id JSON for $1's gateway Secret, read from a local,
# gitignored file (never committed -- see templates/gateway-secret.yaml's own comment). Prints
# "{}" (every request 401s) and a loud warning, rather than failing the whole deploy, when the
# file does not exist yet -- a fresh checkout must be able to run `make helm-apply-dev` at all
# before anyone has provisioned a single tenant key.
gateway_api_keys_json_for() {
  local file="$GATEWAY_KEYS_DIR/api-keys.$1.local.json"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    log_warn "no $file -- gateway will start with zero API keys (every /v1/chat request 401s). See $GATEWAY_KEYS_DIR/api-keys.$1.example.json." >&2
    printf '{}'
  fi
}

need_env() {
  local env="${1:-}"
  [[ -n "$env" ]] || die "Missing environment. Usage: $0 $CMD <dev|staging|prod>"
  for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "$env" ]] && return 0; done
  die "Unknown environment '$env'. Must be one of: ${ENVIRONMENTS[*]}"
}

need_helm() { have helm || die "helm not found. Run 'make tools-install' (pins $CHART_DIR's expected version via versions.env's HELM_VERSION)."; }

need_kubectl() {
  have kubectl || die "kubectl not found. Run 'make doctor'."
  kubectl --context "$CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cannot reach cluster context '$CONTEXT'. Create it first: make cluster-up"
}

need_pushed() {
  have curl || die "curl not found. Run 'make doctor'."
  local tags
  tags="$(curl -fsS "http://localhost:5000/v2/$IMAGE_REPO/tags/list" 2>/dev/null || true)"
  if ! grep -q "\"$TAG\"" <<<"$tags"; then
    die "Tag $TAG is not in the local registry (localhost:5000). Run: make image-build && make image-push"
  fi
}

# Phase 12: same check as need_pushed() above, parameterized, because it is only ever needed
# for the gateway image, and only in environments where gateway.enabled is true (checked by
# the caller, cmd_apply, before calling this -- staging/prod never need the gateway image
# pushed at all).
need_pushed_gateway() {
  have curl || die "curl not found. Run 'make doctor'."
  local tags
  tags="$(curl -fsS "http://localhost:5000/v2/$GATEWAY_IMAGE_REPO/tags/list" 2>/dev/null || true)"
  if ! grep -q "\"$GATEWAY_TAG\"" <<<"$tags"; then
    die "Tag $GATEWAY_TAG is not in the local registry (localhost:5000). Run: make gateway-image-build && make gateway-image-push"
  fi
}

hctl() { helm --kube-context "$CONTEXT" "$@"; }
kctl() { kubectl --context "$CONTEXT" "$@"; }

# ---- subcommands -----------------------------------------------------------------------------

cmd_lint() {
  need_helm
  local rc=0
  for env in "${ENVIRONMENTS[@]}"; do
    log_info "helm lint ($env, using a placeholder image tag — this checks structure, not a real deploy)"
    # gateway.image.* placeholders are passed for every environment, not just dev: harmless
    # for staging/prod (gateway.enabled: false there means gateway-deployment.yaml's own
    # `required` guard on them never even evaluates), and it means this loop does not need to
    # know per-environment which ones are "really" needed.
    if ! helm lint "$CHART_DIR" -f "$CHART_DIR/values-$env.yaml" \
        --set "image.repository=$CLUSTER_REPO" --set "image.tag=$LINT_TAG" \
        --set "gateway.image.repository=$GATEWAY_CLUSTER_REPO" --set "gateway.image.tag=$LINT_TAG"; then
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] || die "helm lint failed for at least one environment."
  log_ok "helm lint passed for: ${ENVIRONMENTS[*]}"
}

cmd_template() {
  need_helm
  local env="${1:-}"; need_env "$env"
  helm template "$(release_for "$env")" "$CHART_DIR" -f "$CHART_DIR/values-$env.yaml" \
    --set "image.repository=$CLUSTER_REPO" --set "image.tag=${TAG}" \
    --set "gateway.image.repository=$GATEWAY_CLUSTER_REPO" --set "gateway.image.tag=${GATEWAY_TAG}"
}

cmd_apply() {
  need_helm
  need_kubectl
  need_pushed
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  local rel; rel="$(release_for "$env")"

  # Phase 12: the gateway image and its real API-key map are only needed for an environment
  # that actually turns gateway.enabled on (dev today) -- staging/prod's `make helm-apply-*`
  # stays exactly as it was before this phase, with no new prerequisite.
  local -a gateway_args=()
  if [[ "$(gateway_enabled_for "$env")" == "true" ]]; then
    need_pushed_gateway
    gateway_args=(
      --set "gateway.image.repository=$GATEWAY_CLUSTER_REPO"
      --set "gateway.image.tag=$GATEWAY_TAG"
      --set-string "gateway.apiKeysJson=$(gateway_api_keys_json_for "$env")"
    )
  fi

  log_info "helm upgrade --install $rel ($env -> namespace $ns, image $CLUSTER_REPO:$TAG)"
  hctl upgrade --install "$rel" "$CHART_DIR" \
    -f "$CHART_DIR/values-$env.yaml" \
    --set "image.repository=$CLUSTER_REPO" \
    --set "image.tag=$TAG" \
    "${gateway_args[@]}" \
    --namespace "$ns" --create-namespace \
    --wait --timeout 120s

  log_ok "$rel is rolled out (image $CLUSTER_REPO:$TAG)"

  log_info "checking pod readiness after the NetworkPolicy in this release (same check as Phase 4's app.sh apply)"
  sleep 10
  local not_ready
  not_ready="$(kctl -n "$ns" get pods -l app.kubernetes.io/name=ai-service \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c 'false' || true)"
  if [[ "$not_ready" -eq 0 ]]; then
    log_ok "pods in $ns are still Ready after the NetworkPolicy was applied"
  else
    log_warn "$not_ready pod(s) in $ns are not Ready after the NetworkPolicy was applied."
    log_warn "See docs/troubleshooting.md (Phase 4/5). To remove just the policy for this release:"
    log_warn "  kubectl --context $CONTEXT -n $ns delete networkpolicy ai-service-default-deny ai-service-allow-ingress"
  fi
}

cmd_status() {
  need_helm
  need_kubectl
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  log_info "release status ($env)"
  hctl status "$(release_for "$env")" -n "$ns" || true
  echo
  log_info "resources in $ns"
  kctl -n "$ns" get deployment,pods,svc,ingress,pdb,networkpolicy -o wide
}

cmd_logs() {
  need_kubectl
  local env="${1:-}"; need_env "$env"; shift || true
  # Phase 12: the remaining arguments, in any order, are "--follow" and/or "gateway" (selects
  # ai-gateway's pods instead of the default ai-service) -- order-independent, rather than
  # fixed positions, specifically so every existing `make helm-logs-<env>` invocation (which
  # only ever passes --follow) keeps behaving exactly as it did before this phase, while
  # `ARGS="gateway"` alone (no --follow) also works.
  local selector_name="ai-service"
  local follow=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --follow) follow=(--follow) ;;
      gateway) selector_name="ai-gateway" ;;
      *) die "Unknown argument '$arg'. Usage: $0 logs <dev|staging|prod> [--follow] [gateway]" ;;
    esac
  done
  local ns; ns="$(namespace_for "$env")"
  kctl -n "$ns" logs -l "app.kubernetes.io/name=$selector_name" --prefix=true --tail=100 "${follow[@]}"
}

# Phase 12: the API key for tenant "demo" from $1's gateway keys file, or empty if that file
# does not exist or has no "demo" entry -- cmd_smoke uses this to authenticate through the
# gateway exactly the way a real caller would, rather than bypassing auth in its own test.
gateway_demo_api_key_for() {
  local file="$GATEWAY_KEYS_DIR/api-keys.$1.local.json"
  [[ -f "$file" ]] || return 0
  jq -r 'to_entries[] | select(.value == "demo") | .key' "$file" 2>/dev/null | head -n1
}

cmd_smoke() {
  need_kubectl
  local env="${1:-}"; need_env "$env"
  [[ -n "$INGRESS_PORT" ]] || die "No host port mapped to container port 80 in $CLUSTER_CONFIG"
  local host; host="$(host_for "$env")"
  [[ -n "$host" ]] || die "Could not read ingress.host from $CHART_DIR/values-$env.yaml"
  local base="http://localhost:${INGRESS_PORT}"

  # Phase 12: once gateway.enabled, every request below actually goes Traefik -> ai-gateway ->
  # ai-service (templates/ingress.yaml), not Traefik -> ai-service directly as before. The
  # /healthz and /readyz checks need no code change (same response shape either way -- see
  # gateway/main.py's own healthz/readyz), but POST /v1/chat now needs an API key, or the
  # gateway correctly rejects it with 401 before ai-service ever sees the request.
  local gateway_on
  gateway_on="$(gateway_enabled_for "$env")"
  local auth_header=()
  if [[ "$gateway_on" == "true" ]]; then
    local api_key; api_key="$(gateway_demo_api_key_for "$env")"
    [[ -n "$api_key" ]] || die "gateway.enabled is true for $env but no 'demo' tenant key was found in $GATEWAY_KEYS_DIR/api-keys.$env.local.json. See $GATEWAY_KEYS_DIR/api-keys.$env.example.json."
    auth_header=(-H "x-api-key: $api_key")
  fi

  log_info "1/4 GET /healthz through Traefik ($env, Host: $host)"
  local healthz
  healthz="$(curl -fsS --max-time 5 -H "Host: $host" "$base/healthz")" \
    || die "No response from $base/healthz. Is 'make helm-apply-$env' rolled out?"
  jq -e '.status == "ok"' <<<"$healthz" >/dev/null || die "/healthz did not answer ok: $healthz"
  log_ok "healthz: $healthz"

  log_info "2/4 GET /readyz through Traefik"
  local readyz
  readyz="$(curl -fsS --max-time 5 -H "Host: $host" "$base/readyz")" \
    || die "No response from $base/readyz."
  jq -e '.status == "ready"' <<<"$readyz" >/dev/null || die "/readyz was not ready: $readyz"
  log_ok "readyz: $readyz"

  if [[ "$gateway_on" == "true" ]]; then
    log_info "3/4 POST /v1/chat through Traefik with NO API key is correctly rejected"
    local unauth_status
    unauth_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $host" -H 'content-type: application/json' \
      -d '{"tenant_id":"demo","prompt":"should be rejected"}' "$base/v1/chat")"
    [[ "$unauth_status" == "401" ]] || die "POST /v1/chat with no API key returned $unauth_status through the real gateway, expected 401."
    log_ok "no API key -> 401, as expected"
  else
    log_info "3/4 (skipped: gateway.enabled is false for $env — ai-service has no auth of its own, by design)"
  fi

  log_info "4/4 POST /v1/chat through Traefik and check the contract"
  local chat
  chat="$(curl -fsS --max-time 10 -H "Host: $host" -H 'content-type: application/json' "${auth_header[@]}" \
    -d '{"tenant_id":"demo","prompt":"hello from helm-smoke ('"$env"')"}' "$base/v1/chat")" \
    || die "POST /v1/chat failed."
  jq -e 'has("response") and has("model") and has("request_id") and has("latency_ms")' <<<"$chat" >/dev/null \
    || die "Response is missing a required field: $chat"
  log_ok "chat: $chat"

  log_ok "HELM SMOKE TEST PASSED ($env)"
}

cmd_uninstall() {
  need_helm
  need_kubectl
  local env="${1:-}"; need_env "$env"
  local ns; ns="$(namespace_for "$env")"
  log_info "uninstalling $(release_for "$env") from $ns (the namespace is kept: helm.sh/resource-policy)"
  hctl uninstall "$(release_for "$env")" -n "$ns" --ignore-not-found
  log_ok "release removed. Namespace $ns is untouched."
}

# ---- dispatch ------------------------------------------------------------------------------

CMD="${1:-}"
case "$CMD" in
  lint)      cmd_lint ;;
  template)  cmd_template "${2:-}" ;;
  apply)     cmd_apply "${2:-}" ;;
  status)    cmd_status "${2:-}" ;;
  logs)      cmd_logs "${@:2}" ;;
  smoke)     cmd_smoke "${2:-}" ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  *)
    echo "Usage: $0 <lint|template|apply|status|logs|smoke|uninstall> [dev|staging|prod] [--follow]" >&2
    exit 1
    ;;
esac
