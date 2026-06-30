# Makefile for rm-sync
# Phase: cloud backend (Traefik + rmfakecloud)

ACME_PROD := https://acme-v02.api.letsencrypt.org/directory
ACME_STAGING := https://acme-staging-v02.api.letsencrypt.org/directory

.PHONY: help setup build up down restart logs logs-traefik logs-rmfakecloud \
        shell-traefik shell-rmfakecloud status clean start \
        use-staging use-prod show-ca

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
	@echo "  show-ca            - Show the ACME CA currently set in .env"
	@echo "  use-staging        - Point ACME_CA at Let's Encrypt staging"
	@echo "  use-prod           - Point ACME_CA at Let's Encrypt production"

setup:
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
		JWT=$$(openssl rand -base64 32 | tr -d '\n'); \
		sed -i.bak "s|^JWT_SECRET_KEY=.*|JWT_SECRET_KEY=$$JWT|" .env && rm .env.bak; \
		echo ".env created. Now edit it to fill in:"; \
		echo "  - ACME_EMAIL   (your email for Let's Encrypt notices)"; \
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
	@echo "Containers and named volumes removed."
	@echo "Local cert dir (/var/lib/rm-sync/traefik-certs) and NAS data are untouched."

start: setup up

# ---- ACME CA management ----
#
# Switching between staging and production requires clearing the stored ACME
# account state (acme.json), because the account is tied to the CA that
# registered it. The targets below print the cleanup commands rather than run
# them, so destructive actions stay explicit.

show-ca:
	@if [ ! -f .env ]; then echo "No .env found; run 'make setup' first."; exit 1; fi
	@grep ^ACME_CA= .env

use-staging:
	@if [ ! -f .env ]; then echo "No .env found; run 'make setup' first."; exit 1; fi
	@sed -i.bak "s|^ACME_CA=.*|ACME_CA=$(ACME_STAGING)|" .env && rm .env.bak
	@echo "ACME_CA set to STAGING."
	@echo ""
	@echo "To apply the change and force a fresh staging cert, run:"
	@echo "  make down"
	@echo "  sudo rm -f /var/lib/rm-sync/traefik-certs/acme.json"
	@echo "  make up"

use-prod:
	@if [ ! -f .env ]; then echo "No .env found; run 'make setup' first."; exit 1; fi
	@sed -i.bak "s|^ACME_CA=.*|ACME_CA=$(ACME_PROD)|" .env && rm .env.bak
	@echo "ACME_CA set to PRODUCTION."
	@echo ""
	@echo "To apply the change and force a fresh production cert, run:"
	@echo "  make down"
	@echo "  sudo rm -f /var/lib/rm-sync/traefik-certs/acme.json"
	@echo "  make up"
	@echo ""
	@echo "WARNING: Production has tight rate limits (5 duplicate certs/week)."
	@echo "Only re-issue when necessary."
