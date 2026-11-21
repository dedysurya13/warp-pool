#!/usr/bin/env bash
# WARP single-proxy agent.
#
# Filosofi: satu identitas WARP, satu tunnel, satu IP. Kalau tunnel tidak
# bisa dipakai -> buang, register ulang, nyalakan lagi. Tidak ada pool,
# tidak ada rebutan identitas, tidak ada slot flapping.
#
# Alur:
#   1. pastikan ada konfigurasi wireproxy (register kalau belum ada)
#   2. jalankan wireproxy di background
#   3. probe: IP keluar harus ada dan != IP asli
#   4. probe: target harus menerima (200/3xx)
#   5. gagal -> kill, buang profil, tunggu, kembali ke 1
#
# State (/data/state.json):
#   registering | starting | healthy | cooldown | rotating | failed

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
STATE_FILE="$STATE_DIR/state.json"
DIR="$STATE_DIR/warp"
CONF="$DIR/wireproxy.conf"
PROFILE="$DIR/wgcf-profile.conf"
SOCKS_PORT="${SOCKS_PORT:-25344}"
HEALTH_URL="${HEALTH_URL:-https://api.ipify.org}"
TARGET_URL="${TARGET_URL:-https://opencode.ai}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
REGISTER_RETRY_DELAY="${REGISTER_RETRY_DELAY:-30}"
MAX_REGISTER_ATTEMPTS="${MAX_REGISTER_ATTEMPTS:-5}"

mkdir -p "$DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

st_set() {
    local key="$1" val="$2" tmp
    [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
    tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

st_get() {
    local key="$1"
    [ -f "$STATE_FILE" ] || { echo "none"; return; }
    jq -r --arg k "$key" '.[$k] // "none"' "$STATE_FILE" 2>/dev/null || echo "none"
}

WP_PID=""

cleanup() {
    log "agent: shutting down"
    if [ -n "$WP_PID" ]; then
        kill "$WP_PID" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# ---------------------------------------------------------------- probing

# Exit IP through the SOCKS listener, empty string on failure.
proxy_ip() {
    curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        "$HEALTH_URL" 2>/dev/null
}

direct_ip() {
    curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null
}

# 0 = accepted, 2 = rate limited, 3 = blocked, 1 = other/inconclusive
target_status() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$TARGET_URL" 2>/dev/null)"
    case "$code" in
        2*|3*) return 0 ;;
        429)   return 2 ;;
        403|401) return 3 ;;
        *)     return 1 ;;
    esac
}

# Wait until wireproxy answers. Prints the IP on success.
wait_ready() {
    local timeout="${1:-45}"
    local waited=0
    local ip=""
    while [ "$waited" -lt "$timeout" ]
    do
        ip="$(proxy_ip)"
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    return 1
}

# ------------------------------------------------------------- lifecycle

stop_tunnel() {
    local i
    if [ -n "$WP_PID" ]; then
        kill "$WP_PID" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10
        do
            if ! kill -0 "$WP_PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        kill -9 "$WP_PID" 2>/dev/null || true
    fi
    WP_PID=""
    pkill -f "wireproxy -c $CONF" 2>/dev/null || true
    sleep 1
}

