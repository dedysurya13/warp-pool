#!/usr/bin/env bash
# Verifikasi tiap slot punya identitas WARP sendiri.
# Kalau dua slot punya PrivateKey/PublicKey sama, mereka akan saling kick
# di sisi Cloudflare dan handshake-nya gagal terus (SOCKS mati).
#
#   docker exec warp-pool /app/scripts/verify-identities.sh

set -uo pipefail
cd /data/pool 2>/dev/null || { echo "tidak bisa masuk /data/pool"; exit 1; }

printf '%-6s %-14s %-14s %-18s %s\n' SLOT PRIVKEY PEERKEY IP STATUS
declare -A SEEN_PK=() SEEN_PEER=()
fail=0

for d in $(ls -d slot-* 2>/dev/null | sort -t- -k2 -n); do
    idx="${d#slot-}"
    f="$d/wgcf-profile.conf"
    ip="$(jq -r '.ip // "?"' "$d/state.json" 2>/dev/null || echo '?')"
    st="$(jq -r '.status // "?"' "$d/state.json" 2>/dev/null || echo '?')"

    if [ ! -f "$f" ]; then
        printf '%-6s %-14s %-14s %-18s %s\n' "$idx" "MISSING" "-" "$ip" "$st"
        fail=1
        continue
    fi

    pk="$(awk -F' = ' '/^PrivateKey/{print substr($2,1,12)}' "$f")"
    peer="$(awk -F' = ' '/^PublicKey/{print substr($2,1,12)}' "$f")"

    note=""
    [ -n "${SEEN_PK[$pk]:-}" ] && { note=" DUP-PRIV(slot ${SEEN_PK[$pk]})"; fail=1; }
    [ -n "${SEEN_PEER[$peer]:-}" ] && { note="$note DUP-PEER(slot ${SEEN_PEER[$peer]})"; fail=1; }
    SEEN_PK[$pk]="$idx"
    SEEN_PEER[$peer]="$idx"

    printf '%-6s %-14s %-14s %-18s %s%s\n' "$idx" "$pk" "$peer" "$ip" "$st" "$note"
done

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: semua slot punya identitas unik (${#SEEN_PK[@]} identitas)"
else
    echo "RUSAK: ada identitas duplikat / hilang — slot akan restart-loop."
    echo "Perbaiki dengan: docker compose down -v && docker compose up -d --build"
fi
exit "$fail"
