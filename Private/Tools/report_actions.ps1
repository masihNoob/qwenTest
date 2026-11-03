# ============================================================
# report_actions.ps1 - aksi generate system report
# Dipanggil dari report_menu.ps1 dengan -Action
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "full",
        "identity",
        "hardware",
        "network",
        "battery",
        "open-folder"
    )]
    [string]$Action
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-KV {
    param([string]$Key, [string]$Value)
    if ($null -eq $Value) { $Value = "N/A" }
    $k = $Key.PadRight(28)
    Write-Host ("  {0}: " -f $k) -NoNewline -ForegroundColor Gray
    Write-Host $Value
}

function Get-Safe {
    param([scriptblock]$Script, [string]$Default = "N/A")
    try {
        $r = & $Script
        if ($null -eq $r) { return $Default }
        if ($r -is [string] -and [string]::IsNullOrWhiteSpace($r)) { return $Default }
        return $r
    } catch {
        return $Default
    }
}

function To-Str {
    param($Value, [string]$Default = "N/A")
    if ($null -eq $Value) { return $Default }
    $s = "$Value"
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s
}

# ---------- Shared state ----------
$script:ReportDir = Join-Path $env:USERPROFILE "Desktop\ITools_Reports"
$script:ComputerName = $env:COMPUTERNAME
$script:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:Sb = New-Object System.Text.StringBuilder
$script:BattFile = $null
$script:ReportFile = $null
$script:HtmlFile = $null

function Add-Line {
    param([string]$Line = "")
    [void]$script:Sb.AppendLine($Line)
}

function Ensure-ReportDir {
    if (-not (Test-Path -LiteralPath $script:ReportDir)) {
        New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null
    }
    $script:ReportFile = Join-Path $script:ReportDir ("Report_{0}_{1}.txt" -f $script:ComputerName, $script:Timestamp)
    $script:HtmlFile   = Join-Path $script:ReportDir ("Report_{0}_{1}.html" -f $script:ComputerName, $script:Timestamp)
    $script:BattFile   = Join-Path $script:ReportDir ("BatteryReport_{0}_{1}.html" -f $script:ComputerName, $script:Timestamp)
}

# ============================================================
# Collectors
# ============================================================

function Collect-Identity {
    Write-Section "IDENTITAS SISTEM"

    $cs   = Get-Safe { Get-CimInstance -ClassName Win32_ComputerSystem }
    $bios = Get-Safe { Get-CimInstance -ClassName Win32_BIOS }
    $bb   = Get-Safe { Get-CimInstance -ClassName Win32_BaseBoard }
    $enc  = Get-Safe { Get-CimInstance -ClassName Win32_SystemEnclosure }
    $csp  = Get-Safe { Get-CimInstance -ClassName Win32_ComputerSystemProduct }

    $serial = "N/A"
    if ($bios -isnot [string]) { $serial = To-Str $bios.SerialNumber }
    if ($serial -eq "N/A" -or $serial -match "To be filled|Default string|None|O\.E\.M|System Serial") {
        if ($enc -isnot [string]) { $serial = To-Str $enc.SerialNumber }
    }

    $manufacturer = if ($cs -isnot [string]) { To-Str $cs.Manufacturer } else { "N/A" }
    $model        = if ($cs -isnot [string]) { To-Str $cs.Model } else { "N/A" }
    $biosVersion  = if ($bios -isnot [string]) { To-Str $bios.SMBIOSBIOSVersion } else { "N/A" }
    $biosDate     = "N/A"
    if ($bios -isnot [string] -and $bios.ReleaseDate) {
        try { $biosDate = $bios.ReleaseDate.ToString("yyyy-MM-dd") } catch {}
    }
    $uuid      = if ($csp -isnot [string]) { To-Str $csp.UUID } else { "N/A" }
    $bbProduct = if ($bb -isnot [string]) { To-Str $bb.Product } else { "N/A" }
    $bbSerial  = if ($bb -isnot [string]) { To-Str $bb.SerialNumber } else { "N/A" }

    Write-KV "Nama Komputer"     $script:ComputerName
    Write-KV "Serial Number"     $serial
    Write-KV "Manufacturer"      $manufacturer
    Write-KV "Model"             $model
    Write-KV "UUID"              $uuid
    Write-KV "BIOS Version"      $biosVersion
    Write-KV "BIOS Date"         $biosDate
    Write-KV "BaseBoard Product" $bbProduct
    Write-KV "BaseBoard Serial"  $bbSerial

    Add-Line "=== IDENTITAS SISTEM ==="
    Add-Line ("Nama Komputer     : {0}" -f $script:ComputerName)
    Add-Line ("Serial Number     : {0}" -f $serial)
    Add-Line ("Manufacturer      : {0}" -f $manufacturer)
    Add-Line ("Model             : {0}" -f $model)
    Add-Line ("UUID              : {0}" -f $uuid)
    Add-Line ("BIOS Version      : {0}" -f $biosVersion)
    Add-Line ("BIOS Date         : {0}" -f $biosDate)
    Add-Line ("BaseBoard Product : {0}" -f $bbProduct)
    Add-Line ("BaseBoard Serial  : {0}" -f $bbSerial)
    Add-Line ""

    return $cs
}

