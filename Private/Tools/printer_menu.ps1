# ============================================================
# printer_menu.ps1 - load data from CSV (Data folder)
# settings.ini | drivers.csv | printers.csv
# ============================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\Data"))
$ActionsScript = Join-Path $ScriptDir "printer_actions.ps1"

$SettingsPath = Join-Path $DataDir "settings.ini"
$DriversPath  = Join-Path $DataDir "drivers.csv"
$PrintersPath = Join-Path $DataDir "printers.csv"

$DriverRoot = ""
$DriverCatalog = @()
$Targets = @()

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn-Host([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Import-CsvSafe([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("File CSV tidak ditemukan: {0}" -f $path)
    }
    return @(Import-Csv -LiteralPath $path -Encoding UTF8)
}

function Read-AllCsv {
    $script:DriverRoot = ""
    $script:DriverCatalog = @()
    $script:Targets = @()

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw ("settings.ini tidak ditemukan: {0}" -f $SettingsPath)
    }
    foreach ($line in (Get-Content -LiteralPath $SettingsPath -Encoding UTF8)) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match '^DriverRoot\s*=') {
            $script:DriverRoot = ($line -split "=", 2)[1].Trim()
        }
    }

    foreach ($row in (Import-CsvSafe -path $DriversPath)) {
        $code = ("{0}" -f $row.Code).Trim()
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $script:DriverCatalog += [PSCustomObject]@{
            Code    = $code
            Name    = ("{0}" -f $row.Name).Trim()
            RelPath = ("{0}" -f $row.Path).Trim()
            Note    = ("{0}" -f $row.Note).Trim()
        }
    }

    foreach ($row in (Import-CsvSafe -path $PrintersPath)) {
        $type = ("{0}" -f $row.Type).Trim().ToLower()
        if ($type -ne "tcpip" -and $type -ne "share") { continue }
        $script:Targets += [PSCustomObject]@{
            Type       = $type
            Dept       = ("{0}" -f $row.Dept).Trim()
            Fungsi     = ("{0}" -f $row.Fungsi).Trim()
            Name       = ("{0}" -f $row.Name).Trim()
            Address    = ("{0}" -f $row.Address).Trim()
            Hostname   = ("{0}" -f $row.Hostname).Trim()
            Location   = ("{0}" -f $row.Location).Trim()
            Status     = ("{0}" -f $row.Status).Trim().ToLower()
            DrvCode    = ("{0}" -f $row.DriverCode).Trim()
        }
    }
}

function Get-DriverByCode([string]$code) {
    $code = ("{0}" -f $code).Trim()
    foreach ($d in $DriverCatalog) {
        if ($d.Code -eq $code) { return $d }
    }
    return $null
}

function Invoke-Action {
    param(
        [string]$Action,
        [string]$Name,
        [string]$RelativePath,
        [string]$ConnType = "driveronly",
        [string]$Address = "",
        [string]$PrinterName = ""
    )
    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Err ("printer_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
        return
    }
    if ($Action -ne "uninstall" -and [string]::IsNullOrWhiteSpace($DriverRoot)) {
        Write-Err "DriverRoot kosong di settings.ini"
        return
    }
    if ($Action -ne "uninstall" -and [string]::IsNullOrWhiteSpace($RelativePath)) {
        Write-Err "Path driver kosong."
        return
    }

    Write-Info ("Menjalankan: {0} / {1}" -f $Action, $ConnType)

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ActionsScript,
        "-Action", $Action,
        "-Name", $Name,
        "-RelativePath", $(if ($RelativePath) { $RelativePath } else { "." })
    )
    if ($Action -ne "uninstall" -and $DriverRoot) {
        $argList += @("-DriverRoot", $DriverRoot)
    }
    if ($Action -eq "install") {
        $argList += @("-ConnType", $ConnType)
        if ($Address)     { $argList += @("-Address", $Address) }
        if ($PrinterName) { $argList += @("-PrinterName", $PrinterName) }
    }
    & powershell.exe @argList
}

function Get-ActiveTargets {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Targets) {
        if ($t.Status -eq "active") { [void]$list.Add($t) }
    }
    # Pipeline unroll + caller @() = array datar
    return $list.ToArray()
}

