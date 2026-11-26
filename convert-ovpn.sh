#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Cách dùng: $0 <file-goc.ovpn> [file-dich.ovpn]"
  exit 1
fi

INPUT="$1"
OUTPUT="${2:-$(dirname "$0")/custom.ovpn}"

if [ ! -f "$INPUT" ]; then
  echo "Lỗi: Không tìm thấy file '$INPUT'"
  exit 1
fi

TMP_FILE=$(mktemp)
IN_BLOCK=0
HAS_AUTH=0
HAS_DATA_CIPHERS=0
EXTERNAL_FILES=()

if grep -qE '^[[:space:]]*data-ciphers[[:space:]]' "$INPUT"; then
  HAS_DATA_CIPHERS=1
fi

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"

  # Giữ nguyên nội dung trong các khối chứng chỉ (<ca>, <cert>, <key>, <tls-auth>...)
  if [[ "$line" =~ ^[[:space:]]*\<[a-zA-Z0-9_-]+\>[[:space:]]*$ ]]; then
    IN_BLOCK=1
    echo "$line" >> "$TMP_FILE"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*\</[a-zA-Z0-9_-]+\>[[:space:]]*$ ]]; then
    IN_BLOCK=0
    echo "$line" >> "$TMP_FILE"
    continue
  fi
  if [ "$IN_BLOCK" -eq 1 ]; then
    echo "$line" >> "$TMP_FILE"
    continue
  fi

  # 1. Đổi tên miền trong dòng 'remote' sang IPv4
  if [[ "$line" =~ ^[[:space:]]*remote[[:space:]]+([^[:space:]]+)([[:space:]]+.*)?$ ]]; then
    host="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ip=$(dig +short "$host" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
      if [ -n "$ip" ]; then
        echo "Đã đổi remote: $host -> $ip"
        echo "remote ${ip}${rest}" >> "$TMP_FILE"
      else
        echo "Cảnh báo: Không phân giải được IP cho '$host', giữ nguyên dòng gốc." >&2
        echo "$line" >> "$TMP_FILE"
      fi
    else
      echo "$line" >> "$TMP_FILE"
    fi
    continue
  fi

  # 2. Chuẩn hóa dòng auth-user-pass
  if [[ "$line" =~ ^[[:space:]]*auth-user-pass([[:space:]]+.*)?$ ]]; then
    HAS_AUTH=1
    echo "auth-user-pass" >> "$TMP_FILE"
    continue
  fi

  # 3. Chuyển cipher cũ sang data-ciphers + data-ciphers-fallback cho OpenVPN 2.6+/2.7+
  if [[ "$line" =~ ^[[:space:]]*cipher[[:space:]]+([^[:space:]]+) ]]; then
    alg="${BASH_REMATCH[1]}"
    echo "# [converted-for-openvpn-2.7] $line" >> "$TMP_FILE"
    if [ "$HAS_DATA_CIPHERS" -eq 0 ]; then
      echo "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:${alg}" >> "$TMP_FILE"
      echo "data-ciphers-fallback ${alg}" >> "$TMP_FILE"
      HAS_DATA_CIPHERS=1
      echo "Đã chuyển cipher '$alg' sang data-ciphers và data-ciphers-fallback"
    fi
    continue
  fi

  # 4. Comment các directive lỗi thời hoặc gây lỗi trong Docker/Gluetun
  if [[ "$line" =~ ^[[:space:]]*(block-outside-dns|setenv[[:space:]]+opt[[:space:]]+block-outside-dns|up[[:space:]]|down[[:space:]]|script-security[[:space:]]|route-nopull|register-dns|persist-key)([[:space:]]|$) ]]; then
    echo "# [disabled-for-gluetun] $line" >> "$TMP_FILE"
    continue
  fi

  # 5. Phát hiện chứng chỉ dùng file rời
  if [[ "$line" =~ ^[[:space:]]*(ca|cert|key|tls-auth|tls-crypt)[[:space:]]+([^[:space:]]+) ]]; then
    EXTERNAL_FILES+=("${BASH_REMATCH[1]} -> ${BASH_REMATCH[2]}")
  fi

  echo "$line" >> "$TMP_FILE"
done < "$INPUT"

if [ "$HAS_AUTH" -eq 0 ]; then
  sed -i '' '1i\
auth-user-pass
' "$TMP_FILE"
fi

mv "$TMP_FILE" "$OUTPUT"
chmod 600 "$OUTPUT"

echo "---"
echo "Hoàn tất! File mới đã được lưu tại: $OUTPUT"

if [ ${#EXTERNAL_FILES[@]} -gt 0 ]; then
  echo "Cảnh báo: Phát hiện chứng chỉ dùng file rời (cần copy vào thư mục này và mount trong docker-compose.yml):"
  printf '  - %s\n' "${EXTERNAL_FILES[@]}"
fi
