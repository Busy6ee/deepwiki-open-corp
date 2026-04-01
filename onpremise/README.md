# DeepWiki 사내 온프레미스 설정 가이드

vLLM 기반 GPU 서버 + 내부 Ollama 임베딩 + 사내 인증서/프록시 환경에서
**소스코드 수정 없이** DeepWiki를 운영하기 위한 설정 가이드입니다.

---

## 핵심 원리

vLLM은 OpenAI-compatible API를 제공하므로, DeepWiki의 기존 `openai` 프로바이더를 그대로 사용합니다.
코드 수정이 없으므로 upstream pull 시 충돌이 발생하지 않습니다.

| 기능 | 방식 | 설정 위치 |
|------|------|----------|
| LLM 생성 | `openai` 프로바이더 + `OPENAI_BASE_URL=vLLM주소` | `.env` |
| 임베딩 | 기존 Ollama (`DEEPWIKI_EMBEDDER_TYPE=ollama`) | `.env` |
| 모델 목록 | `DEEPWIKI_CONFIG_DIR`로 커스텀 `generator.json` | `onpremise/config/` |
| 사내 인증서 | `CUSTOM_CERT_DIR` 빌드 인수 (기존 지원) | `onpremise/certs/` |
| 프록시 | 환경변수 (`HTTP_PROXY`, `HTTPS_PROXY`) | `.env` |
| Docker 오버라이드 | `docker-compose.override.yml` (자동 병합) | 프로젝트 루트 |

---

## 디렉토리 구조

```
deepwiki-open/                    # upstream 소스 (수정하지 않음)
├── docker-compose.yml            # 원본 (수정하지 않음)
├── docker-compose.override.yml   # ← onpremise/에서 복사 (gitignore됨)
├── .env                          # ← onpremise/.env.example에서 복사
│
└── onpremise/                    # 사내 설정 전용 디렉토리
    ├── README.md                 # 이 파일
    ├── .env.example              # 환경변수 템플릿
    ├── docker-compose.override.yml  # 오버라이드 템플릿
    ├── config/
    │   └── generator.json        # vLLM 모델만 포함된 커스텀 설정
    └── certs/
        └── (사내 CA 인증서 배치)
```

---

## 설정 순서

### 1. 사내 CA 인증서 배치

```bash
cp /path/to/company-root-ca.crt onpremise/certs/
cp /path/to/company-sub-ca.crt onpremise/certs/    # 중간 인증서 있으면
```

### 2. 환경변수 파일 생성

```bash
cp onpremise/.env.example .env
```

`.env`를 사내 환경에 맞게 수정:

```bash
# 핵심 설정 3가지만 수정하면 됨
OPENAI_BASE_URL=http://gpu-server-01.corp.local:8000/v1   # vLLM 서버 주소
OPENAI_API_KEY=dummy-key-for-vllm                          # 아무 값 (빈 값 불가)
HTTP_PROXY=http://proxy.corp.local:8080                    # 프록시 주소
```

### 3. 모델 설정 (선택)

`onpremise/config/generator.json`에서 vLLM에 배포된 모델명을 설정합니다:

```json
{
  "default_provider": "openai",
  "providers": {
    "openai": {
      "default_model": "Qwen2.5-72B-Instruct",
      "supportsCustomModel": true,
      "models": {
        "Qwen2.5-72B-Instruct": {
          "temperature": 0.7,
          "top_p": 0.8
        }
      }
    }
  }
}
```

> `supportsCustomModel: true`이므로 UI에서 모델명 직접 입력도 가능합니다.

### 4. Docker Compose 오버라이드 복사

```bash
cp onpremise/docker-compose.override.yml docker-compose.override.yml
```

> `docker-compose.override.yml`은 `docker compose`가 자동으로 `docker-compose.yml`과 병합합니다.
> 원본 파일을 수정하지 않으므로 `git pull` 시 충돌이 없습니다.

### 5. 빌드 및 기동

```bash
# 사내 인증서 포함 빌드 + 기동
docker compose up -d --build

# 로그 확인
docker compose logs -f deepwiki
```

### 6. 검증

```bash
# 헬스체크
curl http://localhost:8001/health

# 모델 설정 확인 (openai 프로바이더에 vLLM 모델이 보이는지)
curl -s http://localhost:8001/models/config | python3 -m json.tool

# 컨테이너 내부에서 vLLM 연결 확인
docker compose exec deepwiki curl $OPENAI_BASE_URL/models

# 브라우저에서 http://localhost:3000 접속
# → Provider: openai 선택 → 모델: Qwen2.5-72B-Instruct
# → 사내 Git 레포 URL 입력 → Wiki 생성
```

---

## vLLM 서버 설정

### 기동 명령 (GPU 서버에서)

```bash
python -m vllm.entrypoints.openai.api_server \
  --model /models/Qwen2.5-72B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 4 \
  --max-model-len 32768
```

### 연결 확인 (DeepWiki 서버에서)

```bash
# 모델 목록
curl http://gpu-server-01.corp.local:8000/v1/models

# 생성 테스트
curl http://gpu-server-01.corp.local:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen2.5-72B-Instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| `OPENAI_API_KEY must be set` | `.env`에 `OPENAI_API_KEY` 미설정 | `OPENAI_API_KEY=dummy` 설정 (빈 값 불가) |
| `Connection refused` to vLLM | 네트워크/DNS | `NO_PROXY`에 vLLM 호스트 추가, `extra_hosts` 설정 |
| `CERTIFICATE_VERIFY_FAILED` | 사내 인증서 미설치 | `onpremise/certs/`에 인증서 배치 후 재빌드 |
| `Model not found` | 모델명 불일치 | `curl $OPENAI_BASE_URL/models`로 정확한 이름 확인 |
| UI에 Google만 보임 | 커스텀 설정 미적용 | `DEEPWIKI_CONFIG_DIR` 확인, 볼륨 마운트 확인 |
| Git clone 실패 | 프록시/인증서 | `HTTP_PROXY`, `GIT_SSL_CAINFO` 환경변수 확인 |

### 진단 명령어

```bash
# 컨테이너 환경변수 전체 확인
docker compose exec deepwiki env | sort | grep -iE 'openai|proxy|ssl|cert|config'

# Python에서 vLLM 연결 테스트
docker compose exec deepwiki python3 -c "
from openai import OpenAI
import os
c = OpenAI(base_url=os.getenv('OPENAI_BASE_URL'), api_key=os.getenv('OPENAI_API_KEY'))
print(c.models.list())
"
```

---

## upstream 업데이트 방법

```bash
git pull origin main              # 충돌 없음 (코어 파일 미수정)
docker compose up -d --build      # 재빌드
```

`docker-compose.override.yml`과 `.env`는 gitignore되어 있으므로 pull에 영향받지 않습니다.