# Register a fresh WARP device and write wireproxy.conf.
register_device() {
    local attempt=1
    local priv peer endpoint addr4 addr6

    while [ "$attempt" -le "$MAX_REGISTER_ATTEMPTS" ]
    do
        log "register: attempt $attempt/$MAX_REGISTER_ATTEMPTS"
        st_set status "registering"
        st_set attempt "$attempt"

        rm -rf "$DIR/wgcf-account.toml" "$PROFILE" "$DIR/.config" "$DIR/.cache" 2>/dev/null || true
        mkdir -p "$DIR/.config" "$DIR/.cache"

        (
            cd "$DIR" || exit 1
            export HOME="$DIR"
            export XDG_CONFIG_HOME="$DIR/.config"
            export XDG_CACHE_HOME="$DIR/.cache"
            wgcf register --accept-tos
            wgcf generate
        ) >"$DIR/register.log" 2>&1

        if [ ! -f "$PROFILE" ]; then
            err "register: no profile produced (attempt $attempt)"
            tail -6 "$DIR/register.log" >&2 2>/dev/null || true
            attempt=$(( attempt + 1 ))
            sleep "$REGISTER_RETRY_DELAY"
            continue
        fi

        priv="$(awk -F' = ' '/^PrivateKey/{print $2}' "$PROFILE")"
        peer="$(awk -F' = ' '/^PublicKey/{print $2}' "$PROFILE")"
        endpoint="$(awk -F' = ' '/^Endpoint/{print $2}' "$PROFILE")"
        addr4="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' | head -1)"
        addr6="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE" | grep -oE '([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:]+(/[0-9]+)?' | head -1)"

        if [ -z "$priv" ] || [ -z "$peer" ] || [ -z "$endpoint" ] || [ -z "$addr4" ]; then
            err "register: incomplete profile (attempt $attempt)"
            cat "$PROFILE" >&2
            attempt=$(( attempt + 1 ))
            sleep "$REGISTER_RETRY_DELAY"
            continue
        fi

        {
            echo "[Interface]"
            echo "Address = $addr4"
            if [ -n "$addr6" ]; then
                echo "Address = $addr6"
            fi
            echo "PrivateKey = $priv"
            echo "DNS = 1.1.1.1"
            echo
            echo "[Peer]"
            echo "PublicKey = $peer"
            echo "Endpoint = $endpoint"
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
            echo
            echo "[Socks5]"
            echo "BindAddress = 0.0.0.0:$SOCKS_PORT"
        } > "$CONF"
        chmod 600 "$CONF"

        st_set identity "${peer:0:12}"
        st_set registered "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        log "register: identity ${peer:0:12}... written"
        return 0
    done

    return 1
}

start_tunnel() {
    st_set status "starting"
    wireproxy -c "$CONF" >>"$DIR/wireproxy.log" 2>&1 &
    WP_PID=$!
    log "tunnel: wireproxy started (pid $WP_PID) on :$SOCKS_PORT"
}

# Tear everything down and get a brand new identity.
rotate() {
    local reason="${1:-unknown}"
    log "rotate: $reason"
    st_set status "rotating"
    st_set last_rotate_reason "$reason"
    st_set ip "none"

    stop_tunnel
    rm -f "$CONF" "$PROFILE" "$DIR/wgcf-account.toml"

    if ! register_device; then
        st_set status "failed"
        err "rotate: registration failed, backing off ${REGISTER_RETRY_DELAY}s"
        sleep "$REGISTER_RETRY_DELAY"
        return 1
    fi

    start_tunnel
    return 0
}

# 0 = usable, 1 = rotate, 2 = rate limited (cooldown)
verify() {
    local ip dir_ip

    ip="$(proxy_ip)"
    if [ -z "$ip" ]; then
        st_set ip "none"
        return 1
    fi

    dir_ip="$(direct_ip)"
    if [ -n "$dir_ip" ] && [ "$ip" = "$dir_ip" ]; then
        st_set ip "$ip"
        st_set leak "yes"
        return 1
    fi
    st_set leak "no"
    st_set ip "$ip"

    target_status
    case $? in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------ boot
log "agent: boot — socks5 :$SOCKS_PORT"

if [ ! -f "$CONF" ]; then
    if ! register_device; then
        st_set status "failed"
        err "agent: cannot register at boot, exiting for restart"
        exit 1
    fi
fi

start_tunnel

# ------------------------------------------------------------- main loop
BACKOFF="$CHECK_INTERVAL"
while true
do
    if ! kill -0 "$WP_PID" 2>/dev/null; then
        log "agent: wireproxy died, rotating"
        rotate "process exited"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    verify
    RC=$?
    if [ "$RC" -eq 0 ]; then
        st_set status "healthy"
        st_set last_ok "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        st_set cooldown_until "none"
        BACKOFF="$CHECK_INTERVAL"
        sleep "$CHECK_INTERVAL"
    elif [ "$RC" -eq 2 ]; then
        until_ts=$(( $(date +%s) + COOLDOWN_SECONDS ))
        log "agent: target rate limited, cooldown until $(date -d "@$until_ts" '+%H:%M:%S')"
        st_set status "cooldown"
        st_set cooldown_until "$until_ts"
        sleep "$CHECK_INTERVAL"
    else
        log "agent: tunnel unusable (ip=$(st_get ip) leak=$(st_get leak))"
        rotate "unusable tunnel"
        if [ "$BACKOFF" -lt 300 ]; then
            BACKOFF=$(( BACKOFF * 2 ))
        else
            BACKOFF=300
        fi
        log "agent: backing off ${BACKOFF}s before next attempt"
        sleep "$BACKOFF"
    fi
done