function Select-DepartmentFilter {
    param($items)

    # Pastikan selalu array datar (hindari nested Object[])
    $arr = @($items)
    if ($arr.Count -eq 1 -and $arr[0] -is [System.Array]) {
        $arr = @($arr[0])
    }
    if ($arr.Count -eq 0) { return @() }

    $deptMap = [ordered]@{}
    foreach ($t in $arr) {
        $d = $t.Dept
        if ([string]::IsNullOrWhiteSpace($d)) { $d = "(tanpa dept)" }
        if (-not $deptMap.Contains($d)) { $deptMap[$d] = 0 }
        $deptMap[$d]++
    }
    $depts = @($deptMap.Keys)

    Write-Host ""
    Write-Host "Filter departemen (dari printers.csv):" -ForegroundColor Cyan
    Write-Host "  A. Semua"
    for ($i = 0; $i -lt $depts.Count; $i++) {
        Write-Host ("  {0}. {1} ({2})" -f ($i + 1), $depts[$i], $deptMap[$depts[$i]])
    }
    Write-Host "  0. Batal"
    $c = (Read-Host "Pilihan").Trim()

    if ($c -eq "0") { return @() }
    if ($c -eq "" -or $c -eq "A" -or $c -eq "a") { return $arr }

    $n = 0
    if (-not [int]::TryParse($c, [ref]$n) -or $n -lt 1 -or $n -gt $depts.Count) {
        Write-Warn-Host "Pilihan tidak valid."
        return @()
    }

    $chosen = $depts[$n - 1]
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($t in $arr) {
        $d = $t.Dept
        if ([string]::IsNullOrWhiteSpace($d)) { $d = "(tanpa dept)" }
        if ($d -eq $chosen) { [void]$result.Add($t) }
    }
    # Pipeline unroll + caller @() = array datar
    return $result.ToArray()
}

function Select-TargetFromList {
    param($items)

    # Flatten satu level jika nested array (hindari System.Object[])
    $arr = @($items)
    if ($arr.Count -eq 1 -and $arr[0] -is [System.Array]) {
        $arr = @($arr[0])
    }
    if ($arr.Count -eq 0) {
        Write-Warn-Host "Daftar kosong."
        return $null
    }

    Write-Host ""
    Write-Host "Pilih target:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $arr.Count; $i++) {
        $t = $arr[$i]
        # Guard: skip jika elemen masih array (data corrupt)
        if ($t -is [System.Array]) { continue }
        $typeLabel = ("{0}" -f $t.Type).ToUpper()
        $extra = @()
        if ($t.Hostname) { $extra += $t.Hostname }
        if ($t.Location) { $extra += $t.Location }
        $extraStr = if ($extra.Count -gt 0) { " | " + ($extra -join " | ") } else { "" }
        Write-Host ("  {0}. [{1}] {2}/{3} - {4}" -f ($i + 1), $typeLabel, $t.Dept, $t.Fungsi, $t.Name)
        Write-Host ("      {0}{1}" -f $t.Address, $extraStr) -ForegroundColor DarkGray
    }
    Write-Host "  0. Batal"
    $c = (Read-Host "Pilihan").Trim()

    $n = 0
    if (-not [int]::TryParse($c, [ref]$n) -or $n -lt 1 -or $n -gt $arr.Count) {
        return $null
    }
    return $arr[$n - 1]
}

function Select-DriverPackage {
    if ($DriverCatalog.Count -eq 0) {
        Write-Err "drivers.csv kosong."
        return $null
    }
    Write-Host ""
    Write-Host "Pilih paket driver:" -ForegroundColor Cyan
    foreach ($d in $DriverCatalog) {
        $note = if ($d.Note) { " - $($d.Note)" } else { "" }
        Write-Host ("  {0}. {1}{2}" -f $d.Code, $d.Name, $note)
    }
    Write-Host "  0. Batal"
    $c = (Read-Host "Pilihan").Trim()
    if ($c -eq "0" -or [string]::IsNullOrWhiteSpace($c)) { return $null }
    $drv = Get-DriverByCode -code $c
    if (-not $drv) {
        Write-Err ("Kode driver tidak ditemukan: {0}" -f $c)
        return $null
    }
    return $drv
}

