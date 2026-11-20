#!/usr/bin/env bash
set -uo pipefail

echo "[entrypoint] warp-pool starting"
echo "[entrypoint] pool=$POOL_SIZE base_port=$BASE_PORT interval=${CHECK_INTERVAL}s"

mkdir -p "$STATE_DIR"

# sanity checks
for bin in wgcf wireproxy curl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "[entrypoint] missing binary: $bin" >&2; exit 1; }
done

exec /app/scripts/supervisor.sh
