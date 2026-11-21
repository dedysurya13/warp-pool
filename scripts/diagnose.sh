#!/usr/bin/env bash
# Diagnose why the HTTP front-ends are not answering.
#   docker exec warp-pool /app/scripts/diagnose.sh
# Also checks the privoxy sidecars when docker CLI is reachable.

set -uo pipefail

echo "=== 1. SOCKS5 slot hidup? =========================================="
for p in 25344 25345 25346; do
    ip="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$p" https://api.ipify.org 2>/dev/null)"
    printf '  socks5 :%s -> %s\n' "$p" "${ip:-MATI}"
done

echo
echo "=== 2. Status slot menurut supervisor =============================="
/app/scripts/healthcheck.sh

echo
echo "=== 3. IP container ini (yang dipakai privoxy untuk connect) ======="
hostname -i 2>/dev/null | tr ' ' '\n' | grep -v '^$' || echo "  <tidak terbaca>"

echo
echo "=== 4. Proses wireproxy per slot ==================================="
ps -eo pid,etime,cmd 2>/dev/null | grep '[w]ireproxy' | sed 's/^/  /' || echo "  tidak ada"

echo
echo "=== 5. Log slot terakhir (20 baris) ================================"
for i in 0 1 2; do
    echo "--- slot $i ---"
    tail -8 "/data/pool/slot-$i/slot.log" 2>/dev/null | sed 's/^/  /' || echo "  <tidak ada log>"
done

echo
echo "=== 6. Petunjuk ===================================================="
cat <<'EOF'
Bagian 1 semua MATI          -> WARP pool bermasalah, bukan privoxy.
Bagian 1 hidup, HTTP mati    -> cek dari HOST:
    docker ps -a --filter name=warp-http
    docker logs warp-http-0 --tail 30
    docker exec warp-http-0 nc -z -w 3 warp-pool 25344; echo "exit=$?"

Slot yang MATI di bagian 1 tapi "starting" di bagian 2 berarti
wireproxy sudah keluar tapi state belum diperbarui (restart-loop).
Lihat bagian 5 untuk penyebabnya.
EOF
