#!/bin/sh
# Render a privoxy config for this container only, then exec privoxy.
# Each container owns its config and its port — nothing is shared.
# Retries the SOCKS probe until the upstream is reachable, so a slow WARP
# handshake never leaves us with a dead front-end.

set -eu

LISTEN_PORT="${LISTEN_PORT:?LISTEN_PORT is required}"
SOCKS_HOST="${SOCKS_HOST:-warp}"
SOCKS_PORT="${SOCKS_PORT:?SOCKS_PORT is required}"

CONF="/tmp/privoxy.conf"

cat > "$CONF" <<EOF
# managed by entrypoint.sh — do not edit inside the container
listen-address 0.0.0.0:${LISTEN_PORT}
forward-socks5t / ${SOCKS_HOST}:${SOCKS_PORT} .
confdir /etc/privoxy
EOF

echo "[privoxy] http :${LISTEN_PORT} -> socks5 ${SOCKS_HOST}:${SOCKS_PORT}"

# Informational only: privoxy itself reconnects per request, so a failing
# probe at boot is not fatal.
i=0
while [ "$i" -lt 12 ]; do
    if nc -z -w 3 "$SOCKS_HOST" "$SOCKS_PORT" 2>/dev/null; then
        echo "[privoxy] upstream reachable"
        break
    fi
    i=$(( i + 1 ))
    sleep 5
done
[ "$i" -ge 12 ] && echo "[privoxy] WARNING: upstream still unreachable, starting anyway"

exec privoxy --no-daemon "$CONF"
