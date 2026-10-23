# Setup Nginx Windows + File Browser (Private only) untuk ITools

**File-browser hanya untuk folder Private.**  
Public diakses langsung (tanpa UI browser).

## Hasil URL

| URL | Akses | Keterangan |
|-----|-------|------------|
| `http://IP/` | Publik | Dashboard (download launcher + link file browser) |
| `http://IP/files/public/` | Publik | Daftar file / download langsung |
| `http://IP/files/public/settings.ini` | Publik | Direct file (untuk launcher) |
| `http://IP/private/` | **Login** | File browser UI untuk Private |
| `http://IP/files/private/...` | **Login** | Direct download / JSON Private |

---

## Struktur folder

```
C:\nginx\
├── nginx.exe
├── conf\
│   ├── nginx.conf                 ← tambah: include itools-windows.conf;
│   └── itools-windows.conf
├── html\
│   ├── dashboard.html
│   └── file-browser\              ← dari github mohamnag
│       ├── index.html
│       ├── css\
│       ├── js\main.js             ← UBAH filesBaseUrl
│       └── image\
├── htpasswd_itools
└── ssl\
    ├── itools.crt
    └── itools.key

C:\ITools\
├── Public\                        ← launcher.bat, settings.ini, dll
└── Private\                       ← Config.txt, Tools\, dll
```

---

## Langkah setup

### 1. Download Nginx Windows
https://nginx.org/en/download.html → extract ke `C:\nginx`

### 2. Download nginx-file-browser
https://github.com/mohamnag/nginx-file-browser → extract ke:

```
C:\nginx\html\file-browser\
```

### 3. Ubah filesBaseUrl di main.js

File: `C:\nginx\html\file-browser\js\main.js`

```js
// dari:
var filesBaseUrl = "/files";

// menjadi:
var filesBaseUrl = "/files/private";
```

### 4. Siapkan data ITools

```
C:\ITools\Public
C:\ITools\Private
```

### 5. Buat password (Basic Auth)

Nginx Windows tidak punya `htpasswd`. Pakai generator online (APR1/MD5):

https://hostingcanada.org/htpasswd-generator/

Simpan hasilnya ke: `C:\nginx\htpasswd_itools`

Contoh isi:
```
admin:$apr1$xxxx$yyyyyyyyyyyyyyyyyyyyyy
```

Atau lewat Git Bash:
```bash
htpasswd -nb admin passwordkamu > /c/nginx/htpasswd_itools
```

### 6. Buat sertifikat TLS (self-signed)

Command Prompt atau PowerShell (dengan `&` jika path ada spasi):

```cmd
mkdir C:\nginx\ssl
"C:\Program Files\OpenSSL-Win64\bin\openssl.exe" req -x509 -nodes -days 365 -newkey rsa:2048 -keyout C:\nginx\ssl\itools.key -out C:\nginx\ssl\itools.crt -subj "/CN=192.168.1.10"
```

PowerShell:
```powershell
& "C:\Program Files\OpenSSL-Win64\bin\openssl.exe" req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "C:\nginx\ssl\itools.key" -out "C:\nginx\ssl\itools.crt" -subj "/CN=192.168.1.10"
```

Ganti `192.168.1.10` dengan IP server.

### 7. Pasang konfigurasi

1. Salin `itools-windows.conf` → `C:\nginx\conf\itools-windows.conf`
2. Salin `dashboard.html` → `C:\nginx\html\dashboard.html`
3. Di `C:\nginx\conf\nginx.conf`, dalam blok `http { }` tambahkan:

```nginx
include itools-windows.conf;
```

4. Sesuaikan path di `itools-windows.conf` jika lokasi folder berbeda.
   Path Windows di nginx **wajib** pakai `/` (forward slash).

### 8. Jalankan Nginx

```cmd
cd C:\nginx
nginx -t
start nginx
```

| Perintah | Fungsi |
|----------|--------|
| `start nginx` | Jalankan |
| `nginx -s reload` | Reload config |
| `nginx -s stop` | Stop |
| `nginx -s quit` | Stop graceful |
| `nginx -t` | Test config |

Log error: `C:\nginx\logs\error.log`

### 9. settings.ini Launcher

```ini
SERVER_HTTP=http://192.168.1.10
PUBLIC_HTTP=files/public
PRIVATE_HTTP=files/private
SETTINGS_HTTP=http://192.168.1.10/files/public/settings.ini
```

### 10. Firewall (opsional)

```powershell
New-NetFirewallRule -DisplayName "Nginx HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow
New-NetFirewallRule -DisplayName "Nginx HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
```

---

## Troubleshooting

| Masalah | Solusi |
|---------|--------|
| 404 file-browser | Path alias harus `C:/nginx/html/file-browser/` |
| "Server cant find this file/directory!" | `filesBaseUrl` di main.js belum `/files/private` |
| 403 Forbidden | Cek path folder + permission |
| 401 terus | Path `htpasswd_itools` atau format password salah |
| Port bind error | Port 80/443 dipakai IIS → matikan atau ganti `listen` |
| Path error | Pakai `/` bukan `\`: `C:/ITools/Public/` |

---

## File di folder ini

| File | Fungsi |
|------|--------|
| `itools-windows.conf` | Konfigurasi Nginx Windows |
| `dashboard.html` | Halaman utama (download launcher + file browser) |
| `README-WINDOWS.md` | Panduan ini |
