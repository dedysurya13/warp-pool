#!/usr/bin/env bash
# Diagnose why the HTTP front-ends are not answering.
# Run inside the warp-pool container:
#   docker exec warp-pool /app/scripts/diagnose.sh

set -uo pipefail

echo "=== 1. Apakah SOCKS5 slot hidup? =================================="
for p in 25344 25345 25346; do
    ip="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$p" https://api.ipify.org 2>/dev/null)"
    printf '  socks5 :%s -> %s\n' "$p" "${ip:-MATI}"
done

echo
echo "=== 2. Status slot menurut supervisor ============================="
/app/scripts/healthcheck.sh

echo
echo "=== 3. Resolusi DNS container pr https://ganti.invalid --- skip ==="

echo
echo "=== 4. IP container warp-pool (dipakai privoxy untuk connect) ====="
hostname -i 2>/dev/null || cat /etc/hosts | grep -v '^127' | head -3

echo
echo "=== 5. Petunjuk =================================================="
cat <<'EOF'
Kalau bagian 1 SEMUA MATI  -> masalah di WARP pool, bukan privoxy.
  Periksa: docker exec warp-pool tail -30 /data/pool/slot-0/slot.log

Kalau bagian 1 HIDUP tapi HTTP mati -> masalah di privoxy/network.
  Periksa dari host:
    docker logs warp-http-0 --tail 20
    docker inspect warp-http-0 --format '{{.State.Status}}'
    docker exec warp-http-0 nc -z -w 3 warp-pool 25344; echo "exit=$?"
EOF
