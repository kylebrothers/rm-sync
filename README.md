# rm-sync

A self-hosted service that converts documents from multiple sources (DOCX, HTML, EPUB, OneNote) into reMarkable-compatible packages and syncs them to a reMarkable 2 tablet via a self-hosted cloud backend.

---

## Table of Contents

- [Project Goals](#project-goals)
- [Architecture Overview](#architecture-overview)
- [Infrastructure](#infrastructure)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Module Interfaces](#module-interfaces)
- [Sync Policy](#sync-policy)
- [Configuration](#configuration)
- [Docker Compose](#docker-compose)
- [Setup Guide](#setup-guide)
- [Design Decisions & Rationale](#design-decisions--rationale)
- [Future Sources](#future-sources)
- [Known Constraints](#known-constraints)

---

## Project Goals

- Convert DOCX, HTML, EPUB, and OneNote documents into formats readable on a reMarkable 2 tablet
- Sync the 50 most recently modified documents per source automatically
- Run entirely self-hosted, with no dependency on reMarkable's official cloud service
- Operate without any permanent modification to the tablet beyond a one-time proxy installation
- Keep the codebase small, modular, and maintainable in focused AI-assisted development sessions

---

## Architecture Overview

```
Sources
  ├── DOCX files (local directory watch)
  ├── HTML files (local directory watch)
  ├── EPUB files (local directory watch)
  └── OneNote (Microsoft Graph API)
          │
          ▼
  rm-sync (Python, Docker)
  ├── source adapters     → fetch/read input documents
  ├── format converters   → convert each format to PDF
  ├── bundle builder      → wrap PDF in xochitl-compatible package
  └── rmfakecloud client  → upload via REST API + trigger sync
          │
          ▼
  rmfakecloud (Docker)    → self-hosted reMarkable cloud replacement
          │
          ▼
  reMarkable 2 tablet     → syncs automatically over WiFi
```

All services run on a home server behind a reverse proxy. The tablet connects over standard HTTPS (port 443) and requires no VPN or ongoing SSH access.

---

## Infrastructure

| Component | Technology | Notes |
|---|---|---|
| Converter service | Python 3.11+, Docker | All source adapters + converters in one container |
| Cloud backend | rmfakecloud (ddvk/rmfakecloud) | Self-hosted reMarkable cloud replacement |
| Reverse proxy | nginx or Traefik | TLS termination on port 443 |
| TLS certificates | Let's Encrypt, DNS challenge | Namecheap plugin or Cloudflare delegation |
| Scheduling | Python APScheduler or cron | Periodic sync runs |

**Why one converter container?** All conversion modules are Python with compatible dependencies and share the same PDF output pipeline. Splitting by source would add inter-container complexity with no scaling benefit for a private single-user service.

**Why rmfakecloud instead of SSH?** rmfakecloud requires only a one-time tablet setup (proxy install + pairing code). After that, the tablet syncs automatically with no ongoing SSH access, no Toltec, and no firmware risk. It exposes a clean REST API that the converter service uses to upload documents and trigger syncs.

**Why not run on the tablet itself?** The RM2 has a single-core ~1GHz ARM CPU and 1GB RAM. LibreOffice, WeasyPrint, and Playwright are far too heavy. The tablet's role is purely as a document consumer.

---

## How It Works

### Document format strategy

The reMarkable tablet's xochitl software natively displays PDF files as document backgrounds. Rather than converting content to reMarkable's proprietary `.rm` stroke format, all input formats are converted to **PDF**, then wrapped in a minimal xochitl bundle. This approach:

- Avoids all dependency on `rmscene`/`rmc` write APIs
- Handles arbitrary content (text, images, layout) without stroke fidelity concerns
- Produces documents the tablet can open, read, and annotate natively

### xochitl bundle structure

Each document becomes a UUID-named bundle uploaded to rmfakecloud:

```
{uuid}.metadata   — document name, type, parent folder (JSON)
{uuid}.content    — fileType: "pdf", orientation, margins (JSON)
{uuid}.pdf        — the converted PDF content
```

rmfakecloud handles storage and delivers the bundle to the tablet on next sync.

### Sync policy

- The 50 most recently modified documents are kept per source
- When a document is updated at the source, it is re-converted and re-uploaded
- Documents that fall outside the 50 most recent are deleted from rmfakecloud (and therefore from the tablet on next sync)
- Sync runs on a configurable schedule (default: every 30 minutes)

---

## Project Structure

```
rm-sync/
├── README.md
├── docker-compose.yml
├── Dockerfile
├── requirements.txt
├── config.yml                  # user configuration (gitignored)
├── config.example.yml          # template with all options documented
│
├── main.py                     # entry point, scheduler
│
├── sources/
│   ├── __init__.py
│   ├── base.py                 # SourceDocument dataclass, BaseSource ABC
│   ├── local_docx.py           # watches a local directory for .docx files
│   ├── local_html.py           # watches a local directory for .html files
│   ├── local_epub.py           # watches a local directory for .epub files
│   └── onenote.py              # fetches pages via Microsoft Graph API
│
├── converters/
│   ├── __init__.py
│   ├── base.py                 # BaseConverter ABC
│   ├── docx_converter.py       # DOCX → PDF via LibreOffice subprocess
│   ├── html_converter.py       # HTML → PDF via WeasyPrint or Playwright
│   └── epub_converter.py       # EPUB → PDF via spine HTML extraction + html_converter
│
├── bundle/
│   ├── __init__.py
│   ├── builder.py              # assembles xochitl bundle from PDF + metadata
│   └── metadata.py             # generates .metadata and .content JSON
│
├── rmfakecloud/
│   ├── __init__.py
│   └── client.py               # REST API client: login, upload, delete, sync
│
├── sync/
│   ├── __init__.py
│   ├── manager.py              # orchestrates full sync cycle
│   └── state.py                # tracks what's currently synced (JSON state file)
│
└── tests/
    ├── test_converters.py
    ├── test_bundle.py
    └── test_client.py
```

---

## Module Interfaces

### `sources/base.py`

```python
@dataclass
class SourceDocument:
    id: str                     # stable unique ID for this document
    title: str                  # human-readable name
    source_type: str            # "docx" | "html" | "epub" | "onenote"
    last_modified: datetime
    content: bytes | None       # raw file bytes, or None if fetched lazily
    fetch: Callable | None      # called to populate content if None

class BaseSource(ABC):
    @abstractmethod
    def list_documents(self) -> list[SourceDocument]:
        """Return all available documents, sorted by last_modified descending."""

    @abstractmethod
    def fetch_content(self, doc: SourceDocument) -> bytes:
        """Return raw content bytes for a document."""
```

### `converters/base.py`

```python
class BaseConverter(ABC):
    @abstractmethod
    def convert(self, content: bytes, title: str) -> bytes:
        """Convert raw input bytes to PDF bytes."""
```

### `bundle/builder.py`

```python
def build_bundle(pdf_bytes: bytes, title: str, uuid: str) -> dict[str, bytes]:
    """
    Returns a dict of filename -> bytes representing the xochitl bundle.
    Keys: "{uuid}.metadata", "{uuid}.content", "{uuid}.pdf"
    """
```

### `rmfakecloud/client.py`

```python
class RmfakecloudClient:
    def __init__(self, base_url: str, email: str, password: str): ...

    def upload_document(self, bundle: dict[str, bytes], parent_id: str = "") -> str:
        """Upload bundle, return assigned document ID."""

    def delete_document(self, doc_id: str) -> None: ...

    def list_documents(self) -> list[dict]: ...

    def trigger_sync(self) -> None:
        """Notify connected tablets to sync."""
```

### `sync/manager.py`

```python
class SyncManager:
    def __init__(self, sources: list[BaseSource], converters: dict[str, BaseConverter],
                 client: RmfakecloudClient, state: SyncState, limit: int = 50): ...

    def run(self) -> None:
        """
        Full sync cycle:
        1. Fetch document list from each source (top `limit` by last_modified)
        2. Diff against current sync state
        3. Convert and upload new/updated documents
        4. Delete documents no longer in top `limit`
        5. Trigger tablet sync
        6. Persist updated state
        """
```

### `sync/state.py`

```python
class SyncState:
    """
    Persists a mapping of source_document_id -> rmfakecloud_doc_id
    and last_modified timestamp, stored as a JSON file.
    Used to detect new, updated, and evicted documents between sync runs.
    """
    def load(self) -> None: ...
    def save(self) -> None: ...
    def get(self, source_id: str) -> dict | None: ...
    def set(self, source_id: str, rm_id: str, last_modified: datetime) -> None: ...
    def remove(self, source_id: str) -> None: ...
    def all_rm_ids(self) -> list[str]: ...
```

---

## Sync Policy

- **Limit**: 50 documents per source (configurable)
- **Selection**: Most recently modified documents win
- **Updates**: A document is re-converted and re-uploaded if `last_modified` has changed since last sync
- **Eviction**: Documents that fall out of the top 50 are deleted from rmfakecloud on the next sync run
- **Schedule**: Configurable interval (default 30 minutes); can also be triggered manually

---

## Configuration

`config.yml` (see `config.example.yml` for full documentation):

```yaml
rmfakecloud:
  url: https://remarkable.yourdomain.com
  email: user@example.com
  password: yourpassword

sync:
  interval_minutes: 30
  limit_per_source: 50

sources:
  local_docx:
    enabled: true
    path: /data/docx

  local_html:
    enabled: true
    path: /data/html

  local_epub:
    enabled: true
    path: /data/epub

  onenote:
    enabled: false
    client_id: ""
    client_secret: ""
    tenant_id: ""

converters:
  html_backend: weasyprint   # "weasyprint" or "playwright"
  docx_backend: libreoffice  # currently only option
  page_size: A4              # reMarkable 2 displays A5 natively; A4 also works well
```

---

## Docker Compose

```yaml
version: "3.9"

services:

  rmfakecloud:
    image: ddvk/rmfakecloud
    container_name: rmfakecloud
    restart: unless-stopped
    environment:
      - JWT_SECRET_KEY=${JWT_SECRET_KEY}
      - STORAGE_URL=https://remarkable.yourdomain.com
    volumes:
      - ./rmfakecloud-data:/data

  converter:
    build: .
    container_name: rm-sync
    restart: unless-stopped
    volumes:
      - ./config.yml:/app/config.yml:ro
      - ./data:/data
      - ./state:/app/state
    depends_on:
      - rmfakecloud

  reverse-proxy:
    image: nginx:alpine
    container_name: rm-proxy
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/letsencrypt:ro
    depends_on:
      - rmfakecloud
```

---

## Setup Guide

### 1. Server setup

```bash
git clone https://github.com/yourname/rm-sync
cd rm-sync
cp config.example.yml config.yml
# edit config.yml with your credentials and paths
```

### 2. TLS certificate

```bash
# Using Certbot with Namecheap DNS plugin
certbot certonly \
  --authenticator dns-namecheap \
  --dns-namecheap-credentials ~/.secrets/namecheap.ini \
  -d remarkable.yourdomain.com
```

Alternatively, delegate the subdomain's DNS to Cloudflare and use the `certbot-dns-cloudflare` plugin, which is more reliable.

### 3. Start services

```bash
docker compose up -d
```

### 4. Create rmfakecloud user

Visit `https://remarkable.yourdomain.com` and register a user account.

### 5. Pair the tablet (one time)

SSH into the tablet:
```bash
ssh root@10.11.99.1   # via USB
```

Install the rmfakecloud proxy:
```bash
wget https://github.com/ddvk/rmfakecloud/releases/latest/download/rmfakecloud-proxy
# follow device setup instructions at ddvk.github.io/rmfakecloud/remarkable/setup/
```

Generate a registration code in the rmfakecloud web UI and enter it on the tablet under Settings → Connect.

### 6. Verify

Drop a `.docx` file into `/data/docx` and wait for the next sync interval. The document should appear on the tablet.

---

## Design Decisions & Rationale

### PDF as universal intermediate format

The reMarkable xochitl software natively renders PDF files as document backgrounds. This means all input formats only need to produce a valid PDF — no knowledge of reMarkable's proprietary `.rm` binary format is needed. The `.rm` format (used for pen strokes) is irrelevant when documents are read-only references.

This was chosen over converting to `.rm` stroke format because:
- `.rm` v6 (firmware 3+) is a complex binary CRDT format
- Stroke conversion loses layout fidelity for text-heavy documents
- PDF background approach is what reMarkable itself uses for annotated PDFs

### rmfakecloud over SSH/SCP delivery

Direct SSH delivery to the tablet's xochitl directory requires the tablet to be reachable by IP and xochitl to be restarted after each batch. rmfakecloud eliminates both requirements — the tablet initiates the sync at its own cadence over standard HTTPS.

### Single converter container

All source adapters and converters share Python as a runtime and a common PDF output interface. Splitting them would add inter-container HTTP calls and deployment complexity with no benefit for a single-user private service.

### WeasyPrint vs Playwright for HTML

WeasyPrint is the default because it is a pure Python library with no browser dependency, making the Docker image smaller and builds faster. Playwright (headless Chromium) is available as a config option for pages that require JavaScript rendering. OneNote HTML export is pre-rendered server-side, so WeasyPrint handles it adequately after a normalization pass.

### LibreOffice for DOCX

No pure-Python DOCX-to-PDF library matches LibreOffice rendering quality. The converter runs `libreoffice --headless --convert-to pdf` as a subprocess. LibreOffice is included in the converter Docker image.

---

## Future Sources

The `BaseSource` interface makes adding new sources straightforward. Planned additions:

| Source | Adapter approach |
|---|---|
| Google Docs | Google Drive API, export as DOCX then convert |
| Notion | Notion API, export as HTML |
| PDF passthrough | Copy directly, skip conversion |
| Web URLs | Playwright fetch + HTML converter |

---

## Known Constraints

- **Firmware 3.15+**: rmfakecloud `STORAGE_URL` must be `https://host` with no port number. A proper domain with HTTPS on port 443 is required.
- **LibreOffice in Docker**: Adds ~300MB to the converter image. Acceptable for a private home server deployment.
- **OneNote HTML**: Graph API returns Microsoft-proprietary HTML. A normalization/cleaning step is required before PDF conversion.
- **RM2 storage**: ~5-6GB available for documents. At 50 documents averaging 2MB each, storage is not a practical constraint.
- **Toltec/WireGuard not required**: The rmfakecloud proxy approach works on current firmware without any package manager or VPN on the tablet.
- **File size limit**: rmfakecloud has no documented hard limit, but reMarkable's own cloud caps uploads at 100MB. Keep converted PDFs under this threshold.
