SHELL := /bin/bash

CLUSTER_NAME := mgmt
CONFIG := $(CURDIR)/config.yaml
KUBECONFIG_FILE := $(abspath $(CURDIR)/../secrets/k3d/mgmt.kubeconfig)

export KUBECONFIG := $(KUBECONFIG_FILE)

.PHONY: help tools validate data network create start stop status bootstrap argocd-status smoke destroy

help:
	@echo "  make tools       k3d/kubectl/argocd CLI 설치"
	@echo "  make validate    버전·설정 정적 검증"
	@echo "  make create      k3d 클러스터 생성 또는 시작"
	@echo "  make bootstrap   Argo CD 설치"
	@echo "  make smoke       Argo CD 실제 동기화 테스트"
	@echo "  make status      클러스터와 Argo CD 상태"
	@echo "  make stop|start  클러스터 중지/시작"

tools:
	./scripts/install-tools.sh

validate:
	./scripts/validate.sh

data:
	@mkdir -p /home/mgmt-data/k3d/mgmt

network:
	@docker network inspect mgmt-proxy >/dev/null 2>&1 || docker network create mgmt-proxy

create: tools validate data network
	@if k3d cluster list --no-headers 2>/dev/null | awk '{print $$1}' | grep -qx "$(CLUSTER_NAME)"; then \
		echo "k3d cluster exists: $(CLUSTER_NAME)"; \
		k3d cluster start "$(CLUSTER_NAME)" >/dev/null 2>&1 || true; \
	else \
		k3d cluster create --config "$(CONFIG)"; \
	fi
	@mkdir -p "$(dir $(KUBECONFIG_FILE))"
	@k3d kubeconfig get "$(CLUSTER_NAME)" > "$(KUBECONFIG_FILE)"
	@chmod 600 "$(KUBECONFIG_FILE)"
	@kubectl wait --for=condition=Ready node --all --timeout=180s

start: tools
	k3d cluster start "$(CLUSTER_NAME)"
	@mkdir -p "$(dir $(KUBECONFIG_FILE))"
	@k3d kubeconfig get "$(CLUSTER_NAME)" > "$(KUBECONFIG_FILE)"
	@chmod 600 "$(KUBECONFIG_FILE)"

stop: tools
	k3d cluster stop "$(CLUSTER_NAME)"

bootstrap: create
	./scripts/bootstrap-argocd.sh

argocd-status:
	@kubectl get nodes -o wide
	@kubectl get pods,svc,ingress -n argocd -o wide

status: tools
	@k3d cluster list
	@if [[ -f "$(KUBECONFIG_FILE)" ]]; then \
		kubectl get nodes -o wide; \
		kubectl get applications.argoproj.io -n argocd 2>/dev/null || true; \
	fi

smoke: bootstrap
	./scripts/smoke-test.sh

destroy: tools
	@if [[ "$(CONFIRM)" != "$(CLUSTER_NAME)" ]]; then \
		echo "거부: make destroy CONFIRM=$(CLUSTER_NAME) 로 명시해야 합니다."; \
		exit 2; \
	fi
	k3d cluster delete "$(CLUSTER_NAME)"
	rm -f "$(KUBECONFIG_FILE)"