function Collect-UserDomain {
    param($cs)

    Write-Section "USER & DOMAIN"

    $currentUser = $env:USERNAME
    $domain      = if ($cs -isnot [string]) { To-Str $cs.Domain } else { "N/A" }
    $workgroup   = if ($cs -isnot [string]) { To-Str $cs.Workgroup } else { "N/A" }
    $partOfDomain = $false
    if ($cs -isnot [string] -and $null -ne $cs.PartOfDomain) {
        $partOfDomain = [bool]$cs.PartOfDomain
    }
    $loggedOn = Get-Safe {
        $u = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if ($u) { $u } else { $env:USERDOMAIN + "\" + $env:USERNAME }
    }

    if ($partOfDomain) {
        $domainDisplay = $domain
    } else {
        $domainDisplay = "Workgroup: $workgroup"
    }

    Write-KV "Username (login)"   $currentUser
    Write-KV "User penuh"         (To-Str $loggedOn)
    Write-KV "Domain / Workgroup" $domainDisplay
    Write-KV "Part of Domain"     (To-Str $partOfDomain)

    Add-Line "=== USER & DOMAIN ==="
    Add-Line ("Username (login)  : {0}" -f $currentUser)
    Add-Line ("User penuh        : {0}" -f (To-Str $loggedOn))
    Add-Line ("Domain/Workgroup  : {0}" -f $domainDisplay)
    Add-Line ("Part of Domain    : {0}" -f (To-Str $partOfDomain))
    Add-Line ""
}

function Collect-OS {
    Write-Section "OPERATING SYSTEM"

    $os = Get-Safe { Get-CimInstance -ClassName Win32_OperatingSystem }

    $osCaption   = if ($os -isnot [string]) { To-Str $os.Caption } else { "N/A" }
    $osVersion   = if ($os -isnot [string]) { To-Str $os.Version } else { "N/A" }
    $osBuild     = if ($os -isnot [string]) { To-Str $os.BuildNumber } else { "N/A" }
    $osArch      = if ($os -isnot [string]) { To-Str $os.OSArchitecture } else { "N/A" }
    $installDate = "N/A"
    $lastBoot    = "N/A"
    $uptime      = "N/A"

    if ($os -isnot [string]) {
        if ($os.InstallDate) {
            try { $installDate = $os.InstallDate.ToString("yyyy-MM-dd HH:mm") } catch {}
        }
        if ($os.LastBootUpTime) {
            try {
                $lastBoot = $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
                $ts = (Get-Date) - $os.LastBootUpTime
                $uptime = "{0} hari {1} jam {2} menit" -f $ts.Days, $ts.Hours, $ts.Minutes
            } catch {}
        }
    }

    Write-KV "OS"              $osCaption
    Write-KV "Version / Build" ("{0} (Build {1})" -f $osVersion, $osBuild)
    Write-KV "Architecture"    $osArch
    Write-KV "Install Date"    $installDate
    Write-KV "Last Boot"       $lastBoot
    Write-KV "Uptime"          $uptime

    Add-Line "=== OPERATING SYSTEM ==="
    Add-Line ("OS                : {0}" -f $osCaption)
    Add-Line ("Version / Build   : {0} (Build {1})" -f $osVersion, $osBuild)
    Add-Line ("Architecture      : {0}" -f $osArch)
    Add-Line ("Install Date      : {0}" -f $installDate)
    Add-Line ("Last Boot         : {0}" -f $lastBoot)
    Add-Line ("Uptime            : {0}" -f $uptime)
    Add-Line ""

    return $os
}

function Collect-Hardware {
    param($cs, $os)

    Write-Section "CPU & MEMORY"

    $cpu = Get-Safe { Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 }

    $cpuName    = "N/A"
    $cpuCores   = "N/A"
    $cpuLogical = "N/A"
    $cpuMax     = "N/A"
    if ($cpu -isnot [string]) {
        $cpuName = To-Str ($cpu.Name)
        if ($cpuName -ne "N/A") { $cpuName = $cpuName.Trim() }
        $cpuCores   = To-Str $cpu.NumberOfCores
        $cpuLogical = To-Str $cpu.NumberOfLogicalProcessors
        if ($cpu.MaxClockSpeed) { $cpuMax = "{0} MHz" -f $cpu.MaxClockSpeed }
    }

    $totalRAM = "N/A"
    $freeRAM  = "N/A"
    if ($cs -isnot [string] -and $cs.TotalPhysicalMemory) {
        $totalRAM = "{0} GB" -f ([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))
    }
    if ($os -isnot [string] -and $os.FreePhysicalMemory) {
        $freeRAM = "{0} GB" -f ([math]::Round($os.FreePhysicalMemory / 1MB, 2))
    }

    Write-KV "Processor"       $cpuName
    Write-KV "Cores / Logical" ("{0} / {1}" -f $cpuCores, $cpuLogical)
    Write-KV "Max Clock"       $cpuMax
    Write-KV "Total RAM"       $totalRAM
    Write-KV "Free RAM"        $freeRAM

    Add-Line "=== CPU & MEMORY ==="
    Add-Line ("Processor         : {0}" -f $cpuName)
    Add-Line ("Cores / Logical   : {0} / {1}" -f $cpuCores, $cpuLogical)
    Add-Line ("Max Clock         : {0}" -f $cpuMax)
    Add-Line ("Total RAM         : {0}" -f $totalRAM)
    Add-Line ("Free RAM          : {0}" -f $freeRAM)
    Add-Line ""

    # Storage
    Write-Section "STORAGE (Disk)"
    $disks = @()
    try { $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue) } catch {}

    Add-Line "=== STORAGE (Disk) ==="
    if ($disks.Count -eq 0) {
        Write-Host "  Tidak ada disk terdeteksi." -ForegroundColor Yellow
        Add-Line "Tidak ada disk terdeteksi."
    } else {
        foreach ($d in $disks) {
            $sizeGB = 0; $freeGB = 0; $usedPct = 0
            if ($d.Size -and $d.Size -gt 0) {
                $sizeGB  = [math]::Round($d.Size / 1GB, 2)
                $freeGB  = [math]::Round($d.FreeSpace / 1GB, 2)
                $usedPct = [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1)
            }
            $volName = To-Str $d.VolumeName ""
            $line = "{0}  {1} GB total, {2} GB free ({3}% used)  [{4}]" -f $d.DeviceID, $sizeGB, $freeGB, $usedPct, $volName
            Write-Host ("  " + $line)
            Add-Line $line
        }
    }
    Add-Line ""

    $phys = @()
    try { $phys = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue) } catch {}
    if ($phys.Count -gt 0) {
        Write-Host ""
        Write-Host "  Physical Disks:" -ForegroundColor Gray
        Add-Line "Physical Disks:"
        foreach ($p in $phys) {
            $sz = "?"
            if ($p.Size) { $sz = "{0:N0} GB" -f ($p.Size / 1GB) }
            $line = "  - {0} | {1} | {2} | Serial: {3}" -f (To-Str $p.Model), $sz, (To-Str $p.InterfaceType), (To-Str $p.SerialNumber)
            Write-Host $line
            Add-Line $line
        }
        Add-Line ""
    }

    # Graphics
    Write-Section "GRAPHICS"
    $gpus = @()
    try { $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue) } catch {}

    Add-Line "=== GRAPHICS ==="
    if ($gpus.Count -eq 0) {
        Write-Host "  Tidak ada GPU terdeteksi." -ForegroundColor Yellow
        Add-Line "Tidak ada GPU terdeteksi."
    } else {
        foreach ($g in $gpus) {
            $vram = "N/A"
            if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) {
                $vram = "{0:N0} MB" -f ($g.AdapterRAM / 1MB)
            }
            $gpuName = To-Str $g.Name
            $gpuDrv  = To-Str $g.DriverVersion
            Write-KV "GPU"    $gpuName
            Write-KV "Driver" $gpuDrv
            Write-KV "VRAM"   $vram
            Add-Line ("GPU    : {0}" -f $gpuName)
            Add-Line ("Driver : {0}" -f $gpuDrv)
            Add-Line ("VRAM   : {0}" -f $vram)
            Add-Line ""
        }
    }
}

