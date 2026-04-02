#!/usr/bin/env bash
# ==============================================================================
# DeepWiki 온프레미스 사전 점검 스크립트
#
# docker compose up --build 전에 실행하여 설정 누락/오류를 미리 확인합니다.
# 사용법: bash onpremise/preflight-check.sh
# ==============================================================================

set -euo pipefail

# --- 색상 정의 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
WARN=0
FAIL=0

pass()  { PASS=$((PASS + 1)); echo -e "  ${GREEN}[PASS]${NC} $1"; }
warn()  { WARN=$((WARN + 1)); echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}[FAIL]${NC} $1"; }

# 프로젝트 루트로 이동
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo " DeepWiki 온프레미스 사전 점검"
echo " 프로젝트 경로: $PROJECT_ROOT"
echo "================================================"
echo ""

# ==============================================================================
# 1. 필수 도구 확인
# ==============================================================================
echo "1. 필수 도구 확인"

if command -v docker &>/dev/null; then
    pass "docker: $(docker --version | head -1)"
else
    fail "docker가 설치되어 있지 않습니다"
fi

if docker compose version &>/dev/null; then
    pass "docker compose: $(docker compose version --short 2>/dev/null || echo 'available')"
elif command -v docker-compose &>/dev/null; then
    warn "docker-compose (v1) 감지. docker compose (v2) 권장"
else
    fail "docker compose가 설치되어 있지 않습니다"
fi

if command -v curl &>/dev/null; then
    pass "curl 설치 확인"
else
    warn "curl 미설치 — vLLM 연결 테스트를 건너뜁니다"
fi

echo ""

# ==============================================================================
# 2. 필수 파일 확인
# ==============================================================================
echo "2. 필수 파일 확인"

if [ -f ".env" ]; then
    pass ".env 파일 존재"
else
    fail ".env 파일이 없습니다 → cp onpremise/.env.example .env"
fi

if [ -f "docker-compose.yml" ]; then
    pass "docker-compose.yml 존재"
else
    fail "docker-compose.yml이 없습니다"
fi

if [ -f "docker-compose.override.yml" ]; then
    pass "docker-compose.override.yml 존재"
else
    fail "docker-compose.override.yml이 없습니다 → cp onpremise/docker-compose.override.yml ."
fi

if [ -f "onpremise/config/generator.json" ]; then
    pass "onpremise/config/generator.json 존재"
else
    warn "onpremise/config/generator.json이 없습니다 — 기본 모델 설정이 사용됩니다"
fi

echo ""

# ==============================================================================
# 3. .env 필수 변수 점검
# ==============================================================================
echo "3. .env 환경변수 점검"

if [ -f ".env" ]; then
    # .env 로드 (주석/빈줄 제외)
    set -a
    while IFS='=' read -r key value; do
        # 주석과 빈줄 건너뛰기
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # 앞뒤 공백 제거
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        # 변수 설정 (기존 환경변수 우선)
        if [ -z "${!key+x}" ]; then
            export "$key=$value"
        fi
    done < .env
    set +a

    # 필수 변수 체크
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        pass "OPENAI_API_KEY 설정됨"
    else
        fail "OPENAI_API_KEY가 비어 있습니다 (vLLM 사용 시에도 dummy 값 필요)"
    fi

    if [ -n "${OPENAI_BASE_URL:-}" ]; then
        pass "OPENAI_BASE_URL=$OPENAI_BASE_URL"
        # 기본 예시 값 그대로인지 확인
        if [[ "$OPENAI_BASE_URL" == *"gpu-server-01.corp.local"* ]]; then
            warn "OPENAI_BASE_URL이 예시 값(gpu-server-01.corp.local)입니다 — 실제 vLLM 주소로 변경했는지 확인하세요"
        fi
    else
        fail "OPENAI_BASE_URL이 설정되지 않았습니다"
    fi

    if [ -n "${DEEPWIKI_EMBEDDER_TYPE:-}" ]; then
        pass "DEEPWIKI_EMBEDDER_TYPE=$DEEPWIKI_EMBEDDER_TYPE"
    else
        warn "DEEPWIKI_EMBEDDER_TYPE 미설정 — 기본값(openai) 사용됨. Ollama 임베딩 시 ollama로 설정 필요"
    fi

    if [ -n "${HTTP_PROXY:-}" ]; then
        pass "HTTP_PROXY=$HTTP_PROXY"
    else
        warn "HTTP_PROXY 미설정 — 프록시 불필요한 환경이면 무시"
    fi
else
    fail ".env 파일 없음 — 변수 점검 건너뜀"
fi

echo ""

# ==============================================================================
# 4. SSL 인증서 확인
# ==============================================================================
echo "4. SSL 인증서 확인"

