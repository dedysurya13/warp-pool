#!/usr/bin/env bash
# Shared helpers for the WARP proxy pool.
# Sourced by the other scripts — not executed directly.

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
POOL_DIR="$STATE_DIR/pool"
BASE_PORT="${BASE_PORT:-25344}"
POOL_SIZE="${POOL_SIZE:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
REGISTER_DELAY="${REGISTER_DELAY:-60}"
HEALTH_URL="${HEALTH_URL:-https://api.ipify.org}"
TARGET_URL="${TARGET_URL:-https://opencode.ai}"
MIN_HEALTHY="${MIN_HEALTHY:-2}"

mkdir -p "$POOL_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

err() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Port for slot index (0-based).
slot_port() {
    echo $(( BASE_PORT + $1 ))
}

slot_dir() {
    echo "$POOL_DIR/slot-$1"
}

# Read a field from a slot's state.json ("none" if missing).
st_get() {
    local idx="$1" key="$2" file
    file="$(slot_dir "$idx")/state.json"
    [ -f "$file" ] || { echo "none"; return; }
    jq -r --arg k "$key" '.[$k] // "none"' "$file" 2>/dev/null || echo "none"
}

# Write a field into a slot's state.json.
st_set() {
    local idx="$1" key="$2" val="$3" file tmp
    file="$(slot_dir "$idx")/state.json"
    mkdir -p "$(slot_dir "$idx")"
    [ -f "$file" ] || echo '{}' > "$file"
    tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Returns 0 if the proxy on this port answers through WARP.
proxy_alive() {
    local port="$1" ip
    ip="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$port" "$HEALTH_URL" 2>/dev/null)"
    [ -n "$ip" ] && printf '%s' "$ip"
}

# Check whether the exit IP is accepted by the target (200/3xx = ok).
target_ok() {
    local port="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        --socks5-hostname "127.0.0.1:$port" "$TARGET_URL" 2>/dev/null)"
    case "$code" in
        2*|3*) return 0 ;;
        429)   return 2 ;;   # rate limited -> cooldown
        403|401) return 3 ;; # blocked -> replace
        *)     return 1 ;;
    esac
}

notify() {
    local msg="$1"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || return 0
    [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
    curl -fsS --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
}