function Collect-Network {
    Write-Section "NETWORK"

    $adapters = @()
    try {
        $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)
    } catch {}

    Add-Line "=== NETWORK ==="
    if ($adapters.Count -eq 0) {
        Write-Host "  Tidak ada adapter IP aktif." -ForegroundColor Yellow
        Add-Line "Tidak ada adapter IP aktif."
        Add-Line ""
        return
    }

    foreach ($a in $adapters) {
        $ips = "N/A"
        if ($a.IPAddress) {
            $v4 = @($a.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            if ($v4.Count -gt 0) { $ips = $v4 -join ", " }
        }
        $mac = To-Str $a.MACAddress
        $gw  = "N/A"
        if ($a.DefaultIPGateway) { $gw = ($a.DefaultIPGateway -join ", ") }
        $dns = "N/A"
        if ($a.DNSServerSearchOrder) { $dns = ($a.DNSServerSearchOrder -join ", ") }

        Write-Host ("  Adapter : {0}" -f (To-Str $a.Description))
        Write-KV "    IP Address" $ips
        Write-KV "    MAC"        $mac
        Write-KV "    Gateway"    $gw
        Write-KV "    DNS"        $dns

        Add-Line ("Adapter : {0}" -f (To-Str $a.Description))
        Add-Line ("  IP Address : {0}" -f $ips)
        Add-Line ("  MAC        : {0}" -f $mac)
        Add-Line ("  Gateway    : {0}" -f $gw)
        Add-Line ("  DNS        : {0}" -f $dns)
        Add-Line ""
    }
}

