# acer-mgmt — 서비스별 독립 compose 오케스트레이션
# 사용:  make up s=cicd/gitlab   (s = stacks 하위 경로)

SHELL    := /bin/bash
COMPOSE  := docker compose
STACKS   := stacks
PROXY_NET ?= mgmt-proxy
ENV_FILE ?= .env

# s 인자를 받는 타깃들을 위한 헬퍼.
# 루트 .env 가 있으면 모든 서비스에 공통 변수(BASE_DOMAIN 등)로 주입한다.
ENVFLAG := $(if $(wildcard $(ENV_FILE)),--env-file $(ENV_FILE),)
CF = $(COMPOSE) $(ENVFLAG) -f $(STACKS)/$(s)/compose.yaml

.PHONY: help net up down restart logs ps pull config

help: ## 이 도움말 출력
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

net: ## 공용 외부 네트워크(mgmt-proxy) 생성
	@docker network inspect $(PROXY_NET) >/dev/null 2>&1 || docker network create $(PROXY_NET)

up: net ## 서비스 기동      (예: make up s=edge/traefik)
	$(CF) up -d

down: ## 서비스 중지        (예: make down s=edge/traefik)
	$(CF) down

restart: ## 서비스 재시작
	$(CF) restart

logs: ## 로그 follow
	$(CF) logs -f --tail=200

ps: ## 컨테이너 상태
	$(CF) ps

pull: ## 이미지 갱신
	$(CF) pull

config: ## compose 렌더 결과 확인(검증)
	$(CF) config
