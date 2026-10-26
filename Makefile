ENV_FILE ?= ./.env
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
endif

RELEASE ?= h2o-knowledge-mgmt
NAMESPACE ?=
HELM_ARGS ?=
STORAGE_ACCESS_KEY_ID ?=
STORAGE_SECRET_ACCESS_KEY ?=
LLM_BASE_URL ?=
LLM_MODEL ?=
LLM_API_KEY ?=
export LLM_BASE_URL LLM_MODEL LLM_API_KEY
export STORAGE_ACCESS_KEY_ID STORAGE_SECRET_ACCESS_KEY
CHART_DIR := deploy/helm/h2o-knowledge-mgmt
HELM_NAMESPACE_ARG = $(if $(strip $(NAMESPACE)),--namespace $(NAMESPACE),)
HELM_CREATE_NAMESPACE_ARG = $(if $(strip $(NAMESPACE)),--create-namespace,)
HELM_LINT_ARGS = --set-string llm.baseUrl=https://maas.example.test/v1 --set-string llm.model=test-model --set-string aws-compatible-storage.s3.accessKeyId=test-access --set-string aws-compatible-storage.s3.secretAccessKey=test-secret

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
	@set -eu; \
	values=$$(mktemp); \
	trap 'rm -f "$$values"' EXIT; \
	jq -n '{ \
	    llm: {baseUrl: env.LLM_BASE_URL, model: env.LLM_MODEL, apiKey: env.LLM_API_KEY}, \
	    "aws-compatible-storage": {s3: {accessKeyId: env.STORAGE_ACCESS_KEY_ID, secretAccessKey: env.STORAGE_SECRET_ACCESS_KEY}} \
	}' > "$$values"; \
	helm upgrade --install $(RELEASE) $(CHART_DIR) $(HELM_NAMESPACE_ARG) $(HELM_CREATE_NAMESPACE_ARG) --values "$$values" $(HELM_ARGS)

undeploy:
	helm uninstall $(RELEASE) $(HELM_NAMESPACE_ARG)
