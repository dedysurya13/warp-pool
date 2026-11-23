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
#   4. probe kuota: cek apakah service target menolak (429)
#   5. gagal tunnel -> rotate; 429 -> rotate HANYA kalau ROTATE_ON_429=1
#
# State (/data/state.json):
#   registering | starting | healthy | quota | rotating | failed
#
# Trigger rotate manual: `docker exec warp touch /data/warp/rotate.req`

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
STATE_FILE="$STATE_DIR/state.json"
DIR="$STATE_DIR/warp"
CONF="$DIR/wireproxy.conf"
PROFILE="$DIR/wgcf-profile.conf"
SOCKS_PORT="${SOCKS_PORT:-25344}"
HEALTH_URL="${HEALTH_URL:-https://api.ipify.org}"

# Probe kuota: POST 1 token ke endpoint model gratis. Ini SATU-SATUNYA cara
# tahu service sudah menolak (429) — probe ke halaman depan opencode.ai
# selalu 200, jadi 429 tidak pernah kelihatan (bug lama).
QUOTA_URL="${QUOTA_URL:-https://opencode.ai/inference/openai/v1/chat/completions}"
QUOTA_MODEL="${QUOTA_MODEL:-deepseek-v4.1-flash-free}"
QUOTA_CHECK_INTERVAL="${QUOTA_CHECK_INTERVAL:-300}"
QUOTA_ENABLED="${QUOTA_ENABLED:-1}"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
REGISTER_RETRY_DELAY="${REGISTER_RETRY_DELAY:-30}"
REGISTER_429_DELAY="${REGISTER_429_DELAY:-300}"
MAX_REGISTER_ATTEMPTS="${MAX_REGISTER_ATTEMPTS:-5}"

# Rotate saat 429? Default 0: limit kuota gratis opencode diikat ke
# identitas/project anonim, BUKAN ke IP, jadi ganti IP tidak membuka limit.
ROTATE_ON_429="${ROTATE_ON_429:-0}"
MIN_ROTATE_GAP="${MIN_ROTATE_GAP:-120}"
ROTATE_FLAG="$DIR/rotate.req"

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
LAST_QUOTA_CHECK=0

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

# Pin endpoint WARP ke IPv4.
#
# wireproxy menerima hostname dan bisa memilih hasil AAAA. Container yang
# tidak punya route IPv6 akan: tetap LISTEN di port SOCKS, tapi handshake
# WireGuard tidak pernah jadi -> setiap CONNECT balas SOCKS error 4
# ("host unreachable"). Gejalanya persis seperti proxy mati padahal port
# terbuka. Diuji: hostname gagal, 162.159.192.1:2408 berhasil.
resolve_endpoint_v4() {
    local ep="$1" host port ip
    host="${ep%:*}"
    port="${ep##*:}"

    # Sudah berupa literal IPv4 -> pakai apa adanya.
    if printf '%s' "$host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        printf '%s' "$ep"
        return 0
    fi

    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$ip" ]; then
        printf '%s:%s' "$ip" "$port"
        return 0
    fi

    printf '%s' "$ep"
}

# Exit IP through the SOCKS listener, empty string on failure.
proxy_ip() {
    curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        "$HEALTH_URL" 2>/dev/null
}

direct_ip() {
    curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null
}

# 0 = kuota masih boleh, 2 = 429 (habis), 3 = 401/403, 1 = lain/tidak jelas
quota_status() {
    local code anon body
    # Token anonim opencode dirakit supaya tidak perlu ditulis literal.
    anon="Bearer $(printf 'pub%s' 'lic')"
    body="$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "$QUOTA_MODEL")"

    code="$(curl -s -o "$DIR/quota-probe.json" -w '%{http_code}' --max-time 40 \
        --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$QUOTA_URL" \
        -A "opencode/latest/1.0.0/cli" \
        -H "Authorization: $anon" \
        -H "x-opencode-client: cli" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null)"

    case "$code" in
        2*)    return 0 ;;
        429)   return 2 ;;
        401|403) return 3 ;;
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
    local priv peer endpoint addr4 addr6 delay

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
            # Simpan sebabnya di state supaya kelihatan dari healthcheck,
            # tanpa perlu masuk container buat baca log.
            st_set last_register_error "$(tail -1 "$DIR/register.log" 2>/dev/null | cut -c1-160)"
            delay="$REGISTER_RETRY_DELAY"
            # Cloudflare membatasi registrasi per IP. Kalau kena 429,
            # ngulang tiap 30 detik cuma nambah hitungan -> tunggu lama.
            if grep -qi "429\|rate limit\|too many" "$DIR/register.log" 2>/dev/null; then
                delay="$REGISTER_429_DELAY"
                log "register: kena rate limit Cloudflare, tunggu ${delay}s"
                st_set register_limited "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            fi
            attempt=$(( attempt + 1 ))
            sleep "$delay"
            continue
        fi

        priv="$(awk -F' = ' '/^PrivateKey/{print $2}' "$PROFILE")"
        peer="$(awk -F' = ' '/^PublicKey/{print $2}' "$PROFILE")"
        endpoint="$(awk -F' = ' '/^Endpoint/{print $2}' "$PROFILE")"
        addr4="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE" | grep -oE '([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]+)?' | head -1)"
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
            echo "Endpoint = $(resolve_endpoint_v4 "$endpoint")"
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
            echo
            echo "[Socks5]"
            echo "BindAddress = 0.0.0.0:$SOCKS_PORT"
        } > "$CONF"
        chmod 600 "$CONF"

        st_set identity "${priv:0:12}"
        st_set endpoint "$(resolve_endpoint_v4 "$endpoint")"
        st_set registered "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        log "register: device identity ${priv:0:12}... peer ${peer:0:12}... endpoint $(resolve_endpoint_v4 "$endpoint")"
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
    local now last age gap

    now="$(date +%s)"
    last="$(st_get last_rotate_ts)"
    [ "$last" = "none" ] && last=0
    gap="$MIN_ROTATE_GAP"
    age=$(( now - last ))

    if [ "$age" -lt "$gap" ]; then
        log "rotate: ditunda ${gap}s (baru ${age}s lalu) — alasan: $reason"
        sleep $(( gap - age ))
    fi

    log "rotate: $reason"
    st_set status "rotating"
    st_set last_rotate_reason "$reason"
    st_set last_rotate_ts "$(date +%s)"
    st_set ip "none"
    st_set quota "unknown"

    stop_tunnel
    rm -f "$CONF" "$PROFILE" "$DIR/wgcf-account.toml"

    if ! register_device; then
        st_set status "failed"
        err "rotate: registration failed, backing off ${REGISTER_429_DELAY}s"
        sleep "$REGISTER_429_DELAY"
        return 1
    fi

    start_tunnel
    return 0
}

