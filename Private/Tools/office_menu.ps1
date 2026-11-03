-# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ActionsScript = Join-Path $ScriptDir "office_actions.ps1"

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

function Invoke-OfficeAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$ProductId = "",
        [string]$OfficeRoot = "",
        [string]$Language = ""
    )

    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Err ("office_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
        return
    }

    Write-Info ("Menjalankan aksi: {0}" -f $Action)
    Write-Host ""

    try {
        $params = @{ Action = $Action }
        if ($ProductId -and $ProductId.Trim() -ne "") { $params.ProductId = $ProductId.Trim() }
        if ($OfficeRoot -and $OfficeRoot.Trim() -ne "") { $params.OfficeRoot = $OfficeRoot.Trim() }
        if ($Language -and $Language.Trim() -ne "") { $params.Language = $Language.Trim() }

        & $ActionsScript @params
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
    Show-Header "OFFICE - Status"
    Invoke-OfficeAction -Action "status"
    Pause-Back
}

function Do-QuickRepair {
    Show-Header "OFFICE - Quick Repair"
    Write-Host "Memperbaiki instalasi Office secara lokal (cepat)."
    Write-Host "Cocok untuk masalah ringan (buka file, ribbon, dll)." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Office harus sudah terpasang (Click-to-Run)." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Confirm-Run "Jalankan Quick Repair?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-OfficeAction -Action "quick-repair"
    Pause-Back
}

