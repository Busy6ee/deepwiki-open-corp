# DeepWiki-Open: vLLM On-Premise Deployment Guide

This guide covers deploying DeepWiki-Open with a vLLM-based inference server in on-premise environments, including configurations for internal CA certificates and proxy servers.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   On-Premise Network                │
│                                                     │
│  ┌─────────┐    ┌──────────────┐    ┌────────────┐  │
│  │ Browser  │───▶│  DeepWiki    │───▶│ vLLM       │  │
│  │          │    │  (Next.js +  │    │ Server     │  │
│  │          │    │   FastAPI)   │    │ (OpenAI    │  │
│  │          │    │  :3000/:8001 │    │ compatible)│  │
│  └─────────┘    └──────┬───────┘    └────────────┘  │
│                        │                            │
│                   ┌────▼─────┐                      │
│                   │ Internal │                      │
│                   │ Git Host │                      │
│                   └──────────┘                      │
│                                                     │
│  ┌──────────────┐           ┌──────────────────┐    │
│  │ Proxy Server │           │ Internal CA Cert │    │
│  │ (optional)   │           │ Authority        │    │
│  └──────────────┘           └──────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

## 1. vLLM Server Setup

### 1-1. Starting vLLM

vLLM serves models via an OpenAI-compatible API endpoint:

```bash
# Basic vLLM launch
python -m vllm.entrypoints.openai.api_server \
  --model /path/to/model \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2

# With Docker
docker run --gpus all \
  -v /path/to/models:/models \
  -p 8000:8000 \
  vllm/vllm-openai:latest \
  --model /models/your-model \
  --tensor-parallel-size 2
```

### 1-2. Verify vLLM is Running

```bash
# List available models
curl http://vllm-server:8000/v1/models

# Test completion
curl http://vllm-server:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### 1-3. Embedding Model (Optional)

If you serve an embedding model on vLLM for RAG:

```bash
python -m vllm.entrypoints.openai.api_server \
  --model /path/to/embedding-model \
  --host 0.0.0.0 \
  --port 8001 \
  --task embed
```

> **Note:** If the generation and embedding models share the same vLLM server, the same `VLLM_BASE_URL` applies to both. If they are on separate servers, you can override `VLLM_EMBED_BASE_URL` separately in `embedder.json`.

---

## 2. DeepWiki Configuration

### 2-1. Environment Variables

Create a `.env` file or set environment variables:

```bash
# === vLLM Provider Settings ===
VLLM_BASE_URL=http://vllm-server:8000/v1        # vLLM OpenAI-compatible endpoint
VLLM_API_KEY=no-key-required                      # vLLM typically doesn't require auth (set if configured)
VLLM_MODEL=your-model-name                        # Model name as registered in vLLM

# === Embedder Settings ===
DEEPWIKI_EMBEDDER_TYPE=vllm                        # Use vLLM for embeddings too
VLLM_EMBED_MODEL=your-embedding-model              # Embedding model name in vLLM

# === Proxy Settings (if applicable) ===
HTTP_PROXY=http://proxy.company.com:8080
HTTPS_PROXY=http://proxy.company.com:8080
NO_PROXY=localhost,127.0.0.1,vllm-server,git.company.com

# === Internal CA Certificate ===
# These are automatically set in the Dockerfile when using CUSTOM_CERT_DIR,
# but can be overridden here if needed:
# REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
# GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt

