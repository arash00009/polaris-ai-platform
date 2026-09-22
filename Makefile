SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP_DIR := app/ai_service
VENV    := $(APP_DIR)/.venv
PY      := $(VENV)/bin/python

.PHONY: help tools-install doctor lint test cluster-up cluster-down cluster-reset cluster-status smoke versions \
	app-install app-lint app-test app-check app-run \
	image-info image-pin image-build image-run image-check image-push image-scan image-sbom \
	deploy-info deploy-apply deploy-status deploy-logs deploy-smoke deploy-delete

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

tools-install: ## Install pinned k3d, kubectl and helm into ~/.local/bin (no sudo)
	./scripts/bootstrap/install-tools.sh

doctor: ## Check that this machine can run the platform
	./scripts/bootstrap/doctor.sh

lint: ## Lint all shell scripts with shellcheck
	shellcheck -x -P SCRIPTDIR scripts/lib/*.sh scripts/bootstrap/*.sh scripts/build/*.sh scripts/deploy/*.sh tests/bootstrap/*.sh

test: ## Run static tests (no Docker or cluster needed)
	./tests/bootstrap/test_static.sh

cluster-up: ## Create (or start) the local k3d cluster and wait until it is ready
	./scripts/bootstrap/cluster.sh up

cluster-down: ## Delete the local cluster and its registry
	./scripts/bootstrap/cluster.sh down

cluster-reset: ## Delete and recreate the cluster from scratch
	./scripts/bootstrap/cluster.sh reset

cluster-status: ## Show nodes, unhealthy pods and the local registry
	./scripts/bootstrap/cluster.sh status

smoke: ## End-to-end check: registry -> cluster -> ingress -> host
	./scripts/bootstrap/smoke-test.sh

versions: ## Print the pinned tool versions
	@grep -vE '^\s*(#|$$)' versions.env

$(PY):
	@echo "No Python virtualenv yet. Run: make app-install" >&2; exit 1

app-install: ## Create the AI service virtualenv and install the pinned dependencies
	python3 -m venv $(VENV)
	$(PY) -m pip install -r $(APP_DIR)/requirements-dev.txt
	$(PY) -m pip install --no-deps -e $(APP_DIR)

app-lint: $(PY) ## Lint and format-check the AI service (ruff)
	$(PY) -m ruff check $(APP_DIR)
	$(PY) -m ruff format --check $(APP_DIR)

app-test: $(PY) ## Run the AI service unit tests with coverage (fails below 95 %)
	cd $(APP_DIR) && .venv/bin/python -m pytest --cov --cov-fail-under=95

app-check: app-lint app-test ## Lint and test the AI service

app-run: $(PY) ## Run the AI service locally on http://127.0.0.1:8000
	cd $(APP_DIR) && .venv/bin/python -m uvicorn ai_service.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log

image-info: ## Show the image tags, base image and scanner that would be used
	./scripts/build/image.sh info

image-pin: ## Print the current digests of the base image and scanner for versions.env
	./scripts/build/image.sh pin

image-build: ## Build the AI service container image (tags: <version>-<git sha> and <version>)
	./scripts/build/image.sh build

image-run: ## Run the image locally, hardened, on http://127.0.0.1:8000 (POLARIS_* variables pass through)
	./scripts/build/image.sh run

image-check: ## Start the image and verify user, probes, contract, JSON logs and clean shutdown
	./scripts/build/image.sh check

image-push: ## Push the image to the local registry (localhost:5000)
	./scripts/build/image.sh push

image-scan: ## Scan the image for vulnerabilities with Trivy (fails on fixable HIGH/CRITICAL)
	./scripts/build/image.sh scan

image-sbom: ## Write a CycloneDX software bill of materials for the image to artifacts/
	./scripts/build/image.sh sbom

deploy-info: ## Show the image tag, namespace and context 'make deploy-apply' would use
	./scripts/deploy/app.sh info

deploy-apply: ## Deploy ai-service to polaris-dev (needs: make cluster-up, make image-build, make image-push)
	./scripts/deploy/app.sh apply

deploy-status: ## Show ai-service pods, rollout status and related resources
	./scripts/deploy/app.sh status

deploy-logs: ## Tail the ai-service pods' JSON logs (add ARGS=--follow to keep streaming)
	./scripts/deploy/app.sh logs $(ARGS)

deploy-smoke: ## Call the deployed ai-service through Traefik and check the /v1/chat contract
	./scripts/deploy/app.sh smoke

deploy-delete: ## Remove the ai-service workload from the cluster (keeps the polaris-dev namespace)
	./scripts/deploy/app.sh delete