function Do-OnlineRepair {
    Show-Header "OFFICE - Online Repair"
    Write-Host "Repair penuh. Bisa mengunduh file perbaikan dari internet."
    Write-Host "Lebih lambat dari Quick Repair, lebih menyeluruh." -ForegroundColor DarkGray
    Write-Host ""
    Write-Warn-Host "Aplikasi Office akan ditutup. Simpan pekerjaan dulu."
    Write-Host ""

    if (-not (Confirm-Run "Jalankan Online Repair?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-OfficeAction -Action "online-repair"
    Pause-Back
}

function Do-Reinstall {
    Show-Header "OFFICE - Reinstall (dari jaringan)"
    Write-Host "Instal ulang Office dari SourcePath di fileserver (ODT)."
    Write-Host "Config XML digenerate otomatis di TEMP - tidak perlu file di share." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Pilih produk yang akan diinstal ulang:" -ForegroundColor Cyan
    Write-Host "  1. Microsoft 365 Apps for enterprise (O365ProPlusRetail)"
    Write-Host "  2. Microsoft 365 Apps for business (O365BusinessRetail)"
    Write-Host "  3. Office LTSC Professional Plus 2021 (ProPlus2021Volume)"
    Write-Host "  4. Office LTSC Professional Plus 2024 (ProPlus2024Volume)"
    Write-Host "  5. Custom Product ID (ketik sendiri)"
    Write-Host "  0. Batal"
    Write-Host ""
    $p = Read-Host "Pilih [0-5]"

    $map = @{
        "1" = "O365ProPlusRetail"
        "2" = "O365BusinessRetail"
        "3" = "ProPlus2021Volume"
        "4" = "ProPlus2024Volume"
    }

    $productId = $null
    if ($p -eq "0" -or [string]::IsNullOrWhiteSpace($p)) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    if ($map.ContainsKey($p)) {
        $productId = $map[$p]
    }
    elseif ($p -eq "5") {
        $productId = Read-Host "Product ID (contoh O365ProPlusRetail)"
        if ([string]::IsNullOrWhiteSpace($productId)) {
            Write-Host "Dibatalkan." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
    }
    else {
        Write-Err "Pilihan tidak valid."
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ""
    Write-Host ("Product ID: {0}" -f $productId) -ForegroundColor Cyan
    Write-Warn-Host "Semua aplikasi Office akan ditutup paksa. Simpan pekerjaan!"
    Write-Host "Proses bisa 10-30 menit tergantung jaringan." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Sesi ini bukan Administrator. Launcher ITools biasanya elevate."
        Write-Host "Jalankan ulang ITools sebagai Admin jika gagal." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not (Confirm-Run "Lanjutkan reinstall?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-OfficeAction -Action "reinstall" -ProductId $productId
    Pause-Back
}

function Do-Update {
    Show-Header "OFFICE - Update (via Internet)"
    Write-Host "Memicu Office Click-to-Run update."
    Write-Host "Membutuhkan koneksi internet (CDN Microsoft)." -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Confirm-Run "Update Office sekarang?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-OfficeAction -Action "update"
    Pause-Back
}

function Do-AddProduct {
    Show-Header "OFFICE - Tambah Produk (Visio / Project)"
    Write-Host "Menambah Visio atau Project ke instalasi Office yang ada."
    Write-Host "Sumber file dari OfficeRoot di fileserver (ODT)." -ForegroundColor DarkGray
    Write-Host "Config XML digenerate otomatis - tidak perlu file di share." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Pilih produk:" -ForegroundColor Cyan
    Write-Host "  1. Visio Professional (VisioProRetail)"
    Write-Host "  2. Visio Standard (VisioStdRetail)"
    Write-Host "  3. Project Professional (ProjectProRetail)"
    Write-Host "  4. Project Standard (ProjectStdRetail)"
    Write-Host "  5. Visio LTSC 2021 (VisioPro2021Volume)"
    Write-Host "  6. Project LTSC 2021 (ProjectPro2021Volume)"
    Write-Host "  7. Custom Product ID"
    Write-Host "  0. Batal"
    Write-Host ""
    $p = Read-Host "Pilih [0-7]"

    $map = @{
        "1" = "VisioProRetail"
        "2" = "VisioStdRetail"
        "3" = "ProjectProRetail"
        "4" = "ProjectStdRetail"
        "5" = "VisioPro2021Volume"
        "6" = "ProjectPro2021Volume"
    }

    $productId = $null
    if ($p -eq "0" -or [string]::IsNullOrWhiteSpace($p)) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    if ($map.ContainsKey($p)) {
        $productId = $map[$p]
    }
    elseif ($p -eq "7") {
        $productId = Read-Host "Product ID (contoh VisioProRetail)"
        if ([string]::IsNullOrWhiteSpace($productId)) {
            Write-Host "Dibatalkan." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
    }
    else {
        Write-Err "Pilihan tidak valid."
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ""
    Write-Host ("Product ID: {0}" -f $productId) -ForegroundColor Cyan
    Write-Warn-Host "Aplikasi Office mungkin ditutup sementara."
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Sesi ini bukan Administrator."
        Write-Host "Jalankan ulang ITools sebagai Admin jika gagal." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not (Confirm-Run "Lanjutkan instalasi produk?")) {
        Write-Host "Dibatalkan." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    Invoke-OfficeAction -Action "add-product" -ProductId $productId
    Pause-Back
}

function Show-MainMenu {
    while ($true) {
        Show-Header "ITools - Office Installer / Repair"
        Write-Host "  Repair, reinstall, update, dan tambah Visio/Project."
        Write-Host "  XML config digenerate otomatis (tidak perlu tulis ke fileserver)." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host ("  Sesi Admin : {0}" -f $(if (Test-IsAdmin) { "Ya" } else { "Tidak (reinstall/add butuh Admin)" })) -ForegroundColor $(if (Test-IsAdmin) { "Green" } else { "Yellow" })
        Write-Host ""
        Write-Host "  1. Status Office (versi, channel, produk)"
        Write-Host "  2. Quick Repair"
        Write-Host "  3. Online Repair"
        Write-Host "  4. Reinstall Office (dari file jaringan)"
        Write-Host "  5. Update Office (via Internet)"
        Write-Host "  6. Tambah Produk (Visio / Project)"
        Write-Host ""
        Write-Host "  0. Kembali / Keluar"
        Write-Host ""

        $pilih = Read-Host "Pilih [0-6]"

        switch ($pilih) {
            "1" { Do-Status }
            "2" { Do-QuickRepair }
            "3" { Do-OnlineRepair }
            "4" { Do-Reinstall }
            "5" { Do-Update }
            "6" { Do-AddProduct }
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
