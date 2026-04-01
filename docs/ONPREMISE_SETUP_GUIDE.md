# DeepWiki 사내 온프레미스 설정 가이드

사내 vLLM 기반 GPU 서버, 내부 인증서(CA), 프록시 환경에서 DeepWiki를 구축·운영하기 위한 단계별 설정 가이드입니다.

---

## 목차

1. [사전 요건](#1-사전-요건)
2. [네트워크 구성도](#2-네트워크-구성도)
3. [디렉토리 구조 준비](#3-디렉토리-구조-준비)
4. [Step 1: 사내 CA 인증서 설정](#4-step-1-사내-ca-인증서-설정)
5. [Step 2: 환경 변수 파일 작성](#5-step-2-환경-변수-파일-작성)
6. [Step 3: vLLM 서버 설정 및 검증](#6-step-3-vllm-서버-설정-및-검증)
7. [Step 4: 커스텀 설정 파일 구성](#7-step-4-커스텀-설정-파일-구성)
8. [Step 5: Docker 이미지 빌드](#8-step-5-docker-이미지-빌드)
9. [Step 6: Docker Compose 구성](#9-step-6-docker-compose-구성)
10. [Step 7: 서비스 기동 및 검증](#10-step-7-서비스-기동-및-검증)
11. [Step 8: 사내 Git 연동 설정](#11-step-8-사내-git-연동-설정)
12. [운영 가이드](#12-운영-가이드)
13. [트러블슈팅 체크리스트](#13-트러블슈팅-체크리스트)
14. [보안 고려사항](#14-보안-고려사항)

---

## 1. 사전 요건

### 인프라

| 항목 | 요구사항 | 비고 |
|------|---------|------|
| Docker | 20.10+ | `docker compose` (V2) 권장 |
| Docker Compose | 2.0+ | `docker-compose.yml` V3 호환 |
| vLLM 서버 | GPU 서버에 vLLM 설치 | OpenAI-compatible API 활성화 |
| 네트워크 | DeepWiki → vLLM 서버 간 통신 가능 | 포트 8000 (vLLM 기본) |
| 디스크 | 최소 20GB 여유 | `~/.adalflow/` 에 클론/인덱스 저장 |
| 메모리 | 최소 4GB (DeepWiki 컨테이너) | docker-compose에서 6GB 제한 |

### 수집해야 할 정보

배포 전에 아래 정보를 인프라/보안팀으로부터 확인하세요:

```
□ vLLM 서버 주소 및 포트         예: http://gpu-server-01.corp.local:8000
□ vLLM에 배포된 모델명            예: Qwen2.5-72B-Instruct
□ vLLM 임베딩 모델명 (선택)       예: bge-large-zh-v1.5
□ vLLM 인증 키 (설정된 경우)      예: sk-xxxx (미설정 시 불필요)
□ 사내 CA 인증서 파일             예: company-root-ca.crt
□ 프록시 서버 주소                예: http://proxy.corp.local:8080
□ 프록시 예외 호스트 목록          예: gpu-server-01,git.corp.local
□ 사내 Git 서버 주소              예: https://git.corp.local
□ 사내 Docker Registry (선택)     예: registry.corp.local
```

---

## 2. 네트워크 구성도

```
사내 네트워크
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  사용자 브라우저                                                   │
│       │                                                          │
│       │ :3000 (HTTPS/리버스 프록시 뒤)                             │
│       ▼                                                          │
│  ┌──────────────────────┐     ┌─────────────────────────────┐    │
│  │  DeepWiki 서버        │     │  vLLM GPU 서버               │    │
│  │  ┌────────────────┐  │     │                             │    │
│  │  │ Next.js (:3000)│  │     │  vLLM API (:8000)           │    │
│  │  │ (프론트엔드)     │  │     │  ├ 생성 모델                 │    │
│  │  └───────┬────────┘  │     │  │  Qwen2.5-72B-Instruct    │    │
│  │          │ rewrite    │     │  └ 임베딩 모델               │    │
│  │  ┌───────▼────────┐  │     │     bge-large-zh-v1.5       │    │
│  │  │ FastAPI (:8001)│──┼─────┼──▶ /v1/chat/completions     │    │
│  │  │ (백엔드/RAG)    │──┼─────┼──▶ /v1/embeddings           │    │
│  │  └───────┬────────┘  │     └─────────────────────────────┘    │
│  │          │            │                                       │
│  │  ┌───────▼────────┐  │     ┌─────────────────────────────┐    │
│  │  │ ~/.adalflow/   │  │     │  사내 Git 서버               │    │
│  │  │ ├ repos/       │  │     │  git.corp.local              │    │
│  │  │ ├ databases/   │  │     │  (GitHub Enterprise /        │    │
│  │  │ └ wikicache/   │  │     │   GitLab Self-Hosted)        │    │
│  │  └────────────────┘  │     └─────────────────────────────┘    │
│  └──────────────────────┘                                        │
│                                                                  │
│  ┌──────────────┐  ┌──────────────────┐                          │
│  │ 프록시 서버   │  │ 사내 CA 인증 기관 │                          │
│  │ :8080        │  │ (Root / Sub CA)   │                          │
│  └──────────────┘  └──────────────────┘                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. 디렉토리 구조 준비

```bash
deepwiki-open/
├── .env                          # 환경 변수 (Step 2에서 작성)
├── certs/                        # 사내 CA 인증서 (Step 1에서 배치)
│   ├── company-root-ca.crt
│   └── company-sub-ca.crt
├── config/                       # 커스텀 설정 파일 (Step 4에서 작성, 선택사항)
│   ├── generator.json
│   ├── embedder.json
│   └── repo.json
├── docker-compose.yml            # Step 6에서 수정
├── docker-compose.override.yml   # 사내 환경 오버라이드 (Step 6에서 생성)
└── Dockerfile
```

---

## 4. Step 1: 사내 CA 인증서 설정

### 인증서 파일 준비

사내 보안팀에서 발급받은 Root CA / Intermediate CA 인증서를 PEM 형식(`.crt` 또는 `.pem`)으로 준비합니다.

```bash
# 프로젝트 루트에 certs 디렉토리 생성
mkdir -p certs

# 인증서 복사
cp /path/to/company-root-ca.crt certs/
cp /path/to/company-sub-ca.crt certs/       # 중간 인증서가 있는 경우
```

### 인증서 유효성 확인

```bash
# PEM 형식인지 확인 (BEGIN CERTIFICATE 가 보여야 함)
head -1 certs/company-root-ca.crt
# 출력: -----BEGIN CERTIFICATE-----

# DER 형식이라면 PEM으로 변환
openssl x509 -inform DER -in cert.der -out certs/cert.crt
```

### 적용 방식

Docker 빌드 시 `CUSTOM_CERT_DIR=certs` 인수가 자동으로:
1. 인증서를 `/usr/local/share/ca-certificates/`로 복사
2. `update-ca-certificates` 실행하여 시스템 CA 번들에 통합
3. 아래 환경변수가 Dockerfile에서 자동 설정됨:

| 환경변수 | 대상 | 설정값 |
|---------|------|--------|
| `REQUESTS_CA_BUNDLE` | Python `requests` | `/etc/ssl/certs/ca-certificates.crt` |
| `SSL_CERT_FILE` | Python `ssl` 모듈 | `/etc/ssl/certs/ca-certificates.crt` |
| `CURL_CA_BUNDLE` | `curl` | `/etc/ssl/certs/ca-certificates.crt` |
| `NODE_EXTRA_CA_CERTS` | Node.js | `/etc/ssl/certs/ca-certificates.crt` |
| `GIT_SSL_CAINFO` | Git | `/etc/ssl/certs/ca-certificates.crt` |

> **참고**: 이 환경변수들은 Dockerfile에 빌드타임으로 설정되어 있어 별도 런타임 설정이 불필요합니다.

---

## 5. Step 2: 환경 변수 파일 작성

프로젝트 루트에 `.env` 파일을 생성합니다:

```bash
cat > .env << 'ENVEOF'
# ==============================================================================
# DeepWiki 온프레미스 환경 변수 설정
# ==============================================================================

# --- vLLM 서버 설정 (필수) ---
VLLM_BASE_URL=http://gpu-server-01.corp.local:8000/v1
VLLM_API_KEY=no-key-required
VLLM_MODEL=Qwen2.5-72B-Instruct

# --- 임베딩 설정 ---
# vLLM 임베딩 사용 시
DEEPWIKI_EMBEDDER_TYPE=vllm
VLLM_EMBED_MODEL=bge-large-zh-v1.5

# Ollama 임베딩 사용 시 (대안)
# DEEPWIKI_EMBEDDER_TYPE=ollama

# --- 프록시 설정 (해당 시) ---
HTTP_PROXY=http://proxy.corp.local:8080
HTTPS_PROXY=http://proxy.corp.local:8080
NO_PROXY=localhost,127.0.0.1,gpu-server-01.corp.local,git.corp.local,ollama

# --- 서버 설정 ---
PORT=8001
SERVER_BASE_URL=http://localhost:8001
LOG_LEVEL=INFO
LOG_FILE_PATH=api/logs/application.log

# --- 인증 (선택) ---
# DEEPWIKI_AUTH_MODE=true
# DEEPWIKI_AUTH_CODE=your-secret-code

# --- 커스텀 설정 디렉토리 (선택, Step 4 사용 시) ---
# DEEPWIKI_CONFIG_DIR=/app/custom-config

# --- 아래는 사내 vLLM만 사용 시 불필요 ---
# GOOGLE_API_KEY=
# OPENAI_API_KEY=
# OPENROUTER_API_KEY=

ENVEOF
```

### `.env` 파일 권한 설정

```bash
chmod 600 .env   # 소유자만 읽기/쓰기
```

---

## 6. Step 3: vLLM 서버 설정 및 검증

### vLLM 서버 기동 (GPU 서버에서)

```bash
# 생성 모델 서빙
python -m vllm.entrypoints.openai.api_server \
  --model /models/Qwen2.5-72B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.9

# 임베딩 모델을 별도 포트로 서빙 (선택)
python -m vllm.entrypoints.openai.api_server \
  --model /models/bge-large-zh-v1.5 \
  --host 0.0.0.0 \
  --port 8001 \
  --task embed
```

> 생성 모델과 임베딩 모델을 같은 vLLM 인스턴스에서 서빙할 경우 동일 `VLLM_BASE_URL`을 공유합니다.
> 별도 서버일 경우, `embedder.json`에서 `env_base_url_name`을 다른 환경변수로 지정하세요.

### DeepWiki 서버에서 vLLM 연결 검증

```bash
# 1. 네트워크 연결 확인
curl -v http://gpu-server-01.corp.local:8000/v1/models

# 2. 프록시 경유 시 NO_PROXY 동작 확인
curl --noproxy gpu-server-01.corp.local \
  http://gpu-server-01.corp.local:8000/v1/models

# 3. 생성 API 테스트
curl http://gpu-server-01.corp.local:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen2.5-72B-Instruct",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'

# 4. 임베딩 API 테스트 (임베딩 모델 사용 시)
curl http://gpu-server-01.corp.local:8000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bge-large-zh-v1.5",
    "input": "테스트 문장입니다."
  }'
```

### 예상 응답

```json
// /v1/models
{
  "data": [
    {"id": "Qwen2.5-72B-Instruct", "object": "model", ...}
  ]
}
```

---

## 7. Step 4: 커스텀 설정 파일 구성

> 기본 설정(`api/config/`)으로 충분하다면 이 단계는 건너뛰세요.
> 모델 목록, 파라미터, 필터링 규칙 등을 사내 환경에 맞게 조정할 때 사용합니다.

### 7-1. generator.json — LLM 프로바이더 설정

사내에서 vLLM만 사용할 경우, 불필요한 프로바이더를 제거하고 `default_provider`를 변경합니다:

```bash
mkdir -p config

cat > config/generator.json << 'EOF'
{
  "default_provider": "vllm",
  "providers": {
    "vllm": {
      "client_class": "OpenAIClient",
      "default_model": "${VLLM_MODEL}",
      "supportsCustomModel": true,
      "initialize_kwargs": {
        "env_base_url_name": "VLLM_BASE_URL",
        "env_api_key_name": "VLLM_API_KEY"
      },
      "models": {
        "${VLLM_MODEL}": {
          "temperature": 0.7,
          "top_p": 0.8
        }
      }
    }
  }
}
EOF
```

> **여러 모델을 서빙하는 경우**, `models` 객체에 각 모델명을 추가합니다:
> ```json
> "models": {
>   "Qwen2.5-72B-Instruct": { "temperature": 0.7, "top_p": 0.8 },
>   "Qwen2.5-7B-Instruct": { "temperature": 0.7, "top_p": 0.9 },
>   "deepseek-coder-33b": { "temperature": 0.2, "top_p": 0.95 }
> }
> ```

### 7-2. embedder.json — 임베딩 모델 설정

```bash
cat > config/embedder.json << 'EOF'
{
  "embedder_vllm": {
    "client_class": "OpenAIClient",
    "batch_size": 500,
    "initialize_kwargs": {
      "env_base_url_name": "VLLM_BASE_URL",
      "env_api_key_name": "VLLM_API_KEY"
    },
    "model_kwargs": {
      "model": "${VLLM_EMBED_MODEL}",
      "dimensions": 256,
      "encoding_format": "float"
    }
  },
  "retriever": {
    "top_k": 20
  },
  "text_splitter": {
    "split_by": "word",
    "chunk_size": 512,
    "chunk_overlap": 128
  }
}
EOF
```

> **`dimensions`**: 임베딩 모델의 출력 차원에 맞게 조정하세요.
> - `bge-large-zh-v1.5`: 1024
> - `bge-base-zh-v1.5`: 768
> - `text-embedding-3-small`: 256~1536 (지정 가능)

### 7-3. repo.json — 사내 레포 필터 설정

대용량 사내 레포에서 불필요한 파일을 제외하여 처리 속도를 높입니다:

```bash
cat > config/repo.json << 'EOF'
{
  "file_filters": {
    "excluded_dirs": [
      "./.venv/", "./venv/", "./node_modules/", "./.git/",
      "./dist/", "./build/", "./out/", "./target/",
      "./__pycache__/", "./.pytest_cache/",
      "./.idea/", "./.vscode/",
      "./docs/", "./test/", "./tests/",
      "./vendor/", "./third_party/"
    ],
    "excluded_files": [
      "*.lock", "*.min.js", "*.min.css", "*.map",
      "*.exe", "*.dll", "*.so", "*.dylib",
      "*.jar", "*.war", "*.class", "*.pyc",
      "*.zip", "*.tar", "*.gz", "*.7z",
      "*.png", "*.jpg", "*.gif", "*.svg", "*.ico",
      "*.pdf", "*.doc", "*.docx", "*.xls", "*.xlsx",
      ".env", ".env.*", "*.env"
    ]
  },
  "repository": {
    "max_size_mb": 50000
  }
}
EOF
```

### 7-4. `.env`에 커스텀 설정 디렉토리 지정

```bash
# .env 파일에 추가
echo "DEEPWIKI_CONFIG_DIR=/app/custom-config" >> .env
```

---

## 8. Step 5: Docker 이미지 빌드

### 사내 레지스트리 미러 사용 시 (에어갭 환경)

```bash
# Dockerfile의 FROM 라인을 사내 레지스트리로 변경 (필요 시)
# FROM registry.corp.local/node:20-alpine3.22 AS node_base
# FROM registry.corp.local/python:3.11-slim AS py_deps

# npm/pip도 사내 미러 설정
# npm config set registry https://npm.corp.local/
# pip config set global.index-url https://pypi.corp.local/simple/
```

### 이미지 빌드

```bash
# 사내 인증서 포함 빌드
docker build \
  --build-arg CUSTOM_CERT_DIR=certs \
  -t deepwiki-open:latest \
  .

# 빌드 확인
docker images deepwiki-open
```

### 에어갭 환경 전달

인터넷 접근 가능한 빌드 머신에서 빌드 후 이미지를 전달합니다:

```bash
# 빌드 머신에서 저장
docker save deepwiki-open:latest | gzip > deepwiki-open.tar.gz

# 운영 서버로 복사 후 로드
docker load < deepwiki-open.tar.gz
```

---

## 9. Step 6: Docker Compose 구성

`docker-compose.override.yml`을 생성하여 기본 설정을 오버라이드합니다. 기존 `docker-compose.yml`은 수정하지 않아도 됩니다.

```bash
cat > docker-compose.override.yml << 'YAMLEOF'
services:
  # vLLM만 사용 시 Ollama 비활성화 (필요에 따라)
  ollama:
    profiles:
      - ollama-only    # docker compose --profile ollama-only up 시에만 기동

  deepwiki:
    build:
      args:
        CUSTOM_CERT_DIR: certs
    environment:
      # vLLM 설정
      - VLLM_BASE_URL=${VLLM_BASE_URL}
      - VLLM_API_KEY=${VLLM_API_KEY:-no-key-required}
      - VLLM_MODEL=${VLLM_MODEL}
      - VLLM_EMBED_MODEL=${VLLM_EMBED_MODEL}
      - DEEPWIKI_EMBEDDER_TYPE=${DEEPWIKI_EMBEDDER_TYPE:-vllm}
      # 프록시 설정
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=${NO_PROXY:-localhost,127.0.0.1}
      # 커스텀 설정 (Step 4 사용 시)
      - DEEPWIKI_CONFIG_DIR=/app/custom-config
    volumes:
      - ~/.adalflow:/root/.adalflow
      - ./api/logs:/app/api/logs
      - ./config:/app/custom-config:ro     # 커스텀 설정 마운트 (Step 4 사용 시)
    depends_on: {}    # Ollama 의존성 제거 (vLLM만 사용 시)
    extra_hosts:
      # vLLM 서버 DNS 해석 불가 시 직접 매핑
      - "gpu-server-01.corp.local:10.0.1.100"
YAMLEOF
```

### 주요 결정 사항

| 결정 포인트 | 옵션 A | 옵션 B |
|------------|--------|--------|
| Ollama 사용 여부 | 사용 (임베딩용) → `depends_on` 유지, `profiles` 제거 | 미사용 (vLLM 전용) → `profiles`로 비활성화 |
| 임베딩 프로바이더 | vLLM (`DEEPWIKI_EMBEDDER_TYPE=vllm`) | Ollama (`DEEPWIKI_EMBEDDER_TYPE=ollama`) |
| 설정 파일 | 커스텀 (`DEEPWIKI_CONFIG_DIR`) | 기본 (`api/config/`) |
| 메모리 제한 | 기본 6GB | 대규모 레포 시 `mem_limit: 12g`으로 조정 |

---

## 10. Step 7: 서비스 기동 및 검증

### 기동

```bash
# vLLM 전용 모드 (Ollama 없이)
docker compose up -d

# Ollama도 함께 사용 시
docker compose --profile ollama-only up -d
```

### 기동 상태 확인

```bash
# 컨테이너 상태
docker compose ps

# 로그 확인
docker compose logs -f deepwiki

# 헬스체크
curl http://localhost:8001/health
# 응답: {"status": "healthy", ...}
```

### 기능 검증 체크리스트

```bash
# 1. 프론트엔드 접속 확인
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
# 응답: 200

# 2. 모델 설정 API 확인 (vLLM 프로바이더가 보이는지)
curl http://localhost:8001/models/config | python3 -m json.tool | grep -A5 vllm

# 3. vLLM 연결 테스트 (컨테이너 내부에서)
docker compose exec deepwiki curl http://gpu-server-01.corp.local:8000/v1/models

# 4. SSL 인증서 확인 (컨테이너 내부)
docker compose exec deepwiki python3 -c "
import ssl, certifi
ctx = ssl.create_default_context()
print(f'CA file: {ctx.ca_certs_count} certificates loaded')
print(f'Verify mode: {ctx.verify_mode}')
"

# 5. 프록시 설정 확인 (컨테이너 내부)
docker compose exec deepwiki env | grep -iE 'proxy|no_proxy'

# 6. Git 클론 테스트 (사내 Git 서버)
docker compose exec deepwiki git ls-remote https://git.corp.local/team/sample-repo.git HEAD
```

### 전체 흐름 검증

1. 브라우저에서 `http://localhost:3000` 접속
2. 설정 아이콘 클릭 → Provider에서 **vllm** 선택
3. 사내 Git 레포 URL 입력 (예: `https://git.corp.local/team/sample-repo`)
4. Wiki 생성 시작 → vLLM 서버에서 스트리밍 응답 확인

---

## 11. Step 8: 사내 Git 연동 설정

### GitHub Enterprise

```
Repository URL: https://github.corp.local/org/repo
Platform: github
Access Token: ghp_xxxxxxxxxxxx (Personal Access Token)
```

### GitLab Self-Hosted

```
Repository URL: https://gitlab.corp.local/group/repo
Platform: gitlab
Access Token: glpat-xxxxxxxxxxxx (Personal Access Token, read_repository 권한)
```

### Bitbucket Server

```
Repository URL: https://bitbucket.corp.local/projects/PROJ/repos/repo
Platform: bitbucket
Access Token: xxxxxxxx (HTTP Access Token)
```

### Git 프록시/인증서 설정 (컨테이너 내 자동 적용)

Dockerfile에서 `GIT_SSL_CAINFO` 환경변수가 설정되어 있어, 사내 CA로 서명된 Git 서버에 대한 SSL 검증이 자동으로 처리됩니다. `HTTP_PROXY`/`HTTPS_PROXY` 환경변수도 Git에 자동 적용됩니다.

---

## 12. 운영 가이드

### 로그 관리

```bash
# 실시간 로그 확인
docker compose logs -f deepwiki --since 5m

# 로그 파일 위치 (호스트)
ls -la ./api/logs/application.log

# 로그 레벨 변경 (재시작 필요)
# .env 에서 LOG_LEVEL=DEBUG 로 변경 후
docker compose restart deepwiki
```

### 데이터 관리

```bash
# 저장 데이터 확인
du -sh ~/.adalflow/repos/       # 클론된 레포
du -sh ~/.adalflow/databases/   # FAISS 인덱스
du -sh ~/.adalflow/wikicache/   # 위키 캐시

# 특정 레포 캐시 삭제
rm -rf ~/.adalflow/repos/<owner>/<repo>
rm -rf ~/.adalflow/databases/<owner>/<repo>
rm -rf ~/.adalflow/wikicache/<owner>/<repo>

# 전체 초기화 (주의)
# rm -rf ~/.adalflow/
```

### 업데이트

```bash
# 소스 업데이트
git pull origin main

# 이미지 재빌드
docker build --build-arg CUSTOM_CERT_DIR=certs -t deepwiki-open:latest .

# 롤링 재시작
docker compose up -d --build
```

### 리소스 모니터링

```bash
# 컨테이너 리소스 사용량
docker stats deepwiki-open-deepwiki-1

# 디스크 사용량
df -h ~/.adalflow/
```

---

## 13. 트러블슈팅 체크리스트

### 연결 오류

| 증상 | 확인 사항 | 해결 방법 |
|------|----------|----------|
| `Connection refused` to vLLM | vLLM 서버 기동 여부 | `curl $VLLM_BASE_URL/models` 직접 확인 |
| `Connection refused` to vLLM (Docker 내부) | 네트워크 접근 | `extra_hosts` 설정 또는 Docker 네트워크 확인 |
| `Connection timeout` | 프록시 경유 여부 | `NO_PROXY`에 vLLM 호스트 추가 |
| `Name resolution failed` | DNS 해석 | `extra_hosts`에 IP 매핑 추가 |

### SSL 오류

| 증상 | 확인 사항 | 해결 방법 |
|------|----------|----------|
| `CERTIFICATE_VERIFY_FAILED` | 인증서 설치 여부 | `docker exec <c> ls /usr/local/share/ca-certificates/` |
| `SSL: CERTIFICATE_VERIFY_FAILED` (Python) | `REQUESTS_CA_BUNDLE` | `docker exec <c> python3 -c "import ssl; print(ssl.get_default_verify_paths())"` |
| Git SSL 오류 | `GIT_SSL_CAINFO` | `docker exec <c> git config --global --list \| grep ssl` |

### 모델 오류

| 증상 | 확인 사항 | 해결 방법 |
|------|----------|----------|
| `Model not found` | 모델명 불일치 | `curl $VLLM_BASE_URL/models`로 정확한 모델명 확인 |
| 임베딩 실패 | 임베딩 모델 미배포 | vLLM에 `--task embed`로 서빙 중인지 확인 |
| 느린 응답 | GPU 리소스 | `nvidia-smi`로 GPU 사용률 확인 |
| `context length exceeded` | 긴 입력 | vLLM 시작 시 `--max-model-len` 증가 |

### 프록시 오류

| 증상 | 확인 사항 | 해결 방법 |
|------|----------|----------|
| 외부 Git 클론 실패 | 프록시 설정 | `HTTP_PROXY`, `HTTPS_PROXY` 확인 |
| 내부 vLLM에 프록시 경유 | NO_PROXY 미설정 | `NO_PROXY`에 vLLM 호스트 추가 |
| aiohttp 프록시 미적용 | 라이브러리 동작 | `trust_env=True` 확인 (기본값) |

### 진단 명령어 모음

```bash
# 컨테이너 내부 셸 접속
docker compose exec deepwiki bash

# 환경변수 전체 확인
env | sort

# Python SSL 경로 확인
python3 -c "import ssl; print(ssl.get_default_verify_paths())"

# vLLM 연결 테스트 (Python)
python3 -c "
from openai import OpenAI
import os
c = OpenAI(base_url=os.getenv('VLLM_BASE_URL'), api_key='test')
print(c.models.list())
"

# 네트워크 연결 확인
curl -v $VLLM_BASE_URL/models 2>&1 | head -30

# DNS 확인
getent hosts gpu-server-01.corp.local
```

---

## 14. 보안 고려사항

### 네트워크

- [ ] DeepWiki → vLLM 간 통신은 사내망으로 제한 (방화벽 규칙)
- [ ] 외부 인터넷 접근이 불필요하면 아웃바운드 트래픽 차단
- [ ] `NO_PROXY` 설정으로 내부 통신이 프록시를 거치지 않도록 확인
- [ ] 리버스 프록시(Nginx 등) 뒤에 배치하여 HTTPS 적용 권장

### 인증/인가

- [ ] `DEEPWIKI_AUTH_MODE=true` + `DEEPWIKI_AUTH_CODE` 설정으로 위키 생성 제한
- [ ] Git 액세스 토큰은 최소 권한 (read-only) 부여
- [ ] `.env` 파일 권한을 `600`으로 제한

### 데이터

- [ ] `~/.adalflow/` 디렉토리 접근 권한 제한 (클론된 소스코드 포함)
- [ ] 로그 파일에 민감 정보 미포함 확인 (`LOG_LEVEL=INFO` 이상 권장)
- [ ] 주기적으로 불필요한 레포 캐시 정리

### 컨테이너

- [ ] Docker 이미지에 불필요한 도구(ssh, telnet 등) 미포함 확인
- [ ] 컨테이너를 non-root 사용자로 실행 (필요 시 Dockerfile 수정)
- [ ] 리소스 제한 (`mem_limit`, `cpus`) 설정으로 리소스 고갈 방지
