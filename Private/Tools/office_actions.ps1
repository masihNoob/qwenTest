# ============================================================

# office_actions.ps1 - Modul aksi Office (dot-source-able, TIDAK auto-run)
# Cara pakai:
#   1) Dari menu (in-process): . .\office_actions.ps1 ; Invoke-OfficeAction -Action "status"
#   2) CLI standalone: powershell -File office_actions.ps1 -Action status

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        "",
        "status",
        "quick-repair",
        "online-repair",
        "reinstall",
        "update",
        "add-product"
    )]
    [string]$Action = "",

    [string]$ProductId = "O365ProPlusRetail",

    [string]$OfficeRoot = "",

    [string]$Language = ""
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn-Host([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegValue {
    param([string]$Path, [string]$Name, [string]$Default = "N/A")
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $Default }
        $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        if ($null -eq $v -or "$v" -eq "") { return $Default }
        return "$v"
    } catch { return $Default }
}

function Get-C2RClient {
    $paths = @(
        "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe",
        "${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-ScriptDirectory {
    if ($PSScriptRoot -and $PSScriptRoot.Trim() -ne "") {
        return $PSScriptRoot
    }
    try {
        $cmdPath = $MyInvocation.MyCommand.Path
        if ($cmdPath -and $cmdPath.Trim() -ne "") {
            $dir = Split-Path -Parent $cmdPath
            if ($dir) { return $dir }
        }
    } catch {}
    try {
        $cmdPath = $script:MyInvocation.MyCommand.Path
        if ($cmdPath -and $cmdPath.Trim() -ne "") {
            $dir = Split-Path -Parent $cmdPath
            if ($dir) { return $dir }
        }
    } catch {}
    $candidates = @(
        (Join-Path $env:TEMP "ITools_Work\Tools"),
        (Join-Path $env:TEMP "ITools_Launcher")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $PWD.Path
}

function Get-OfficeRootFromIni {
    $scriptDir = Get-ScriptDirectory
    $candidates = @()
    if ($scriptDir) {
        $candidates += (Join-Path $scriptDir "..\Data\settings.ini")
        $candidates += (Join-Path $scriptDir "..\Data\office_settings.ini")
        $candidates += (Join-Path $scriptDir "settings.ini")
        $candidates += (Join-Path $scriptDir "..\settings.ini")
    }
    if ($env:TEMP) {
        $candidates += (Join-Path $env:TEMP "ITools_Work\Data\settings.ini")
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($c)
        } catch { continue }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($line in (Get-Content -LiteralPath $full -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $line = ("{0}" -f $line).Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            if ($line -match '^OfficeRoot\s*=') {
                return (($line -split "=", 2)[1].Trim())
            }
        }
    }
    return ""
}

function Ensure-OfficeRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:OfficeRoot)) { return $true }
    $fromIni = Get-OfficeRootFromIni
    if (-not [string]::IsNullOrWhiteSpace($fromIni)) {
        $script:OfficeRoot = $fromIni
        Write-Info ("OfficeRoot dari settings: {0}" -f $script:OfficeRoot)
        return $true
    }
    Write-Err "OfficeRoot kosong. Set di Data\settings.ini (OfficeRoot=\\server\share\Office) atau -OfficeRoot."
    return $false
}

function Get-SetupExe {
    if (-not (Ensure-OfficeRoot)) { return $null }
    $setup = Join-Path $script:OfficeRoot "setup.exe"
    if (Test-Path -LiteralPath $setup) { return $setup }
    $alt = Get-ChildItem -LiteralPath $script:OfficeRoot -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($alt) { return $alt.FullName }
    Write-Err ("setup.exe tidak ditemukan di: {0}" -f $script:OfficeRoot)
    Write-Host "Pastikan ODT setup.exe dan folder Office (hasil /download) ada di share." -ForegroundColor DarkGray
    return $null
}

function Get-DefaultLanguage {
    if (-not [string]::IsNullOrWhiteSpace($Language)) { return $Language }
    try {
        $cul = [System.Globalization.CultureInfo]::CurrentUICulture.Name
        if ($cul) { return $cul }
    } catch {}
    return "en-us"
}

