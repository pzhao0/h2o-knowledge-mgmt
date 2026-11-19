.DEFAULT_GOAL := help

.PHONY: help lint deploy undeploy install uninstall

help:
	@printf '%s\n' \
	  'make deploy    Install or upgrade h2oGPTe using .env' \
	  'make undeploy  Remove h2oGPTe and its namespace (asks for confirmation)' \
	  'make lint      Check installation script syntax'

lint:
	bash -n scripts/install.sh
	bash -n scripts/uninstall.sh

deploy install:
	./scripts/install.sh

undeploy uninstall:
	./scripts/uninstall.sh