function Collect-Battery {
    Write-Section "BATTERY"

    $batteries = @()
    try { $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) } catch {}

    Add-Line "=== BATTERY ==="
    if ($batteries.Count -eq 0) {
        Write-Host "  Tidak terdeteksi battery (kemungkinan desktop)." -ForegroundColor Yellow
        Add-Line "Tidak terdeteksi battery (kemungkinan desktop)."
        Add-Line ""
        return
    }

    $statusMap = @{
        1 = "Other"; 2 = "Unknown"; 3 = "Fully Charged"; 4 = "Low"
        5 = "Critical"; 6 = "Charging"; 7 = "Charging and High"
        8 = "Charging and Low"; 9 = "Charging and Critical"
        10 = "Undefined"; 11 = "Partially Charged"
    }
    $chemMap = @{
        1 = "Other"; 2 = "Unknown"; 3 = "Lead Acid"; 4 = "Nickel Cadmium"
        5 = "Nickel Metal Hydride"; 6 = "Lithium-ion"; 7 = "Zinc air"
        8 = "Lithium Polymer"
    }

    foreach ($b in $batteries) {
        $status = To-Str $b.BatteryStatus
        $bsInt = 0
        if ([int]::TryParse("$($b.BatteryStatus)", [ref]$bsInt) -and $statusMap.ContainsKey($bsInt)) {
            $status = $statusMap[$bsInt]
        }

        $chem = To-Str $b.Chemistry
        $chInt = 0
        if ([int]::TryParse("$($b.Chemistry)", [ref]$chInt) -and $chemMap.ContainsKey($chInt)) {
            $chem = $chemMap[$chInt]
        }

        $estCharge = "N/A"
        if ($null -ne $b.EstimatedChargeRemaining) {
            $estCharge = "{0}%" -f $b.EstimatedChargeRemaining
        }

        $estRuntime = "N/A (AC atau tidak tersedia)"
        if ($b.EstimatedRunTime -and $b.EstimatedRunTime -lt 71582788) {
            $estRuntime = "{0} menit" -f $b.EstimatedRunTime
        }

        $designVoltage = "N/A"
        if ($b.DesignVoltage) { $designVoltage = "{0} mV" -f $b.DesignVoltage }

        $battName = To-Str $b.Name

        Write-KV "Name"              $battName
        Write-KV "Status"            $status
        Write-KV "Chemistry"         $chem
        Write-KV "Charge Remaining"  $estCharge
        Write-KV "Estimated Runtime" $estRuntime
        Write-KV "Design Voltage"    $designVoltage

        Add-Line ("Name              : {0}" -f $battName)
        Add-Line ("Status            : {0}" -f $status)
        Add-Line ("Chemistry         : {0}" -f $chem)
        Add-Line ("Charge Remaining  : {0}" -f $estCharge)
        Add-Line ("Estimated Runtime : {0}" -f $estRuntime)
        Add-Line ("Design Voltage    : {0}" -f $designVoltage)
        Add-Line ""
    }

    try {
        $null = & powercfg.exe /batteryreport /output $script:BattFile 2>&1
        if (Test-Path -LiteralPath $script:BattFile) {
            Write-Host ""
            Write-Host "  Battery report detail disimpan:" -ForegroundColor Green
            Write-Host ("  " + $script:BattFile) -ForegroundColor Green
            Add-Line ("Battery report HTML : {0}" -f $script:BattFile)
        }
    } catch {
        Write-Host "  (powercfg /batteryreport gagal dijalankan)" -ForegroundColor Yellow
    }
}

