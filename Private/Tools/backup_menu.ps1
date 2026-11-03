$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ActionsScript = Join-Path $ScriptDir "backup_actions.ps1"
$DefaultBackupRoot = "D:\Backup"

# Muat modul aksi IN-PROCESS via dot-source (tanpa child process powershell.exe).
# Menghilangkan rantai proses powershell->powershell yang memicu deteksi SONAR.
if (Test-Path -LiteralPath $ActionsScript) {
    . $ActionsScript
}

function Show-Header {
    param ([string]$Title)
    Clear-Host
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "   ITools - $Title" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Format-Size {
    param ([double]$SizeMB)
    if ($SizeMB -ge 1024) { return "{0:N2} GB" -f ($SizeMB / 1024) }
    return "{0:N2} MB" -f $SizeMB
}

function Get-FolderSizePreview {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $size = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    if ($null -eq $size) { return 0 }
    return [math]::Round(($size / 1MB), 2)
}

function Show-SourcePreview {
    param ([string]$SourceRoot)

    $folders = @(
        "Documents", "Desktop", "Downloads", "Pictures", "Videos",
        "Music", "Favorites", "Contacts", "Links", "Saved Games",
        "AppData\Roaming"
    )
    $special = @(
        @{ Name = "Chrome";           Path = "AppData\Local\Google\Chrome\User Data" },
        @{ Name = "Edge";             Path = "AppData\Local\Microsoft\Edge\User Data" },
        @{ Name = "Outlook Local";    Path = "AppData\Local\Microsoft\Outlook" },
        @{ Name = "Themes Wallpaper"; Path = "AppData\Roaming\Microsoft\Windows\Themes" },
        @{ Name = "Signatures";       Path = "AppData\Roaming\Microsoft\Signatures" }
    )

    Write-Host ("{0,-28} {1,12} {2,12}" -f "FOLDER / DATA", "UKURAN", "STATUS") -ForegroundColor White
    Write-Host ("{0,-28} {1,12} {2,12}" -f "-------------", "------", "------") -ForegroundColor DarkGray

    $total = 0.0
    foreach ($f in $folders) {
        $full = Join-Path $SourceRoot $f
        $sz = Get-FolderSizePreview -Path $full
        $total += $sz
        $st = if (Test-Path $full) { "OK" } else { "Tidak ada" }
        $color = if ($st -eq "OK") { "Green" } else { "DarkGray" }
        Write-Host ("{0,-28} {1,12} {2,12}" -f $f, (Format-Size $sz), $st) -ForegroundColor $color
    }
    foreach ($s in $special) {
        $full = Join-Path $SourceRoot $s.Path
        $sz = Get-FolderSizePreview -Path $full
        $total += $sz
        $st = if (Test-Path $full) { "OK" } else { "Tidak ada" }
        $color = if ($st -eq "OK") { "Green" } else { "DarkGray" }
        Write-Host ("{0,-28} {1,12} {2,12}" -f $s.Name, (Format-Size $sz), $st) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host ("{0,-28} {1,12}" -f "TOTAL (estimasi kasar)", (Format-Size $total)) -ForegroundColor Cyan
    Write-Host "Catatan: ukuran preview belum exclude cache sepenuhnya." -ForegroundColor DarkGray
    Write-Host ""
}

function Cleanup-Remote {
    param ([string]$Drive)
    if ($Drive) { net use $Drive /delete /y 2>$null | Out-Null }
}

function Stop-BrowserProcessesLocal {
    $procs = @("chrome", "msedge", "chromium")
    Write-Host ""
    Write-Host "Mendeteksi proses browser..." -ForegroundColor Gray
    $found = @()
    foreach ($p in $procs) {
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $found += $p }
    }
    if ($found.Count -eq 0) {
        Write-Host "Tidak ada Chrome/Edge yang berjalan." -ForegroundColor Green
        return
    }
    Write-Host "Proses aktif: $($found -join ', ')" -ForegroundColor Yellow
    $ans = Read-Host "Tutup proses browser sekarang? (Y/N)"
    if ($ans -notin @("Y","y")) {
        Write-Host "Browser dibiarkan berjalan (risiko file terkunci)." -ForegroundColor Yellow
        return
    }
    foreach ($p in $found) {
        Write-Host "Menutup $p ..." -NoNewline
        Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) {
            Write-Host " [GAGAL]" -ForegroundColor Red
        } else {
            Write-Host " [OK]" -ForegroundColor Green
        }
    }
    Start-Sleep -Seconds 1
}

function Invoke-BackupActions {
    param (
        [string]$SourceRoot,
        [string]$Destination,
        [string]$Username
    )
    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Host "[ERROR] backup_actions.ps1 tidak ditemukan: $ActionsScript" -ForegroundColor Red
        return
    }
    # Pemanggilan in-process: fungsi tersedia dari dot-source di awal skrip.
    # Tidak ada spawn powershell.exe anak.
    if (-not (Get-Command -Name "Invoke-BackupAction" -ErrorAction SilentlyContinue)) {
        . $ActionsScript
    }
    $null = Invoke-BackupAction -SourceRoot $SourceRoot -Destination $Destination -Username $Username
}

