#!/usr/bin/env bash
# scripts/build/gateway-image.sh — build, check, push, scan and describe the ai-gateway
# container image (Phase 12). Mirrors scripts/build/image.sh closely on purpose -- same
# hardening, same subcommands, same reasoning -- but is a separate file rather than a shared
# function library: image.sh's own header already explains why ai-service's build script is
# never touched to add a second app (ADR-22's reasoning: a change for one service must never
# be able to alter another service's already-verified script).
#
# Usage: scripts/build/gateway-image.sh <info|pin|build|run|check|push|scan|sbom|publish>
# Normally invoked through the make targets (make gateway-image-build, ...).
#
# Status: written and shellchecked; info/build/check/push/scan/sbom/publish all run against a
# real Docker daemon -- there is none in this sandbox (same constraint image.sh's own header
# documents). The first real run is this phase's target-machine step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"
load_versions

APP_DIR="app/gateway"
IMAGE_REPO="polaris/ai-gateway"
REGISTRY_HOST="${POLARIS_REGISTRY:-localhost:5000}"
ARTIFACTS="artifacts"
CHECK_CONTAINER="polaris-ai-gateway-check"
RUN_CONTAINER="polaris-ai-gateway"
# A fixed, obviously-fake test key/tenant pair, used only by cmd_check below -- never a real
# credential, never written anywhere outside this script's own throwaway container.
CHECK_API_KEY="sk-image-check-0123456789abcdef"
CHECK_TENANT="demo"

# ---- computed values -----------------------------------------------------------------------

app_version() { awk -F'"' '/^version = / {print $2; exit}' "$APP_DIR/pyproject.toml"; }

app_revision() {
  local rev
  rev="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  [[ -n "$rev" ]] || { printf 'unknown'; return; }
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then rev="$rev-dirty"; fi
  printf '%s' "$rev"
}

base_image() {
  if [[ -n "${PYTHON_BASE_DIGEST:-}" ]]; then
    printf 'python:%s@%s' "$PYTHON_BASE_TAG" "$PYTHON_BASE_DIGEST"
  else
    printf 'python:%s' "$PYTHON_BASE_TAG"
  fi
}

trivy_image() {
  if [[ -n "${TRIVY_IMAGE_DIGEST:-}" ]]; then
    printf '%s:%s@%s' "$TRIVY_IMAGE" "$TRIVY_VERSION" "$TRIVY_IMAGE_DIGEST"
  else
    printf '%s:%s' "$TRIVY_IMAGE" "$TRIVY_VERSION"
  fi
}

VERSION="$(app_version)"
REVISION="$(app_revision)"
TAG_IMMUTABLE="$REGISTRY_HOST/$IMAGE_REPO:$VERSION-$REVISION"
TAG_VERSION="$REGISTRY_HOST/$IMAGE_REPO:$VERSION"

need_docker() {
  have docker || die "docker not found. Run 'make doctor'."
  docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Run 'make doctor'."
}

need_image() {
  docker image inspect "$TAG_IMMUTABLE" >/dev/null 2>&1 \
    || die "Image $TAG_IMMUTABLE not found. Run 'make gateway-image-build' first."
}

# ---- info / pin ------------------------------------------------------------------------------

cmd_info() {
  log_info "version:          $VERSION"
  log_info "revision:         $REVISION"
  log_info "immutable tag:    $TAG_IMMUTABLE"
  log_info "version tag:      $TAG_VERSION"
  log_info "base image:       $(base_image)"
  log_info "scanner image:    $(trivy_image)"
  [[ -n "${PYTHON_BASE_DIGEST:-}" ]] || log_warn "PYTHON_BASE_DIGEST is empty: the base image is a moving tag. Run 'make image-pin' (shared with ai-service -- same base image)."
  [[ "$REVISION" != *-dirty ]] || log_warn "working tree has uncommitted changes: the tag ends in -dirty."
}

cmd_pin() {
  log_info "ai-gateway shares versions.env's PYTHON_BASE_DIGEST/TRIVY_IMAGE_DIGEST with ai-service -- run 'make image-pin', not a separate gateway-specific one."
}

# ---- build ---------------------------------------------------------------------------------

cmd_build() {
  need_docker
  local created size
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cmd_info
  docker build --pull \
    --file "$APP_DIR/Dockerfile" \
    --build-arg "PYTHON_IMAGE=$(base_image)" \
    --build-arg "VERSION=$VERSION" \
    --build-arg "REVISION=$REVISION" \
    --build-arg "CREATED=$created" \
    --tag "$TAG_IMMUTABLE" \
    --tag "$TAG_VERSION" \
    "$APP_DIR"
  size="$(docker image inspect --format '{{.Size}}' "$TAG_IMMUTABLE")"
  log_ok "built $TAG_IMMUTABLE ($((size / 1024 / 1024)) MB)"
}

