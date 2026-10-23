# ============================================================
# printer_actions.ps1 - eksekusi saja (tanpa menu interaktif koneksi)
#
# install:
#   -ConnType usb|tcpip|share|driveronly
#   -Address IP atau \\server\share (tcpip/share)
#   -PrinterName nama di Windows (opsional)
#   -RelativePath path penuh ke .exe/.msi/.inf (atau relatif ke DriverRoot)
# modify / uninstall: seperti sebelumnya
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("install", "modify", "uninstall")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$RelativePath,

    [string]$DriverRoot = "",

    [ValidateSet("usb", "tcpip", "share", "driveronly", "")]
    [string]$ConnType = "driveronly",

    [string]$Address = "",

    [string]$PrinterName = "",

    [string]$ShareUser = "",
    [string]$SharePass = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Get-DriverRootFromIni {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidates = @(
        (Join-Path $scriptDir "..\Data\settings.ini"),
        (Join-Path $scriptDir "settings.ini")
    )
    foreach ($c in $candidates) {
        $full = [System.IO.Path]::GetFullPath($c)
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($line in (Get-Content -LiteralPath $full -Encoding UTF8)) {
            $line = $line.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            if ($line -match '^DriverRoot\s*=') {
                return (($line -split "=", 2)[1].Trim())
            }
        }
    }
    return ""
}

function Ensure-DriverRoot {
    if (-not [string]::IsNullOrWhiteSpace($DriverRoot)) { return }
    $fromIni = Get-DriverRootFromIni
    if (-not [string]::IsNullOrWhiteSpace($fromIni)) {
        $script:DriverRoot = $fromIni
        Write-Info ("DriverRoot dari settings.ini: {0}" -f $DriverRoot)
        return
    }
    throw "DriverRoot kosong. Set di Data\settings.ini atau -DriverRoot."
}

function Connect-DriverShare {
    if (Test-Path -LiteralPath $DriverRoot) { return }
    if ([string]::IsNullOrWhiteSpace($ShareUser)) {
        cmd /c ("net use `"{0}`" /persistent:no" -f $DriverRoot) | Out-Null
    } else {
        cmd /c ("net use `"{0}`" /user:{1} `"{2}`" /persistent:no" -f $DriverRoot, $ShareUser, $SharePass) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DriverRoot)) {
        throw ("Tidak bisa akses share driver: {0}" -f $DriverRoot)
    }
}

function Test-IsAbsolutePath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    # UNC \\server\share\... atau drive letter C:\...
    if ($p.StartsWith("\\")) { return $true }
    if ($p.Length -ge 3 -and $p[1] -eq [char]':' -and ($p[2] -eq [char]'\' -or $p[2] -eq [char]'/')) { return $true }
    return $false
}

function Get-ResolvedDriverPath {
    # Path di drivers.csv = path penuh ke .exe / .msi / .inf
    # Jika relatif, digabung dengan DriverRoot
    $raw = ("{0}" -f $RelativePath).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Path driver kosong di database (drivers.csv kolom Path)."
    }
    if (Test-IsAbsolutePath -p $raw) { return $raw }
    if ([string]::IsNullOrWhiteSpace($DriverRoot)) {
        throw ("Path relatif membutuhkan DriverRoot: {0}" -f $raw)
    }
    return (Join-Path $DriverRoot $raw)
}

