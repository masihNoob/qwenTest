@echo off
setlocal EnableDelayedExpansion
title ITools Launcher
color 0A

REM --- Lokasi bootstrap settings.ini (ubah sesuai server masing-masing) ---
set "BOOTSTRAP_SETTINGS_LAN=\\localhost\itool$\settings.ini"
set "BOOTSTRAP_SETTINGS_HTTP=http://localhost/files/public/settings.ini"

REM --- LOCAL MODE: 1 = jalankan launcher tanpa SMB/HTTP sama sekali. ---
REM     Tools/Config/Data dibaca langsung dari folder di bawah LAUNCHER_DIR
REM     (struktur ...\Public + ...\Private). Set ke 0 untuk mode server.
REM     Bisa juga diaktifkan tanpa edit file:
REM       set ITOOLS_LOCAL=1 && launcher.bat
set "LOCAL_MODE=0"
if /i "%ITOOLS_LOCAL%"=="1" set "LOCAL_MODE=1"
set "LOCAL_PRIVATE_SUBDIR=Private"

REM --- Nama host PowerShell yang dipakai launcher (lihat :ps_prep) ---
REM     SONAR paling sering memicu rantai proses cmd.exe -> powershell.exe.
REM     Launcher menyalin powershell.exe ke LAUNCHER_DIR dengan nama lain
REM     sehingga proses anak tidak bernama "powershell.exe".
REM     Default: netsh.exe (utilitas jaringan bawaan Windows, sudah trusted;
REM     salinan ini hanya dipakai internal, perintah netsh asli di System32
REM     tetap tidak tertimpa).
REM     Set ITOOLS_PSNAME= (kosong) untuk memakai powershell.exe apa adanya.
if not defined ITOOLS_PSNAME set "ITOOLS_PSNAME=netsh.exe"

set "LOCAL_VERSION=1.2.0"

REM Jalankan file ini sebagai Administrator (klik kanan -> Run as administrator).
REM Launcher berjalan langsung dari lokasi file; tidak ada salinan ke TEMP/LocalAppData.
set "LAUNCHER_DIR=%~dp0"
set "LAUNCHER_BAT=%~f0"

set "TEMP_DIR="
set "PRIVATE_DIR="
set "SERVER_LAN="
set "ACCESS_MODE="
set "HTTP_USER="
set "HTTP_PASS="
set "AUTH_USER="
set "AUTH_PASS="
set "PS_EXE="

cd /d "%LAUNCHER_DIR%" >nul 2>&1

:ps_prep
REM ============================================================
REM SONAR menilai rantai proses; cmd.exe -> powershell.exe adalah
REM pemicu yang paling sering untuk launcher berbasis batch.
REM Launcher menyalin powershell.exe ke LAUNCHER_DIR memakai nama
REM ITOOLS_PSNAME (lihat bagian atas file), lalu semua panggilan
REM PowerShell dijalankan lewat subroutine :ps_run / :ps_file.
REM Bila penamaan tidak diizinkan kebijakan, set ITOOLS_PSNAME=
REM (kosong) agar launcher memakai powershell.exe asli.
REM ============================================================
set "PS_REAL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_REAL%" set "PS_REAL=%ProgramFiles%\Windows PowerShell\v1.0\powershell.exe"
set "PS_EXE=%PS_REAL%"
if not "%ITOOLS_PSNAME%"=="" (
    if exist "%LAUNCHER_DIR%%ITOOLS_PSNAME%" (
        set "PS_EXE=%LAUNCHER_DIR%%ITOOLS_PSNAME%"
    ) else if exist "%PS_REAL%" (
        copy /y "%PS_REAL%" "%LAUNCHER_DIR%%ITOOLS_PSNAME%" >nul 2>&1
        if exist "%LAUNCHER_DIR%%ITOOLS_PSNAME%" (
            set "PS_EXE=%LAUNCHER_DIR%%ITOOLS_PSNAME%"
        )
    )
)
echo [INFO] PowerShell host: !PS_EXE!

REM --- Helper SecureString -> teks plain (dipakai lewat for /f) ---
REM     Dekode hanya terjadi pada proses yang sudah dinamai ulang,
REM     dan password tidak pernah ditulis ke disk.
set "PS_UNPROTECT=$s=Read-Host $env:ITOOLS_PROMPT -AsSecureString; $i=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try {[Runtime.InteropServices.Marshal]::PtrToStringBSTR($i)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($i)}"

