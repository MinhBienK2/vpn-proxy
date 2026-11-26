#!/bin/bash

cd "$(dirname "$0")" || exit 1

REFRESH_INTERVAL=3300   # 55 phút (chủ động refresh trước mốc 3600s của OpenVPN)
CHECK_INTERVAL=15       # Kiểm tra trạng thái mỗi 15 giây
MAX_FAILS=3
FAIL_COUNT=0
LAST_REFRESH=0

if [ ! -f .env ]; then
  echo "Lỗi: Không tìm thấy file .env"
  exit 1
fi

set -a
source .env
set +a

if [ -z "$OPENVPN_BASE_PASSWORD" ]; then
  echo "Lỗi: Chưa khai báo OPENVPN_BASE_PASSWORD trong .env"
  exit 1
fi

get_otp() {
  if [ -n "$OTP_AUTH_URI" ]; then
    python3 - "$OTP_AUTH_URI" << 'PYEOF'
import base64, hashlib, hmac, struct, sys, time, urllib.parse

raw = sys.argv[1].strip()
if raw.startswith("otpauth://"):
    parsed = urllib.parse.urlparse(raw)
    params = urllib.parse.parse_qs(parsed.query)
    secret = params["secret"][0]
    digits = int(params.get("digits", ["6"])[0])
    period = int(params.get("period", ["30"])[0])
    algo_name = params.get("algorithm", ["SHA1"])[0].upper()
else:
    secret, digits, period, algo_name = raw, 6, 30, "SHA1"

secret = secret.strip().replace(" ", "").upper()
pad = len(secret) % 8
if pad:
    secret += "=" * (8 - pad)

algos = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}
digestmod = algos.get(algo_name, hashlib.sha1)

rem = period - (int(time.time()) % period)
if rem < 5:
    print(f"Mã OTP sắp hết hạn ({rem}s), đang chờ mã mới...", file=sys.stderr)
    time.sleep(rem + 1)

key = base64.b32decode(secret, casefold=True)
counter = int(time.time()) // period
h = hmac.new(key, struct.pack(">Q", counter), digestmod).digest()
offset = h[-1] & 0x0F
code = (struct.unpack(">I", h[offset:offset + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
print(f"{code:0{digits}d}")
PYEOF
  else
    read -r -p "Nhập mã OTP: " MANUAL_OTP
    echo "$MANUAL_OTP"
  fi
}

connect_vpn() {
  echo "[$(date '+%H:%M:%S')] $1"
  OTP=$(get_otp)
  if [ -z "$OTP" ]; then
    echo "[$(date '+%H:%M:%S')] Lỗi: Không lấy được mã OTP"
    return 1
  fi

  export OPENVPN_PASSWORD="${OPENVPN_BASE_PASSWORD}${OTP}"
  if docker compose up -d --force-recreate; then
    LAST_REFRESH=$(date +%s)
    return 0
  else
    echo "[$(date '+%H:%M:%S')] Lỗi khi chạy docker compose up"
    return 1
  fi
}

trap 'echo ""; echo "Đã dừng tự động refresh (container vẫn đang chạy nền). Gõ \"docker compose stop\" để tắt hẳn VPN."; exit 0' INT TERM

connect_vpn "Đang khởi động VPN..." || exit 1

# Nếu không có OTP_AUTH_URI thì chỉ chạy 1 lần và mở log như cũ
if [ -z "$OTP_AUTH_URI" ]; then
  docker logs -f vpn-proxy
  exit 0
fi

echo "[$(date '+%H:%M:%S')] Đang theo dõi VPN (tự refresh mỗi ${REFRESH_INTERVAL}s). Nhấn Ctrl + C để dừng."
sleep 20

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_REFRESH))

  # 1. Chủ động refresh trước mốc 3600s
  if [ "$ELAPSED" -ge "$REFRESH_INTERVAL" ]; then
    if connect_vpn "Đã chạy ${ELAPSED}s (gần mốc 3600s), đang sinh OTP mới và refresh VPN..."; then
      FAIL_COUNT=0
    fi
    sleep 20
    continue
  fi

  # 2. Dự phòng: tự nối lại nếu VPN rớt bất ngờ trước mốc 55 phút
  STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' vpn-proxy 2>/dev/null || echo "stopped")
  HAS_AUTH_FAIL=$(docker logs --since 25s vpn-proxy 2>&1 | grep -c "AUTH_FAILED" || true)

  if [ "$HAS_AUTH_FAIL" -gt 0 ] || [ "$STATUS" = "unhealthy" ] || [ "$STATUS" = "stopped" ] || [ "$STATUS" = "exited" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[$(date '+%H:%M:%S')] Phát hiện VPN rớt (status=$STATUS, auth_fail=$HAS_AUTH_FAIL) - Lần thử $FAIL_COUNT/$MAX_FAILS"

    if [ "$FAIL_COUNT" -gt "$MAX_FAILS" ]; then
      echo "[$(date '+%H:%M:%S')] Lỗi quá $MAX_FAILS lần liên tiếp. Đang dừng container để tránh khóa tài khoản!"
      docker compose stop
      exit 1
    fi

    connect_vpn "Đang sinh OTP mới và kết nối lại..."
    sleep 20
  else
    if [ "$STATUS" = "healthy" ]; then
      FAIL_COUNT=0
    fi
    sleep "$CHECK_INTERVAL"
  fi
done

