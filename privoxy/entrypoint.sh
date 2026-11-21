#!/bin/sh
# Render a privoxy config for this container only, then exec privoxy.
# Each container owns its config and its port — nothing is shared.

set -eu

LISTEN_PORT="${LISTEN_PORT:?LISTEN_PORT is required}"
SOCKS_HOST="${SOCKS_HOST:-warp-pool}"
SOCKS_PORT="${SOCKS_PORT:?SOCKS_PORT is required}"

CONF="/tmp/privoxy.conf"

cat > "$CONF" <<EOF
# managed by entrypoint.sh — do not edit inside the container
listen-address 0.0.0.0:${LISTEN_PORT}
forward-socks5t / ${SOCKS_HOST}:${SOCKS_PORT} .
confdir /etc/privoxy
EOF

# sanity: can we resolve/reach the SOCKS slot at all?
if ! nc -z -w 3 "$SOCKS_HOST" "$SOCKS_PORT" 2>/dev/null; then
    echo "[privoxy] WARNING: cannot reach socks5 ${SOCKS_HOST}:${SOCKS_PORT} yet"
fi

echo "[privoxy] http :${LISTEN_PORT} -> socks5 ${SOCKS_HOST}:${SOCKS_PORT}"
exec privoxy --no-daemon "$CONF"
