SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP_DIR := app/ai_service
VENV    := $(APP_DIR)/.venv
PY      := $(VENV)/bin/python

# Phase 8: polaris-gitops is a separate repository (ADR-08); default to a sibling checkout next
# to this one (~/polaris/polaris-gitops next to ~/polaris/polaris-ai-platform).
GITOPS_DIR ?= $(CURDIR)/../polaris-gitops

.PHONY: help tools-install doctor lint test cluster-up cluster-down cluster-reset cluster-status smoke versions \
	app-install app-lint app-test app-check app-run \
	image-info image-pin image-build image-run image-check image-push image-scan image-sbom image-publish \
	deploy-info deploy-apply deploy-status deploy-logs deploy-smoke deploy-delete \
	helm-lint helm-template-dev helm-template-staging helm-template-prod \
	helm-apply-dev helm-apply-staging helm-apply-prod \
	helm-status-dev helm-status-staging helm-status-prod \
	helm-logs-dev helm-logs-staging helm-logs-prod \
	helm-smoke-dev helm-smoke-staging helm-smoke-prod \
	helm-uninstall-dev helm-uninstall-staging helm-uninstall-prod \
	ci-secrets-scan ci-deps-audit ci-workflow-lint ci-verify \
	verify-dev verify-staging verify-prod \
	argocd-install argocd-status argocd-password argocd-uninstall gitops-bootstrap \
	gitops-bump-dev gitops-bump-staging gitops-bump-prod

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

tools-install: ## Install pinned k3d, kubectl, helm, gitleaks and actionlint into ~/.local/bin (no sudo). Add ARGS="--only gitleaks" etc. to install just one
	./scripts/bootstrap/install-tools.sh $(ARGS)

doctor: ## Check that this machine can run the platform
	./scripts/bootstrap/doctor.sh

