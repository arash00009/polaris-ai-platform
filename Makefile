SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help tools-install doctor lint test cluster-up cluster-down cluster-reset cluster-status smoke versions

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

tools-install: ## Install pinned k3d, kubectl and helm into ~/.local/bin (no sudo)
	./scripts/bootstrap/install-tools.sh

doctor: ## Check that this machine can run the platform
	./scripts/bootstrap/doctor.sh

lint: ## Lint all shell scripts with shellcheck
	shellcheck -x -P SCRIPTDIR scripts/lib/*.sh scripts/bootstrap/*.sh tests/bootstrap/*.sh

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
