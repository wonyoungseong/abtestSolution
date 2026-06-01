#!/usr/bin/env bash
# ============================================================
#  Cloudflare named tunnel 자동 구성 스크립트
#  사용 전제: `cloudflared tunnel login` 을 먼저 1회 실행(브라우저 인증)
#  사용법:
#    ./cloudflared/setup-tunnel.sh <FRONT_HOSTNAME> <API_HOSTNAME> [TUNNEL_NAME]
#  예:
#    ./cloudflared/setup-tunnel.sh gb.example.com gb-api.example.com abtest
# ============================================================
set -euo pipefail

FRONT_HOST="${1:?front hostname 필요 (예: gb.example.com)}"
API_HOST_NAME="${2:?api hostname 필요 (예: gb-api.example.com)}"
TUNNEL_NAME="${3:-abtest}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_DIR="$REPO_DIR/cloudflared"
CONFIG="$CF_DIR/config.yml"

# 1) 터널 생성 (이미 있으면 재사용)
if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
  echo "[=] 터널 '$TUNNEL_NAME' 이미 존재 — 재사용"
else
  echo "[+] 터널 '$TUNNEL_NAME' 생성"
  cloudflared tunnel create "$TUNNEL_NAME"
fi

TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}')"
echo "[=] TUNNEL_ID=$TUNNEL_ID"

# 자격증명 파일 위치 확인 (~/.cloudflared/<id>.json)
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
[ -f "$CRED_FILE" ] || { echo "자격증명 파일 없음: $CRED_FILE"; exit 1; }

# 2) config.yml 작성 (ingress: front->3000, api->3100)
cat > "$CONFIG" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  # 127.0.0.1 명시 (localhost=::1 IPv6 로 두면 포트 점유한 다른 앱에 붙을 수 있음)
  - hostname: ${FRONT_HOST}
    service: http://127.0.0.1:3000
  - hostname: ${API_HOST_NAME}
    service: http://127.0.0.1:3100
  - service: http_status:404
EOF
echo "[+] config 작성: $CONFIG"

# 3) DNS 라우트 (CNAME -> 터널)
# 주의: 전역 ~/.cloudflared/config.yml 의 tunnel: 값이 우선 적용되는 버그 방지 위해
#       반드시 --config(이 repo config) + UUID 명시 + --overwrite-dns 사용
cloudflared --config "$CONFIG" tunnel route dns --overwrite-dns "$TUNNEL_ID" "$FRONT_HOST"
cloudflared --config "$CONFIG" tunnel route dns --overwrite-dns "$TUNNEL_ID" "$API_HOST_NAME"
echo "[+] DNS 라우트 완료: $FRONT_HOST, $API_HOST_NAME"

# 4) .env 의 APP_ORIGIN / API_HOST 갱신
ENV_FILE="$REPO_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  sed -i.bak -E "s#^APP_ORIGIN=.*#APP_ORIGIN=https://${FRONT_HOST}#" "$ENV_FILE"
  sed -i.bak -E "s#^API_HOST=.*#API_HOST=https://${API_HOST_NAME}#" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
  echo "[+] .env 갱신: APP_ORIGIN=https://${FRONT_HOST}  API_HOST=https://${API_HOST_NAME}"
fi

echo
echo "다음 단계:"
echo "  1) docker compose up -d   (APP_ORIGIN/API_HOST 반영 위해 재기동)"
echo "  2) cloudflared tunnel --config $CONFIG run $TUNNEL_NAME"
echo "  3) Zero Trust 대시보드에서 Access 정책(이메일 허용) 설정"
