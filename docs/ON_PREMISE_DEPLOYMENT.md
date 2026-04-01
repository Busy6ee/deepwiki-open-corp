# DeepWiki-Open On-Premise Deployment Guide

This guide covers deploying DeepWiki-Open in environments with restricted or no outbound internet access (air-gapped / secured network environments).

> **관련 문서:**
> - [사내 온프레미스 설정 가이드 (한국어)](ONPREMISE_SETUP_GUIDE.md) — 사내 vLLM·인증서·프록시 환경 단계별 설정
> - [vLLM On-Premise Guide](VLLM_ONPREMISE_GUIDE.md) — vLLM server integration details

---

## Overview of Outbound Traffic Sources

| Category | Default Target | Status | Action Required |
|----------|---------------|--------|-----------------|
| Google Fonts (CDN) | `fonts.googleapis.com` | **Removed** | Fonts now bundled via `next/font` at build time |
| jsDelivr CDN (slides preview) | `cdn.jsdelivr.net` | **Removed** | Assets served from `public/vendor/` locally |
| jsDelivr CDN (slide export HTML) | `cdn.jsdelivr.net` | Kept (standalone HTML) | See [Slide Export](#slide-export-html) |
| LLM Provider APIs | Various | Configurable | Use Ollama (local) or internal endpoints |
| Git Repository Access | `github.com`, `gitlab.com`, etc. | Configurable | Restrict to internal Git hosts |
| Docker Base Images | Docker Hub | Build-time only | Use internal registry mirror |
| npm / PyPI Packages | `registry.npmjs.org`, `pypi.org` | Build-time only | Use internal package mirrors |
| Next.js Telemetry | Vercel servers | **Disabled** | `NEXT_TELEMETRY_DISABLED=1` already set |
| Third-party Analytics | N/A | **None** | No analytics/tracking code present |

---

## 1. Completed Code Changes

### 1-1. Google Fonts (Removed)

**Before:** Every page load fetched fonts from `fonts.googleapis.com` and `fonts.gstatic.com`.

**After:** Fonts (Geist Mono, Noto Sans JP, Noto Serif JP) are downloaded at **build time** by `next/font/google` and self-hosted as static assets. No runtime external requests.

**Files changed:**
- `src/app/layout.tsx` - Replaced `<link>` tags with `next/font/google` imports
- `src/app/globals.css` - CSS variables reference font variables from `next/font`

### 1-2. jsDelivr CDN for Slides (Removed for Preview)

**Before:** Slide preview loaded Font Awesome CSS, Chart.js, and Mermaid from `cdn.jsdelivr.net`.

**After:** These assets are served locally from `public/vendor/`:
- `/vendor/fontawesome/css/all.min.css` + webfonts
- `/vendor/chartjs/chart.umd.js`
- `/vendor/mermaid/mermaid.min.js`

**Files changed:**
- `src/app/[owner]/[repo]/slides/page.tsx` - CDN URLs replaced with local `/vendor/` paths
- `scripts/copy-vendor-assets.sh` - Script to copy assets from `node_modules` to `public/vendor/`
- `package.json` - Added `postinstall` hook to run the copy script
- `Dockerfile` - Runs `copy-vendor-assets.sh` during build
- `.gitignore` - Excludes `public/vendor/` (generated files)

### Slide Export HTML

Exported slide HTML files (downloaded by users) still reference CDN URLs because they are standalone HTML files that need to work when opened outside the application. If fully offline export is needed, replace the CDN URLs in the export template at `src/app/[owner]/[repo]/slides/page.tsx` (search for "Exported HTML uses CDN").

---

## 2. LLM Provider Configuration

All LLM providers are optional. Only the configured provider generates outbound traffic.

### Recommended: Ollama (Fully Local)

No external traffic. Deploy Ollama on the same host or an internal server.

```bash
# Environment variables
OLLAMA_HOST=http://localhost:11434

# Or point to an internal Ollama server
OLLAMA_HOST=http://ollama.internal.company.com:11434
```

### Alternative: vLLM (On-Premise GPU Server)

For on-premise environments with GPU servers, vLLM provides high-performance model serving with an OpenAI-compatible API. No external traffic.

```bash
VLLM_BASE_URL=http://vllm-server.internal:8000/v1
VLLM_MODEL=your-model-name
VLLM_API_KEY=no-key-required          # Only if vLLM has auth enabled
DEEPWIKI_EMBEDDER_TYPE=vllm            # Also use vLLM for embeddings
VLLM_EMBED_MODEL=your-embedding-model
```

For detailed vLLM setup including certificates and proxy configuration, see [vLLM On-Premise Guide](VLLM_ONPREMISE_GUIDE.md).

### Alternative: Internal Cloud Endpoints

| Provider | Environment Variable | Example |
|----------|---------------------|---------|
| OpenAI-compatible | `OPENAI_BASE_URL` | `https://llm-proxy.internal.com/v1` |
| vLLM | `VLLM_BASE_URL` | `http://vllm-server:8000/v1` |
| Azure OpenAI | `AZURE_OPENAI_ENDPOINT` | `https://your-instance.openai.azure.com` |
| AWS Bedrock | AWS VPC endpoints | Configure via `AWS_*` env vars |
| DashScope | `DASHSCOPE_BASE_URL` | Internal proxy URL |

### Disable Unused Providers

Simply do not set API keys for providers you don't use. No API calls are made without configured keys.

---

## 3. Git Repository Access

DeepWiki clones repositories via HTTPS. Control which hosts are accessed:

| Service | Endpoint Pattern |
|---------|-----------------|
| GitHub Enterprise | `https://{your-domain}/api/v3` |
| GitLab Self-Hosted | `https://{your-domain}/api/v4` |
| Bitbucket Server | Internal Bitbucket endpoint |

**To restrict to internal repositories only**, configure network-level firewall rules to block `github.com`, `gitlab.com`, and `api.bitbucket.org`, or implement a domain whitelist in your reverse proxy.

---

## 4. Build-Time Dependencies

For fully air-gapped builds, mirror these registries internally:

### Docker Images
```bash
# Pull and push to internal registry
docker pull node:20-alpine3.22
docker tag node:20-alpine3.22 registry.internal.com/node:20-alpine3.22
docker push registry.internal.com/node:20-alpine3.22

docker pull python:3.11-slim
docker tag python:3.11-slim registry.internal.com/python:3.11-slim
docker push registry.internal.com/python:3.11-slim
```

Update `Dockerfile` `FROM` lines to use internal registry:
```dockerfile
FROM registry.internal.com/node:20-alpine3.22 AS node_base
# ...
FROM registry.internal.com/python:3.11-slim AS py_deps
```

### npm Packages
```bash
# Configure npm to use internal registry
npm config set registry https://npm.internal.com/
```

### Python Packages (Poetry)
```bash
# Configure Poetry to use internal PyPI mirror
poetry config repositories.internal https://pypi.internal.com/simple/
```

### Pre-built Docker Image (Recommended)
The simplest approach: build the Docker image once on a machine with internet access, then transfer it:

```bash
# On machine with internet
docker build -t deepwiki-open:latest .
docker save deepwiki-open:latest | gzip > deepwiki-open.tar.gz

# Transfer to air-gapped environment
docker load < deepwiki-open.tar.gz
```

---

## 5. Runtime Environment Variables

Complete set for on-premise deployment:

```bash
# Required
NEXT_TELEMETRY_DISABLED=1          # Already set in Dockerfile

# LLM Provider (choose one)
OLLAMA_HOST=http://localhost:11434  # Recommended for air-gap
# OR
OPENAI_BASE_URL=https://internal-proxy/v1
OPENAI_API_KEY=your-key
# OR (vLLM — recommended for GPU servers)
VLLM_BASE_URL=http://vllm-server:8000/v1
VLLM_MODEL=your-model-name
VLLM_API_KEY=no-key-required       # Only if vLLM has auth

# Backend
SERVER_BASE_URL=http://localhost:8001
PORT=8001

# Optional: Authentication
DEEPWIKI_AUTH_MODE=code
DEEPWIKI_AUTH_CODE=your-auth-code

# Optional: Embedder (default: openai)
DEEPWIKI_EMBEDDER_TYPE=ollama      # Use ollama for fully local
# OR
DEEPWIKI_EMBEDDER_TYPE=vllm        # Use vLLM for embeddings
VLLM_EMBED_MODEL=your-embed-model

# Proxy (if behind corporate proxy)
HTTP_PROXY=http://proxy.company.com:8080
HTTPS_PROXY=http://proxy.company.com:8080
NO_PROXY=localhost,127.0.0.1,vllm-server,ollama

# SSL certificates (auto-set in Dockerfile when using CUSTOM_CERT_DIR)
# REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
# GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
```

---

## 6. Verification Checklist

After deployment, verify no unintended outbound traffic:

- [ ] Page loads without requests to `fonts.googleapis.com` or `fonts.gstatic.com`
- [ ] Slide preview works without requests to `cdn.jsdelivr.net`
- [ ] LLM calls go only to configured internal endpoints
- [ ] Git operations access only internal repositories
- [ ] `NEXT_TELEMETRY_DISABLED=1` is set
- [ ] No requests to external analytics services (none are included)

### Network Monitoring

```bash
# Monitor outbound connections from the container
docker exec <container> ss -tnp | grep ESTAB

# Or use tcpdump on the host
tcpdump -i docker0 -n 'dst net not 10.0.0.0/8 and dst net not 172.16.0.0/12 and dst net not 192.168.0.0/16'
```

---

## 7. Optional: Remove External Social Links

The main page (`src/app/page.tsx`) contains links to GitHub, BuyMeCoffee, and X (Twitter). These are `<a>` tags only (no automatic requests), but can be removed for a cleaner internal deployment by editing the file.

## 8. Optional: OpenRouter HTTP-Referer Header

If using OpenRouter, `api/openrouter_client.py` sends an `HTTP-Referer` header. Remove it if OpenRouter is not used or if this header is undesirable.