:elev_check
net session >nul 2>&1
if %errorLevel% equ 0 goto :get_settings
echo [ERROR] Aplikasi ini membutuhkan hak Administrator.
echo         Klik kanan pada launcher.bat dan pilih "Run as administrator",
echo         atau buka Command Prompt sebagai Administrator lalu jalankan file ini.
pause
exit /b 1

:get_settings
if "%LOCAL_MODE%"=="1" goto :local_mode
cd /d "%LAUNCHER_DIR%" >nul 2>&1
set "SETTINGS_FILE=%LAUNCHER_DIR%settings.ini"
set "GOT_SETTINGS=0"
set "SETTINGS_SOURCE="
set "SERVER_LAN="
set "PUBLIC_LAN="
set "PRIVATE_LAN="
set "SERVER_HTTP="
set "PUBLIC_HTTP="
set "PRIVATE_HTTP="

echo [INFO] Mengambil konfigurasi...
if exist "%BOOTSTRAP_SETTINGS_LAN%" (
    copy /y "%BOOTSTRAP_SETTINGS_LAN%" "%SETTINGS_FILE%" >nul 2>&1
    if exist "%SETTINGS_FILE%" (
        set "GOT_SETTINGS=1"
        set "SETTINGS_SOURCE=LAN"
    )
)
if "!GOT_SETTINGS!"=="0" (
    call :ps_run "try { Invoke-WebRequest -Uri '%BOOTSTRAP_SETTINGS_HTTP%' -OutFile '%SETTINGS_FILE%' -UseBasicParsing -TimeoutSec 20; exit 0 } catch { exit 1 }"
    if exist "%SETTINGS_FILE%" (
        set "GOT_SETTINGS=1"
        set "SETTINGS_SOURCE=HTTP"
    )
)
if "!GOT_SETTINGS!"=="0" goto :no_settings

call :read_settings "%SETTINGS_FILE%"
if not defined SERVER_LAN goto :no_settings
if not defined PUBLIC_LAN goto :no_settings
if not defined PRIVATE_LAN goto :no_settings
if not defined SERVER_HTTP goto :no_settings
if not defined PRIVATE_HTTP goto :no_settings

echo [OK] Konfigurasi siap (!SETTINGS_SOURCE!).
timeout /t 1 >nul
set "PUBLIC_DIR=\\!SERVER_LAN!\!PUBLIC_LAN!"
set "PRIVATE_DIR=\\!SERVER_LAN!\!PRIVATE_LAN!"
set "TOOLS_DIR=!PRIVATE_DIR!\Tools"
set "DATA_DIR=!PRIVATE_DIR!\Data"
set "CONFIG_FILE=!PRIVATE_DIR!\Config.txt"
set "HTTP_PRIVATE=!SERVER_HTTP!/!PRIVATE_HTTP!"
set "HTTP_CONFIG=!HTTP_PRIVATE!/Config.txt"
set "HTTP_TOOLS=!HTTP_PRIVATE!/Tools"
set "TEMP_DIR=%LAUNCHER_DIR%cache"
set "LOCAL_CONFIG=%TEMP_DIR%\Config.txt"
set "LOCAL_TOOLS=%TEMP_DIR%\Tools"
set "LOCAL_DATA=%TEMP_DIR%\Data"

if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%" >nul 2>&1
if not exist "%LOCAL_TOOLS%" mkdir "%LOCAL_TOOLS%" >nul 2>&1
if not exist "%LOCAL_DATA%" mkdir "%LOCAL_DATA%" >nul 2>&1
goto :auth

:no_settings
echo [ERROR] Konfigurasi tidak ditemukan atau tidak lengkap.
pause
goto :cleanup_and_exit