function Start-InstallFromDatabase {
    $active = @(Get-ActiveTargets)
    if ($active.Count -eq 0) {
        Write-Warn-Host "Tidak ada target active di printers.csv."
        Write-Info ("Total baris di CSV: {0}" -f $Targets.Count)
        return
    }

    Write-Info ("Target active: {0}" -f $active.Count)

    $filtered = @(Select-DepartmentFilter -items $active)
    if ($filtered.Count -eq 0) { return }

    $t = Select-TargetFromList -items $filtered
    if (-not $t) { return }

    $drv = Get-DriverByCode -code $t.DrvCode
    if (-not $drv) {
        Write-Err ("DriverCode tidak ada di drivers.csv: {0}" -f $t.DrvCode)
        return
    }

    Write-Info ("Target : {0} ({1})" -f $t.Name, $t.Type)
    Write-Info ("Address: {0}" -f $t.Address)
    Write-Info ("Driver : {0}" -f $drv.Name)

    Invoke-Action -Action install -Name $drv.Name -RelativePath $drv.RelPath `
        -ConnType $t.Type -Address $t.Address -PrinterName $t.Name
}

function Start-InstallManual {
    Write-Host ""
    Write-Host "Tipe koneksi manual:" -ForegroundColor Cyan
    Write-Host "  1. TCP/IP"
    Write-Host "  2. Share"
    Write-Host "  0. Batal"
    $c = (Read-Host "Pilihan").Trim()

    $connType = ""
    switch ($c) {
        "1" { $connType = "tcpip" }
        "2" { $connType = "share" }
        default { Write-Info "Dibatalkan."; return }
    }

    $drv = Select-DriverPackage
    if (-not $drv) { return }

    if ($connType -eq "tcpip") {
        $ip = (Read-Host "IP printer").Trim()
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        $pname = (Read-Host ("Nama printer Windows (default: {0})" -f $drv.Name)).Trim()
        if ([string]::IsNullOrWhiteSpace($pname)) { $pname = $drv.Name }
        Invoke-Action -Action install -Name $drv.Name -RelativePath $drv.RelPath `
            -ConnType tcpip -Address $ip -PrinterName $pname
    }
    else {
        $unc = (Read-Host "Path share (\\\\server\\printer)").Trim()
        if ([string]::IsNullOrWhiteSpace($unc)) { return }
        Invoke-Action -Action install -Name $drv.Name -RelativePath $drv.RelPath `
            -ConnType share -Address $unc
    }
}

function Start-InstallFlow {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "     Install printer / driver baru" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  1. USB"
    Write-Host "  2. Database (dari printers.csv)"
    Write-Host "  3. Manual (TCP/IP atau Share)"
    Write-Host "  0. Batal"
    Write-Host "========================================"
    $c = (Read-Host "Pilihan").Trim()

    switch ($c) {
        "1" {
            $drv = Select-DriverPackage
            if (-not $drv) { return }
            Invoke-Action -Action install -Name $drv.Name -RelativePath $drv.RelPath -ConnType usb
        }
        "2" {
            Start-InstallFromDatabase
        }
        "3" {
            Start-InstallManual
        }
        default { Write-Info "Dibatalkan." }
    }
}

# --- MAIN ---
try {
    if (-not (Test-Path -LiteralPath $ActionsScript)) {
        Write-Err ("printer_actions.ps1 tidak ditemukan: {0}" -f $ActionsScript)
        Read-Host "Tekan Enter"; exit 1
    }

    Read-AllCsv
    $activeCount = @(Get-ActiveTargets).Count
    Write-Info ("Drivers: {0} | Printers active: {1}" -f $DriverCatalog.Count, $activeCount)

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "       Kelola Driver / Printer" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    $installed = @()
    try { $installed = @(Get-Printer -ErrorAction Stop | Sort-Object Name) } catch {
        Write-Err ("Gagal baca printer terinstall: {0}" -f $_.Exception.Message)
    }

    Write-Host "--- Printer terinstall ---" -ForegroundColor Cyan
    if ($installed.Count -eq 0) {
        Write-Host "  (tidak ada)" -ForegroundColor Yellow
    } else {
        for ($i = 0; $i -lt $installed.Count; $i++) {
            $pr = $installed[$i]
            Write-Host ("  {0}. {1}" -f ($i + 1), $pr.Name)
            Write-Host ("      Driver: {0}" -f $pr.DriverName) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "--- Lainnya ---" -ForegroundColor Cyan
    Write-Host "  N. Install printer / driver baru"
    Write-Host "  0. Batal / Kembali"
    Write-Host "========================================"
    Write-Host ""

    $choice = (Read-Host "Pilih nomor, N, atau 0").Trim()
    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) {
        Write-Info "Dibatalkan."; exit 0
    }

    if ($choice -eq "N" -or $choice -eq "n") {
        Start-InstallFlow
        exit 0
    }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $installed.Count) {
        Write-Err "Pilihan tidak valid."
        Read-Host "Tekan Enter"; exit 1
    }

    $sel = $installed[$idx - 1]
    Write-Host ""
    Write-Host ("Printer: {0}" -f $sel.Name) -ForegroundColor Cyan
    Write-Host "  1. Modify / Update driver"
    Write-Host "  2. Uninstall"
    Write-Host "  0. Batal"
    $act = (Read-Host "Pilih aksi").Trim()
    if ($act -eq "2") {
        Invoke-Action -Action uninstall -Name $sel.Name -RelativePath "."
        exit 0
    }
    if ($act -eq "1") {
        $drv = Select-DriverPackage
        if (-not $drv) { exit 0 }
        Invoke-Action -Action modify -Name $sel.Name -RelativePath $drv.RelPath
        exit 0
    }
    Write-Info "Dibatalkan."
}
catch {
    Write-Err $_.Exception.Message
}

Read-Host "Tekan Enter untuk kembali ke menu"
exit 0
