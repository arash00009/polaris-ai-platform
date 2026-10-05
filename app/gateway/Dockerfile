# Polaris ai-gateway: container image (Phase 12).
#
# Build it with `make gateway-image-build` (scripts/build/gateway-image.sh), not by hand: the
# script passes the base image pinned in versions.env, the version, the git revision and the
# build time -- same reasoning as app/ai_service/Dockerfile, which this file mirrors closely on
# purpose (one reviewed security posture for every image in this repo, not two).
# Build context is this directory (app/gateway).
#
# Status: written and reviewed, but not built in the sandbox -- there is no Docker daemon here
# (the same constraint app/ai_service/Dockerfile's own header documents). `make gateway-image-*`
# against a real Docker daemon, and whether this image runs under the non-root securityContext
# in helm/ai-platform/templates/gateway-deployment.yaml, are this phase's target-machine step.

ARG PYTHON_IMAGE=python:3.12-slim-trixie


# ---- Stage 1: builder ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build

COPY requirements.txt ./
RUN pip install --only-binary=:all: -r requirements.txt

COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-deps . \
 && pip uninstall -y pip


# ---- Stage 2: runtime ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ARG PYTHON_IMAGE
ARG VERSION=0.0.0
ARG REVISION=unknown
ARG CREATED=unknown

RUN /usr/local/bin/python -m pip uninstall -y pip \
 && groupadd --system --gid 10002 app \
 && useradd --system --uid 10002 --gid 10002 --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

# GATEWAY_LOG_FORMAT=json: same reasoning as ai_service's image. Every other GATEWAY_* setting,
# including the GATEWAY_API_KEYS_JSON secret, comes from the environment at run time (a
# Kubernetes Secret, see helm/ai-platform/templates/gateway-secret.yaml), never from the image.
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    GATEWAY_LOG_FORMAT=json

WORKDIR /app
USER 10002:10002
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

CMD ["uvicorn", "gateway.main:create_app", "--factory", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--no-access-log", "--no-server-header"]

LABEL org.opencontainers.image.title="polaris-ai-gateway" \
      org.opencontainers.image.description="Polaris ai-gateway: auth, per-tenant rate limit/quota and routing in front of ai-service" \
      org.opencontainers.image.source="https://github.com/arash00009/polaris-ai-platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="${PYTHON_IMAGE}"