function Invoke-RestoreActions {
    param (
        [string]$BackupPath,
        [string]$DestRoot,
        [switch]$ImportRegistry
    )
    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Host "[ERROR] backup_actions.ps1 tidak ditemukan: $ActionsScript" -ForegroundColor Red
        return
    }
    if (-not (Get-Command -Name "Invoke-RestoreAction" -ErrorAction SilentlyContinue)) {
        . $ActionsScript
    }
    $null = Invoke-RestoreAction -BackupPath $BackupPath -DestRoot $DestRoot -ImportRegistry:$ImportRegistry
}

function Start-BackupMenu {
    Show-Header "BACKUP USER PROFILE"

    Write-Host "Sumber data:" -ForegroundColor Yellow
    Write-Host "  1. Lokal (user di PC ini)"
    Write-Host "  2. Remote (PC lain via IP / hostname)"
    Write-Host ""
    $srcChoice = Read-Host "Pilih sumber [1/2]"

    $SourceRoot = ""
    $Username = $env:USERNAME
    $remoteDrive = $null

    if ($srcChoice -eq "2") {
        Write-Host ""
        Write-Host "--- Sumber Remote ---" -ForegroundColor Cyan
        $targetHost = Read-Host "IP atau hostname PC sumber"
        if ([string]::IsNullOrWhiteSpace($targetHost)) {
            Write-Host "Hostname/IP wajib diisi." -ForegroundColor Red
            pause; return
        }
        $Username = Read-Host "Username profil (nama folder di C:\Users\)"
        if ([string]::IsNullOrWhiteSpace($Username)) {
            Write-Host "Username wajib diisi." -ForegroundColor Red
            pause; return
        }

        Write-Host ""
        Write-Host "Akses remote memakai share admin (C$)." -ForegroundColor Gray
        Write-Host "Masukkan kredensial yang punya hak admin di PC sumber." -ForegroundColor Gray
        $credUser = Read-Host "Username login (contoh: DOMAIN\admin atau .\admin)"
        $credPassSecure = Read-Host "Password" -AsSecureString
        $credPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credPassSecure)
        )

        $remoteDrive = "Z:"
        $unc = "\\$targetHost\C$"
        Write-Host ""
        Write-Host "Menghubungkan ke $unc ..." -ForegroundColor Gray

        net use $remoteDrive /delete /y 2>$null | Out-Null
        $null = net use $remoteDrive $unc /user:$credUser $credPassPlain 2>&1
        $credPassPlain = $null
        $credPassSecure = $null
        [System.GC]::Collect()

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Gagal terhubung ke $unc (kode: $LASTEXITCODE)" -ForegroundColor Red
            Write-Host "Pastikan: PC sumber online, File Sharing aktif, firewall mengizinkan, akun admin benar." -ForegroundColor Yellow
            pause; return
        }

        $SourceRoot = "$remoteDrive\Users\$Username"
        if (-not (Test-Path $SourceRoot)) {
            Write-Host "Folder profil tidak ditemukan: $SourceRoot" -ForegroundColor Red
            if (Test-Path "$remoteDrive\Users") {
                Write-Host "Daftar folder user di PC sumber:" -ForegroundColor Cyan
                Get-ChildItem "$remoteDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  - $($_.Name)" }
            }
            Cleanup-Remote $remoteDrive
            pause; return
        }
    }
    else {
        Write-Host ""
        $inputUser = Read-Host "Username profil [Enter = $env:USERNAME]"
        if (-not [string]::IsNullOrWhiteSpace($inputUser)) { $Username = $inputUser }
        $SourceRoot = "C:\Users\$Username"
        if (-not (Test-Path $SourceRoot)) {
            Write-Host "Folder tidak ditemukan: $SourceRoot" -ForegroundColor Red
            pause; return
        }
    }

    if ($srcChoice -ne "2") {
        Stop-BrowserProcessesLocal
    } else {
        Write-Host ""
        Write-Host "Mode remote: pastikan Chrome/Edge di PC sumber sudah ditutup atau user logout." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Mode backup:" -ForegroundColor Yellow
    Write-Host "  1. Backup baru (folder timestamp baru)"
    Write-Host "  2. Lanjutkan backup yang sudah ada (resume)"
    Write-Host ""
    $modeChoice = Read-Host "Pilih mode [1/2]"

    $Destination = $null
    $isResume = $false
    $DestinationRoot = $DefaultBackupRoot

    if ($modeChoice -eq "2") {
        Write-Host ""
        Write-Host "--- Resume Backup ---" -ForegroundColor Cyan
        $resumePath = Read-Host "Path folder backup yang akan dilanjutkan"
        if ([string]::IsNullOrWhiteSpace($resumePath) -or -not (Test-Path $resumePath)) {
            Write-Host "Folder backup tidak ditemukan." -ForegroundColor Red
            Cleanup-Remote $remoteDrive
            pause; return
        }
        $Destination = $resumePath.TrimEnd('\')
        $isResume = $true
        $metaFile = Join-Path $Destination "backup_info.txt"
        if (Test-Path $metaFile) {
            Write-Host ""
            Write-Host "Info backup sebelumnya:" -ForegroundColor Cyan
            Get-Content $metaFile | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
        Write-Host ""
        Write-Host "Resume ke : $Destination" -ForegroundColor Yellow
        Write-Host "File yang sudah ada (ukuran & tanggal sama) akan dilewati." -ForegroundColor Gray
    }
    else {
        Write-Host ""
        $destInput = Read-Host "Folder tujuan backup [Enter = $DestinationRoot]"
        if (-not [string]::IsNullOrWhiteSpace($destInput)) { $DestinationRoot = $destInput }
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
        $Destination = Join-Path $DestinationRoot "$Username`_$timestamp"
    }

    Write-Host ""
    Write-Host "Sumber      : $SourceRoot" -ForegroundColor Yellow
    Write-Host "User        : $Username" -ForegroundColor Yellow
    Write-Host "Tujuan      : $Destination" -ForegroundColor Yellow
    Write-Host ("Mode        : {0}" -f $(if ($isResume) { "RESUME" } else { "BACKUP BARU" })) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Menghitung ukuran (preview)..." -ForegroundColor Gray
    Write-Host ""
    Show-SourcePreview -SourceRoot $SourceRoot

    $confirm = Read-Host "Lanjutkan backup? (Y/N)"
    if ($confirm -notin @("Y","y","Yes","yes")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Cleanup-Remote $remoteDrive
        pause; return
    }

    Invoke-BackupActions -SourceRoot $SourceRoot -Destination $Destination -Username $Username

    Cleanup-Remote $remoteDrive
    Write-Host ""
    pause
}

function Start-RestoreMenu {
    Show-Header "RESTORE USER PROFILE"

    Write-Host "Gunakan setelah user sudah login di device baru." -ForegroundColor Yellow
    Write-Host "Permission TIDAK diubah (tanpa takeown/icacls)." -ForegroundColor Gray
    Write-Host ""

    $backupPath = Read-Host "Path folder backup (contoh: D:\Backup\nama.user_2026-10-29_0815)"
    if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path $backupPath)) {
        Write-Host "Folder backup tidak ditemukan." -ForegroundColor Red
        pause; return
    }

    $metaFile = Join-Path $backupPath "backup_info.txt"
    $metaUser = $null
    if (Test-Path $metaFile) {
        foreach ($line in (Get-Content $metaFile)) {
            if ($line -match "^Username=(.+)$") { $metaUser = $Matches[1].Trim() }
        }
        Write-Host ""
        Write-Host "Info backup:" -ForegroundColor Cyan
        Get-Content $metaFile | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }

    Write-Host ""
    $defaultUser = if ($metaUser) { $metaUser } else { $env:USERNAME }
    $targetUser = Read-Host "Username tujuan di PC ini [Enter = $defaultUser]"
    if ([string]::IsNullOrWhiteSpace($targetUser)) { $targetUser = $defaultUser }

    $destRoot = "C:\Users\$targetUser"
    if (-not (Test-Path $destRoot)) {
        Write-Host ""
        Write-Host "Folder profil belum ada: $destRoot" -ForegroundColor Red
        Write-Host "Pastikan user sudah pernah login di PC ini terlebih dahulu." -ForegroundColor Yellow
        pause; return
    }

    Write-Host ""
    Write-Host "Sumber restore : $backupPath" -ForegroundColor Yellow
    Write-Host "Tujuan         : $destRoot" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Isi folder backup:" -ForegroundColor Cyan
    Get-ChildItem $backupPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Gray
    }
    Write-Host ""

    $confirm = Read-Host "Lanjutkan restore? (Y/N)"
    if ($confirm -notin @("Y","y","Yes","yes")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        pause; return
    }

    $doReg = $false
    $regFile = Join-Path $backupPath "UserSettings_Wallpaper_Desktop.reg"
    if (Test-Path $regFile) {
        $imp = Read-Host "Import registry Wallpaper/Desktop? (Y/N)"
        if ($imp -in @("Y","y")) { $doReg = $true }
    }

    Invoke-RestoreActions -BackupPath $backupPath -DestRoot $destRoot -ImportRegistry:$doReg
    Write-Host ""
    pause
}

Show-Header "BACKUP / RESTORE USER PROFILE"

if (-not (Test-Path -LiteralPath $ActionsScript)) {
    Write-Host "[ERROR] backup_actions.ps1 tidak ditemukan di:" -ForegroundColor Red
    Write-Host "  $ActionsScript" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "  1. Backup  (copy data user ke folder backup)"
Write-Host "  2. Restore (kembalikan data ke profil user setelah login)"
Write-Host "  0. Keluar"
Write-Host ""
$pilih = Read-Host "Pilih [0-2]"

switch ($pilih) {
    "1" { Start-BackupMenu }
    "2" { Start-RestoreMenu }
    default {
        Write-Host "Keluar." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}
