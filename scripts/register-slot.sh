#!/usr/bin/env bash
# Register a fresh WARP device for slot N and start wireproxy on its port.
# Usage: register-slot.sh <slot-index>

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

log "slot $IDX: registering WARP device (port $PORT)"

# wgcf needs a writable HOME for its config dir
export HOME="$DIR"

rm -f "$PROFILE" "$DIR/wgcf-profile.conf"

if ! wgcf register --accept-tos >"$DIR/register.log" 2>&1; then
    err "slot $IDX: wgcf register failed"
    tail -5 "$DIR/register.log" >&2 || true
    exit 1
fi

if ! wgcf generate >"$DIR/generate.log" 2>&1; then
    err "slot $IDX: wgcf generate failed"
    tail -5 "$DIR/generate.log" >&2 || true
    exit 1
fi

PROFILE_SRC="$DIR/wgcf-profile.conf"
[ -f "$PROFILE_SRC" ] || { err "slot $IDX: profile not generated"; exit 1; }

# Translate the WireGuard profile into a wireproxy config with a SOCKS5 listener.
PRIV_KEY="$(awk -F' = ' '/^PrivateKey/{print $2}' "$PROFILE_SRC")"
PEER_PUB="$(awk -F' = ' '/^PublicKey/{print $2}' "$PROFILE_SRC")"
ENDPOINT="$(awk -F' = ' '/^Endpoint/{print $2}' "$PROFILE_SRC")"
ADDR_V4="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE_SRC" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' | head -1)"
ADDR_V6="$(awk -F' = ' '/^Address/{print $2}' "$PROFILE_SRC" | grep -oE '([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:]+(/[0-9]+)?' | head -1)"

for v in PRIV_KEY PEER_PUB ENDPOINT ADDR_V4; do
    if [ -z "${!v}" ]; then
        err "slot $IDX: cannot parse $v from profile"
        cat "$PROFILE_SRC" >&2
        exit 1
    fi
done

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

slot_set "$IDX" port "$PORT"
slot_set "$IDX" status "starting"
slot_set "$IDX" created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
slot_set "$IDX" ip "none"
slot_set "$IDX" restarts "0"

log "slot $IDX: wireproxy config written, starting on :$PORT"
exec wireproxy -c "$CONF"
