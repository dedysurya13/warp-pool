#!/usr/bin/env bash
# Supervisor for the WARP proxy pool.
# Keeps POOL_SIZE wireproxy instances alive, re-registers dead/blocked slots,
# and writes an aggregate status file for humans and 9Router.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

declare -A PID=()
# Shared clock: all slots consult the same timestamp, so the rate-limit guard
# actually serialises registrations instead of letting each slot sleep alone.
LAST_REGISTER_FILE="$STATE_DIR/.last-register"

get_last_register() {
    [ -f "$LAST_REGISTER_FILE" ] && cat "$LAST_REGISTER_FILE" 2>/dev/null || echo 0
}

mark_register() {
    date +%s > "$LAST_REGISTER_FILE"
}

STATUS_FILE="$STATE_DIR/status.json"
PROBE_INTERVAL="${PROBE_INTERVAL:-45}"

cleanup() {
    log "supervisor: shutting down"
    for idx in "${!PID[@]}"; do
        kill "${PID[$idx]}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

start_slot() {
    local idx="$1"
    local dir; dir="$(slot_dir "$idx")"

    if [ -f "$dir/wireproxy.conf" ] && [ "$(st_get "$idx" status)" != "dead" ]; then
        log "slot $idx: reusing existing wireproxy config"
        wireproxy -c "$dir/wireproxy.conf" >>"$dir/wireproxy.log" 2>&1 &
        PID[$idx]=$!
        st_set "$idx" status "starting"
        return 0
    fi

    local now elapsed last
    last="$(get_last_register)"
    now="$(date +%s)"
    elapsed=$(( now - last ))
    if [ "$last" -ne 0 ] && [ "$elapsed" -lt "$REGISTER_DELAY" ]; then
        local wait_for=$(( REGISTER_DELAY - elapsed ))
        log "slot $idx: waiting ${wait_for}s before registering (rate limit guard)"
        sleep "$wait_for"
    fi

    mark_register
    "$SCRIPT_DIR/register-slot.sh" "$idx" >>"$dir/slot.log" 2>&1 &
    PID[$idx]=$!
}

restart_slot() {
    local idx="$1"
    if [ -n "${PID[$idx]:-}" ]; then
        kill "${PID[$idx]}" 2>/dev/null || true
        wait "${PID[$idx]}" 2>/dev/null || true
    fi
    start_slot "$idx"
}

# Give a freshly started wireproxy time to complete its WARP handshake
# before we call it dead. A cold start needs ~5-15s.
wait_for_proxy() {
    local port="$1" tries="${2:-6}" i
    for (( i=0; i<tries; i++ )); do
        [ -n "$(proxy_alive "$port")" ] && return 0
        sleep 5
    done
    return 1
}

write_status() {
    local tmp
    tmp="$(mktemp)"
    {
        printf '{\n  "updated": "%s",\n  "pool_size": %s,\n  "slots": [' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$POOL_SIZE"
        local first=1
        for (( i=0; i<POOL_SIZE; i++ )); do
            local meta; meta="$(slot_dir "$i")/state.json"
            [ $first -eq 1 ] || printf ','
            first=0
            if [ -f "$meta" ]; then
                jq -c '{slot: (.slot // ""), port, ip, status, cooldown_until}' "$meta" 2>/dev/null \
                    || printf '{"slot":"%s","status":"unknown"}' "$i"
            else
                printf '{"slot":"%s","status":"empty"}' "$i"
            fi
        done
        printf '  ]\n}\n'
    } > "$tmp"
    mv "$tmp" "$STATUS_FILE"
}

# --- boot ---
log "supervisor: starting pool of $POOL_SIZE on ports $BASE_PORT..$(( BASE_PORT + POOL_SIZE - 1 ))"

for (( i=0; i<POOL_SIZE; i++ )); do
    st_set "$i" slot "$i"
    start_slot "$i"
    sleep 2
done

# --- main loop ---
while true; do
    for (( i=0; i<POOL_SIZE; i++ )); do
        port="$(slot_port "$i")"
        dir="$(slot_dir "$i")"

        # 1. child process gone -> restart (cheapest fix)
        if [ -n "${PID[$i]:-}" ] && ! kill -0 "${PID[$i]}" 2>/dev/null; then
            log "slot $i: wireproxy process gone, restarting"
            st_set "$i" status "dead"
            restart_slot "$i"
            continue
        fi

        # 2. does it actually answer? give a cold start some grace time
        ip="$(proxy_alive "$port")"
        if [ -z "$ip" ]; then
            if ! wait_for_proxy "$port"; then
                log "slot $i: no answer on :$port after grace period, restarting"
                st_set "$i" status "dead"
                restart_slot "$i"
                continue
            fi
            ip="$(proxy_alive "$port")"
        fi

        # 3. duplicate exit IP means rotation is pointless
        dup=0
        for (( j=0; j<POOL_SIZE; j++ )); do
            [ "$j" -eq "$i" ] && continue
            [ "$(st_get "$j" ip)" = "$ip" ] && dup=1 && break
        done

        if [ "$dup" -eq 1 ]; then
            log "slot $i: duplicate exit IP $ip, re-registering"
            st_set "$i" status "duplicate"
            rm -f "$dir/wireproxy.conf"
            st_set "$i" status "dead"
            restart_slot "$i"
            continue
        fi

        st_set "$i" ip "$ip"

        # 4. does the target accept this IP?
        target_ok "$port"
        case $? in
            0) st_set "$i" status "healthy" ;;
            2)
                until_ts=$(( $(date +%s) + COOLDOWN_SECONDS ))
                log "slot $i: rate limited, cooling down until $(date -d "@$until_ts" '+%H:%M:%S')"
                st_set "$i" status "cooldown"
                st_set "$i" cooldown_until "$until_ts"
                ;;
            3)
                log "slot $i: exit IP $ip blocked by target, replacing"
                st_set "$i" status "blocked"
                rm -f "$dir/wireproxy.conf"
                st_set "$i" status "dead"
                restart_slot "$i"
                ;;
            *)
                log "slot $i: target check inconclusive for $ip"
                st_set "$i" status "unknown"
                ;;
        esac
    done

    healthy=0
    for (( i=0; i<POOL_SIZE; i++ )); do
        [ "$(st_get "$i" status)" = "healthy" ] && healthy=$(( healthy + 1 ))
    done

    write_status

    if [ "$healthy" -lt "$MIN_HEALTHY" ]; then
        log "pool degraded: $healthy/$POOL_SIZE healthy"
        notify "warp-pool: hanya $healthy/$POOL_SIZE proxy sehat. Cek container."
    fi

    sleep "$PROBE_INTERVAL"
done