# === Backend ===
SERVER_BASE_URL=http://localhost:8001
PORT=8001
```

### 2-2. Generator Config (Optional Override)

The default `api/config/generator.json` includes a `vllm` provider. To customize models:

```json
{
  "default_provider": "vllm",
  "providers": {
    "vllm": {
      "client_class": "OpenAIClient",
      "default_model": "your-model-name",
      "supportsCustomModel": true,
      "initialize_kwargs": {
        "env_base_url_name": "VLLM_BASE_URL",
        "env_api_key_name": "VLLM_API_KEY"
      },
      "models": {
        "your-model-name": {
          "temperature": 0.7,
          "top_p": 0.8
        }
      }
    }
  }
}
```

Use `DEEPWIKI_CONFIG_DIR` to point to a custom config directory:

```bash
DEEPWIKI_CONFIG_DIR=/path/to/custom/config
```

### 2-3. Embedder Config (Optional Override)

If using vLLM for embeddings, the default `embedder.json` includes `embedder_vllm`. To customize:

```json
{
  "embedder_vllm": {
    "client_class": "OpenAIClient",
    "batch_size": 500,
    "initialize_kwargs": {
      "env_base_url_name": "VLLM_BASE_URL",
      "env_api_key_name": "VLLM_API_KEY"
    },
    "model_kwargs": {
      "model": "your-embedding-model",
      "dimensions": 256,
      "encoding_format": "float"
    }
  }
}
```

---

## 3. Internal CA Certificate Setup

### 3-1. Docker Build with Custom Certificates

Place your internal CA certificate(s) (`.crt` or `.pem`) in a `certs/` directory at the project root:

```
deepwiki-open/
├── certs/
│   ├── company-root-ca.crt
│   └── company-intermediate-ca.crt
├── Dockerfile
└── ...
```

Build with custom certificates:

```bash
docker build --build-arg CUSTOM_CERT_DIR=certs -t deepwiki-open:latest .
```

The Dockerfile automatically:
1. Copies certificates to `/usr/local/share/ca-certificates/`
2. Runs `update-ca-certificates` to update the system CA bundle
3. Sets environment variables (`REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`) to point to the system CA bundle

### 3-2. Runtime Certificate Mount (Alternative)

If you prefer not to rebuild the image:

```yaml
# docker-compose.yml
services:
  deepwiki:
    volumes:
      - /path/to/company-ca.crt:/usr/local/share/ca-certificates/company-ca.crt:ro
    environment:
      - REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
      - SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      - NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/company-ca.crt
```

> **Note:** With runtime mount, you need to run `update-ca-certificates` inside the container or point `REQUESTS_CA_BUNDLE` directly to the mounted cert file.

---

## 4. Proxy Server Configuration

### 4-1. Environment Variables

All HTTP clients used in DeepWiki (`requests`, `aiohttp`, OpenAI SDK, `git`) respect standard proxy environment variables:

```bash
HTTP_PROXY=http://proxy.company.com:8080
HTTPS_PROXY=http://proxy.company.com:8080
NO_PROXY=localhost,127.0.0.1,vllm-server,internal-git.company.com
```

### 4-2. Important `NO_PROXY` entries

Ensure local services bypass the proxy:

| Service | Hostname to exclude |
|---------|-------------------|
| vLLM server | `vllm-server` (or actual hostname) |
| DeepWiki backend | `localhost`, `127.0.0.1` |
| Internal Git | `git.company.com` |
| Ollama (if used) | `ollama`, `localhost` |

### 4-3. Git Proxy Configuration

Git clone operations automatically use `HTTP_PROXY`/`HTTPS_PROXY`. For more specific control:

```bash
# Inside Dockerfile or container
git config --global http.proxy http://proxy.company.com:8080
git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt
```

---

## 5. Docker Compose (Complete Example)

```yaml
services:
  deepwiki:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        CUSTOM_CERT_DIR: certs
    ports:
      - "8001:8001"
      - "3000:3000"
    env_file:
      - .env
    environment:
      - PORT=8001
      - NODE_ENV=production
      - SERVER_BASE_URL=http://localhost:8001
      # vLLM configuration
      - VLLM_BASE_URL=http://vllm-server:8000/v1
      - VLLM_API_KEY=no-key-required
      - VLLM_MODEL=your-model-name
      - VLLM_EMBED_MODEL=your-embedding-model
      - DEEPWIKI_EMBEDDER_TYPE=vllm
      # Proxy (if needed)
      - HTTP_PROXY=http://proxy.company.com:8080
      - HTTPS_PROXY=http://proxy.company.com:8080
      - NO_PROXY=localhost,127.0.0.1,vllm-server
    volumes:
      - ~/.adalflow:/root/.adalflow
      - ./api/logs:/app/api/logs
    extra_hosts:
      - "vllm-server:10.0.1.100"   # Map hostname to internal IP if needed
