#!/bin/sh
# Privoxy front-end: HTTP proxy -> SOCKS5 WARP tunnel.
#
# Privoxy on Alpine is compiled WITHOUT forward-socks5t on some builds, and
# the config parser silently accepts it while the forwarding fails at
# runtime (connection reset on CONNECT). So we:
#   1. probe the SOCKS port AND verify a real request goes through it
#   2. use plain forward-socks5 (always available)
#   3. enable logging so failures are visible instead of silent

set -eu

LISTEN_PORT="${LISTEN_PORT:?LISTEN_PORT is required}"
SOCKS_HOST="${SOCKS_HOST:-warp}"
SOCKS_PORT="${SOCKS_PORT:?SOCKS_PORT is required}"
UPSTREAM_TIMEOUT="${UPSTREAM_TIMEOUT:-90}"
PROBE_URL="${PROBE_URL:-https://api.ipify.org}"

CONF="/tmp/privoxy.conf"
LOGDIR="/var/log/privoxy"

mkdir -p "$LOGDIR"

cat > "$CONF" <<EOF
# managed by entrypoint.sh — do not edit inside the container
listen-address 0.0.0.0:${LISTEN_PORT}
forward-socks5 / ${SOCKS_HOST}:${SOCKS_PORT} .
confdir /etc/privoxy
logdir ${LOGDIR}
debug 1024
debug 4096
debug 8192
EOF

echo "[privoxy] http :${LISTEN_PORT} -> socks5 ${SOCKS_HOST}:${SOCKS_PORT}"

# ---------------------------------------------------------------- wait
# A bare TCP connect is not enough: wireproxy binds the port before the
# WARP handshake completes. Verify an actual HTTPS request egresses.
i=0
ready=0
while [ "$i" -lt "$UPSTREAM_TIMEOUT" ]; do
    if curl -fsS --max-time 10 --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" \
            "$PROBE_URL" >/tmp/probe.out 2>/tmp/probe.err; then
        echo "[privoxy] upstream verified after ${i}s: $(cat /tmp/probe.out)"
        ready=1
        break
    fi
    i=$(( i + 5 ))
    sleep 5
done

if [ "$ready" -ne 1 ]; then
    echo "[privoxy] WARNING: upstream never verified after ${UPSTREAM_TIMEOUT}s"
    echo "[privoxy] last probe error: $(tail -1 /tmp/probe.err 2>/dev/null)"
    echo "[privoxy] starting anyway — requests will fail until WARP settles"
fi

echo "[privoxy] listening on :${LISTEN_PORT}"
exec privoxy --no-daemon "$CONF"
