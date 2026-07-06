# acer-mgmt — Docker Compose와 k3d 관리 진입점

SHELL := /bin/bash

.PHONY: help \
	compose-up compose-down compose-restart compose-logs compose-ps compose-pull compose-config \
	up down restart logs ps pull config net \
	cluster-tools cluster-validate cluster-create cluster-start cluster-stop cluster-status \
	cluster-dns argocd-bootstrap argocd-status argocd-smoke cluster-destroy

help: ## 전체 도움말
	@echo "Docker Compose"
	@echo "  make compose-up s=cicd/gitlab"
	@echo "  make compose-down s=cicd/gitlab"
	@echo "  make compose-logs s=edge/traefik"
	@echo
	@echo "k3d / Argo CD"
	@echo "  make cluster-tools"
	@echo "  make cluster-create"
	@echo "  make argocd-bootstrap"
	@echo "  make argocd-smoke"
	@echo "  make cluster-status"
	@echo "  make cluster-dns"
	@echo
	@echo "기존 호환 명령"
	@echo "  make up|down|logs|ps s=<domain/service>"

compose-up compose-down compose-restart compose-logs compose-ps compose-pull compose-config:
	$(MAKE) -C compose $(@:compose-%=%) s="$(s)"

# 기존 운영 명령을 깨지 않도록 Compose Makefile에 위임한다.
up down restart logs ps pull config net:
	$(MAKE) -C compose $@ s="$(s)"

cluster-tools:
	$(MAKE) -C k3d tools

cluster-validate:
	$(MAKE) -C k3d validate

cluster-create:
	$(MAKE) -C k3d create

cluster-start:
	$(MAKE) -C k3d start

cluster-stop:
	$(MAKE) -C k3d stop

cluster-status:
	$(MAKE) -C k3d status

cluster-dns:
	$(MAKE) -C k3d dns

argocd-bootstrap:
	$(MAKE) -C k3d bootstrap

argocd-status:
	$(MAKE) -C k3d argocd-status

argocd-smoke:
	$(MAKE) -C k3d smoke

cluster-destroy:
	$(MAKE) -C k3d destroy CONFIRM="$(CONFIRM)"
