.DEFAULT_GOAL := help

INSTALL_MODEL ?= false

.PHONY: help lint deploy undeploy install uninstall model-install model-uninstall helm-lint helm-template

help:
	@printf '%s\n' \
	  'make install [INSTALL_MODEL=true]  Install h2oGPTe and optionally the vLLM model' \
	  'make uninstall                    Remove both releases and the namespace (asks for confirmation)' \
	  'make model-install                Install or upgrade only the vLLM model using .env' \
	  'make model-uninstall              Remove only the vLLM model; keep h2oGPTe and its data' \
	  'make lint                         Check Bash syntax and lint the model Helm chart' \
	  'make helm-template                Render the model Helm chart locally'

lint: helm-lint
	bash -n scripts/install.sh
	bash -n scripts/uninstall.sh
	bash -n scripts/model.sh

helm-lint:
	helm lint deploy/helm/model --strict

helm-template:
	helm template h2oai-model deploy/helm/model --namespace h2o-knowledge-mgmt

deploy install:
	./scripts/install.sh --install-model "$(INSTALL_MODEL)"

undeploy uninstall:
	./scripts/uninstall.sh

model-install:
	./scripts/model.sh install

model-uninstall:
	./scripts/model.sh uninstall