function New-OdtConfigXml {
    param(
        [string]$Mode,          # Install | Repair
        [string]$ProductId,
        [string]$SourcePath,
        [string]$Lang,
        [switch]$ForceAppShutdown,
        [switch]$RemoveAllBefore
    )

    $tempDir = Join-Path $env:TEMP "ITools_Office"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $xmlPath = Join-Path $tempDir ("config_{0}_{1}.xml" -f $Mode, (Get-Date -Format "HHmmss"))

    $force = if ($ForceAppShutdown) { "TRUE" } else { "FALSE" }
    $srcAttr = ""
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $srcAttr = " SourcePath=`"$SourcePath`""
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine('  <Display Level="Full" AcceptEULA="TRUE" />')
    [void]$sb.AppendLine("  <Property Name=`"FORCEAPPSHUTDOWN`" Value=`"$force`" />")
    [void]$sb.AppendLine('  <Property Name="SharedComputerLicensing" Value="0" />')
    [void]$sb.AppendLine('  <Property Name="PinIconsToTaskbar" Value="FALSE" />')

    if ($RemoveAllBefore) {
        [void]$sb.AppendLine('  <Remove All="TRUE" />')
    }

    if ($Mode -eq "Install" -or $Mode -eq "Add") {
        [void]$sb.AppendLine("  <Add OfficeClientEdition=`"64`"$srcAttr Channel=`"Current`">")
        [void]$sb.AppendLine("    <Product ID=`"$ProductId`">")
        [void]$sb.AppendLine("      <Language ID=`"$Lang`" />")
        [void]$sb.AppendLine('      <ExcludeApp ID="Groove" />')
        [void]$sb.AppendLine('      <ExcludeApp ID="Lync" />')
        [void]$sb.AppendLine('      <ExcludeApp ID="OneDrive" />')
        [void]$sb.AppendLine('      <ExcludeApp ID="Teams" />')
        [void]$sb.AppendLine('    </Product>')
        [void]$sb.AppendLine('  </Add>')
    }
    elseif ($Mode -eq "Repair") {
        [void]$sb.AppendLine("  <Add OfficeClientEdition=`"64`"$srcAttr>")
        [void]$sb.AppendLine("    <Product ID=`"$ProductId`">")
        [void]$sb.AppendLine("      <Language ID=`"$Lang`" />")
        [void]$sb.AppendLine('    </Product>')
        [void]$sb.AppendLine('  </Add>')
        [void]$sb.AppendLine('  <Updates Enabled="TRUE" />')
    }

    [void]$sb.AppendLine('</Configuration>')

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($xmlPath, $sb.ToString(), $utf8NoBom)
    return $xmlPath
}

function Invoke-OdtSetup {
    param(
        [string]$SetupExe,
        [string]$ConfigXml,
        [string]$Label = "ODT"
    )
    if (-not (Test-Path -LiteralPath $SetupExe)) {
        Write-Err "setup.exe tidak ada: $SetupExe"
        return $false
    }
    if (-not (Test-Path -LiteralPath $ConfigXml)) {
        Write-Err "Config XML tidak ada: $ConfigXml"
        return $false
    }

    Write-Info ("Menjalankan {0}..." -f $Label)
    Write-Host ("  setup : {0}" -f $SetupExe) -ForegroundColor DarkGray
    Write-Host ("  config: {0}" -f $ConfigXml) -ForegroundColor DarkGray
    Write-Host ""
    Write-Warn-Host "Proses bisa lama. Jangan tutup jendela ini."
    Write-Host ""

    try {
        $p = Start-Process -FilePath $SetupExe -ArgumentList "/configure", "`"$ConfigXml`"" -PassThru -Wait -ErrorAction Stop
        Write-Host ("Exit code: {0}" -f $p.ExitCode)
        if ($p.ExitCode -eq 0) {
            Write-Ok "$Label selesai."
            return $true
        } else {
            Write-Warn-Host ("Selesai dengan exit code {0}" -f $p.ExitCode)
            return $false
        }
    } catch {
        Write-Err ("Gagal menjalankan setup: {0}" -f $_)
        return $false
    } finally {
        try { Remove-Item -LiteralPath $ConfigXml -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Action-Status {
    Write-Host "========== STATUS MICROSOFT OFFICE ==========" -ForegroundColor Cyan
    Write-Host ""

    $c2r = Get-C2RClient
    if ($c2r) {
        Write-Ok "Click-to-Run client ditemukan"
        Write-Host ("  {0}" -f $c2r) -ForegroundColor DarkGray
    } else {
        Write-Warn-Host "OfficeC2RClient.exe tidak ditemukan (bukan C2R / belum terpasang)"
    }

    $cfg = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    $cfg86 = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"

    $version   = Get-RegValue $cfg "VersionToReport"
    if ($version -eq "N/A") { $version = Get-RegValue $cfg86 "VersionToReport" }
    $channel   = Get-RegValue $cfg "UpdateChannel"
    if ($channel -eq "N/A") { $channel = Get-RegValue $cfg "UpdateChannelName" }
    $productIds = Get-RegValue $cfg "ProductReleaseIds"
    $clientVer = Get-RegValue $cfg "ClientFolder"
    $cdnBase   = Get-RegValue $cfg "CDNBaseUrl"

    Write-Host ""
    Write-Host "---------- Konfigurasi C2R ----------" -ForegroundColor Cyan
    Write-Host ("  VersionToReport : {0}" -f $version)
    Write-Host ("  Channel         : {0}" -f $channel)
    Write-Host ("  Product IDs     : {0}" -f $productIds)
    Write-Host ("  CDNBaseUrl      : {0}" -f $cdnBase)

    Write-Host ""
    Write-Host "---------- Produk terdeteksi (Uninstall) ----------" -ForegroundColor Cyan
    $found = $false
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $uninstallPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and ($_.DisplayName -match 'Microsoft (365|Office|Visio|Project)') } |
                ForEach-Object {
                    $found = $true
                    Write-Host ("  {0}" -f $_.DisplayName)
                    if ($_.DisplayVersion) {
                        Write-Host ("    Versi: {0}" -f $_.DisplayVersion) -ForegroundColor DarkGray
                    }
                }
        } catch {}
    }
    if (-not $found) {
        Write-Host "  Tidak ada entri Office/Visio/Project di Uninstall." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "---------- OfficeRoot (settings) ----------" -ForegroundColor Cyan
    $root = Get-OfficeRootFromIni
    if ($root) {
        Write-Host ("  {0}" -f $root)
        $setup = Join-Path $root "setup.exe"
        if (Test-Path -LiteralPath $setup) {
            Write-Ok "setup.exe ditemukan di share"
        } else {
            Write-Warn-Host "setup.exe belum ada di path di atas (perlu untuk Reinstall / Add Product)"
        }
    } else {
        Write-Warn-Host "OfficeRoot belum diset di Data\settings.ini"
        Write-Host "  Tambahkan baris: OfficeRoot=\\server\share\Office" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("Sesi Administrator : {0}" -f $(if (Test-IsAdmin) { "Ya" } else { "Tidak" }))
}

function Action-QuickRepair {
    Write-Host "========== QUICK REPAIR OFFICE ==========" -ForegroundColor Cyan
    Write-Host ""

    $c2r = Get-C2RClient
    if (-not $c2r) {
        Write-Err "Office Click-to-Run tidak ditemukan. Quick Repair hanya untuk C2R."
        return
    }

    Write-Ok "OfficeC2RClient: $c2r"
    Write-Info "Menjalankan Quick Repair..."
    Write-Host "Jendela progress Office mungkin muncul." -ForegroundColor Yellow
    Write-Host ""

    try {
        $p = Start-Process -FilePath $c2r -ArgumentList "scenario=Repair" -PassThru -Wait -ErrorAction Stop
        Write-Host ("Exit code: {0}" -f $p.ExitCode)
        if ($p.ExitCode -eq 0) {
            Write-Ok "Quick Repair selesai / perintah dikirim."
        } else {
            Write-Warn-Host "Selesai dengan exit code $($p.ExitCode)"
        }
    } catch {
        Write-Err "Gagal Quick Repair: $_"
        Write-Host "Alternatif: gunakan Online Repair atau Reinstall dari jaringan." -ForegroundColor DarkGray
    }
}

function Action-OnlineRepair {
    Write-Host "========== ONLINE REPAIR OFFICE ==========" -ForegroundColor Cyan
    Write-Host ""

    $c2r = Get-C2RClient
    if (-not $c2r) {
        Write-Err "Office Click-to-Run tidak ditemukan."
        return
    }

    Write-Ok "OfficeC2RClient: $c2r"
    Write-Info "Menjalankan Online Repair (full)..."
    Write-Host "Proses ini mengunduh file perbaikan dari internet jika diperlukan." -ForegroundColor Yellow
    Write-Host "Jendela progress Office mungkin muncul." -ForegroundColor Yellow
    Write-Host ""

    try {
        $args = @("scenario=Repair", "forceappshutdown=True")
        $p = Start-Process -FilePath $c2r -ArgumentList $args -PassThru -Wait -ErrorAction Stop
        Write-Host ("Exit code: {0}" -f $p.ExitCode)
        if ($p.ExitCode -eq 0) {
            Write-Ok "Online Repair selesai / perintah dikirim."
        } else {
            Write-Warn-Host "Selesai dengan exit code $($p.ExitCode). Coba Reinstall dari jaringan jika masih bermasalah."
        }
    } catch {
        Write-Err "Gagal Online Repair: $_"
    }
}

function Action-Update {
    Write-Host "========== UPDATE MICROSOFT OFFICE ==========" -ForegroundColor Cyan
    Write-Host ""

    $c2r = Get-C2RClient
    if (-not $c2r) {
        Write-Err "Office Click-to-Run tidak ditemukan."
        Write-Host "Tool ini hanya mendukung Office 365 / 2019+ Click-to-Run." -ForegroundColor DarkGray
        return
    }

    Write-Ok "OfficeC2RClient: $c2r"
    Write-Info "Menjalankan update (update user)..."
    Write-Host "Jendela Office Update mungkin muncul." -ForegroundColor Yellow
    Write-Host ""

    try {
        $p = Start-Process -FilePath $c2r -ArgumentList "/update", "user" -PassThru -Wait -ErrorAction Stop
        Write-Host ("Exit code: {0}" -f $p.ExitCode)
        if ($p.ExitCode -eq 0) {
            Write-Ok "Perintah update Office dikirim."
        } else {
            Write-Warn-Host "Selesai dengan exit code $($p.ExitCode)"
        }
    } catch {
        Write-Err "Gagal menjalankan Office update: $_"
    }

    $cfg = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    $ver = Get-RegValue $cfg "VersionToReport"
    Write-Host ("Versi terlapor saat ini: {0}" -f $ver)
}

function Action-Reinstall {
    Write-Host "========== REINSTALL OFFICE (dari jaringan) ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Butuh Administrator untuk reinstall."
        return
    }

    $setup = Get-SetupExe
    if (-not $setup) { return }

    $lang = Get-DefaultLanguage
    $product = if ([string]::IsNullOrWhiteSpace($ProductId)) { "O365ProPlusRetail" } else { $ProductId }

    Write-Info ("Product ID : {0}" -f $product)
    Write-Info ("Language   : {0}" -f $lang)
    Write-Info ("SourcePath : {0}" -f $script:OfficeRoot)
    Write-Host ""
    Write-Warn-Host "Aplikasi Office akan ditutup paksa. Simpan pekerjaan dulu."
    Write-Host ""

    $xml = New-OdtConfigXml -Mode "Install" -ProductId $product -SourcePath $script:OfficeRoot `
        -Lang $lang -ForceAppShutdown -RemoveAllBefore

    Write-Info "Config XML digenerate di TEMP (tidak menyentuh fileserver)."
    Invoke-OdtSetup -SetupExe $setup -ConfigXml $xml -Label "Reinstall Office"
}

function Action-AddProduct {
    Write-Host "========== TAMBAH PRODUK OFFICE (Visio / Project / dll) ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Butuh Administrator untuk menambah produk."
        return
    }

    $setup = Get-SetupExe
    if (-not $setup) { return }

    $lang = Get-DefaultLanguage
    $product = if ([string]::IsNullOrWhiteSpace($ProductId)) { "VisioProRetail" } else { $ProductId }

    Write-Info ("Product ID : {0}" -f $product)
    Write-Info ("Language   : {0}" -f $lang)
    Write-Info ("SourcePath : {0}" -f $script:OfficeRoot)
    Write-Host ""
    Write-Warn-Host "Aplikasi Office mungkin ditutup sementara."
    Write-Host ""

    $xml = New-OdtConfigXml -Mode "Install" -ProductId $product -SourcePath $script:OfficeRoot `
        -Lang $lang -ForceAppShutdown

    Write-Info "Config XML digenerate di TEMP (tidak menyentuh fileserver)."
    Invoke-OdtSetup -SetupExe $setup -ConfigXml $xml -Label "Add Product ($product)"
}

# ============================================================
# PUBLIC API: Invoke-OfficeAction
# Bisa dipanggil in-process setelah dot-source dari menu:
#   . .\office_actions.ps1
#   Invoke-OfficeAction -Action "status"
# Tidak ada spawn child process, tidak ada exit.
# ============================================================
function Invoke-OfficeAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$ProductId = "",
        [string]$OfficeRoot = "",
        [string]$Language = ""
    )

    # Override nilai param skrip (standalone) dengan argumen pemanggilan fungsi,
    # karena fungsi-fungsi Action-* membaca variabel level atas.
    if ($ProductId)  { $script:ProductId = $ProductId }
    if ($OfficeRoot) { $script:OfficeRoot = $OfficeRoot }
    if ($Language)   { $script:Language = $Language }

    switch ($Action) {
        "status"        { Action-Status }
        "quick-repair"  { Action-QuickRepair }
        "online-repair" { Action-OnlineRepair }
        "reinstall"     { Action-Reinstall }
        "update"        { Action-Update }
        "add-product"   { Action-AddProduct }
        default {
            Write-Err ("Aksi tidak dikenal: {0}" -f $Action)
            return $false
        }
    }
    return $true
}

# CLI entry point HANYA jika dijalankan standalone dengan -Action.
# Saat di-dot-source dari menu, skrip TIDAK boleh auto-run/exit.
if ($PSBoundParameters.ContainsKey('Action') -and -not [string]::IsNullOrWhiteSpace($Action)) {
    $okCli = Invoke-OfficeAction -Action $Action -ProductId $ProductId -OfficeRoot $OfficeRoot -Language $Language
    exit $(if ($okCli) { 0 } else { 1 })
}
