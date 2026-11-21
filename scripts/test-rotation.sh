#!/usr/bin/env bash
# Test rotation: shows the exit IP for every slot port.
# Run inside the container:  docker exec warp-pool /app/scripts/test-rotation.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

echo "Menguji exit IP tiap proxy..."
declare -A SEEN=()
for (( i=0; i<POOL_SIZE; i++ )); do
    port="$(slot_port "$i")"
    ip="$(proxy_alive "$port")"
    if [ -z "$ip" ]; then
        printf '  slot %-2s port %-6s -> MATI\n' "$i" "$port"
        continue
    fi
    dup=""
    [ -n "${SEEN[$ip]:-}" ] && dup=" (DUPLIKAT dengan slot ${SEEN[$ip]})"
    SEEN[$ip]="$i"
    printf '  slot %-2s port %-6s -> %s%s\n' "$i" "$port" "$ip" "$dup"
done
echo
echo "Total IP unik: ${#SEEN[@]} dari $POOL_SIZE slot"
