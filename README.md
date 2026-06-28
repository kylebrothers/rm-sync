# rm-sync

Self-hosted sync backend and conversion pipeline for reMarkable tablets.

This repository will eventually contain multiple components, each in its own subdirectory, orchestrated by a single root `docker-compose.yml`.

## Current phase: cloud backend

Deployed:

- **Traefik** — reverse proxy, terminates TLS, handles Let's Encrypt via HTTP-01.
- **rmfakecloud** (ddvk/rmfakecloud) — drop-in replacement for reMarkable's cloud, accepts xochitl-format bundles and serves them to paired tablets.

Future phases (not yet implemented):

- **converter** — Python service that ingests source documents, converts them to xochitl bundles, and uploads them via rmfakecloud's REST API.

## Layout

```
rm-sync/
├── docker-compose.yml       # orchestrates all services
├── .env.example             # template; copy to .env via `make setup`
├── Makefile                 # bring services up/down, manage cert lifecycle
├── reverse-proxy/
│   └── traefik.yml          # Traefik static config
├── rmfakecloud/             # placeholder (data lives on NAS)
└── converter/               # (future phase)
```

## Prerequisites

- A host that can reach the NAS (`192.168.0.134` by default) via NFSv4 and has the NFS exports `/Docker/rm-sync/rmfakecloud-data` and `/Docker/rm-sync/traefik-certs` available.
- Public DNS `A` record for the rmfakecloud hostname (default `remarkable.brothersbrothers.net`), tracking this host's public IP via DDNS.
- Inbound ports 80 and 443 reach this host. In the current deployment, both are forwarded to the host by an nginx front proxy on the MediaWiki host; see the separate `mediawiki-host-frontproxy.md` document for that setup.
- Docker + Docker Compose v2.

## Quick start

```bash
make setup                  # creates .env, generates JWT secret
$EDITOR .env                # fill in ACME_EMAIL
make up
make logs-traefik           # watch cert issuance
```

ACME defaults to the Let's Encrypt **staging** CA. Browsers will warn on staging certs — that's expected. Once you've confirmed the staging cert issues correctly, switch to production:

```bash
make switch-prod
# follow the printed instructions to recreate the cert volume and re-issue
```

## First-time tablet pairing

1. Visit `https://<RMFAKECLOUD_DOMAIN>` and create the first user via the rmfakecloud web UI.
2. Generate a one-time pairing code in the web UI.
3. On the tablet (firmware 3.15+), point the cloud endpoint at the rmfakecloud host. The exact procedure depends on firmware version; see rmfakecloud's documentation.
4. Enter the pairing code on the tablet.

## See also

- `mediawiki-host-frontproxy.md` — front-proxy setup on the host owning public port 80, required for this deployment to receive inbound traffic.
