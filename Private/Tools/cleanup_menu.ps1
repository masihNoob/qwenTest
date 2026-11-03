$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ActionsScript = Join-Path $ScriptDir "cleanup_actions.ps1"

# Muat modul aksi IN-PROCESS via dot-source (tanpa child process baru).
# Ini menghilangkan rantai proses powershell->powershell yang memicu SONAR.
if (Test-Path -LiteralPath $ActionsScript) {
    . $ActionsScript
}

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn-Host([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-ActionsPresent {
    if (Test-Path -LiteralPath $ActionsScript) { return $true }
    Write-Err ("cleanup_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
    Write-Host ""
    Write-Host "  Mode HTTP: pastikan companion ikut terunduh oleh launcher." -ForegroundColor Yellow
    Write-Host "  Mode SMB : pastikan file ada di share Tools." -ForegroundColor Yellow
    return $false
}

function Invoke-CleanupAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if (-not (Test-ActionsPresent)) { return }

    Write-Info ("Menjalankan aksi: {0}" -f $Action)
    Write-Host ""

    # Pemanggilan in-process: tidak ada spawn powershell.exe anak.
    # Fungsi Invoke-Cleanup tersedia dari dot-source di awal skrip.
    if (Get-Command -Name "Invoke-Cleanup" -ErrorAction SilentlyContinue) {
        $null = Invoke-Cleanup -Action $Action
    } else {
        # Fallback aman bila dot-source gagal (mis. file companion berubah)
        Write-Warn-Host "Modul aksi belum termuat, memuat ulang..."
        . $ActionsScript
        $null = Invoke-Cleanup -Action $Action
    }
}

function Confirm-Run {
    param([string]$Message = "Lanjutkan?")
    Write-Host ""
    $ans = Read-Host "$Message [Y/N]"
    return ($ans -match '^[Yy]')
}

function Show-DiskInline {
    Write-Host "Status disk saat ini:" -ForegroundColor Cyan
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
            $free  = [double]$_.FreeSpace
            $total = [double]$_.Size
            $pct   = if ($total -gt 0) { [math]::Round(($free / $total) * 100, 1) } else { 0 }
            $fmt = {
                param($b)
                if ($b -ge 1GB) { "{0:N2} GB" -f ($b/1GB) }
                elseif ($b -ge 1MB) { "{0:N2} MB" -f ($b/1MB) }
                else { "{0:N0} B" -f $b }
            }
            Write-Host ("  {0}  Bebas: {1} / {2}  ({3}%)" -f $_.DeviceID, (& $fmt $free), (& $fmt $total), $pct)
        }
    } catch {
        Write-Host "  (gagal membaca info disk)" -ForegroundColor DarkGray
    }
}

function Start-FullCleanup {
    Show-Header "SYSTEM CLEANUP - Full Safe Cleanup"
    Write-Host "Target: file sementara, cache, log, prefetch, update cache,"
    Write-Host "        browser cache, DNS. TIDAK menyentuh Recycle Bin."
    Write-Host ""
    Write-Host "Peringatan: tutup browser & aplikasi berat sebelum lanjut." -ForegroundColor Yellow
    Write-Host ""

    Show-DiskInline
    if (-not (Confirm-Run "Jalankan full cleanup?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        return
    }

    Invoke-CleanupAction -Action "full"
}

function Start-CustomCleanup {
    Show-Header "SYSTEM CLEANUP - Pilih Kategori"
    Write-Host "  1. Temp User + INetCache"
    Write-Host "  2. Temp Windows + Prefetch + Thumbnail"
    Write-Host "  3. Windows Update & Delivery Optimization"
    Write-Host "  4. Log, Error Report, Dump, Font Cache"
    Write-Host "  5. Cache Browser (Chrome/Edge/Firefox)"
    Write-Host "  6. DNS Flush saja"
    Write-Host "  0. Kembali"
    Write-Host ""
    $pilih = Read-Host "Pilih [0-6] (bisa multiple, pisah koma, contoh 1,2,5)"

    if ($pilih -eq "0" -or [string]::IsNullOrWhiteSpace($pilih)) { return }

    $map = @{
        "1" = "user-temp"
        "2" = "windows-temp"
        "3" = "update-cache"
        "4" = "logs"
        "5" = "browser"
        "6" = "dns"
    }

    $ids = $pilih -split '[, ]+' | Where-Object { $_ -match '^\d+$' }
    $actions = @()
    foreach ($id in $ids) {
        if ($map.ContainsKey($id)) { $actions += $map[$id] }
    }

    if ($actions.Count -eq 0) {
        Write-Err "Pilihan tidak valid."
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Write-Host ("Kategori: {0}" -f ($actions -join ", ")) -ForegroundColor Cyan
    if (-not (Confirm-Run "Jalankan kategori terpilih?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        return
    }

    Invoke-CleanupAction -Action ($actions -join ",")
}

function Show-DiskOnly {
    Show-Header "STATUS DISK"
    Show-DiskInline
}

Show-Header "SYSTEM CLEANUP"
Write-Host "  Membersihkan file tidak penting untuk:"
Write-Host "  - Mempercepat kinerja Windows"
Write-Host "  - Memperbesar ruang penyimpanan kosong"
Write-Host ""
Write-Host "  Recycle Bin TIDAK akan dihapus." -ForegroundColor Green
Write-Host ""
Write-Host "  1. Full Safe Cleanup (semua kategori aman)"
Write-Host "  2. Pilih kategori manual"
Write-Host "  3. Lihat status disk saja"
Write-Host "  0. Keluar"
Write-Host ""
$pilih = Read-Host "Pilih [0-3]"

switch ($pilih) {
    "1" { Start-FullCleanup }
    "2" { Start-CustomCleanup }
    "3" { Show-DiskOnly }
    default {
        Write-Host "Keluar." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        exit 0
    }
}

Write-Host ""
Read-Host "Tekan Enter untuk kembali ke menu"
exit 0
