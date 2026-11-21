#!/usr/bin/env bash
# Health/status helper untuk agent WARP tunggal.
#   healthcheck.sh            -> tabel status
#   healthcheck.sh --quick    -> exit 0 kalau tunnel menjawab (docker healthcheck)
#   healthcheck.sh --json     -> isi state.json mentah

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
STATE_FILE="$STATE_DIR/state.json"
SOCKS_PORT="${SOCKS_PORT:-25344}"
HEALTH_URL="${HEALTH_URL:-https://api.ipify.org}"

proxy_ip() {
    curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        "$HEALTH_URL" 2>/dev/null
}

MODE="${1:-table}"

if [ "$MODE" = "--quick" ]; then
    [ -n "$(proxy_ip)" ] && exit 0
    exit 1
fi

if [ "$MODE" = "--json" ]; then
    cat "$STATE_FILE" 2>/dev/null || echo '{}'
    exit 0
fi

st_get() {
    [ -f "$STATE_FILE" ] || { echo "none"; return; }
    jq -r --arg k "$1" '.[$k] // "none"' "$STATE_FILE" 2>/dev/null || echo "none"
}

LIVE="$(proxy_ip)"
CD="$(st_get cooldown_until)"
CD_HUMAN="-"
if [ "$CD" != "none" ] && [ "$CD" -gt "$(date +%s)" ] 2>/dev/null; then
    CD_HUMAN="$(date -d "@$CD" '+%H:%M:%S')"
fi

echo "status        : $(st_get status)"
echo "identity      : $(st_get identity)"
echo "ip (state)    : $(st_get ip)"
echo "ip (live)     : ${LIVE:-MATI}"
echo "leak          : $(st_get leak)"
echo "cooldown      : $CD_HUMAN"
echo "registered    : $(st_get registered)"
echo "last ok       : $(st_get last_ok)"
echo "last rotate   : $(st_get last_rotate_reason)"
