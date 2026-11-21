#!/usr/bin/env bash
# Verify the HTTP front-end (privoxy) actually egresses through WARP.
#
#   docker exec warp /app/scripts/verify-http-proxies.sh
#
# Prints the direct IP plus the exit IP for the HTTP proxy and flags
# "same as direct" (which means the proxy is not being used).

set -uo pipefail

PORTS=("$@")
[ ${#PORTS[@]} -eq 0 ] && PORTS=(8118)

DIRECT="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"
echo "IP asli        : ${DIRECT:-<gagal>}"
echo

fail=0
for p in "${PORTS[@]}"; do
    ip="$(curl -fsS --max-time 20 -x "http://127.0.0.1:$p" https://api.ipify.org 2>/dev/null)"
    if [ -z "$ip" ]; then
        printf '  http://127.0.0.1:%-5s -> MATI\n' "$p"
        fail=1
        continue
    fi
    note=""
    if [ -n "$DIRECT" ] && [ "$ip" = "$DIRECT" ]; then
        note=" (SAMA DENGAN IP ASLI - proxy tidak dipakai)"
        fail=1
    fi
    printf '  http://127.0.0.1:%-5s -> %s%s\n' "$p" "$ip" "$note"
done

echo
exit "$fail"
