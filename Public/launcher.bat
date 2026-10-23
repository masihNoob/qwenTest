@echo off
setlocal EnableDelayedExpansion
title ITools Launcher
color 0A

:: ============================================================
:: ITools Launcher
:: settings: LAN dulu, fallback HTTP
:: Tools: SMB dulu, fallback HTTP + Basic Auth untuk private
:: ============================================================
set "BOOTSTRAP_SETTINGS_LAN=\\localhost\itool$\settings.ini"
set "BOOTSTRAP_SETTINGS_HTTP=http://localhost/files/public/settings.ini"

set "LOCAL_DIR=%TEMP%\ITools_Launcher"
set "LOCAL_BAT=%LOCAL_DIR%\launcher.bat"
set "LOCAL_SETTINGS=%LOCAL_DIR%\settings.ini"
set "TEMP_DIR="
set "PRIVATE_DIR="
set "SERVER_LAN="
set "ACCESS_MODE="
set "HTTP_USER="
set "HTTP_PASS="

:: ------------------------------------------------------------
:: 0. Salinan lokal
:: ------------------------------------------------------------
if /i "%~f0"=="%LOCAL_BAT%" goto :elev_check
if not exist "%LOCAL_DIR%" mkdir "%LOCAL_DIR%" >nul 2>&1
copy /y "%~f0" "%LOCAL_BAT%" >nul 2>&1
start "" /D "%LOCAL_DIR%" "%LOCAL_BAT%"
exit /b

:: ------------------------------------------------------------
:: 1. Elevate
:: ------------------------------------------------------------
:elev_check
net session >nul 2>&1
if %errorLevel% equ 0 goto :get_settings
echo [INFO] Meminta hak Administrator...
powershell -NoProfile -Command "Start-Process -FilePath '%LOCAL_BAT%' -WorkingDirectory '%LOCAL_DIR%' -Verb RunAs"
exit /b

:: ------------------------------------------------------------
:: 2. Settings.ini - selalu timpa dari server
:: ------------------------------------------------------------
:get_settings
set "SETTINGS_FILE=%LOCAL_SETTINGS%"
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
    powershell -NoProfile -Command "try { Invoke-WebRequest -Uri '%BOOTSTRAP_SETTINGS_HTTP%' -OutFile '%SETTINGS_FILE%' -UseBasicParsing -TimeoutSec 20; exit 0 } catch { exit 1 }"
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

echo [OK] Konfigurasi siap.
timeout /t 1 >nul

set "PUBLIC_DIR=\\!SERVER_LAN!\!PUBLIC_LAN!"
set "PRIVATE_DIR=\\!SERVER_LAN!\!PRIVATE_LAN!"
set "TOOLS_DIR=!PRIVATE_DIR!\Tools"
set "DATA_DIR=!PRIVATE_DIR!\Data"
set "CONFIG_FILE=!PRIVATE_DIR!\Config.txt"
set "HTTP_PRIVATE=!SERVER_HTTP!/!PRIVATE_HTTP!"
set "HTTP_CONFIG=!HTTP_PRIVATE!/Config.txt"
set "HTTP_TOOLS=!HTTP_PRIVATE!/Tools"
set "TEMP_DIR=%TEMP%\ITools_Work"
set "LOCAL_CONFIG=%TEMP_DIR%\Config.txt"
set "LOCAL_TOOLS=%TEMP_DIR%\Tools"

if exist "%TEMP_DIR%" rd /s /q "%TEMP_DIR%" >nul 2>&1
mkdir "%TEMP_DIR%" >nul 2>&1
mkdir "%LOCAL_TOOLS%" >nul 2>&1

goto :auth

:no_settings
echo [ERROR] Konfigurasi tidak ditemukan atau tidak lengkap.
pause
goto :cleanup_and_exit

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

:: ------------------------------------------------------------
:: 3. Autentikasi SMB, fallback HTTP + Basic Auth
:: ------------------------------------------------------------
:auth
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

set /p "AUTH_USER=SMB Username : "
if not defined AUTH_USER (
    echo [ERROR] Username kosong.
    timeout /t 2 >nul
    goto :cleanup_and_exit
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

:: Hapus password SMB dari memori segera setelah dipakai
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
echo.
echo ========================================
echo        ITools - Autentikasi HTTP
echo ========================================
echo  Akses files/private membutuhkan
echo  username dan password tersendiri.
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

:: Unduh Config.txt dengan Basic Auth HTTP terpisah
call :http_download "!HTTP_CONFIG!" "!LOCAL_CONFIG!"
if not exist "!LOCAL_CONFIG!" (
    echo [ERROR] Gagal akses private via HTTP.
    echo         Periksa HTTP user/password atau server.
    set "HTTP_PASS="
    pause
    goto :cleanup_and_exit
)

set "CONFIG_FILE=!LOCAL_CONFIG!"
set "TOOLS_DIR=!LOCAL_TOOLS!"
set "DATA_DIR=!TEMP_DIR!\Data"
if not exist "!DATA_DIR!" mkdir "!DATA_DIR!" >nul 2>&1
echo [OK] Mode: HTTP

:validate_access
if not exist "!CONFIG_FILE!" (
    echo [ERROR] Config tidak tersedia.
    set "HTTP_PASS="
    pause
    goto :cleanup_and_exit
)

:: ------------------------------------------------------------
:: 4. Menu
:: ------------------------------------------------------------
:menu
cls
echo ========================================
echo           ITools Launcher
echo ========================================
echo  User : !AUTH_USER!
echo  Mode : !ACCESS_MODE!
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
    if /i "!exe_type!"=="bat" call "!exe_path!"
    if /i "!exe_type!"=="ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "!exe_path!"
    goto :after_run
)

:: Mode HTTP: unduh tool dengan Basic Auth
set "exe_url=!HTTP_TOOLS!/!exe_file!"
set "exe_path=!LOCAL_TOOLS!\!exe_file!"
call :http_download "!exe_url!" "!exe_path!"
if not exist "!exe_path!" (
    echo [ERROR] Gagal mengunduh tool via HTTP.
    pause
    goto :menu
)
if /i "!exe_type!"=="bat" call "!exe_path!"
if /i "!exe_type!"=="ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "!exe_path!"

:after_run
echo.
echo [INFO] Selesai.
pause
goto :menu

:: ------------------------------------------------------------
:: Unduh file HTTP dengan Basic Auth (untuk /files/private)
:: Usage: call :http_download "URL" "OUTFILE"
:: ------------------------------------------------------------
:http_download
set "DL_URL=%~1"
set "DL_OUT=%~2"
if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>&1
powershell -NoProfile -Command ^
  "$u='!HTTP_USER!'; $p='!HTTP_PASS!'; $url='!DL_URL!'; $out='!DL_OUT!';" ^
  "try {" ^
  "  $pair = $u + ':' + $p;" ^
  "  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair));" ^
  "  $hdr = @{ Authorization = 'Basic ' + $b64 };" ^
  "  Invoke-WebRequest -Uri $url -OutFile $out -Headers $hdr -UseBasicParsing -TimeoutSec 30;" ^
  "  exit 0" ^
  "} catch { exit 1 }"
goto :eof

:: ------------------------------------------------------------
:: 5. Cleanup
:: ------------------------------------------------------------
:cleanup_and_exit
echo.
echo [INFO] Membersihkan...

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
echo [INFO] Selesai.
timeout /t 1 >nul
start "" /min cmd /c "timeout /t 2 /nobreak >nul & rd /s /q %TEMP%\ITools_Launcher >nul 2>&1"
endlocal
exit /b 0
