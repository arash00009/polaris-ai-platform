# Polaris AI service: container image (Phase 3).
#
# Build it with `make image-build` (scripts/build/image.sh), not by hand: the script passes the
# base image pinned in versions.env, the version, the git revision and the build time.
# Build context is this directory (app/ai_service).
#
# Status: written and reviewed, but built for the first time on the target machine. Nothing in
# here has been built in the environment where it was written (no access to Docker Hub there).

# The base image is a build argument so the build script can pin it by digest. The default must
# equal PYTHON_BASE_TAG in versions.env (`make test` checks that). No "latest", ever: the Debian
# release is named on purpose, so moving to another release is a visible, reviewed change.
ARG PYTHON_IMAGE=python:3.12-slim-trixie


# ---- Stage 1: builder ------------------------------------------------------------------
# Installs the dependencies into a virtual environment. Nothing from this stage ends up in
# the final image except that directory, so pip, build caches and build isolation stay behind.
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build

# Dependencies first: this layer is rebuilt only when requirements.txt changes, not on every
# code change. Every line in requirements.txt is pinned with ==, and --only-binary=:all: means
# pip refuses to compile anything from source (a compiler is not in this image).
COPY requirements.txt ./
RUN pip install --only-binary=:all: -r requirements.txt

# The service itself, installed as a normal (non-editable) package. --no-deps: the exact
# dependency set already came from requirements.txt. The last step removes pip from the
# virtual environment, so the runtime image carries no package installer.
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-deps . \
 && pip uninstall -y pip


# ---- Stage 2: runtime ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

# Build metadata, passed in by scripts/build/image.sh (see the OCI image annotations spec).
ARG PYTHON_IMAGE
ARG VERSION=0.0.0
ARG REVISION=unknown
ARG CREATED=unknown

# A dedicated, unprivileged user with a fixed numeric id. Kubernetes can only verify
# "runAsNonRoot" for a numeric id (Phase 4). Also remove pip from the base image: nothing at
# runtime installs packages, and a scanner (Phase 3, Trivy) reports fewer irrelevant findings.
RUN /usr/local/bin/python -m pip uninstall -y pip \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

# POLARIS_LOG_FORMAT=json: one JSON object per line on stdout, which is what a container
# runtime and a log pipeline expect. All other POLARIS_* settings come from the environment
# at run time (docker run -e, Kubernetes ConfigMap and Secret), never from the image.
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    POLARIS_LOG_FORMAT=json

WORKDIR /app
USER 10001:10001
EXPOSE 8000

# Docker-only health check (Kubernetes ignores it and uses its own probes, Phase 4). It uses
# the Python that is already in the image, so no curl is needed. /healthz is liveness: it
# does not depend on the model backend.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

# 0.0.0.0 is correct inside a container (the container's own network namespace); the host
# decides what to publish. --no-access-log: the service writes its own access line, which
# carries the request id. --no-server-header: do not advertise the server software.
CMD ["uvicorn", "ai_service.main:create_app", "--factory", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--no-access-log", "--no-server-header"]

LABEL org.opencontainers.image.title="polaris-ai-service" \
      org.opencontainers.image.description="Polaris AI service: a FastAPI chat API in front of a swappable model backend" \
      org.opencontainers.image.source="https://github.com/arash00009/polaris-ai-platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="${PYTHON_IMAGE}"
