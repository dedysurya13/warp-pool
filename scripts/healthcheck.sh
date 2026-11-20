#!/usr/bin/env bash
# Health/status helper.
#   healthcheck.sh            -> human readable table
#   healthcheck.sh --quick    -> exit 0 if at least one proxy answers (docker healthcheck)
#   healthcheck.sh --json     -> machine readable

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

MODE="${1:-table}"

if [ "$MODE" = "--quick" ]; then
    for (( i=0; i<POOL_SIZE; i++ )); do
        if [ -n "$(proxy_alive "$(slot_port "$i")")" ]; then
            exit 0
        fi
    done
    exit 1
fi

if [ "$MODE" = "--json" ]; then
    cat "$STATE_DIR/status.json" 2>/dev/null || echo '{"slots":[]}'
    exit 0
fi

printf '%-6s %-7s %-17s %-10s %s\n' SLOT PORT IP STATUS COOLDOWN
for (( i=0; i<POOL_SIZE; i++ )); do
    port="$(slot_port "$i")"
    ip="$(slot_meta "$i" ip)"
    st="$(slot_meta "$i" status)"
    cd_until="$(slot_meta "$i" cooldown_until)"
    cd_human="-"
    if [ "$cd_until" != "none" ] && [ "$cd_until" -gt "$(date +%s)" ] 2>/dev/null; then
        cd_human="$(date -d "@$cd_until" '+%H:%M:%S')"
    fi
    printf '%-6s %-7s %-17s %-10s %s\n' "$i" "$port" "$ip" "$st" "$cd_human"
done