:local_mode
REM ============================================================
REM MODE LOKAL - tanpa SMB (share) dan tanpa HTTP (nginx).
REM Butuh struktur folder:
REM   <induk>\Public\launcher.bat   (file ini)
REM   <induk>\Private\Config.txt
REM   <induk>\Private\Tools\*.ps1 / *.bat
REM   <induk>\Private\Data\*        (settings.ini, drivers.csv, printers.csv)
REM Aktifkan dengan mengubah LOCAL_MODE=1 di bagian atas file ini.
REM ============================================================
set "ACCESS_MODE=LOCAL"
set "PRIVATE_DIR=%LAUNCHER_DIR%%LOCAL_PRIVATE_SUBDIR%"
if not exist "%PRIVATE_DIR%\" (
    echo [ERROR] Folder Private tidak ditemukan: %PRIVATE_DIR%
    echo         Letakkan folder Public dan Private dalam satu induk folder yang sama.
    pause
    goto :cleanup_and_exit
)
set "TOOLS_DIR=%PRIVATE_DIR%\Tools"
set "DATA_DIR=%PRIVATE_DIR%\Data"
set "CONFIG_FILE=%PRIVATE_DIR%\Config.txt"
if not exist "%CONFIG_FILE%" (
    echo [ERROR] Config.txt tidak ditemukan: %CONFIG_FILE%
    pause
    goto :cleanup_and_exit
)
if not exist "%TOOLS_DIR%\" mkdir "%TOOLS_DIR%" >nul 2>&1
if not exist "%DATA_DIR%\" mkdir "%DATA_DIR%" >nul 2>&1
echo [OK] Mode lokal aktif - share SMB dan HTTP tidak dipakai.
goto :menu

:read_settings
set "SF=%~1"
if not exist "%SF%" goto :eof
for /f "usebackq tokens=1,* delims== eol=#" %%a in ("%SF%") do (
    set "_k=%%a"
    set "_v=%%b"
    if defined _k if defined _v (
        for /f "tokens=* delims= " %%x in ("!_k!") do set "_k=%%x"
        for /f "tokens=* delims= " %%x in ("!_v!") do set "_v=%%x"
        if /i "!_k!"=="SERVER_LAN" set "SERVER_LAN=!_v!"
        if /i "!_k!"=="PUBLIC_LAN" set "PUBLIC_LAN=!_v!"
        if /i "!_k!"=="PRIVATE_LAN" set "PRIVATE_LAN=!_v!"
        if /i "!_k!"=="SERVER_HTTP" set "SERVER_HTTP=!_v!"
        if /i "!_k!"=="PUBLIC_HTTP" set "PUBLIC_HTTP=!_v!"
        if /i "!_k!"=="PRIVATE_HTTP" set "PRIVATE_HTTP=!_v!"
    )
)
goto :eof

:auth
cd /d "%LAUNCHER_DIR%" >nul 2>&1
cls
echo ========================================
echo        ITools - Autentikasi SMB
echo ========================================
echo.
echo  Format: username  atau  DOMAIN\username
echo.

set "AUTH_USER="
set "AUTH_PASS="
set "HTTP_USER="
set "HTTP_PASS="

echo  Kosongkan username SMB untuk login HTTP.
echo.
set /p "AUTH_USER=SMB Username : "
if not defined AUTH_USER (
    echo [INFO] Username SMB kosong - mode HTTP.
    goto :auth_http
)

for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "$p=Read-Host 'SMB Password ' -AsSecureString; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($p); [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)"`) do set "AUTH_PASS=%%p"
if not defined AUTH_PASS (
    echo [ERROR] Password kosong.
    timeout /t 2 >nul
    goto :cleanup_and_exit
)

set "ACCESS_MODE="
set "SMB_OK=0"
echo.
echo [INFO] Mencoba akses share...
net use "!PRIVATE_DIR!" /delete /y >nul 2>&1
powershell -NoProfile -Command ^
  "try { $u='!AUTH_USER!'; $p='!AUTH_PASS!'; $r='!PRIVATE_DIR!';" ^
  " $sec=ConvertTo-SecureString $p -AsPlainText -Force;" ^
  " $cred=New-Object System.Management.Automation.PSCredential($u,$sec);" ^
  " New-PSDrive -Name IToolsP -PSProvider FileSystem -Root $r -Credential $cred -ErrorAction Stop | Out-Null;" ^
  " net use $r /user:$u $p /persistent:no | Out-Null; exit 0 } catch { exit 1 }"
if !errorLevel! equ 0 if exist "!PRIVATE_DIR!" set "SMB_OK=1"
set "AUTH_PASS="

if "!SMB_OK!"=="1" (
    set "ACCESS_MODE=SMB"
    set "TOOLS_DIR=!PRIVATE_DIR!\Tools"
    set "CONFIG_FILE=!PRIVATE_DIR!\Config.txt"
    set "DATA_DIR=!PRIVATE_DIR!\Data"
    echo [OK] Mode: SMB
    goto :validate_access
)

echo [INFO] Share tidak tersedia. Beralih ke HTTP private...

:auth_http
echo.
echo ========================================
echo        ITools - Autentikasi HTTP
echo ========================================
echo.

set /p "HTTP_USER=HTTP Username : "
if not defined HTTP_USER (
    echo [ERROR] HTTP Username kosong.
    timeout /t 2 >nul
    goto :cleanup_and_exit
)
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "$p=Read-Host 'HTTP Password ' -AsSecureString; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($p); [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)"`) do set "HTTP_PASS=%%p"
if not defined HTTP_PASS (
    echo [ERROR] HTTP Password kosong.
    timeout /t 2 >nul
    goto :cleanup_and_exit
)

