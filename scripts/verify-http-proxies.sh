#!/usr/bin/env bash
# Verify the HTTP front-ends (privoxy) actually egress through WARP.
#
#   ./scripts/verify-http-proxies.sh            # defaults: 8118 8119 8120
#   ./scripts/verify-http-proxies.sh 8118 8119  # custom ports
#
# Prints the direct IP plus the exit IP for every HTTP proxy and flags
# duplicates or "same as direct" (which means the proxy is not being used).

set -uo pipefail

PORTS=("$@")
[ ${#PORTS[@]} -eq 0 ] && PORTS=(8118 8119 8120)

DIRECT="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"
echo "IP asli        : ${DIRECT:-<gagal>}"
echo

declare -A SEEN=()
fail=0

for p in "${PORTS[@]}"; do
    ip="$(curl -fsS --max-time 15 -x "http://127.0.0.1:$p" https://api.ipify.org 2>/dev/null)"
    if [ -z "$ip" ]; then
        printf '  http://127.0.0.1:%-5s -> MATI\n' "$p"
        fail=1
        continue
    fi

    note=""
    if [ -n "${SEEN[$ip]:-}" ]; then
        note=" (DUPLIKAT dengan port ${SEEN[$ip]})"
        fail=1
    fi
    if [ "$ip" = "$DIRECT" ]; then
        note=" (SAMA DENGAN IP ASLI - proxy tidak dipakai)"
        fail=1
    fi
    SEEN[$ip]="$p"
    printf '  http://127.0.0.1:%-5s -> %s%s\n' "$p" "$ip" "$note"
done

echo
echo "Total IP unik: ${#SEEN[@]} dari ${#PORTS[@]}"
exit "$fail"
