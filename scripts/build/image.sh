#!/usr/bin/env bash
# scripts/build/image.sh — build, check, push, scan and describe the ai-service container image.
#
# Usage: scripts/build/image.sh <info|pin|build|run|check|push|scan|sbom|publish>
# Normally invoked through the make targets (make image-build, make image-check, ...).
#
# Status: written and shellchecked; first real run happens on the target machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ROOT="$(repo_root)"
cd "$ROOT"
load_versions

APP_DIR="app/ai_service"
IMAGE_REPO="polaris/ai-service"
# The local registry k3d created. From the host it is localhost:5000; inside the cluster the
# same registry is registry.localhost:5000 (see ADR-16 / troubleshooting for the naming).
REGISTRY_HOST="${POLARIS_REGISTRY:-localhost:5000}"
ARTIFACTS="artifacts"
CHECK_CONTAINER="polaris-ai-service-check"
RUN_CONTAINER="polaris-ai-service"

# ---- computed values -----------------------------------------------------------------------

app_version() { awk -F'"' '/^version = / {print $2; exit}' "$APP_DIR/pyproject.toml"; }

# Short git revision; "-dirty" when the working tree has uncommitted changes, so an image built
# from unsaved work can never be mistaken for the commit it claims to be.
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
# The immutable tag identifies exactly one build of one commit: deploy by this one.
# The version tag moves with every build of that version and is only a convenience.
# There is no "latest" tag, by design.
TAG_IMMUTABLE="$REGISTRY_HOST/$IMAGE_REPO:$VERSION-$REVISION"
TAG_VERSION="$REGISTRY_HOST/$IMAGE_REPO:$VERSION"

need_docker() {
  have docker || die "docker not found. Run 'make doctor'."
  docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Run 'make doctor'."
}

need_image() {
  docker image inspect "$TAG_IMMUTABLE" >/dev/null 2>&1 \
    || die "Image $TAG_IMMUTABLE not found. Run 'make image-build' first (from a clean git state, the tag changes with every commit)."
}

# ---- info / pin ----------------------------------------------------------------------------

cmd_info() {
  log_info "version:          $VERSION"
  log_info "revision:         $REVISION"
  log_info "immutable tag:    $TAG_IMMUTABLE"
  log_info "version tag:      $TAG_VERSION"
  log_info "base image:       $(base_image)"
  log_info "scanner image:    $(trivy_image)"
  [[ -n "${PYTHON_BASE_DIGEST:-}" ]] || log_warn "PYTHON_BASE_DIGEST is empty: the base image is a moving tag. Run 'make image-pin'."
  [[ "$REVISION" != *-dirty ]] || log_warn "working tree has uncommitted changes: the tag ends in -dirty."
}

