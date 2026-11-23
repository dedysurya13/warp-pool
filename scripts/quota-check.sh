#!/usr/bin/env bash
# Cek kuota bucket gratis lewat tunnel WARP, tanpa menyentuh agent.
#   quota-check.sh          -> status kuota lewat SOCKS
#   quota-check.sh direct   -> status kuota tanpa proxy (IP asli)
#
# Exit: 0 = masih boleh, 2 = 429 habis, 3 = 401/403, 1 = error lain.
#
# Catatan: tiap run memakai 1 token dari bucket gratis. Jangan di-loop rapat.

set -uo pipefail

MODE="${1:-proxy}"
SOCKS_PORT="${SOCKS_PORT:-25344}"
QUOTA_URL="${QUOTA_URL:-https://opencode.ai/inference/openai/v1/chat/completions}"
QUOTA_MODEL="${QUOTA_MODEL:-deepseek-v4.1-flash-free}"

if [ "$MODE" = "direct" ]; then
    PROXY_ARGS=()
    LABEL="IP asli (tanpa proxy)"
else
    PROXY_ARGS=(--socks5-hostname "127.0.0.1:$SOCKS_PORT")
    LABEL="lewat WARP :$SOCKS_PORT"
fi

ANON="Bearer $(printf 'pub%s' 'lic')"
BODY="$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' "$QUOTA_MODEL")"

OUT="$(mktemp)"
CODE="$(curl -s -o "$OUT" -w '%{http_code}' --max-time 40 "${PROXY_ARGS[@]}" \
    "$QUOTA_URL" \
    -A "opencode/latest/1.0.0/cli" \
    -H "Authorization: $ANON" \
    -H "x-opencode-client: cli" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>/dev/null)"

echo "target : $LABEL"
echo "model  : $QUOTA_MODEL"
echo "http   : ${CODE:-000}"

case "${CODE:-000}" in
    2*)  echo "hasil  : OK — kuota masih boleh"; rm -f "$OUT"; exit 0 ;;
    429) echo "hasil  : HABIS — 429"; sed -n '1p' "$OUT" | head -c 300; echo
         rm -f "$OUT"; exit 2 ;;
    401|403)
         echo "hasil  : DITOLAK — $CODE"; sed -n '1p' "$OUT" | head -c 300; echo
         rm -f "$OUT"; exit 3 ;;
    *)
         echo "hasil  : ERROR — ${CODE:-no response}"; sed -n '1p' "$OUT" | head -c 300; echo
         rm -f "$OUT"; exit 1 ;;
esac