SSL_CERT="${SSL_CERT_FILE:-}"
if [ -n "$SSL_CERT" ]; then
    if [ -f "$SSL_CERT" ]; then
        pass "SSL_CERT_FILE=$SSL_CERT (파일 존재)"
        # 유효한 PEM인지 간단 확인
        if head -1 "$SSL_CERT" | grep -q "BEGIN CERTIFICATE"; then
            pass "PEM 형식 확인"
        else
            warn "PEM 형식이 아닐 수 있습니다 (첫 줄: $(head -1 "$SSL_CERT"))"
        fi
    else
        fail "SSL_CERT_FILE=$SSL_CERT 파일이 존재하지 않습니다"
        echo -e "       → 인증서를 배치하거나, 불필요하면 .env에서 SSL_CERT_FILE을 비워주세요"
    fi
else
    warn "SSL_CERT_FILE 미설정 — 사내 인증서가 필요 없으면 무시"
fi

echo ""

# ==============================================================================
# 5. 호스트 디렉토리 확인
# ==============================================================================
echo "5. 호스트 볼륨 디렉토리 확인"

ADALFLOW_DIR="${HOME}/.adalflow"
if [ -d "$ADALFLOW_DIR" ]; then
    pass "$ADALFLOW_DIR 존재"
else
    warn "$ADALFLOW_DIR 없음 — 자동 생성합니다"
    mkdir -p "$ADALFLOW_DIR"
    pass "$ADALFLOW_DIR 생성 완료"
fi

LOG_DIR="$PROJECT_ROOT/api/logs"
if [ -d "$LOG_DIR" ]; then
    pass "$LOG_DIR 존재"
else
    warn "$LOG_DIR 없음 — 자동 생성합니다"
    mkdir -p "$LOG_DIR"
    pass "$LOG_DIR 생성 완료"
fi

echo ""

# ==============================================================================
# 6. Docker 데몬 상태
# ==============================================================================
echo "6. Docker 데몬 상태"

if docker info &>/dev/null; then
    pass "Docker 데몬 실행 중"
    # 디스크 여유 확인
    AVAIL_KB=$(df -k "$PROJECT_ROOT" | tail -1 | awk '{print $4}')
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    if [ "$AVAIL_GB" -ge 10 ]; then
        pass "디스크 여유: ${AVAIL_GB}GB"
    elif [ "$AVAIL_GB" -ge 5 ]; then
        warn "디스크 여유: ${AVAIL_GB}GB — Docker 빌드에 10GB 이상 권장"
    else
        fail "디스크 여유: ${AVAIL_GB}GB — 공간이 부족할 수 있습니다"
    fi
else
    fail "Docker 데몬이 실행 중이 아닙니다"
fi

echo ""

# ==============================================================================
# 7. vLLM 서버 연결 테스트 (선택)
# ==============================================================================
echo "7. vLLM 서버 연결 테스트"

VLLM_URL="${OPENAI_BASE_URL:-}"
if [ -n "$VLLM_URL" ] && command -v curl &>/dev/null; then
    MODELS_URL="${VLLM_URL%/}/models"
    echo -e "   → $MODELS_URL"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$MODELS_URL" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        pass "vLLM 서버 응답 정상 (HTTP $HTTP_CODE)"
    elif [ "$HTTP_CODE" = "000" ]; then
        warn "vLLM 서버에 연결할 수 없습니다 — 네트워크/프록시/DNS를 확인하세요"
    else
        warn "vLLM 서버 응답: HTTP $HTTP_CODE"
    fi
else
    warn "OPENAI_BASE_URL 미설정 또는 curl 없음 — vLLM 연결 테스트 건너뜀"
fi

echo ""

# ==============================================================================
# 8. docker-compose 설정 유효성
# ==============================================================================
echo "8. Docker Compose 설정 검증"

if docker compose config --quiet 2>/dev/null; then
    pass "docker compose config 유효"
else
    COMPOSE_ERR=$(docker compose config 2>&1 || true)
    fail "docker compose config 오류 — 아래 내용을 확인하세요:"
    echo "       $COMPOSE_ERR" | head -5
fi

echo ""

# ==============================================================================
# 결과 요약
# ==============================================================================
echo "================================================"
TOTAL=$((PASS + WARN + FAIL))
echo -e " 결과: ${GREEN}PASS $PASS${NC} / ${YELLOW}WARN $WARN${NC} / ${RED}FAIL $FAIL${NC}  (총 ${TOTAL}건)"
echo "================================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e ""
    echo -e " ${RED}FAIL 항목을 해결한 후 다시 실행하세요.${NC}"
    echo -e " 해결 후: docker compose up -d --build"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e ""
    echo -e " ${YELLOW}WARN 항목을 확인하세요. 환경에 따라 무시 가능합니다.${NC}"
    echo -e " 준비 완료: docker compose up -d --build"
    exit 0
else
    echo -e ""
    echo -e " ${GREEN}모든 점검 통과! 빌드를 시작하세요.${NC}"
    echo -e " 실행: docker compose up -d --build"
    exit 0
fi