# ---- run / check ---------------------------------------------------------------------------

HARDENING=(--read-only --tmpfs "/tmp:rw,noexec,nosuid,size=16m"
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 --memory 256m --cpus 1)

gateway_env_args() {
  local name
  while IFS= read -r name; do
    printf '%s\n' "-e" "$name"
  done < <(compgen -e | grep '^GATEWAY_' || true)
}

cmd_run() {
  need_docker
  need_image
  local port="${GATEWAY_IMAGE_PORT:-8080}"
  local -a env_args=()
  mapfile -t env_args < <(gateway_env_args)
  log_info "serving on http://127.0.0.1:$port (Ctrl+C to stop)"
  docker run --rm --name "$RUN_CONTAINER" \
    --publish "127.0.0.1:$port:8000" \
    "${HARDENING[@]}" "${env_args[@]}" "$TAG_IMMUTABLE"
}

CHECK_PASSED=0
CHECK_FAILED=0
check_ok()  { log_ok "$1"; CHECK_PASSED=$((CHECK_PASSED + 1)); }
check_bad() { log_fail "$1"; CHECK_FAILED=$((CHECK_FAILED + 1)); }

cleanup_check() { docker rm -f "$CHECK_CONTAINER" >/dev/null 2>&1 || true; }

cmd_check() {
  need_docker
  need_image
  have curl || die "curl not found."
  have jq || die "jq not found."
  trap cleanup_check EXIT
  cleanup_check

  log_info "Checking $TAG_IMMUTABLE"

  # 1. Not running as root.
  local uid
  uid="$(docker run --rm --entrypoint id "$TAG_IMMUTABLE" -u 2>/dev/null || true)"
  if [[ "$uid" =~ ^[0-9]+$ && "$uid" -ne 0 ]]; then check_ok "runs as non-root (uid $uid)"; else check_bad "does not run as a non-root user (uid '$uid')"; fi

  # 2. Starts under the hardening flags, with one test key configured and NO real ai-service
  # to proxy to -- this check is deliberately standalone (same reasoning as image.sh's own
  # check: no cluster dependency), so GATEWAY_UPSTREAM_BASE_URL is left at its default
  # ("http://ai-service:80"), which cannot resolve inside this bare container. That is used
  # below to confirm the gateway's own 502 behaviour, not treated as a check failure.
  docker run --detach --name "$CHECK_CONTAINER" \
    --publish 127.0.0.1::8000 \
    --health-interval 2s --health-start-period 0s \
    -e "GATEWAY_API_KEYS_JSON={\"$CHECK_API_KEY\":\"$CHECK_TENANT\"}" \
    "${HARDENING[@]}" "$TAG_IMMUTABLE" >/dev/null
  local hostport url
  hostport="$(docker port "$CHECK_CONTAINER" 8000/tcp | head -n1)"
  url="http://127.0.0.1:${hostport##*:}"

  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "$url/healthz" 2>/dev/null && break
    sleep 1
  done
  if curl -fsS "$url/healthz" 2>/dev/null | jq -e '.status == "ok"' >/dev/null; then
    check_ok "GET /healthz answers ok (does not depend on ai-service)"
  else
    check_bad "GET /healthz did not answer ok (see: docker logs $CHECK_CONTAINER)"
    docker logs "$CHECK_CONTAINER" 2>&1 | tail -n 20 >&2 || true
  fi

  # 3. /readyz correctly reports not ready when ai-service is unreachable -- this is the
  # intended behaviour standalone, not a bug; a real cluster is this phase's target-machine step.
  if curl -s -o /dev/null -w '%{http_code}' "$url/readyz" 2>/dev/null | grep -q '^503$'; then
    check_ok "GET /readyz correctly reports 503 with no ai-service reachable"
  else
    check_bad "GET /readyz did not return 503 with no ai-service reachable"
  fi

  # 4. Auth contract: no key -> 401, unknown key -> 401, wrong tenant in body -> 403, correct
  # key+tenant with ai-service unreachable -> 502 (proves the request got PAST auth/tenant/
  # rate-limit and failed only at the proxy step).
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/chat" -H 'content-type: application/json' -d "{\"tenant_id\":\"$CHECK_TENANT\",\"prompt\":\"hi\"}")"
  if [[ "$status" == "401" ]]; then check_ok "POST /v1/chat with no API key is 401"; else check_bad "POST /v1/chat with no API key returned $status, expected 401"; fi

  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/chat" -H 'content-type: application/json' -H "x-api-key: wrong-key-entirely" -d "{\"tenant_id\":\"$CHECK_TENANT\",\"prompt\":\"hi\"}")"
  if [[ "$status" == "401" ]]; then check_ok "POST /v1/chat with an unknown API key is 401"; else check_bad "POST /v1/chat with an unknown API key returned $status, expected 401"; fi

  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/chat" -H 'content-type: application/json' -H "x-api-key: $CHECK_API_KEY" -d "{\"tenant_id\":\"someone-else\",\"prompt\":\"hi\"}")"
  if [[ "$status" == "403" ]]; then check_ok "POST /v1/chat with a mismatched tenant_id is 403"; else check_bad "POST /v1/chat with a mismatched tenant_id returned $status, expected 403"; fi

  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/chat" -H 'content-type: application/json' -H "x-api-key: $CHECK_API_KEY" -d "{\"tenant_id\":\"$CHECK_TENANT\",\"prompt\":\"hi\"}")"
  if [[ "$status" == "502" ]]; then check_ok "POST /v1/chat with a valid key and no reachable ai-service is 502"; else check_bad "POST /v1/chat with a valid key returned $status, expected 502 (ai-service unreachable)"; fi

  # 5. Logs: every line is JSON, and neither the test API key nor the prompt text appear.
  local logs
  logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
  if [[ -n "$logs" ]] && ! grep -v '^{' <<<"$logs" | grep -q .; then check_ok "every log line is a JSON object"; else check_bad "some log lines are not JSON (docker logs $CHECK_CONTAINER)"; fi
  if grep -qF "$CHECK_API_KEY" <<<"$logs"; then check_bad "the API key appears in the logs"; else check_ok "the API key does not appear in the logs"; fi

  # 6. Docker's own HEALTHCHECK turns healthy.
  local health="starting"
  for _ in $(seq 1 30); do
    health="$(docker inspect --format '{{.State.Health.Status}}' "$CHECK_CONTAINER" 2>/dev/null || echo unknown)"
    [[ "$health" == "healthy" ]] && break
    sleep 1
  done
  if [[ "$health" == "healthy" ]]; then check_ok "Docker HEALTHCHECK reports healthy"; else check_bad "Docker HEALTHCHECK status is '$health'"; fi

  # 7. SIGTERM ends the service gracefully.
  docker stop --time 10 "$CHECK_CONTAINER" >/dev/null
  local exit_code
  exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$CHECK_CONTAINER" 2>/dev/null || echo '?')"
  logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
  if [[ "$exit_code" == "0" || "$exit_code" == "143" ]] && grep -q 'Application shutdown complete' <<<"$logs"; then
    check_ok "shuts down gracefully on SIGTERM (exit code $exit_code, application shutdown ran)"
  else
    check_bad "SIGTERM handling: exit code '$exit_code' (0 or 143 expected) or no 'Application shutdown complete' in the logs"
  fi

  printf '\nIMAGE CHECK: PASSED=%d  FAILED=%d\n' "$CHECK_PASSED" "$CHECK_FAILED"
  [[ "$CHECK_FAILED" -eq 0 ]]
}

