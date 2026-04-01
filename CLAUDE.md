# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DeepWiki-Open is an AI-powered wiki generator for code repositories. It clones repos (GitHub/GitLab/Bitbucket), creates embeddings, and uses RAG + LLMs to generate structured documentation with Mermaid diagrams. It supports multiple LLM providers (Google, OpenAI, OpenRouter, Ollama, Azure, AWS Bedrock, DashScope).

## Common Commands

### Frontend (Next.js)
```bash
npm run dev          # Dev server with Turbopack on port 3000
npm run build        # Production build
npm run lint         # ESLint (next/core-web-vitals + next/typescript)
```

### Backend (Python/FastAPI)
```bash
poetry install -C api            # Install dependencies
python -m api.main               # Start API server on port 8001
```

### Testing
```bash
python tests/run_tests.py             # All tests
python tests/run_tests.py --unit      # Unit tests only
python tests/run_tests.py --integration
python tests/run_tests.py --api
pytest tests/unit/test_specific.py    # Single test file
```
Pytest markers: `unit`, `integration`, `slow`, `network`. Test path is `test/`.

### Docker
```bash
docker-compose up
```

## Architecture

**Two-process system**: Next.js frontend (port 3000) + FastAPI backend (port 8001). The frontend proxies API calls to the backend via Next.js rewrites configured in `next.config.ts`.

### Backend (`api/`)
- `main.py` — Uvicorn entry point
- `api.py` — FastAPI route definitions (REST + WebSocket endpoints)
- `websocket_wiki.py` — WebSocket streaming for wiki generation
- `data_pipeline.py` — Repository cloning, file indexing, embedding creation
- `rag.py` — RAG conversation management with FAISS retrieval
- `simple_chat.py` — Chat/Q&A handling
- `prompts.py` — LLM prompt templates
- `config.py` — Configuration loading with `${ENV_VAR}` substitution from JSON configs
- Provider clients: `openai_client.py`, `google_embedder_client.py`, `openrouter_client.py`, `azureai_client.py`, `bedrock_client.py`, `dashscope_client.py`, `ollama_patch.py`
- `tools/embedder.py` — Embedder factory/selector
- `config/generator.json` — Model provider configurations
- `config/embedder.json` — Embedding model configs (model, dimensions, chunk size)
- `config/repo.json` — File/directory exclusion filters for repo indexing

### Frontend (`src/`)
- `app/page.tsx` — Main wiki generation UI
- `app/[owner]/[repo]/page.tsx` — Wiki viewing page for a specific repo
- `app/api/` — Next.js API routes (auth, chat streaming, model config)
- `components/Ask.tsx` — RAG-powered Q&A interface
- `components/Mermaid.tsx` — Diagram rendering
- `components/Markdown.tsx` — Markdown renderer with code highlighting
- `components/ConfigurationModal.tsx` — Model/embedder settings UI
- `contexts/LanguageContext.tsx` — i18n provider (10 languages)
- `messages/` — Localization string files

### Data Flow
1. User submits repo URL via frontend
2. Backend clones repo, indexes files, creates embeddings (stored in `~/.adalflow/`)
3. WebSocket streams wiki content back using RAG + selected LLM
4. Frontend renders Markdown + Mermaid diagrams

### Storage
All persistent data lives in `~/.adalflow/`: cloned repos (`repos/`), FAISS indexes (`databases/`), wiki cache (`wikicache/`).

## Key Environment Variables

- `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` — LLM provider keys
- `DEEPWIKI_EMBEDDER_TYPE` — "openai" (default), "google", "ollama", "bedrock"
- `SERVER_BASE_URL` — Backend URL for frontend rewrites (default: `http://localhost:8001`)
- `PORT` — API server port (default: 8001)
- `DEEPWIKI_AUTH_MODE` / `DEEPWIKI_AUTH_CODE` — Optional auth protection
- `OLLAMA_HOST` — Local Ollama server (default: `http://localhost:11434`)

## Code Conventions

- Backend uses Python 3.11+, managed with Poetry (`api/pyproject.toml`)
- Frontend uses TypeScript with Next.js 15, React 19, Tailwind CSS 4
- ESLint config: `next/core-web-vitals` + `next/typescript` (flat config in `eslint.config.mjs`)
- Use `Exception` not bare `except:` in Python (enforced by recent fix)
- LLM provider configs are JSON-driven (`api/config/`), not hardcoded
