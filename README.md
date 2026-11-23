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
   - probe kuota (tiap `QUOTA_CHECK_INTERVAL`, `QUOTA_ENABLED=1`):
     POST 1 token ke model gratis, lihat HTTP code-nya
   - 429 → status `quota`, **tidak** rotate (lihat catatan di bawah)
   - 401/403 → rotate
4. **rotate** — kill wireproxy, hapus profil, register ulang, start lagi
5. gagal berulang → backoff naik 60 → 120 → 240 → 300 detik

### Kenapa probe kuota bukan `TARGET_URL`

Versi lama memakai `TARGET_URL=https://opencode.ai` — halaman depan.
Halaman depan selalu balas 200, jadi **429 tidak pernah terdeteksi** dan
agent selalu melaporkan `healthy` walau kuota sudah habis. Sekarang probe
menembak endpoint inference yang sebenarnya.

### Kenapa 429 tidak di-rotate

Limit bucket gratis opencode diikat ke **identitas anonim** (kredensial
`Bearer public` + project/session), bukan ke alamat IP. Buktinya: dua IP
berbeda (exit WARP Cloudflare dan IP VPS langsung) sama-sama dapat
`FreeUsageLimitError`. Ganti IP tidak membuka limit, dan tiap rotate
mubazir satu registrasi WARP — yang sendirinya dibatasi Cloudflare per IP.

Set `ROTATE_ON_429=1` kalau suatu saat targetnya justru limit per-IP.

### Rotate manual

```bash
# tidak perlu masuk shell container
sudo docker exec warp touch /data/warp/rotate.req
```

Agent akan menghapus file itu dan rotate dalam ≤ `CHECK_INTERVAL` detik.

## Status agent

```bash
sudo docker exec warp /app/scripts/healthcheck.sh
```

Field penting di `/data/state.json`:

- `status` — `registering` / `starting` / `healthy` / `quota` / `blocked` / `rotating` / `failed`
- `identity` — 12 karakter pertama PeerKey (harus berganti tiap rotate)
- `ip` — IP keluar yang terakhir terverifikasi
- `leak` — `yes` kalau IP keluar == IP asli (tunnel tidak dipakai)
- `quota` — `ok` / `429` / `403` / `error` (hasil probe terakhir)
- `quota_checked` — kapan probe terakhir jalan
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
# kuota bucket gratis masih boleh atau sudah 429?
sudo docker exec warp /app/scripts/quota-check.sh
```

```bash
# banding: lewat WARP vs IP asli VPS — buktikan limit ikut IP atau tidak
sudo docker exec warp /app/scripts/quota-check.sh
sudo docker exec warp /app/scripts/quota-check.sh direct
```

```bash
# kalau ada yang aneh
sudo docker exec warp /app/scripts/diagnose.sh
```

## Troubleshooting

**`ip (live): MATI` tapi port 25344 terbuka.** Endpoint WARP di-resolve ke
IPv6, container tidak punya route IPv6 — SOCKS tetap listen, handshake
tidak pernah jadi, setiap CONNECT balas SOCKS error 4. Sekarang endpoint
di-pin ke IPv4 (`getent ahostsv4`), dan conf lama dimigrasi otomatis saat
boot. Kalau `endpoint :` di healthcheck masih berupa hostname, hapus
`/data/warp/wireproxy.conf` lalu restart.

```bash
sudo docker exec warp rm -f /data/warp/wireproxy.conf
sudo docker restart warp
```

**`status: failed` + `registered` lama.** Registrasi WARP gagal. Lihat
`register err :` di healthcheck, atau log lengkapnya:

```bash
sudo docker exec warp tail -20 /data/warp/register.log
```

Kalau isinya 429/rate limit, Cloudflare membatasi registrasi per IP —
tunggu (bisa berjam-jam), jangan di-restart berulang.

## Konfigurasi

Semua lewat environment di `docker-compose.yml`:

- `SOCKS_PORT` (default `25344`)
- `CHECK_INTERVAL` (default `60`) — jeda verifikasi
- `COOLDOWN_SECONDS` (default `1800`) — durasi status `quota` sebelum dicoba lagi
- `QUOTA_ENABLED` (default `1`) — probe kuota on/off
- `QUOTA_CHECK_INTERVAL` (default `300`) — jeda probe kuota (tiap probe makan 1 token)
- `QUOTA_URL` / `QUOTA_MODEL` — endpoint + model yang diprobe
- `ROTATE_ON_429` (default `0`) — `1` kalau targetnya limit per-IP
- `MIN_ROTATE_GAP` (default `120`) — jarak minimum antar rotate
- `REGISTER_RETRY_DELAY` (default `30`) — jeda antar percobaan register
- `REGISTER_429_DELAY` (default `300`) — jeda kalau register kena 429 Cloudflare
- `MAX_REGISTER_ATTEMPTS` (default `5`)
- `HEALTH_URL` (default `https://api.ipify.org`)

Naikkan `REGISTER_RETRY_DELAY` ke `120` kalau Cloudflare mulai menolak
registrasi beruntun.

## 9Router

Tambahkan sebagai proxy pool berisi **satu** entri:

```
http://127.0.0.1:8118
```

Tunnel tetap dipakai walau kuota model habis — 429 datang dari provider
model, bukan dari WARP. Yang berubah cuma status agent jadi `quota`.
Untuk hasil tercepat, restart tunnel manual:

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