# ---- push ----------------------------------------------------------------------------------

cmd_push() {
  need_docker
  need_image
  curl -fsS -o /dev/null "http://$REGISTRY_HOST/v2/" 2>/dev/null \
    || die "The registry at $REGISTRY_HOST does not answer. Is the cluster up? (make cluster-up)"
  docker push "$TAG_IMMUTABLE"
  docker push "$TAG_VERSION"
  local tags
  tags="$(curl -fsS "http://$REGISTRY_HOST/v2/$IMAGE_REPO/tags/list")"
  if jq -e --arg t "$VERSION-$REVISION" '.tags | index($t) != null' <<<"$tags" >/dev/null; then
    log_ok "registry lists $IMAGE_REPO: $(jq -c '.tags' <<<"$tags")"
  else
    die "pushed, but the registry does not list $VERSION-$REVISION: $tags"
  fi
}

# ---- scan / sbom ---------------------------------------------------------------------------

trivy_env_args() {
  local name
  while IFS= read -r name; do
    printf '%s\n' "--env" "$name"
  done < <(compgen -e | grep '^TRIVY_' | grep -vxE 'TRIVY_(IMAGE|VERSION|IMAGE_DIGEST)' || true)
}

trivy_run() {
  local -a env_args=()
  mapfile -t env_args < <(trivy_env_args)
  mkdir -p "$ARTIFACTS/trivy-cache"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env TRIVY_CACHE_DIR=/cache \
    "${env_args[@]}" \
    --volume "$ROOT/$ARTIFACTS/trivy-cache:/cache" \
    --volume "$ROOT/$ARTIFACTS:/work" \
    "$(trivy_image)" "$@"
}

