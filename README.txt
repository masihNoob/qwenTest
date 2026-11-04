ITools Launcher
===============

settings.ini — variabel
-----------------------
# LAN
SERVER_LAN=nama-komputer
PUBLIC_LAN=itool$
PRIVATE_LAN=private$
SETTINGS_LAN=\\nama-komputer\itool$\settings.ini

# HTTP (cadangan)
SERVER_HTTP=http://192.168.1.10
PUBLIC_HTTP=files/public
PRIVATE_HTTP=files/private
SETTINGS_HTTP=http://192.168.1.10/files/public/settings.ini


Urutan ambil settings
---------------------
1. SETTINGS_LAN (atau \\SERVER_LAN\PUBLIC_LAN\settings.ini)
2. Jika LAN gagal → unduh SETTINGS_HTTP

Mode lokal (tanpa SMB & tanpa HTTP)
-----------------------------------
Set LOCAL_MODE=1 di launcher.bat, atau jalankan:
  set ITOOLS_LOCAL=1 && launcher.bat
Launcher membaca Config.txt/Tools/Data langsung dari folder
Private yang berada satu induk dengan folder Public.
Tetap butuh hak Administrator, tapi tidak login dan tidak
menyentuh share maupun nginx.


Path kerja Tools/Config
-----------------------
Tetap memakai LAN:
  \\SERVER_LAN\PRIVATE_LAN\Tools
  \\SERVER_LAN\PRIVATE_LAN\Config.txt

Kebijakan Eksekusi PowerShell (patuh IT)
----------------------------------------
Launcher SELALU memakai powershell.exe resmi dari System32.
Opsi rename host (mis. netsh.exe) telah DIHAPUS karena termasuk
taktik penghindaran deteksi (MITRE T1036.003) yang melanggar
kebijakan EDR dan dapat dianggap insiden keamanan.

- -ExecutionPolicy Bypass tidak dipakai secara default; execution
  policy diambil dari registry/GPO (MachinePolicy). Bila environment
  menolak skrip, set secara sadar: set ITOOLS_ALLOW_BYPASS=1
- Agar lolos Symantec tanpa trik: minta exclusion berbasis hash atau
  tanda tangan code-signing kepada tim Security.
