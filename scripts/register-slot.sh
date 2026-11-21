#!/usr/bin/env bash
# Register a fresh WARP device for slot N and start wireproxy on its port.
# Usage: register-slot.sh <slot-index>
#
# HARD REQUIREMENT: every slot must end up with a DISTINCT WireGuard identity.
# If two slots share a peer key, Cloudflare kicks one of them on every
# handshake and both flap forever. So this script:
#   1. isolates wgcf's state per slot (HOME + cwd + config dir)
#   2. validates the generated key pair is unique across the pool
#   3. retries with backoff when registration is rate limited
#   4. never reuses a config whose identity collides with another slot

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

IDX="${1:?usage: register-slot.sh <slot-index>}"
DIR="$(slot_dir "$IDX")"
PORT="$(slot_port "$IDX")"
PROFILE="$DIR/wgcf-account.toml"
CONF="$DIR/wireproxy.conf"

mkdir -p "$DIR"

# wgcf writes ./wgcf-account.toml into the CURRENT DIRECTORY (not $HOME),
# so we must cd into the slot dir or every slot fights over /app.
cd "$DIR" || { err "slot $IDX: cannot enter $DIR"; exit 1; }
# Also isolate HOME and XDG config so wgcf can never pick up another slot's
# cached account from a shared location.
export HOME="$DIR"
export XDG_CONFIG_HOME="$DIR/.config"
export XDG_CACHE_HOME="$DIR/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# Peer key currently used by every OTHER slot, so we can reject duplicates.
other_keys() {
    local i other
    for (( i=0; i<POOL_SIZE; i++ )); do
        [ "$i" -eq "$IDX" ] && continue
        other="$(slot_dir "$i")/wgcf-profile.conf"
        [ -f "$other" ] || continue
        awk -F' = ' '/^PublicKey/{print $2}' "$other"
    done
}

profile_pubkey() {
    local f="$1"
    [ -f "$f" ] || return 1
    awk -F' = ' '/^PublicKey/{print $2}' "$f"
}

log "slot $IDX: registering WARP device (port $PORT)"

ATTEMPT=0
MAX_ATTEMPTS="${REGISTER_ATTEMPTS:-4}"

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$(( ATTEMPT + 1 ))

    rm -rf "$DIR/wgcf-account.toml" "$DIR/wgcf-profile.conf" \
           "$DIR/.config/wgcf" "$DIR/.cache/wgcf" 2>/dev/null || true

    log "slot $IDX: register attempt $ATTEMPT/$MAX_ATTEMPTS"

    if ! wgcf register --accept-tos >"$DIR/register.log" 2>&1; then
        err "slot $IDX: wgcf register failed (attempt $ATTEMPT)"
        tail -5 "$DIR/register.log" >&2 || true
        sleep "$(( 20 * ATTEMPT ))"
        continue
    fi

    if ! wgcf generate >"$DIR/generate.log" 2>&1; then
        err "slot $IDX: wgcf generate failed (attempt $ATTEMPT)"
        tail -5 "$DIR/generate.log" >&2 || true
        sleep "$(( 10 * ATTEMPT ))"
        continue
    fi

    PROFILE_SRC="$DIR/wgcf-profile.conf"
    if [ ! -f "$PROFILE_SRC" ]; then
        err "slot $IDX: profile not generated (attempt $ATTEMPT)"
        tail -8 "$DIR/register.log" >&2 2>/dev/null || true
        tail -8 "$DIR/generate.log" >&2 2>/dev/null || true
        sleep "$(( 10 * ATTEMPT ))"
        continue
    fi

    # --- identity collision check -------------------------------------
    MY_KEY="$(profile_pubkey "$PROFILE_SRC")"
    if [ -z "$MY_KEY" ]; then
        err "slot $IDX: generated profile has no PublicKey"
        sleep "$(( 10 * ATTEMPT ))"
        continue
    fi

    COLLISION=""
    while read -r k; do
        [ -z "$k" ] && continue
        if [ "$k" = "$MY_KEY" ]; then
            COLLISION="$k"
            break
        fi
    done < <(other_keys)

    if [ -n "$COLLISION" ]; then
        err "slot $IDX: identity collides with another slot (${MY_KEY:0:12}...), retrying"
        rm -f "$PROFILE_SRC" "$DIR/wgcf-account.toml"
        # Longer pause: Cloudflare rate limits registration per source IP.
        sleep "$(( 30 * ATTEMPT ))"
        continue
    fi

    # --- build the wireproxy config -----------------------------------
    PRIV_KEY="$(awk -F' = ' '/^PrivateKey/{print $2}' "$PROFILE_SRC")"
    PEER_PUB="$(awk -F' = ' '/^PublicKey/{print $2}' "$PROFILE_SRC")"
    ENDPOINT="$(awk -F' = ' '/^Endpoint/{print $2}' "$PROFILE_SRC")"
    ADDR_V4="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE_SRC" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' | head -1)"
    ADDR_V6="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE_SRC" | grep -oE '([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:]+(/[0-9]+)?' | head -1)"

    MISSING=""
    for v in PRIV_KEY PEER_PUB ENDPOINT ADDR_V4; do
        [ -z "${!v}" ] && MISSING="$MISSING $v"
    done
    if [ -n "$MISSING" ]; then
        err "slot $IDX: cannot parse$MISSING from profile"
        cat "$PROFILE_SRC" >&2
        exit 1
    fi

    {
        echo "[Interface]"
        echo "Address = $ADDR_V4"
        [ -n "$ADDR_V6" ] && echo "Address = $ADDR_V6"
        echo "PrivateKey = $PRIV_KEY"
        echo "DNS = 1.1.1.1"
        echo
        echo "[Peer]"
        echo "PublicKey = $PEER_PUB"
        echo "Endpoint = $ENDPOINT"
        echo "AllowedIPs = 0.0.0.0/0, ::/0"
        echo
        echo "[Socks5]"
        echo "BindAddress = 0.0.0.0:$PORT"
    } > "$CONF"

    chmod 600 "$CONF"

    STATE="$DIR/state.json"
    [ -f "$STATE" ] || echo '{}' > "$STATE"
    jq --arg port "$PORT" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
       --arg key "${MY_KEY:0:12}" \
       '.slot = "'"$IDX"'" | .port = $port | .status = "starting" | .created = $ts
        | .ip = "none" | .identity = $key | .cooldown_until = "none"' \
       "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

    log "slot $IDX: identity ${MY_KEY:0:12}... unique, wireproxy config written, starting on :$PORT"
    exec wireproxy -c "$CONF"
done

err "slot $IDX: gave up after $MAX_ATTEMPTS registration attempts"
st_set "$IDX" status "dead"
exit 1
