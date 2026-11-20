# warp-pool

Proxy pool otomatis berbasis Cloudflare WARP. Menjaga N proxy SOCKS5 tetap hidup, mendeteksi IP mati/duplikat/kena limit, lalu mendaftarkan device WARP baru sendiri.

Dipakai sebagai proxy pool untuk 9Router (atau klien apa pun yang mendukung SOCKS5).

## Cara kerja

```
wgcf      -> daftarkan device WARP, hasilkan profil WireGuard
wireproxy -> bungkus profil jadi listener SOCKS5 di 127.0.0.1:<port>
supervisor-> cek tiap CHECK_INTERVAL detik, sembuhkan yang rusak
```

Setiap slot punya siklus hidup sendiri:

```
starting -> healthy -> (cooldown | duplicate | blocked | dead) -> restart/re-register
```

Aturan penyembuhan, dari yang paling murah:

1. Proses mati        -> restart wireproxy (sering dapat IP baru)
2. Exit IP duplikat   -> hapus config, register ulang
3. Target balas 403   -> IP diblok, register ulang
4. Target balas 429   -> cooldown, jangan dipakai sampai COOLDOWN_SECONDS habis
5. Gagal berkali-kali -> tetap dicoba, dengan jeda REGISTER_DELAY antar registrasi

## Instalasi

```bash
git clone https://github.com/<user>/warp-pool.git
cd warp-pool
docker compose up -d --build
```

Cek status:

```bash
docker exec warp-pool /app/scripts/healthcheck.sh
docker exec warp-pool /app/scripts/test-rotation.sh
```

## Environment

| Variabel | Default | Arti |
|---|---|---|
| `POOL_SIZE` | `3` | jumlah slot proxy |
| `BASE_PORT` | `25344` | port SOCKS5 slot 0; slot N = BASE_PORT + N |
| `CHECK_INTERVAL` | `300` | jeda antar siklus pengecekan (detik) |
| `COOLDOWN_SECONDS` | `1800` | lama cooldown setelah kena 429 |
| `REGISTER_DELAY` | `60` | jeda minimum antar registrasi WARP |
| `TARGET_URL` | `https://opencode.ai` | endpoint untuk cek apakah IP diterima |
| `HEALTH_URL` | `https://api.ipify.org` | endpoint untuk membaca exit IP |
| `MIN_HEALTHY` | `2` | batas bawah sebelum kirim notifikasi |
| `TELEGRAM_BOT_TOKEN` | kosong | opsional, untuk notifikasi |
| `TELEGRAM_CHAT_ID` | kosong | opsional |

## Menghubungkan ke 9Router

Proxy hanya listen di `127.0.0.1` host. Kalau 9Router ada di mesin lain (mis. Windows), pakai SSH tunnel:

```powershell
ssh -L 25344:127.0.0.1:25344 -L 25345:127.0.0.1:25345 -L 25346:127.0.0.1:25346 ubuntu@<vps>
```

Lalu di 9Router -> Providers -> opencode -> Proxy Pool, tambahkan:

```
socks5://127.0.0.1:25344
socks5://127.0.0.1:25345
socks5://127.0.0.1:25346
```

Mode rotasi yang disarankan: **on-error** (rotate hanya saat kena limit), bukan round-robin.

## Status

`/data/status.json` berisi ringkasan mesin-terbaca:

```json
{
  "updated": "2026-11-21T01:00:00Z",
  "pool_size": 3,
  "slots": [
    {"slot": "0", "port": "25344", "ip": "104.28.x.x", "status": "healthy"}
  ]
}
```

## Catatan operasional

- Registrasi WARP berlebihan dari satu IP bisa diblokir Cloudflare sementara. `REGISTER_DELAY` ada untuk itu — jangan dikecilkan.
- IP WARP bersifat shared. Sebagian IP mungkin sudah tidak diterima target; itulah gunanya pengecekan `TARGET_URL`.
- Container tidak expose port ke `0.0.0.0` dengan sengaja. Jangan ubah binding di `docker-compose.yml` tanpa alasan.

## Struktur

```
Dockerfile
docker-compose.yml
scripts/
  entrypoint.sh      mulai supervisor
  supervisor.sh      loop utama: health check + penyembuhan
  register-slot.sh   daftar WARP + jalankan wireproxy untuk satu slot
  healthcheck.sh     tabel status / --json / --quick
  test-rotation.sh   lihat exit IP tiap slot
  common.sh          helper bersama
```
