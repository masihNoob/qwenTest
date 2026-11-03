$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ActionsScript = Join-Path $ScriptDir "update_actions.ps1"

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

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-UpdateAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$WingetId = ""
    )

    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Err ("update_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
        return
    }

    Write-Info ("Menjalankan aksi: {0}" -f $Action)
    Write-Host ""

    try {
        if ($WingetId -and $WingetId.Trim() -ne "") {
            & $ActionsScript -Action $Action -WingetId $WingetId.Trim()
        } else {
            & $ActionsScript -Action $Action
        }
    } catch {
        Write-Err ("Aksi '{0}' gagal: {1}" -f $Action, $_)
    }
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

function Do-Status {
    Show-Header "UPDATE TOOLS - Status Sistem & Update"
    Invoke-UpdateAction -Action "status"
    Pause-Back
}

function Do-Scan {
    Show-Header "UPDATE TOOLS - Scan Windows Update"
    Write-Host "Mencari update yang belum terpasang."
    Write-Host "Tidak mengunduh atau menginstal apa pun." -ForegroundColor DarkGray
    Write-Host ""
    if (-not (Confirm-Run "Jalankan scan?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-UpdateAction -Action "scan"
    Pause-Back
}

function Do-Install {
    Show-Header "UPDATE TOOLS - Install Windows Update"
    Write-Host "Akan mengunduh dan menginstal semua update Software yang tersedia."
    Write-Host "Proses bisa lama. Restart mungkin diperlukan setelah selesai." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Sesi ini bukan Administrator. Launcher ITools biasanya elevate."
        Write-Host "Jalankan ulang ITools sebagai Admin jika menu ini gagal." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not (Confirm-Run "Lanjutkan install Windows Update?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-UpdateAction -Action "install"
    Pause-Back
}

function Do-ResetWU {
    Show-Header "UPDATE TOOLS - Reset Windows Update"
    Write-Host "Memperbaiki komponen Windows Update yang macet:"
    Write-Host "  - Stop wuauserv, bits, cryptsvc, msiserver"
    Write-Host "  - Rename SoftwareDistribution & Catroot2"
    Write-Host "  - Start service kembali"
    Write-Host ""
    Write-Host "Gunakan jika scan/install error atau update stuck." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Butuh Administrator."
        Pause-Back
        return
    }

    if (-not (Confirm-Run "Reset komponen Windows Update?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-UpdateAction -Action "reset-wu"
    Pause-Back
}

function Do-WingetList {
    Show-Header "UPDATE TOOLS - Daftar Upgrade (winget)"
    Write-Host "Menampilkan aplikasi yang punya versi baru (via winget)."
    Write-Host ""
    Invoke-UpdateAction -Action "winget-list"
    Pause-Back
}

function Do-WingetUpgrade {
    Show-Header "UPDATE TOOLS - Upgrade Aplikasi (winget)"
    Write-Host "  1. Upgrade SEMUA aplikasi yang tersedia"
    Write-Host "  2. Upgrade satu paket (ketik ID, contoh Google.Chrome)"
    Write-Host "  0. Kembali"
    Write-Host ""
    $p = Read-Host "Pilih [0-2]"

    if ($p -eq "0" -or [string]::IsNullOrWhiteSpace($p)) { return }

    if ($p -eq "1") {
        Write-Host ""
        Write-Warn-Host "Upgrade semua bisa mengubah banyak aplikasi sekaligus."
        if (-not (Confirm-Run "Upgrade semua via winget?")) {
            Write-Host "Dibatalkan." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
        Invoke-UpdateAction -Action "winget-upgrade"
        Pause-Back
        return
    }

    if ($p -eq "2") {
        Write-Host ""
        $id = Read-Host "Winget package ID (contoh Microsoft.Edge)"
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-Host "Dibatalkan." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
        if (-not (Confirm-Run "Upgrade $id ?")) {
            Write-Host "Dibatalkan." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
        Invoke-UpdateAction -Action "winget-upgrade" -WingetId $id
        Pause-Back
        return
    }

    Write-Err "Pilihan tidak valid."
    Start-Sleep -Seconds 1
}

function Do-Office {
    Show-Header "UPDATE TOOLS - Update Microsoft Office"
    Write-Host "Memicu Office Click-to-Run update (Office 365 / 2019+)."
    Write-Host "Jendela progress Office mungkin muncul." -ForegroundColor DarkGray
    Write-Host ""
    if (-not (Confirm-Run "Update Office sekarang?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-UpdateAction -Action "office"
    Pause-Back
}

function Do-Browsers {
    Show-Header "UPDATE TOOLS - Update Browser"
    Write-Host "Edge dan Chrome:"
    Write-Host "  - via winget jika tersedia, atau"
    Write-Host "  - pemicu update native (EdgeUpdate / GoogleUpdate)"
    Write-Host ""
    if (-not (Confirm-Run "Update browser?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-UpdateAction -Action "browsers"
    Pause-Back
}

function Show-MainMenu {
    while ($true) {
        Show-Header "ITools - Update Tools"
        Write-Host "  Update Windows, Office, browser, dan aplikasi perusahaan."
        Write-Host ""
        Write-Host ("  Sesi Admin : {0}" -f $(if (Test-IsAdmin) { "Ya" } else { "Tidak (beberapa fitur terbatas)" })) -ForegroundColor $(if (Test-IsAdmin) { "Green" } else { "Yellow" })
        Write-Host ""
        Write-Host "  1. Status sistem & update"
        Write-Host "  2. Scan Windows Update"
        Write-Host "  3. Install Windows Update"
        Write-Host "  4. Reset komponen Windows Update"
        Write-Host "  5. Daftar aplikasi (winget upgrade)"
        Write-Host "  6. Upgrade aplikasi (winget)"
        Write-Host "  7. Update Microsoft Office"
        Write-Host "  8. Update Browser (Edge / Chrome)"
        Write-Host ""
        Write-Host "  0. Kembali / Keluar"
        Write-Host ""

        $pilih = Read-Host "Pilih [0-8]"

        switch ($pilih) {
            "1" { Do-Status }
            "2" { Do-Scan }
            "3" { Do-Install }
            "4" { Do-ResetWU }
            "5" { Do-WingetList }
            "6" { Do-WingetUpgrade }
            "7" { Do-Office }
            "8" { Do-Browsers }
            "0" { return }
            default {
                Write-Host "Pilihan tidak valid." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

Show-MainMenu
exit 0
