# printer_actions.ps1 - Modul aksi printer/driver (dot-source-able, TIDAK auto-run)
# Cara pakai:
#   1) Dari menu (in-process): . .\printer_actions.ps1 ; Invoke-PrinterAction -Action install ...
#   2) CLI standalone: powershell -File printer_actions.ps1 -Action install -Name ... -RelativePath ...

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("", "install", "modify", "uninstall")]
    [string]$Action = "",

    [string]$Name = "",

    [string]$RelativePath = "",

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

# Helper: map share SMB tanpa memanggil cmd.exe / net use (mengurangi pemicu SONAR).
function Connect-UncShare {
    param(
        [string]$UncPath,
        [string]$User,
        [string]$Pass
    )
    if ([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Pass)) { return }
    try {
        $sec  = ConvertTo-SecureString $Pass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
        $root = [System.IO.Directory]::GetDirectoryRoot((Split-Path -Parent $UncPath.TrimEnd('\')))
        $driveName = "ITmp{0}" -f (Get-Random -Maximum 9999)
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $root -Credential $cred `
            -Scope Global -ErrorAction Stop | Out-Null
        Write-Info ("Mapped share via PSDrive: {0}" -f $root)
    } catch {
        Write-Warn ("Gagal map share {0}: {1}" -f $UncPath, $_.Exception.Message)
    }
}

function Connect-DriverShare {
    if (Test-Path -LiteralPath $DriverRoot) { return }
    Connect-UncShare -UncPath $DriverRoot -User $ShareUser -Pass $SharePass
    if (-not (Test-Path -LiteralPath $DriverRoot)) {
        throw ("Tidak bisa akses share driver: {0}" -f $DriverRoot)
    }
}

function Test-IsAbsolutePath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    if ($p.StartsWith("\\")) { return $true }
    if ($p.Length -ge 3 -and $p[1] -eq [char]':' -and ($p[2] -eq [char]'\' -or $p[2] -eq [char]'/')) { return $true }
    return $false
}

function Get-ResolvedDriverPath {
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
    if (-not $filePath.StartsWith("\\")) { return }
    if (Test-Path -LiteralPath $filePath) { return }

    $parts = $filePath.TrimStart('\').Split('\')
    if ($parts.Count -lt 2) { return }
    $shareRoot = "\\" + $parts[0] + "\" + $parts[1]

    if (Test-Path -LiteralPath $shareRoot) { return }

    Write-Info ("Map share: {0}" -f $shareRoot)
    Connect-UncShare -UncPath $shareRoot -User $ShareUser -Pass $SharePass
}

function Install-DriverPackage {
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

# ============================================================
# PUBLIC API: Invoke-PrinterAction
# Bisa dipanggil in-process setelah dot-source dari menu:
#   . .\printer_actions.ps1
#   Invoke-PrinterAction -Action install -Name ... -RelativePath ...
# Tidak ada spawn child process, tidak ada exit saat di-dot-source.
# ============================================================
function Invoke-PrinterAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$Name = "",
        [string]$RelativePath = ".",
        [string]$DriverRoot = "",
        [string]$ConnType = "driveronly",
        [string]$Address = "",
        [string]$PrinterName = "",
        [string]$ShareUser = "",
        [string]$SharePass = ""
    )

    # Sinkronkan variabel level-skrip karena fungsi internal (helper) membacanya.
    $script:Action       = $Action
    $script:Name         = $Name
    $script:RelativePath = $RelativePath
    if ($DriverRoot) { $script:DriverRoot = $DriverRoot }
    $script:ConnType   = $ConnType
    $script:Address    = $Address
    $script:PrinterName = $PrinterName
    $script:ShareUser  = $ShareUser
    $script:SharePass  = $SharePass

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
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}

# CLI entry point HANYA jika dijalankan standalone dengan -Action.
# Saat di-dot-source dari menu, skrip TIDAK boleh auto-run / exit,
# karena exit akan menghentikan proses induk (menu).
if ($PSBoundParameters.ContainsKey('Action') -and -not [string]::IsNullOrWhiteSpace($Action)) {
    $okCli = Invoke-PrinterAction -Action $Action -Name $Name -RelativePath $RelativePath `
        -DriverRoot $DriverRoot -ConnType $ConnType -Address $Address `
        -PrinterName $PrinterName -ShareUser $ShareUser -SharePass $SharePass
    exit $(if ($okCli) { 0 } else { 1 })
}
