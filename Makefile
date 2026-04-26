# Makefile for rm-sync
# Phase: cloud backend (Traefik + rmfakecloud)

.PHONY: help setup build up down restart logs logs-traefik logs-rmfakecloud \
        shell-traefik shell-rmfakecloud status clean start switch-prod

help:
	@echo "rm-sync — available commands:"
	@echo "  setup              - Create .env from .env.example, generate JWT secret"
	@echo "  build              - (no-op for cloud backend phase)"
	@echo "  up                 - Start Traefik + rmfakecloud"
	@echo "  down               - Stop services"
	@echo "  restart            - Restart services"
	@echo "  logs               - Tail logs from all services"
	@echo "  logs-traefik       - Tail Traefik logs only"
	@echo "  logs-rmfakecloud   - Tail rmfakecloud logs only"
	@echo "  shell-traefik      - Shell into Traefik container"
	@echo "  shell-rmfakecloud  - Shell into rmfakecloud container"
	@echo "  status             - Show container status"
	@echo "  clean              - Stop and remove containers + volumes"
	@echo "  start              - setup + up"
	@echo "  switch-prod        - Switch ACME_CA from staging to production in .env"

setup:
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
		JWT=$$(openssl rand -base64 32 | tr -d '\n'); \
		# Use | as sed delimiter since base64 may contain / \
		sed -i.bak "s|^JWT_SECRET_KEY=.*|JWT_SECRET_KEY=$$JWT|" .env && rm .env.bak; \
		echo ".env created. Now edit it to fill in:"; \
		echo "  - CF_API_TOKEN (Cloudflare API token, Zone:DNS:Edit)"; \
		echo "  - ACME_EMAIL   (your email)"; \
		echo "Then run: make up"; \
	else \
		echo ".env already exists; leaving it alone."; \
	fi

build:
	@echo "Cloud backend phase uses prebuilt images; nothing to build."
	@echo "(The 'converter' service will add a Dockerfile in a later phase.)"

up:
	docker compose up -d
	@echo ""
	@echo "Started. Watch certificate issuance with: make logs-traefik"
	@echo "Once cert issues, visit: https://$$(grep ^RMFAKECLOUD_DOMAIN .env | cut -d= -f2)"

down:
	docker compose down

restart: down up

logs:
	docker compose logs -f

logs-traefik:
	docker compose logs -f traefik

logs-rmfakecloud:
	docker compose logs -f rmfakecloud

shell-traefik:
	docker compose exec traefik sh

shell-rmfakecloud:
	docker compose exec rmfakecloud sh

status:
	docker compose ps

clean:
	docker compose down -v
	@echo "Containers and named volumes removed. NFS data on NAS is untouched."

start: setup up

switch-prod:
	@if [ ! -f .env ]; then echo "No .env found; run 'make setup' first."; exit 1; fi
	@sed -i.bak "s|^ACME_CA=.*|ACME_CA=https://acme-v02.api.letsencrypt.org/directory|" .env && rm .env.bak
	@echo "Switched ACME_CA to production. Now run:"
	@echo "  make down && docker volume rm rm-sync_traefik_certs && make up"
	@echo "(Removing the cert volume forces re-issuance against the production CA.)"