function Connect-PackageShare([string]$filePath) {
    # Map \\server\share jika path UNC belum accessible
    if (-not $filePath.StartsWith("\\")) { return }
    if (Test-Path -LiteralPath $filePath) { return }

    $parts = $filePath.TrimStart('\').Split('\')
    if ($parts.Count -lt 2) { return }
    $shareRoot = "\\" + $parts[0] + "\" + $parts[1]

    if (Test-Path -LiteralPath $shareRoot) { return }

    Write-Info ("Map share: {0}" -f $shareRoot)
    if ([string]::IsNullOrWhiteSpace($ShareUser)) {
        cmd /c ("net use `"{0}`" /persistent:no" -f $shareRoot) | Out-Null
    } else {
        cmd /c ("net use `"{0}`" /user:{1} `"{2}`" /persistent:no" -f $shareRoot, $ShareUser, $SharePass) | Out-Null
    }
}

function Install-DriverPackage {
    # 1) Resolve path dari drivers.csv
    # 2) Map share jika perlu
    # 3) Eksekusi langsung .exe / .msi / .inf (tanpa scan folder)
    $full = Get-ResolvedDriverPath
    Connect-PackageShare -filePath $full

    if (-not (Test-Path -LiteralPath $full)) {
        throw ("File driver tidak ditemukan: {0}" -f $full)
    }

    $pkg = Get-Item -LiteralPath $full -Force
    if ($pkg.PSIsContainer) {
        throw ("Path di database harus file .exe / .msi / .inf, bukan folder: {0}" -f $full)
    }

    $ext = ""
    if ($pkg.Extension) { $ext = $pkg.Extension.ToLowerInvariant() }
    $workDir = $pkg.DirectoryName
    $full = $pkg.FullName

    Write-Info ("Eksekusi: {0}" -f $full)

    if ($ext -eq ".exe") {
        $p = Start-Process -FilePath $full -WorkingDirectory $workDir -Wait -PassThru
        $code = $p.ExitCode
        if ($null -eq $code -or $code -eq 0 -or $code -eq 3010) {
            Write-Ok ("EXE selesai (exit: {0})" -f $code)
            return
        }
        throw ("EXE gagal (exit: {0}): {1}" -f $code, $full)
    }

    if ($ext -eq ".msi") {
        $p = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList @("/i", $full) `
            -WorkingDirectory $workDir -Wait -PassThru -NoNewWindow
        $code = $p.ExitCode
        if ($null -eq $code -or $code -eq 0 -or $code -eq 3010) {
            Write-Ok ("MSI selesai (exit: {0})" -f $code)
            return
        }
        throw ("MSI gagal (exit: {0}): {1}" -f $code, $full)
    }

    if ($ext -eq ".inf") {
        $r = Start-Process -FilePath "pnputil.exe" `
            -ArgumentList @("/add-driver", $full, "/install") `
            -Wait -PassThru -NoNewWindow
        if ($r.ExitCode -eq 0) {
            Write-Ok "INF terinstall."
            return
        }
        throw ("pnputil gagal (exit: {0}): {1}" -f $r.ExitCode, $full)
    }

    throw ("Path harus .exe / .msi / .inf: {0}" -f $full)
}

function Get-PreferredDriverName([string]$hint) {
    $drivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($drivers.Count -eq 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $m = $drivers | Where-Object { $_.Name -like ("*{0}*" -f $hint) } | Select-Object -First 1
        if ($m) { return $m.Name }
    }
    return $drivers[0].Name
}

function Add-ConnUsb {
    Write-Info "Mode USB: buka wizard Add Printer Windows."
    Write-Info "Pastikan printer sudah tercolok."
    try {
        Start-Process "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry /il" -Wait
        Write-Ok "Wizard selesai."
    } catch {
        Write-Warn "Buka manual: Settings > Printers > Add device."
    }
}

function Add-ConnTcpIp {
    param([string]$Ip, [string]$QueueName, [string]$DriverHint)

    if ([string]::IsNullOrWhiteSpace($Ip)) { throw "Address IP kosong untuk TCP/IP." }
    if ([string]::IsNullOrWhiteSpace($QueueName)) { $QueueName = $Name }

    $driverName = Get-PreferredDriverName -hint $DriverHint
    if (-not $driverName) {
        $driverName = Get-PreferredDriverName -hint $Name
    }
    if (-not $driverName) { throw "Tidak ada printer driver di sistem. Pasang paket driver dulu." }

    $portName = "IP_{0}" -f $Ip
    if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
        Write-Info ("Buat port TCP/IP: {0}" -f $portName)
        try {
            Add-PrinterPort -Name $portName -PrinterHostAddress $Ip -ErrorAction Stop
        } catch {
            $port = ([WMIClass]"Win32_TCPIPPrinterPort").CreateInstance()
            $port.Name = $portName
            $port.SNMPEnabled = $false
            $port.Protocol = 1
            $port.HostAddress = $Ip
            $port.PortNumber = 9100
            $port.Put() | Out-Null
        }
        Write-Ok "Port dibuat."
    }

    if (Get-Printer -Name $QueueName -ErrorAction SilentlyContinue) {
        Write-Warn ("Printer sudah ada: {0}" -f $QueueName)
        return
    }

    Write-Info ("Add-Printer TCP/IP: {0} driver={1}" -f $QueueName, $driverName)
    Add-Printer -Name $QueueName -DriverName $driverName -PortName $portName -ErrorAction Stop
    Write-Ok ("Printer TCP/IP OK: {0} -> {1}" -f $QueueName, $Ip)
}

function Add-ConnShare {
    param([string]$Unc)

    if ([string]::IsNullOrWhiteSpace($Unc) -or $Unc -notmatch '^\\\\') {
        throw "Address share tidak valid (harus \\\\server\\printer)."
    }
    Write-Info ("Hubungkan share: {0}" -f $Unc)
    try {
        Add-Printer -ConnectionName $Unc -ErrorAction Stop
        Write-Ok ("Share printer OK: {0}" -f $Unc)
    } catch {
        Write-Warn $_.Exception.Message
        Start-Process "rundll32.exe" -ArgumentList ("printui.dll,PrintUIEntry /in /n`"{0}`"" -f $Unc) -Wait
        Write-Ok "Perintah share dikirim. Cek Settings > Printers."
    }
}

function Uninstall-PrinterRelated([string]$printerName) {
    Write-Info ("Uninstall bersih: {0}" -f $printerName)
    $protected = @("Microsoft Print to PDF", "Microsoft XPS Document Writer", "Fax", "OneNote")

    $all = @(Get-Printer -ErrorAction SilentlyContinue)
    $printers = @($all | Where-Object { $_.Name -eq $printerName })
    if ($printers.Count -eq 0) {
        $printers = @($all | Where-Object {
            $_.Name -like ("*{0}*" -f $printerName) -or $_.DriverName -like ("*{0}*" -f $printerName)
        })
    }

    $driverNames = @(); $portNames = @()
    foreach ($pr in $printers) {
        if ($protected | Where-Object { $pr.Name -like ("*{0}*" -f $_) }) {
            Write-Warn ("Dilewati sistem: {0}" -f $pr.Name)
            continue
        }
        if ($pr.DriverName) { $driverNames += $pr.DriverName }
        if ($pr.PortName) { $portNames += $pr.PortName }

        try {
            foreach ($j in @(Get-PrintJob -PrinterName $pr.Name -ErrorAction SilentlyContinue)) {
                try { Remove-PrintJob -PrinterName $pr.Name -ID $j.Id -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }

        try {
            Remove-Printer -Name $pr.Name -ErrorAction Stop
            Write-Ok ("Printer dihapus: {0}" -f $pr.Name)
        } catch {
            try {
                $wmi = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f $pr.Name.Replace("'", "''")) -ErrorAction SilentlyContinue
                if ($wmi) { Remove-CimInstance $wmi; Write-Ok ("Dihapus via WMI: {0}" -f $pr.Name) }
            } catch { Write-Warn $_.Exception.Message }
        }
    }

    foreach ($port in ($portNames | Select-Object -Unique)) {
        if ($port -match '^(FILE:|PORTPROMPT:|nul:|SHRFAX:)') { continue }
        if (@(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $port }).Count -gt 0) { continue }
        try { Remove-PrinterPort -Name $port -ErrorAction Stop; Write-Ok ("Port dihapus: {0}" -f $port) } catch { }
    }

    foreach ($drv in ($driverNames | Select-Object -Unique)) {
        if (@(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.DriverName -eq $drv }).Count -gt 0) { continue }
        try { Remove-PrinterDriver -Name $drv -ErrorAction Stop; Write-Ok ("Driver dihapus: {0}" -f $drv) } catch { }
    }

    try {
        Stop-Service Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Service Spooler -ErrorAction Stop
        Write-Ok "Spooler di-restart."
    } catch {
        try { Restart-Service Spooler -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# --- MAIN ---
try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ("  Action: {0}" -f $Action.ToUpper()) -ForegroundColor Green
    Write-Host ("  Name  : {0}" -f $Name) -ForegroundColor Green
    if ($ConnType) { Write-Host ("  Conn  : {0}" -f $ConnType) -ForegroundColor Green }
    if ($Address)  { Write-Host ("  Addr  : {0}" -f $Address) -ForegroundColor Green }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($Action -eq "uninstall") {
        Uninstall-PrinterRelated -printerName $Name
    } else {
        # Path penuh ke .exe/.msi/.inf ada di -RelativePath (dari drivers.csv kolom Path)
        # DriverRoot hanya dipakai jika Path di CSV relatif
        if (-not (Test-IsAbsolutePath -p $RelativePath)) {
            Ensure-DriverRoot
            Connect-DriverShare
        }
        Install-DriverPackage

        if ($Action -eq "install") {
            $qName = if ($PrinterName) { $PrinterName } else { $Name }
            switch ($ConnType) {
                "usb"        { Add-ConnUsb }
                "tcpip"      { Add-ConnTcpIp -Ip $Address -QueueName $qName -DriverHint $Name }
                "share"      { Add-ConnShare -Unc $Address }
                "driveronly" { Write-Info "Hanya paket driver (tanpa buat antrian printer)." }
                default      { Write-Info "ConnType tidak di-set; hanya driver." }
            }
        } else {
            Write-Ok "Modify: paket driver di-update."
        }
    }

    Write-Host ""
    Write-Ok "Selesai."
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
exit 0