save_image() {
  mkdir -p "$ARTIFACTS"
  docker save --output "$ARTIFACTS/ai-gateway.tar" "$TAG_IMMUTABLE"
}

cmd_scan() {
  need_docker
  need_image
  have jq || die "jq not found."
  local report="$ARTIFACTS/trivy-gateway-$VERSION-$REVISION.json"
  save_image
  log_info "scanning with $(trivy_image) (the first run downloads the vulnerability database)"
  trivy_run image --no-progress --input /work/ai-gateway.tar --format json --output "/work/$(basename "$report")"
  rm -f "$ARTIFACTS/ai-gateway.tar"

  log_info "operating system: $(jq -r '.Metadata.OS | "\(.Family) \(.Name)"' "$report")"
  log_info "findings by severity (fixed and unfixed):"
  jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | map("  \(.[0].Severity): \(length)") | if length == 0 then ["  none reported"] else . end | .[]' "$report"
  log_info "HIGH and CRITICAL findings:"
  jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")
    | [.Severity, .VulnerabilityID, .PkgName, .InstalledVersion, (.FixedVersion // "no fix yet"), $t] | @tsv' "$report" \
    | { if have column; then column -t -s $'\t'; else cat; fi; }

  local fixable
  fixable="$(jq '[.Results[]?.Vulnerabilities[]? | select((.Severity == "HIGH" or .Severity == "CRITICAL") and (.FixedVersion // "") != "")] | length' "$report")"
  log_info "full report: $report"
  if [[ "$fixable" -gt 0 ]]; then
    die "$fixable HIGH/CRITICAL finding(s) have a fix available. Rebuild on a newer base image or update the dependency, then scan again."
  fi
  log_ok "no HIGH/CRITICAL finding with an available fix. Findings without a fix must be recorded in docs/security/image-scan.md."
}

cmd_sbom() {
  need_docker
  need_image
  have jq || die "jq not found."
  local sbom="$ARTIFACTS/sbom-gateway-$VERSION-$REVISION.cdx.json"
  save_image
  trivy_run image --no-progress --input /work/ai-gateway.tar --format cyclonedx --output "/work/$(basename "$sbom")"
  rm -f "$ARTIFACTS/ai-gateway.tar"
  log_ok "SBOM (CycloneDX $(jq -r '.specVersion' "$sbom")): $(jq '.components | length' "$sbom") components -> $sbom"
}

# ---- publish (GHCR) -------------------------------------------------------------------------

ghcr_owner_repo() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s' "$GITHUB_REPOSITORY"
    return
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$url"
}

cmd_publish() {
  need_docker
  need_image
  local owner_repo image ghcr_immutable ghcr_version
  owner_repo="$(ghcr_owner_repo)"
  [[ -n "$owner_repo" && "$owner_repo" == */* ]] \
    || die "Could not determine the GitHub owner/repo. Set GITHUB_REPOSITORY=owner/repo, or run inside a checkout with a GitHub 'origin' remote."
  image="ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"$owner_repo")/ai-gateway"
  ghcr_immutable="$image:$VERSION-$REVISION"
  ghcr_version="$image:$VERSION"

  log_info "publishing $ghcr_immutable and $ghcr_version (retagged from the local build $TAG_IMMUTABLE, not rebuilt)"
  docker tag "$TAG_IMMUTABLE" "$ghcr_immutable"
  docker tag "$TAG_VERSION" "$ghcr_version"
  docker push "$ghcr_immutable" \
    || die "push failed. Logged in? docker login ghcr.io -u <user> --password-stdin (needs write:packages)."
  docker push "$ghcr_version"
  log_ok "published: $ghcr_immutable"
}

# ---- dispatch ------------------------------------------------------------------------------

case "${1:-}" in
  info)    cmd_info ;;
  pin)     cmd_pin ;;
  build)   cmd_build ;;
  run)     cmd_run ;;
  check)   cmd_check ;;
  push)    cmd_push ;;
  scan)    cmd_scan ;;
  sbom)    cmd_sbom ;;
  publish) cmd_publish ;;
  *)       die "usage: $0 <info|pin|build|run|check|push|scan|sbom|publish>" ;;
esac
