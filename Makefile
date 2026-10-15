RELEASE ?= h2o-knowledge-mgmt
NAMESPACE ?=
HELM_ARGS ?=
GPU_NODE ?=
GPU_TOLERATIONS ?=
STORAGE_ACCESS_KEY_ID ?=
STORAGE_SECRET_ACCESS_KEY ?=
CHART_DIR := deploy/helm/h2o-knowledge-mgmt
HELM_NAMESPACE_ARG = $(if $(strip $(NAMESPACE)),--namespace $(NAMESPACE),)
HELM_CREATE_NAMESPACE_ARG = $(if $(strip $(NAMESPACE)),--create-namespace,)
STORAGE_CREDENTIAL_ARGS = --set-string aws-compatible-storage.s3.accessKeyId='$(STORAGE_ACCESS_KEY_ID)' --set-string aws-compatible-storage.s3.secretAccessKey='$(STORAGE_SECRET_ACCESS_KEY)'
GPU_NODE_ARG = $(if $(strip $(GPU_NODE)),--set-string 'inference.nodeName=$(GPU_NODE)',)
GPU_TOLERATION_ARGS = $(if $(strip $(GPU_TOLERATIONS)),--set-json 'inference.tolerations=$(GPU_TOLERATIONS)',)
HELM_LINT_ARGS = --set-string inference.nodeName=test-a100 --set-string aws-compatible-storage.s3.accessKeyId=test-access --set-string aws-compatible-storage.s3.secretAccessKey=test-secret

.PHONY: setup test lint dev helm-lint helm-dependency-build helm-dependency-update deploy undeploy

setup:
	uv sync --project services/api --extra dev

test:
	uv run --project services/api --extra dev pytest

lint:
	uv run --project services/api --extra dev ruff check .

dev:
	uv run --project services/api uvicorn h2o_knowledge_mgmt_api.main:app --reload --app-dir services/api/src

helm-lint: helm-dependency-build
	helm lint $(CHART_DIR) $(HELM_LINT_ARGS)

helm-dependency-build:
	helm dependency build $(CHART_DIR)

helm-dependency-update:
	helm dependency update $(CHART_DIR)

deploy: helm-dependency-build
	@if [ -z "$(strip $(STORAGE_ACCESS_KEY_ID))" ] || [ -z "$(strip $(STORAGE_SECRET_ACCESS_KEY))" ]; then \
		echo "Set STORAGE_ACCESS_KEY_ID and STORAGE_SECRET_ACCESS_KEY to deploy." >&2; exit 1; \
	fi
	helm upgrade --install $(RELEASE) $(CHART_DIR) $(HELM_NAMESPACE_ARG) $(HELM_CREATE_NAMESPACE_ARG) $(STORAGE_CREDENTIAL_ARGS) $(GPU_NODE_ARG) $(GPU_TOLERATION_ARGS) $(HELM_ARGS)

undeploy:
	helm uninstall $(RELEASE) $(HELM_NAMESPACE_ARG)