# Resolve the current digests of the base image and the scanner and print them, ready to paste
# into versions.env. It changes nothing by itself: pinning is a reviewed commit.
cmd_pin() {
  need_docker
  local ref digest
  for ref in "python:$PYTHON_BASE_TAG" "$TRIVY_IMAGE:$TRIVY_VERSION"; do
    log_info "pulling $ref"
    docker pull --quiet "$ref" >/dev/null || die "Could not pull $ref (wrong tag, or no network to the registry)."
    digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" | head -n1)"
    digest="${digest#*@}"
    [[ "$digest" == sha256:* ]] || die "Could not read a digest for $ref"
    if [[ "$ref" == python:* ]]; then
      printf 'PYTHON_BASE_DIGEST=%s\n' "$digest"
    else
      printf 'TRIVY_IMAGE_DIGEST=%s\n' "$digest"
    fi
  done
  log_info "Copy the two lines above into versions.env, then: make test && git commit."
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

# Hardening applied when the image is run: read-only root filesystem, no Linux capabilities,
# no privilege escalation, small resource limits. These are the same restrictions the
# Kubernetes manifests apply in Phase 4.
HARDENING=(--read-only --tmpfs "/tmp:rw,noexec,nosuid,size=16m"
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 --memory 256m --cpus 1)

# Any POLARIS_* variable exported in the calling shell is passed through to the container.
polaris_env_args() {
  local name
  while IFS= read -r name; do
    printf '%s\n' "-e" "$name"
  done < <(compgen -e | grep '^POLARIS_' || true)
}

cmd_run() {
  need_docker
  need_image
  local port="${POLARIS_IMAGE_PORT:-8000}"
  local -a env_args=()
  mapfile -t env_args < <(polaris_env_args)
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

  local prompt='Explain Kubernetes pods' uid
  log_info "Checking $TAG_IMMUTABLE"

  # 1. Not running as root (checked on a throwaway container that only prints the user id).
  uid="$(docker run --rm --entrypoint id "$TAG_IMMUTABLE" -u 2>/dev/null || true)"
  if [[ "$uid" =~ ^[0-9]+$ && "$uid" -ne 0 ]]; then check_ok "runs as non-root (uid $uid)"; else check_bad "does not run as a non-root user (uid '$uid')"; fi

  # 2. Starts under the hardening flags. Random host port, so it cannot clash with make app-run.
  docker run --detach --name "$CHECK_CONTAINER" \
    --publish 127.0.0.1::8000 \
    --health-interval 2s --health-start-period 0s \
    "${HARDENING[@]}" "$TAG_IMMUTABLE" >/dev/null
  local hostport url
  hostport="$(docker port "$CHECK_CONTAINER" 8000/tcp | head -n1)"
  url="http://127.0.0.1:${hostport##*:}"

  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "$url/healthz" 2>/dev/null && break
    sleep 1
  done
  if curl -fsS "$url/healthz" 2>/dev/null | jq -e '.status == "ok"' >/dev/null; then
    check_ok "GET /healthz answers ok"
  else
    check_bad "GET /healthz did not answer ok (see: docker logs $CHECK_CONTAINER)"
    docker logs "$CHECK_CONTAINER" 2>&1 | tail -n 20 >&2 || true
  fi

  # 3. Readiness and the chat contract.
  if curl -fsS "$url/readyz" 2>/dev/null | jq -e '.status == "ready"' >/dev/null; then check_ok "GET /readyz answers ready"; else check_bad "GET /readyz is not ready"; fi

  local reply
  reply="$(curl -sS -X POST "$url/v1/chat" -H 'content-type: application/json' -H 'x-request-id: image-check-1' \
    -d "{\"tenant_id\":\"demo\",\"prompt\":\"$prompt\"}" 2>/dev/null || true)"
  if jq -e 'keys == ["latency_ms","model","request_id","response"] and .request_id == "image-check-1"' <<<"$reply" >/dev/null 2>&1; then
    check_ok "POST /v1/chat returns exactly response, model, request_id, latency_ms"
  else
    check_bad "POST /v1/chat returned an unexpected body: $reply"
  fi

  # 4. Logs: every line is JSON, the request id is in the access line, the prompt is nowhere.
  local logs
  logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
  if [[ -n "$logs" ]] && ! grep -v '^{' <<<"$logs" | grep -q .; then check_ok "every log line is a JSON object"; else check_bad "some log lines are not JSON (docker logs $CHECK_CONTAINER)"; fi
  if jq -e 'select(.logger == "ai_service.access" and .request_id == "image-check-1" and .status == 200)' <<<"$logs" >/dev/null 2>&1; then check_ok "the access log line carries the request id"; else check_bad "no access log line with the request id"; fi
  if grep -qF "$prompt" <<<"$logs"; then check_bad "the prompt text appears in the logs"; else check_ok "the prompt text does not appear in the logs"; fi

  # 5. Docker's own HEALTHCHECK (the command in the Dockerfile) turns healthy.
  local health="starting"
  for _ in $(seq 1 30); do
    health="$(docker inspect --format '{{.State.Health.Status}}' "$CHECK_CONTAINER" 2>/dev/null || echo unknown)"
    [[ "$health" == "healthy" ]] && break
    sleep 1
  done
  if [[ "$health" == "healthy" ]]; then check_ok "Docker HEALTHCHECK reports healthy"; else check_bad "Docker HEALTHCHECK status is '$health'"; fi

  # 6. SIGTERM ends the service gracefully: uvicorn runs the application shutdown and the
  # process ends. The exit code is 0 or 143 (128 + SIGTERM: uvicorn re-raises the signal after
  # a graceful shutdown); 137 would mean it ignored SIGTERM and was killed after the timeout.
  docker stop --time 10 "$CHECK_CONTAINER" >/dev/null
  local exit_code
  exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$CHECK_CONTAINER" 2>/dev/null || echo '?')"
  logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
  if [[ "$exit_code" == "0" || "$exit_code" == "143" ]] && grep -q 'Application shutdown complete' <<<"$logs"; then
    check_ok "shuts down gracefully on SIGTERM (exit code $exit_code, application shutdown ran)"
  else
    check_bad "SIGTERM handling: exit code '$exit_code' (0 or 143 expected; 137 means it was killed) or no 'Application shutdown complete' in the logs"
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
# The scanner runs as a container and reads the image from a tar file (docker save). It is not
# given the Docker socket, which would be root-equivalent access to this machine.

# TRIVY_* variables exported in the calling shell (for example TRIVY_DB_REPOSITORY, to use a
# different vulnerability database mirror) are passed on. Not TRIVY_IMAGE, TRIVY_VERSION and
# TRIVY_IMAGE_DIGEST: those are this repository's own settings from versions.env, and Trivy
# would read TRIVY_VERSION as its own --version flag.
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
  docker save --output "$ARTIFACTS/ai-service.tar" "$TAG_IMMUTABLE"
}

cmd_scan() {
  need_docker
  need_image
  have jq || die "jq not found."
  local report="$ARTIFACTS/trivy-$VERSION-$REVISION.json"
  save_image
  log_info "scanning with $(trivy_image) (the first run downloads the vulnerability database)"
  trivy_run image --no-progress --input /work/ai-service.tar --format json --output "/work/$(basename "$report")"
  rm -f "$ARTIFACTS/ai-service.tar"

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
  local sbom="$ARTIFACTS/sbom-$VERSION-$REVISION.cdx.json"
  save_image
  trivy_run image --no-progress --input /work/ai-service.tar --format cyclonedx --output "/work/$(basename "$sbom")"
  rm -f "$ARTIFACTS/ai-service.tar"
  log_ok "SBOM (CycloneDX $(jq -r '.specVersion' "$sbom")): $(jq '.components | length' "$sbom") components -> $sbom"
}

# ---- publish (Phase 6: GHCR) -----------------------------------------------------------------
# Retags the image cmd_build already produced and pushes it to GHCR — it never rebuilds, so what
# gets published is byte-for-byte what cmd_check and cmd_scan already examined. This is
# deliberately separate from cmd_push: cmd_push talks to the local, unauthenticated k3d registry
# (localhost:5000) used by deploy-apply/helm-apply-*; GHCR needs HTTPS and a prior `docker login
# ghcr.io`, which this script does not do itself (in CI: docker/login-action with GITHUB_TOKEN;
# locally: `echo $CR_PAT | docker login ghcr.io -u <user> --password-stdin`, a personal access
# token with write:packages).

# "owner/repo" from $GITHUB_REPOSITORY (set automatically inside GitHub Actions), or parsed from
# the git 'origin' remote when run outside Actions (e.g. a manual publish from a developer machine).
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
  image="ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"$owner_repo")/ai-service"
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