```

---

## 6. Using vLLM in the UI

1. Open DeepWiki at `http://localhost:3000`
2. Click the configuration (gear) icon
3. Select **vllm** as the Provider
4. The model field will show the default model from `VLLM_MODEL`
5. You can also type a custom model name (if `supportsCustomModel` is `true`)

If `default_provider` is set to `"vllm"` in `generator.json`, it will be selected automatically.

---

## 7. Troubleshooting

### Connection Refused to vLLM

```
Error with vLLM API: Connection refused
```

- Verify `VLLM_BASE_URL` is reachable: `curl $VLLM_BASE_URL/models`
- Check `NO_PROXY` includes the vLLM hostname
- If using Docker, ensure the vLLM server is accessible from the container network (use `extra_hosts` or Docker network)

### SSL Certificate Errors

```
SSL: CERTIFICATE_VERIFY_FAILED
```

- Ensure custom certificates are installed: `docker exec <container> ls /usr/local/share/ca-certificates/`
- Verify CA bundle: `docker exec <container> python -c "import ssl; print(ssl.get_default_verify_paths())"`
- Check env vars: `docker exec <container> env | grep -E 'SSL|CERT|CA'`

### Model Not Found

```
Error: Model 'xxx' not found
```

- List models on vLLM: `curl $VLLM_BASE_URL/models`
- Ensure `VLLM_MODEL` matches the model name exactly as served by vLLM
- Note: vLLM uses the model path as the model name by default (e.g., `/models/Qwen2.5-72B-Instruct` → `Qwen2.5-72B-Instruct`)

### Proxy Blocks vLLM Traffic

- Ensure vLLM hostname is in `NO_PROXY`
- Test direct connection: `curl --noproxy vllm-server http://vllm-server:8000/v1/models`

### Embedding Errors with vLLM

- Verify the embedding model supports the OpenAI embeddings API: `curl $VLLM_BASE_URL/embeddings -d '{"model":"your-embed-model","input":"test"}'`
- Some models require `--task embed` flag when starting vLLM

---

## 8. Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VLLM_BASE_URL` | Yes | — | vLLM server OpenAI-compatible endpoint (e.g., `http://host:8000/v1`) |
| `VLLM_API_KEY` | No | `no-key-required` | API key if vLLM has auth enabled |
| `VLLM_MODEL` | Yes | — | Default generation model name |
| `VLLM_EMBED_MODEL` | If using vLLM embedder | — | Embedding model name |
| `DEEPWIKI_EMBEDDER_TYPE` | No | `openai` | Set to `vllm` for vLLM embeddings |
| `HTTP_PROXY` | If behind proxy | — | HTTP proxy URL |
| `HTTPS_PROXY` | If behind proxy | — | HTTPS proxy URL |
| `NO_PROXY` | If behind proxy | — | Comma-separated hosts to bypass proxy |
| `REQUESTS_CA_BUNDLE` | Auto-set in Docker | System CA | Python `requests` CA bundle path |
| `SSL_CERT_FILE` | Auto-set in Docker | System CA | Python `ssl` module CA path |
| `NODE_EXTRA_CA_CERTS` | Auto-set in Docker | — | Node.js additional CA certs |
| `GIT_SSL_CAINFO` | Auto-set in Docker | System CA | Git SSL CA info path |
| `CUSTOM_CERT_DIR` | No | `certs` | Docker build arg for custom CA certificates directory |
| `DEEPWIKI_CONFIG_DIR` | No | `api/config/` | Path to custom JSON config directory |
