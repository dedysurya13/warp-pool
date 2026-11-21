# warp-pool — satu proxy WARP yang menyembuhkan diri sendiri

Satu identitas WARP, satu tunnel, satu IP. Kalau tunnel tidak bisa dipakai,
agent langsung membuang profilnya, register ulang, dan menyalakan tunnel baru.

Tidak ada pool, tidak ada slot, tidak ada rebutan identitas.

## Kenapa bukan pool

Versi sebelumnya menjalankan 3 slot paralel. Masalahnya: Cloudflare hanya
mengizinkan satu peer aktif per device. Ketika tiga slot memakai identitas
yang sama (karena `wgcf` membaca cache global saat registrasi kena rate
limit), mereka saling kick di setiap handshake — hasilnya restart-loop
tanpa henti dan hanya satu slot yang kebetulan hidup.

Satu tunnel yang selalu diverifikasi jauh lebih andal daripada tiga tunnel
yang saling membunuh.

## Arsitektur

```
9Router / klien HTTP
        │
        ▼
   warp-http (privoxy :8118)   ← hanya menerima http://
        │
        ▼
   warp (wireproxy :25344)     ← SOCKS5, tunnel WireGuard ke WARP
        │
        ▼
   Cloudflare WARP → internet (IP Cloudflare)
```

Kalau klien mendukung SOCKS5, lewati privoxy dan pakai `:25344` langsung.

## Siklus hidup agent

1. **boot** — kalau belum ada `wireproxy.conf`, register device WARP baru
2. **start** — jalankan `wireproxy` di background
3. **verify** (tiap `CHECK_INTERVAL` detik):
   - IP keluar ada? tidak → rotate
   - IP keluar sama dengan IP asli container? → WARP leak → rotate
   - target (`TARGET_URL`) balas 200/3xx? tidak → rotate
   - target balas 429 → cooldown `COOLDOWN_SECONDS`, tunnel dipertahankan
4. **rotate** — kill wireproxy, hapus profil, register ulang, start lagi
5. gagal berulang → backoff naik 60 → 120 → 240 → 300 detik

## Status agent

```bash
sudo docker exec warp /app/scripts/healthcheck.sh
```

Field penting di `/data/state.json`:

- `status` — `registering` / `starting` / `healthy` / `cooldown` / `rotating` / `failed`
- `identity` — 12 karakter pertama PeerKey (harus berganti tiap rotate)
- `ip` — IP keluar yang terakhir terverifikasi
- `leak` — `yes` kalau IP keluar == IP asli (tunnel tidak dipakai)
- `last_rotate_reason` — alasan rotate terakhir

## Deploy

```bash
git clone https://github.com/dedysurya13/warp-pool.git
cd warp-pool
sudo docker compose up -d --build
```

Port sengaja bind ke `127.0.0.1` — akses dari luar wajib lewat SSH tunnel.

```bash
ssh -N -L 8118:127.0.0.1:8118 -L 25344:127.0.0.1:25344 user@vps
```

## Verifikasi

```bash
# status lengkap + IP live
sudo docker exec warp /app/scripts/healthcheck.sh
```

```bash
# HTTP proxy benar-benar lewat WARP (bukan IP asli)
sudo docker exec warp /app/scripts/verify-http-proxies.sh
```

```bash
# kalau ada yang aneh
sudo docker exec warp /app/scripts/diagnose.sh
```

## Konfigurasi

Semua lewat environment di `docker-compose.yml`:

- `SOCKS_PORT` (default `25344`)
- `CHECK_INTERVAL` (default `60`) — jeda verifikasi
- `COOLDOWN_SECONDS` (default `1800`) — istirahat saat kena 429
- `REGISTER_RETRY_DELAY` (default `30`) — jeda antar percobaan register
- `MAX_REGISTER_ATTEMPTS` (default `5`)
- `TARGET_URL` (default `https://opencode.ai`)
- `HEALTH_URL` (default `https://api.ipify.org`)

Naikkan `REGISTER_RETRY_DELAY` ke `120` kalau Cloudflare mulai menolak
registrasi beruntun.

## 9Router

Tambahkan sebagai proxy pool berisi **satu** entri:

```
http://127.0.0.1:8118
```

Kalau IP-nya kena limit, agent otomatis rotate dalam ≤ `CHECK_INTERVAL`
detik. Untuk hasil tercepat, restart tunnel manual:

```bash
sudo docker restart warp
```

## Log

```bash
sudo docker logs -f warp
```

```bash
# log agent (juga tersimpan di volume)
sudo docker exec warp tail -50 /data/warp/agent.log
```