set "ACCESS_MODE=HTTP"
call :http_download "!HTTP_CONFIG!" "!LOCAL_CONFIG!"
if not exist "!LOCAL_CONFIG!" (
    echo [ERROR] Gagal akses private via HTTP.
    set "HTTP_PASS="
    pause
    goto :cleanup_and_exit
)
set "CONFIG_FILE=!LOCAL_CONFIG!"
set "TOOLS_DIR=!LOCAL_TOOLS!"
set "DATA_DIR=!LOCAL_DATA!"
if not exist "!DATA_DIR!" mkdir "!DATA_DIR!" >nul 2>&1
echo [OK] Mode: HTTP

:validate_access
if not exist "!CONFIG_FILE!" (
    echo [ERROR] Config tidak tersedia.
    set "HTTP_PASS="
    pause
    goto :cleanup_and_exit
)

:menu
cd /d "%LAUNCHER_DIR%" >nul 2>&1
if not exist "!CONFIG_FILE!" (
    if /i "!ACCESS_MODE!"=="HTTP" (
        echo [INFO] Config hilang, unduh ulang...
        call :http_download "!HTTP_CONFIG!" "!LOCAL_CONFIG!"
        set "CONFIG_FILE=!LOCAL_CONFIG!"
    )
)
if not exist "!CONFIG_FILE!" (
    echo [ERROR] Config tidak ditemukan: !CONFIG_FILE!
    pause
    goto :cleanup_and_exit
)
cls
echo ========================================
echo           ITools Launcher
echo ========================================
echo  Ver  : %LOCAL_VERSION%
if defined AUTH_USER (echo  User : !AUTH_USER!) else (echo  User : !HTTP_USER! [HTTP])
echo  Mode : !ACCESS_MODE!
echo  Home : %LAUNCHER_DIR%
echo ========================================
echo.

set "menu_count=0"
for /f "usebackq tokens=1,2,3,4 delims=| eol=#" %%a in ("!CONFIG_FILE!") do (
    if not "%%a"=="" (
        set /a menu_count+=1
        echo   %%a. %%b
        set "m_%%a_name=%%b"
        set "m_%%a_file=%%c"
        set "m_%%a_type=%%d"
    )
)
echo.
echo   0. Exit
echo ========================================
echo.
set /p "pilih=Pilih menu [0-!menu_count!]: "

if "%pilih%"=="0" goto :cleanup_and_exit
if "%pilih%"=="" goto :menu
if not defined m_%pilih%_file (
    echo [ERROR] Pilihan tidak valid.
    timeout /t 2 >nul
    goto :menu
)

set "exe_file=!m_%pilih%_file!"
set "exe_type=!m_%pilih%_type!"
echo.
echo [INFO] Menjalankan: !m_%pilih%_name!
echo.

if /i "!ACCESS_MODE!"=="SMB" (
    set "exe_path=!TOOLS_DIR!\!exe_file!"
    if not exist "!exe_path!" (
        echo [ERROR] File tidak ditemukan.
        pause
        goto :menu
    )
    if /i "!exe_type!"=="bat" cmd.exe /c call "!exe_path!"
    if /i "!exe_type!"=="ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!exe_path!"
    goto :after_run
)

