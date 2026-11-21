#!/usr/bin/env bash
# Diagnosa lengkap agent WARP tunggal.
#   docker exec warp /app/scripts/diagnose.sh

set -uo pipefail

STATE_DIR="${STATE_DIR:-/data}"
DIR="$STATE_DIR/warp"
SOCKS_PORT="${SOCKS_PORT:-25344}"

echo "=== 1. Status agent ================================================="
/app/scripts/healthcheck.sh 2>/dev/null || echo "  <healthcheck gagal>"

echo
echo "=== 2. SOCKS5 langsung =============================================="
ip="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://api.ipify.org 2>/dev/null)"
printf '  socks5 :%s -> %s\n' "$SOCKS_PORT" "${ip:-MATI}"

echo
echo "=== 3. HTTP (privoxy) ==============================================="
for p in 8118; do
    h="$(curl -fsS --max-time 15 -x "http://127.0.0.1:$p" https://api.ipify.org 2>/dev/null)"
    printf '  http  :%s -> %s\n' "$p" "${h:-MATI}"
done

echo
echo "=== 4. IP asli container ============================================"
d="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"
echo "  ${d:-<gagal>}"

echo
echo "=== 5. Proses ======================================================="
ps -eo pid,etime,cmd 2>/dev/null | grep -E '[w]ireproxy|[p]rivoxy' | sed 's/^/  /' || echo "  tidak ada"

echo
echo "=== 6. Identitas WARP ==============================================="
if [ -f "$DIR/wgcf-profile.conf" ]; then
    awk -F' = ' '/^PrivateKey/{print "  PrivateKey : " substr($2,1,12)"..."}
                 /^PublicKey/{print "  PeerKey    : " substr($2,1,12)"..."}
                 /^Endpoint/{print "  Endpoint   : " $2}' "$DIR/wgcf-profile.conf"
else
    echo "  <profil belum ada>"
fi

echo
echo "=== 7. Log agent (12 baris) ========================================="
tail -12 "$DIR/agent.log" 2>/dev/null | sed 's/^/  /' || echo "  <tidak ada>"

echo
echo "=== 8. Log register terakhir ========================================"
tail -6 "$DIR/register.log" 2>/dev/null | sed 's/^/  /' || echo "  <tidak ada>"

echo
echo "=== 9. Log wireproxy (8 baris) ======================================"
tail -8 "$DIR/wireproxy.log" 2>/dev/null | sed 's/^/  /' || echo "  <tidak ada>"

echo
echo "=== 10. Petunjuk ===================================================="
cat <<'EOF'
Bagian 1 status healthy + bagian 2 ada IP  -> normal, tidak ada yang perlu
Bagian 2 MATI, bagian 1 status rotating    -> agent sedang register ulang
Bagian 2 MATI, status failed               -> Cloudflare menolak registrasi
                                              cek bagian 8, naikkan
                                              REGISTER_RETRY_DELAY
Bagian 2 ada IP tapi sama dengan bagian 4  -> WARP leak, agent akan rotate
Bagian 2 hidup, bagian 3 MATI              -> cek: docker logs warp-http
EOF
