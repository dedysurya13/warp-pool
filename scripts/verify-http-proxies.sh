#!/usr/bin/env bash
# Verify the HTTP front-end (privoxy) actually egresses through WARP.
#
#   docker exec warp /app/scripts/verify-http-proxies.sh
#
# Privoxy lives in its own container, so this script runs inside `warp` and
# reaches it by container name (or via the public port from the host).
# Prints the direct IP plus the exit IP and flags "same as direct"
# (which means the proxy is not being used).

set -uo pipefail

PORTS=("$@")
[ ${#PORTS[@]} -eq 0 ] && PORTS=(8118)

# Where to find privoxy: its container name on the compose network, or
# 127.0.0.1 when the script is run from the host.
HTTP_HOST="${HTTP_HOST:-warp-http}"
if ! getent hosts "$HTTP_HOST" >/dev/null 2>&1; then
    HTTP_HOST="127.0.0.1"
fi

DIRECT="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"
echo "IP asli        : ${DIRECT:-<gagal>}"
echo "target http    : ${HTTP_HOST}:${PORTS[0]}"
echo

fail=0
for p in "${PORTS[@]}"; do
    ip="$(curl -fsS --max-time 25 -x "http://${HTTP_HOST}:$p" https://api.ipify.org 2>/dev/null)"
    if [ -z "$ip" ]; then
        printf '  http://%s:%-5s -> MATI\n' "$HTTP_HOST" "$p"
        fail=1
        continue
    fi
    note=""
    if [ -n "$DIRECT" ] && [ "$ip" = "$DIRECT" ]; then
        note=" (SAMA DENGAN IP ASLI - proxy tidak dipakai)"
        fail=1
    fi
    printf '  http://%s:%-5s -> %s%s\n' "$HTTP_HOST" "$p" "$ip" "$note"
done

echo
if [ "$fail" -ne 0 ]; then
    echo "Kalau MATI: privoxy mungkin belum siap / SOCKS upstream belum hidup."
    echo "  docker logs warp-http --tail 30"
    echo "  docker exec warp-http nc -z -w 3 warp 25344; echo exit=\$?"
fi
exit "$fail"
