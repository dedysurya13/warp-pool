# warp-pool

Proxy pool otomatis berbasis Cloudflare WARP. Menjaga N proxy tetap hidup, mendeteksi IP mati/duplikat/kena limit, lalu mendaftarkan device WARP baru sendiri.

Tersedia dalam **dua protokol**:

| Protokol | Port | Untuk klien |
|---|---|---|
| SOCKS5 | `25344`–`25346` | klien yang mendukung `socks5://` |
| HTTP | `8118`–`8120` | klien yang hanya menerima `http://` (9Router, dsb) |

Port HTTP dilayani `privoxy` yang meneruskan ke SOCKS5 WARP di slot yang sama.

## Cara kerja

```
wgcf      -> daftarkan device WARP, hasilkan profil WireGuard
wireproxy -> bungkus profil jadi listener SOCKS5 di 127.0.0.1:<port>
privoxy   -> bungkus SOCKS5 itu jadi listener HTTP
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
git clone https://github.com/dedysurya13/warp-pool.git
cd warp-pool
docker compose up -d --build
```

Cek status:

```bash
docker exec warp-pool /app/scripts/healthcheck.sh
docker exec warp-pool /app/scripts/test-rotation.sh
```

Tes jalur HTTP:

```bash
docker exec warp-pool /app/scripts/verify-http-proxies.sh
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

Kalau `POOL_SIZE` diubah, sesuaikan juga jumlah service `warp-http-*` dan daftar `ports` di compose.

## Menghubungkan ke klien

Semua port hanya listen di `127.0.0.1` host. Untuk klien di mesin lain, pakai SSH tunnel:

```bash
ssh -L 25344:127.0.0.1:25344 -L 25345:127.0.0.1:25345 -L 25346:127.0.0.1:25346 \
    -L 8118:127.0.0.1:8118 -L 8119:127.0.0.1:8119 -L 8120:127.0.0.1:8120 \
    ubuntu@<vps>
```

Atau permanen lewat `~/.ssh/config`:

```
Host warppool
    HostName <vps>
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 25344 127.0.0.1:25344
    LocalForward 25345 127.0.0.1:25345
    LocalForward 25346 127.0.0.1:25346
    LocalForward 8118 127.0.0.1:8118
    LocalForward 8119 127.0.0.1:8119
    LocalForward 8120 127.0.0.1:8120
```

### 9Router

9Router menolak skema `socks5://` (`Invalid URL protocol: the URL must start with http: or https:`), jadi pakai port HTTP:

```
http://127.0.0.1:8118
http://127.0.0.1:8119
http://127.0.0.1:8120
```

Buat satu pool per URL (field `Proxy URL` hanya menerima satu URL), lalu assign pool ke provider. Mode rotasi: **on-error**, bukan round-robin. Nyalakan **Strict Proxy** supaya request gagal terang-terangan alih-alih diam-diam keluar lewat IP asli.

### Klien yang mendukung SOCKS5

Pakai port `25344`–`25346` dengan skema `socks5h://` (DNS resolve di sisi proxy, bukan di sisi klien):

```
socks5h://127.0.0.1:25344
```

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
- Setelah mengubah kode, rebuild **dan** bersihkan state: `git pull && docker compose down -v && docker compose up -d --build`. Tanpa `-v`, state lama tetap dipakai dan perbaikan tampak tidak berhasil.

## Struktur

```
Dockerfile
docker-compose.yml
scripts/
  entrypoint.sh           mulai supervisor
  supervisor.sh           loop utama: health check + penyembuhan
  register-slot.sh        daftar WARP + jalankan wireproxy untuk satu slot
  healthcheck.sh          tabel status / --json / --quick
  test-rotation.sh        lihat exit IP tiap slot (SOCKS5)
  verify-http-proxies.sh  lihat exit IP tiap port HTTP
  common.sh               helper bersama
```