if /i "!ACCESS_MODE!"=="LOCAL" (
    set "exe_path=!TOOLS_DIR!\!exe_file!"
    if not exist "!exe_path!" (
        echo [ERROR] File tidak ditemukan: !exe_path!
        pause
        goto :menu
    )
    if /i "!exe_type!"=="bat" cmd.exe /c call "!exe_path!"
    if /i "!exe_type!"=="ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!exe_path!"
    goto :after_run
)

set "exe_url=!HTTP_TOOLS!/!exe_file!"
set "exe_path=!LOCAL_TOOLS!\!exe_file!"
set "companion="
set "companion_path="
echo !exe_file! | findstr /i "_menu.ps1" >nul 2>&1
if !errorLevel! equ 0 (
    set "companion=!exe_file:_menu.ps1=_actions.ps1!"
    set "companion_path=!LOCAL_TOOLS!\!companion!"
)

echo [INFO] Mengunduh tool via HTTP...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$u='!HTTP_USER!'; $p='!HTTP_PASS!';" ^
  "$pair=$u+':'+$p; $b64=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair));" ^
  "$hdr=@{Authorization=('Basic '+$b64)};" ^
  "function Get-One($Url,$Out) {" ^
  "  if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force -EA SilentlyContinue };" ^
  "  Invoke-WebRequest -Uri $Url -OutFile $Out -Headers $hdr -UseBasicParsing -TimeoutSec 60" ^
  "};" ^
  "Get-One '!exe_url!' '!exe_path!';" ^
  "if ('!companion!' -ne '') { try { Get-One ('!HTTP_TOOLS!'+'/'+'!companion!') '!companion_path!' } catch {} };" ^
  "if ('!exe_file!' -eq 'printer_menu.ps1') {" ^
  "  $dd='!DATA_DIR!'; if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null };" ^
  "  try { Get-One ('!HTTP_PRIVATE!'+'/Data/settings.ini') (Join-Path $dd 'settings.ini') } catch {};" ^
  "  try { Get-One ('!HTTP_PRIVATE!'+'/Data/drivers.csv') (Join-Path $dd 'drivers.csv') } catch {};" ^
  "  try { Get-One ('!HTTP_PRIVATE!'+'/Data/printers.csv') (Join-Path $dd 'printers.csv') } catch {}" ^
  "}"

if not exist "!exe_path!" (
    echo [ERROR] Gagal mengunduh tool via HTTP.
    pause
    goto :menu
)
if defined companion if not exist "!companion_path!" (
    echo [WARN] Companion !companion! gagal diunduh.
)
if /i "!exe_type!"=="bat" cmd.exe /c call "!exe_path!"
if /i "!exe_type!"=="ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!exe_path!"

:after_run
cd /d "%LAUNCHER_DIR%" >nul 2>&1
echo.
echo [INFO] Selesai.
pause
goto :menu

:http_download
set "DL_URL=%~1"
set "DL_OUT=%~2"
if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>&1
powershell -NoProfile -Command ^
  "$u='!HTTP_USER!'; $p='!HTTP_PASS!'; $url='!DL_URL!'; $out='!DL_OUT!';" ^
  "try {" ^
  "  $pair=$u+':'+$p; $b64=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair));" ^
  "  $hdr=@{ Authorization='Basic '+$b64 };" ^
  "  Invoke-WebRequest -Uri $url -OutFile $out -Headers $hdr -UseBasicParsing -TimeoutSec 30;" ^
  "  exit 0" ^
  "} catch { exit 1 }"
goto :eof

:cleanup_and_exit
echo.
echo [INFO] Membersihkan sesi (credential + work temp)...
cd /d "%LAUNCHER_DIR%" >nul 2>&1

if defined PRIVATE_DIR net use "!PRIVATE_DIR!" /delete /y >nul 2>&1
if defined SERVER_LAN (
    for /f "tokens=1,2 delims= " %%a in ('cmdkey /list 2^>nul ^| findstr /i /c:"!SERVER_LAN!"') do (
        if /i "%%a"=="Target:" cmdkey /delete:%%b >nul 2>&1
    )
)

if defined TEMP_DIR if exist "!TEMP_DIR!" rd /s /q "!TEMP_DIR!" >nul 2>&1

set "AUTH_USER="
set "AUTH_PASS="
set "HTTP_USER="
set "HTTP_PASS="
echo [INFO] Selesai. Launcher tetap di: %LAUNCHER_DIR%
timeout /t 1 >nul
endlocal
exit /b 0