lint: ## Lint all shell scripts with shellcheck
	shellcheck -x -P SCRIPTDIR scripts/lib/*.sh scripts/bootstrap/*.sh scripts/build/*.sh scripts/deploy/*.sh scripts/ci/*.sh scripts/verify/*.sh scripts/gitops/*.sh tests/bootstrap/*.sh

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

image-publish: ## Retag the already-built image and push it to GHCR (needs: docker login ghcr.io first)
	./scripts/build/image.sh publish

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

# --- Phase 5: Helm (helm/ai-platform), replaces deploy-* above one environment at a time -------
# deploy/k8s/ai-service/ (Phase 4) is kept as a raw-manifest reference; it is not applied by these.

helm-lint: ## helm lint the chart against all three values files (uses a placeholder image tag)
	./scripts/deploy/helm.sh lint

helm-template-dev: ## Render the chart for polaris-dev with the real computed image tag (no cluster needed)
	./scripts/deploy/helm.sh template dev

helm-template-staging: ## Render the chart for polaris-staging with the real computed image tag
	./scripts/deploy/helm.sh template staging

helm-template-prod: ## Render the chart for polaris-prod with the real computed image tag
	./scripts/deploy/helm.sh template prod

helm-apply-dev: ## helm upgrade --install the dev release (needs: cluster-up, image-build, image-push)
	./scripts/deploy/helm.sh apply dev

helm-apply-staging: ## helm upgrade --install the staging release
	./scripts/deploy/helm.sh apply staging

helm-apply-prod: ## helm upgrade --install the prod release
	./scripts/deploy/helm.sh apply prod

helm-status-dev: ## Show the dev release's status and resources
	./scripts/deploy/helm.sh status dev

helm-status-staging: ## Show the staging release's status and resources
	./scripts/deploy/helm.sh status staging

helm-status-prod: ## Show the prod release's status and resources
	./scripts/deploy/helm.sh status prod

helm-logs-dev: ## Tail the dev release's pods' JSON logs (add ARGS=--follow to keep streaming)
	./scripts/deploy/helm.sh logs dev $(ARGS)

helm-logs-staging: ## Tail the staging release's pods' JSON logs (add ARGS=--follow)
	./scripts/deploy/helm.sh logs staging $(ARGS)

helm-logs-prod: ## Tail the prod release's pods' JSON logs (add ARGS=--follow)
	./scripts/deploy/helm.sh logs prod $(ARGS)

helm-smoke-dev: ## Call the dev release through Traefik and check the /v1/chat contract
	./scripts/deploy/helm.sh smoke dev

helm-smoke-staging: ## Call the staging release through Traefik and check the /v1/chat contract
	./scripts/deploy/helm.sh smoke staging

helm-smoke-prod: ## Call the prod release through Traefik and check the /v1/chat contract
	./scripts/deploy/helm.sh smoke prod

helm-uninstall-dev: ## Remove the dev release (keeps the polaris-dev namespace)
	./scripts/deploy/helm.sh uninstall dev

helm-uninstall-staging: ## Remove the staging release (keeps the polaris-staging namespace)
	./scripts/deploy/helm.sh uninstall staging

helm-uninstall-prod: ## Remove the prod release (keeps the polaris-prod namespace)
	./scripts/deploy/helm.sh uninstall prod

# --- Phase 6: CI pipeline (.github/workflows/ci.yml runs these same targets) -------------------
# Deliberately just wrappers around scripts/ci/*.sh, so "what CI runs" and "what you can run
# locally before pushing" are the same command, not two things that can drift apart.

ci-secrets-scan: ## Scan the repository for committed secrets with gitleaks (needs: make tools-install)
	./scripts/ci/secrets-scan.sh

ci-deps-audit: ## Audit app/ai_service's pinned runtime dependencies with pip-audit
	./scripts/ci/deps-audit.sh

ci-workflow-lint: ## Lint .github/workflows/*.yml with yamllint and actionlint (needs: make tools-install)
	./scripts/ci/workflow-lint.sh

ci-verify: lint test ci-secrets-scan ci-deps-audit ci-workflow-lint ## Everything CI checks before it needs Docker or a cluster

# --- Phase 7: post-deploy verification (scripts/verify/post-deploy.sh), the local-cluster half --
# of ADR-12's two verification loops. Run after any helm-apply-<env>, not part of CI (loop 1
# already deploys+smokes its own ephemeral cluster inside build-scan-deploy — see ADR-24).

verify-dev: ## Rollout, health, readyz, a real AI answer, logs and (advisory) metrics for the dev release
	./scripts/verify/post-deploy.sh dev

verify-staging: ## Same checks as verify-dev, for the staging release
	./scripts/verify/post-deploy.sh staging

verify-prod: ## Same checks as verify-dev, for the prod release
	./scripts/verify/post-deploy.sh prod

# --- Phase 8: GitOps with Argo CD (polaris-gitops is a separate repository, ADR-08/ADR-26) -----
# argocd-* manage the control plane itself (its own 'argocd' namespace); gitops-* talk to the
# separate polaris-gitops checkout that Argo CD is told to reconcile from.

argocd-install: ## Install the pinned Argo CD release into the argocd namespace (needs: make cluster-up)
	./scripts/bootstrap/argocd.sh install

argocd-status: ## Show every Argo CD Application's sync/health status and the control plane's pods
	./scripts/bootstrap/argocd.sh status

argocd-password: ## Print the initial Argo CD admin password (admin / <password>)
	./scripts/bootstrap/argocd.sh password

argocd-uninstall: ## Remove Argo CD (the workloads it deployed to polaris-dev/-staging/-prod are untouched)
	./scripts/bootstrap/argocd.sh uninstall

gitops-bootstrap: ## Apply polaris-gitops' app-of-apps root Application, once (needs: make argocd-install; GITOPS_DIR defaults to a sibling checkout)
	./scripts/gitops/bootstrap.sh $(GITOPS_DIR)

gitops-bump-dev: ## Write the currently built image tag into polaris-gitops' environments/dev/image.yaml (needs: make image-build image-push; add ARGS=--push to commit+push)
	./scripts/gitops/bump-image-tag.sh dev $(GITOPS_DIR) $(ARGS)

gitops-bump-staging: ## Same, for staging
	./scripts/gitops/bump-image-tag.sh staging $(GITOPS_DIR) $(ARGS)

gitops-bump-prod: ## Same, for prod
	./scripts/gitops/bump-image-tag.sh prod $(GITOPS_DIR) $(ARGS)