# 0 = usable, 1 = rotate tunnel, 2 = kuota habis (429), 3 = diblokir
verify() {
    local ip dir_ip rc now

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

    [ "$QUOTA_ENABLED" = "1" ] || return 0

    # Probe kuota dibatasi intervalnya: tiap probe MEMAKAN 1 token dari
    # bucket gratis, jadi jangan tiap 60 detik.
    now="$(date +%s)"
    if [ $(( now - LAST_QUOTA_CHECK )) -lt "$QUOTA_CHECK_INTERVAL" ]; then
        return 0
    fi
    LAST_QUOTA_CHECK="$now"

    quota_status
    rc=$?
    st_set quota_checked "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    case "$rc" in
        0) st_set quota "ok";   return 0 ;;
        2) st_set quota "429";  return 2 ;;
        3) st_set quota "403";  return 3 ;;
        *) st_set quota "error"; return 0 ;;
    esac
}

# ------------------------------------------------------------------ boot
log "agent: boot — socks5 :$SOCKS_PORT quota-probe=$QUOTA_ENABLED rotate-on-429=$ROTATE_ON_429"

if [ ! -f "$CONF" ]; then
    if ! register_device; then
        st_set status "failed"
        err "agent: cannot register at boot, exiting for restart"
        exit 1
    fi
else
    # Migrasi: conf lama masih memakai hostname di Endpoint. Ganti ke IPv4
    # supaya tunnel tidak mati di container tanpa route IPv6.
    EP_OLD="$(awk -F' = ' '/^Endpoint/{print $2}' "$CONF")"
    if [ -n "$EP_OLD" ] && printf '%s' "$EP_OLD" | grep -qE '[A-Za-z]'; then
        EP_NEW="$(resolve_endpoint_v4 "$EP_OLD")"
        if [ "$EP_NEW" != "$EP_OLD" ]; then
            sed -i "s|^Endpoint = .*|Endpoint = $EP_NEW|" "$CONF"
            log "boot: endpoint $EP_OLD -> $EP_NEW (pin IPv4)"
            st_set endpoint "$EP_NEW"
        fi
    fi
fi

start_tunnel

# ------------------------------------------------------------- main loop
BACKOFF="$CHECK_INTERVAL"
while true
do
    # Trigger rotate manual: file dibuat dari luar container.
    if [ -f "$ROTATE_FLAG" ]; then
        rm -f "$ROTATE_FLAG"
        log "agent: rotate diminta lewat flag file"
        rotate "manual request"
        sleep "$CHECK_INTERVAL"
        continue
    fi

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
        # Kuota habis. Ganti IP hampir selalu sia-sia: limit diikat ke
        # identitas anonim, bukan IP. Jadi default-nya DIAM, cuma catat.
        until_ts=$(( $(date +%s) + COOLDOWN_SECONDS ))
        st_set status "quota"
        st_set cooldown_until "$until_ts"
        log "agent: kuota target habis (429), cooldown sampai $(date -d "@$until_ts" '+%H:%M:%S')"
        if [ "$ROTATE_ON_429" = "1" ]; then
            rotate "target 429 (ROTATE_ON_429=1)"
        else
            sleep "$CHECK_INTERVAL"
        fi

    elif [ "$RC" -eq 3 ]; then
        st_set status "blocked"
        log "agent: target menolak identitas (401/403), rotate"
        rotate "target 401/403"
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