function Collect-Printers {
    Write-Section "PRINTERS"

    $printers = @()
    try { $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue) } catch {}

    Add-Line "=== PRINTERS ==="
    if ($printers.Count -eq 0) {
        Write-Host "  Tidak ada printer terpasang." -ForegroundColor Yellow
        Add-Line "Tidak ada printer terpasang."
    } else {
        foreach ($pr in $printers) {
            $def = ""
            if ($pr.Default) { $def = " [DEFAULT]" }
            $line = "{0}{1}  |  Port: {2}  |  Driver: {3}" -f (To-Str $pr.Name), $def, (To-Str $pr.PortName), (To-Str $pr.DriverName)
            Write-Host ("  " + $line)
            Add-Line $line
        }
    }
    Add-Line ""
}

function Collect-Security {
    Write-Section "SECURITY (ringkas)"

    $secureBoot = "Tidak tersedia / butuh admin"
    try {
        $sbResult = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($sbResult) { $secureBoot = "Enabled" } else { $secureBoot = "Disabled" }
    } catch {
        $secureBoot = "Tidak tersedia / butuh admin / Legacy BIOS"
    }

    Write-KV "Secure Boot" $secureBoot
    Add-Line "=== SECURITY ==="
    Add-Line ("Secure Boot       : {0}" -f $secureBoot)

    try {
        $blList = @(Get-BitLockerVolume -ErrorAction Stop | Select-Object -First 5)
        if ($blList.Count -gt 0) {
            foreach ($v in $blList) {
                $line = "BitLocker {0} : {1} (Protection: {2})" -f $v.MountPoint, $v.VolumeStatus, $v.ProtectionStatus
                Write-Host ("  " + $line)
                Add-Line $line
            }
        } else {
            Write-Host "  BitLocker: tidak ada volume / tidak aktif" -ForegroundColor Yellow
            Add-Line "BitLocker: tidak ada volume / tidak aktif"
        }
    } catch {
        Write-Host "  BitLocker status: tidak tersedia / butuh admin" -ForegroundColor Yellow
        Add-Line "BitLocker status: tidak tersedia / butuh admin"
    }
    Add-Line ""
}

