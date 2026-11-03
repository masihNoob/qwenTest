# ============================================================
# report_menu.ps1 - menu Generate System Report
# Memanggil report_actions.ps1 untuk aksi sebenarnya
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ActionsScript = Join-Path $ScriptDir "report_actions.ps1"

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
    Write-Err ("report_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
    Write-Host ""
    Write-Host "  Mode HTTP: pastikan companion ikut terunduh oleh launcher." -ForegroundColor Yellow
    Write-Host "  Mode SMB : pastikan file ada di share Tools." -ForegroundColor Yellow
    return $false
}

function Invoke-ReportAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if (-not (Test-ActionsPresent)) { return }

    Write-Info ("Menjalankan aksi: {0}" -f $Action)
    Write-Host ""

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ActionsScript,
        "-Action", $Action
    )
    & powershell.exe @argList
}

function Confirm-Run {
    param([string]$Message = "Lanjutkan?")
    Write-Host ""
    $ans = Read-Host "$Message [Y/N]"
    return ($ans -match '^[Yy]')
}

function Pause-Back {
    Write-Host ""
    Read-Host "Tekan Enter untuk kembali"
}

function Do-FullReport {
    Show-Header "GENERATE REPORT - Full System"
    Write-Host "  Mengumpulkan semua info yang berguna untuk IT:"
    Write-Host "  - Serial number, nama PC, model, BIOS"
    Write-Host "  - User, domain/workgroup"
    Write-Host "  - OS, uptime, install date"
    Write-Host "  - CPU, RAM, disk, GPU"
    Write-Host "  - Network (IP, MAC, gateway, DNS)"
    Write-Host "  - Battery (+ powercfg report jika laptop)"
    Write-Host "  - Printers, Secure Boot, BitLocker"
    Write-Host ""
    Write-Host "  Output: Desktop\ITools_Reports\ (TXT + HTML)" -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Confirm-Run "Generate full report?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Invoke-ReportAction -Action "full"
    Pause-Back
}

function Do-Identity {
    Show-Header "GENERATE REPORT - Identitas Sistem"
    Write-Host "  Serial number, nama PC, manufacturer, model,"
    Write-Host "  BIOS, UUID, user login, domain/workgroup, OS."
    Write-Host ""

    if (-not (Confirm-Run "Generate identity report?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Invoke-ReportAction -Action "identity"
    Pause-Back
}

function Do-Hardware {
    Show-Header "GENERATE REPORT - Hardware"
    Write-Host "  CPU, RAM, logical/physical disk, GPU."
    Write-Host ""

    if (-not (Confirm-Run "Generate hardware report?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Invoke-ReportAction -Action "hardware"
    Pause-Back
}

function Do-Network {
    Show-Header "GENERATE REPORT - Network"
    Write-Host "  Adapter aktif, IP, MAC, gateway, DNS."
    Write-Host ""

    if (-not (Confirm-Run "Generate network report?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Invoke-ReportAction -Action "network"
    Pause-Back
}

function Do-Battery {
    Show-Header "GENERATE REPORT - Battery"
    Write-Host "  Status baterai + powercfg /batteryreport (HTML)."
    Write-Host "  Jika desktop tanpa baterai, laporan akan kosong."
    Write-Host ""

    if (-not (Confirm-Run "Generate battery report?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Invoke-ReportAction -Action "battery"
    Pause-Back
}

function Do-OpenFolder {
    Show-Header "GENERATE REPORT - Buka Folder Laporan"
    Write-Host "  Membuka Desktop\ITools_Reports"
    Write-Host ""
    Invoke-ReportAction -Action "open-folder"
    Pause-Back
}

# ---------- Main loop ----------
while ($true) {
    Show-Header "GENERATE SYSTEM REPORT"
    Write-Host "  Laporan sistem untuk teknisi & admin IT."
    Write-Host "  File disimpan di Desktop\ITools_Reports"
    Write-Host ""
    Write-Host "  1. Full System Report (semua info)"
    Write-Host "  2. Identitas saja (serial, PC, user, OS)"
    Write-Host "  3. Hardware (CPU, RAM, disk, GPU)"
    Write-Host "  4. Network (IP, MAC, gateway, DNS)"
    Write-Host "  5. Battery report"
    Write-Host "  6. Buka folder laporan"
    Write-Host "  0. Kembali ke menu ITools"
    Write-Host ""

    $pilih = Read-Host "Pilih [0-6]"

    switch ($pilih) {
        "1" { Do-FullReport }
        "2" { Do-Identity }
        "3" { Do-Hardware }
        "4" { Do-Network }
        "5" { Do-Battery }
        "6" { Do-OpenFolder }
        "0" { return }
        default {
            Write-Warn-Host "Pilihan tidak valid."
            Start-Sleep -Seconds 1
        }
    }
}
