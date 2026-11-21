#!/bin/sh
# Render a privoxy config for this container only, then exec privoxy.
# Each container gets its own filesystem and its own port, so there is
# no shared config file and no port collision between slots.

set -eu

LISTEN_PORT="${LISTEN_PORT:?LISTEN_PORT is required}"
SOCKS_HOST="${SOCKS_HOST:-warp-pool}"
SOCKS_PORT="${SOCKS_PORT:?SOCKS_PORT is required}"

CONF="/tmp/privoxy.conf"

cat > "$CONF" <<EOF
# managed by entrypoint.sh — do not edit inside the container
listen-address 0.0.0.0:${LISTEN_PORT}
forward-socks5t / ${SOCKS_HOST}:${SOCKS_PORT} .
logfile /dev/stdout
log-level 256
confdir /etc/privoxy
EOF

echo "[privoxy] http :${LISTEN_PORT} -> socks5 ${SOCKS_HOST}:${SOCKS_PORT}"

exec privoxy --no-daemon "$CONF"