function Save-ReportFiles {
    param([string]$Title = "ITools System Report")

    if ([string]::IsNullOrWhiteSpace($script:Sb.ToString())) {
        Write-Warn "Tidak ada data untuk disimpan."
        return
    }

    Ensure-ReportDir

    $header = @"
================================================================================
  $Title
  Generated : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Computer  : $($script:ComputerName)
  User      : $env:USERNAME
================================================================================

"@

    $fullText = $header + $script:Sb.ToString()
    $fullText | Out-File -FilePath $script:ReportFile -Encoding UTF8

    $htmlEscaped = [System.Net.WebUtility]::HtmlEncode($fullText)
    $htmlEscaped = $htmlEscaped -replace "`r?`n", "<br>`n"

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$Title - $($script:ComputerName)</title>
<style>
  body { font-family: Consolas, 'Courier New', monospace; background: #1e1e1e; color: #d4d4d4; padding: 24px; }
  h1 { color: #4ec9b0; }
  .meta { color: #9cdcfe; margin-bottom: 20px; }
  .content { white-space: pre-wrap; line-height: 1.45; }
</style>
</head>
<body>
<h1>$Title</h1>
<div class="meta">
  Computer: <b>$($script:ComputerName)</b><br>
  Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")<br>
  User: $env:USERNAME
</div>
<div class="content">$htmlEscaped</div>
</body>
</html>
"@
    $html | Out-File -FilePath $script:HtmlFile -Encoding UTF8

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host "  REPORT SELESAI" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host ""
    Write-Host ("  File teks  : {0}" -f $script:ReportFile) -ForegroundColor Green
    Write-Host ("  File HTML  : {0}" -f $script:HtmlFile) -ForegroundColor Green
    if ($script:BattFile -and (Test-Path -LiteralPath $script:BattFile)) {
        Write-Host ("  Battery    : {0}" -f $script:BattFile) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host ("  Folder laporan: {0}" -f $script:ReportDir) -ForegroundColor Cyan
    Write-Host ""
}

function Open-ReportsFolder {
    Ensure-ReportDir
    Write-Info ("Membuka folder: {0}" -f $script:ReportDir)
    try {
        Start-Process explorer.exe -ArgumentList $script:ReportDir
        Write-Ok "Folder laporan dibuka."
    } catch {
        Write-Err ("Gagal membuka folder: {0}" -f $_)
    }
}

# ============================================================
# Action dispatch
# ============================================================

Ensure-ReportDir

switch ($Action) {
    "full" {
        Write-Info "Mengumpulkan full system report..."
        $cs = Collect-Identity
        Collect-UserDomain -cs $cs
        $os = Collect-OS
        Collect-Hardware -cs $cs -os $os
        Collect-Network
        Collect-Battery
        Collect-Printers
        Collect-Security
        Save-ReportFiles -Title "ITools Full System Report"
        Open-ReportsFolder
    }
    "identity" {
        Write-Info "Mengumpulkan identitas sistem..."
        $cs = Collect-Identity
        Collect-UserDomain -cs $cs
        $null = Collect-OS
        Save-ReportFiles -Title "ITools Identity Report"
        Open-ReportsFolder
    }
    "hardware" {
        Write-Info "Mengumpulkan info hardware..."
        $cs = Get-Safe { Get-CimInstance -ClassName Win32_ComputerSystem }
        $os = Get-Safe { Get-CimInstance -ClassName Win32_OperatingSystem }
        Collect-Hardware -cs $cs -os $os
        Save-ReportFiles -Title "ITools Hardware Report"
        Open-ReportsFolder
    }
    "network" {
        Write-Info "Mengumpulkan info network..."
        Collect-Network
        Save-ReportFiles -Title "ITools Network Report"
        Open-ReportsFolder
    }
    "battery" {
        Write-Info "Mengumpulkan battery report..."
        Collect-Battery
        Save-ReportFiles -Title "ITools Battery Report"
        Open-ReportsFolder
    }
    "open-folder" {
        Open-ReportsFolder
    }
    default {
        Write-Err ("Aksi tidak dikenal: {0}" -f $Action)
        exit 1
    }
}
