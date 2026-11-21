#!/usr/bin/env bash
# Entrypoint: run the single WARP agent, tee its output to a log file so
# `docker logs` AND /data/warp/agent.log both work.

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
mkdir -p "$STATE_DIR/warp"

exec > >(tee -a "$STATE_DIR/warp/agent.log") 2>&1

exec /app/scripts/agent.sh
