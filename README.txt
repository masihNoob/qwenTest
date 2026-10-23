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


Path kerja Tools/Config
-----------------------
Tetap memakai LAN:
  \\SERVER_LAN\PRIVATE_LAN\Tools
  \\SERVER_LAN\PRIVATE_LAN\Config.txt
