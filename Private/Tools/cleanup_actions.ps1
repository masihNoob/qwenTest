# cleanup_actions.ps1 - Modul aksi cleanup (dot-source-able, TIDAK auto-run)
# Cara pakai:
#   1) Dari menu (in-process, tanpa child process):
#        . .\cleanup_actions.ps1
#        Invoke-Cleanup -Action "full"
#   2) CLI standalone (opsional, untuk debugging):
#        powershell -File cleanup_actions.ps1 -Action full

param(
    [Parameter(Mandatory = $false)]
    [string]$Action
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Test-RecyclePath {
    param([string]$FullName)
    if ([string]::IsNullOrEmpty($FullName)) { return $true }
    return ($FullName -match '\\\$Recycle\.Bin(\\|$)' -or $FullName -match '\\Recycler(\\|$)')
}

function Get-FolderSizeFast {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0L }
    if (-not [System.IO.Directory]::Exists($Path)) { return 0L }
    $sum = 0L
    try {
        $enum = [System.IO.SearchOption]::AllDirectories
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, "*", $enum)) {
            try {
                if (Test-RecyclePath -FullName $f) { continue }
                $sum += (New-Object System.IO.FileInfo $f).Length
            } catch {}
        }
    } catch {
        try {
            Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object {
                    if (-not (Test-RecyclePath -FullName $_.FullName)) { $sum += $_.Length }
                }
        } catch {}
    }
    return $sum
}

function Remove-FolderContents {
    param(
        [string]$Path,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("  [-] {0,-42} (tidak ada)" -f $Label) -ForegroundColor DarkGray
        return 0L
    }

    Write-Host ("  [..] {0,-42} menghitung..." -f $Label) -NoNewline
    $before = Get-FolderSizeFast -Path $Path
    Write-Host (" `r  [..] {0,-42} menghapus... " -f $Label) -NoNewline

    $ok = $false
    # Native PowerShell only (tanpa spawn cmd.exe -> menghindari heuristik SONAR)
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $full = $_.FullName
            if (Test-RecyclePath -FullName $full) { return }
            try {
                if ($_.PSIsContainer) {
                    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        $ok = $true
    } catch {}

    $after = 0L
    try {
        if (Test-Path -LiteralPath $Path) {
            $left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
            if ($left.Count -gt 0) { $after = Get-FolderSizeFast -Path $Path }
        }
    } catch {}

    $freed = [Math]::Max(0L, $before - $after)
    $color = if ($freed -gt 0) { "Green" } elseif ($ok) { "DarkGray" } else { "Yellow" }
    Write-Host ("`r  [OK] {0,-42} dibebaskan {1}   " -f $Label, (Format-Size $freed)) -ForegroundColor $color
    return $freed
}

function Remove-FilesByPattern {
    param(
        [string]$Path,
        [string[]]$Patterns,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("  [-] {0,-42} (tidak ada)" -f $Label) -ForegroundColor DarkGray
        return 0L
    }

    $freed = 0L
    try {
        foreach ($pat in $Patterns) {
            Get-ChildItem -LiteralPath $Path -Filter $pat -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object {
                    if (Test-RecyclePath -FullName $_.FullName) { return }
                    $len = $_.Length
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        if (-not (Test-Path -LiteralPath $_.FullName)) { $freed += $len }
                    } catch {}
                }
        }
    } catch {}

    $color = if ($freed -gt 0) { "Green" } else { "DarkGray" }
    Write-Host ("  [OK] {0,-42} dibebaskan {1}" -f $Label, (Format-Size $freed)) -ForegroundColor $color
    return $freed
}

function Stop-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            return $true
        }
    } catch {}
    return $false
}

function Start-ServiceSafe {
    param([string]$Name)
    try { Start-Service -Name $Name -ErrorAction SilentlyContinue } catch {}
}

function Show-DiskSpace {
    Write-Host ""
    Write-Host "Status disk saat ini:" -ForegroundColor Cyan
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
            $free  = [double]$_.FreeSpace
            $total = [double]$_.Size
            $pct   = if ($total -gt 0) { [math]::Round(($free / $total) * 100, 1) } else { 0 }
            Write-Host ("  {0}  Bebas: {1} / {2}  ({3}%)" -f $_.DeviceID, (Format-Size $free), (Format-Size $total), $pct)
        }
    } catch {
        Write-Host "  (gagal membaca info disk)" -ForegroundColor DarkGray
    }
}

function Clean-UserTemp {
    $total = 0L
    Write-Host ""
    Write-Host ">>> Temp User" -ForegroundColor Yellow

    $paths = @(
        @{ P = $env:TEMP; L = "User TEMP" },
        @{ P = $env:TMP;  L = "User TMP" }
    )
    if ($env:LOCALAPPDATA) {
        $lat = Join-Path $env:LOCALAPPDATA "Temp"
        if ($lat -ne $env:TEMP -and $lat -ne $env:TMP) {
            $paths += @{ P = $lat; L = "LocalAppData\Temp" }
        }
        $paths += @{ P = (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"); L = "INetCache" }
        $paths += @{ P = (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WebCache");  L = "WebCache" }
        $paths += @{ P = (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\History");   L = "History" }
    }
    if ($env:APPDATA) {
        $paths += @{ P = (Join-Path $env:APPDATA "Microsoft\Windows\Recent"); L = "Recent (shortcut)" }
    }

    $seen = @{}
    foreach ($item in $paths) {
        if (-not $item.P) { continue }
        $key = $item.P.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $total += Remove-FolderContents -Path $item.P -Label $item.L
    }
    return $total
}

function Clean-WindowsTemp {
    $total = 0L
    Write-Host ""
    Write-Host ">>> Temp Windows" -ForegroundColor Yellow

    if ($env:SystemRoot) {
        $total += Remove-FolderContents -Path (Join-Path $env:SystemRoot "Temp") -Label "Windows\Temp"
        $total += Remove-FolderContents -Path (Join-Path $env:SystemRoot "Prefetch") -Label "Prefetch"
    }

    if ($env:LOCALAPPDATA) {
        $thumb = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
        $total += Remove-FilesByPattern -Path $thumb -Patterns @("thumbcache_*.db", "iconcache_*.db") -Label "Thumbnail / Icon Cache"
    }
    return $total
}

function Clean-UpdateCache {
    $total = 0L
    Write-Host ""
    Write-Host ">>> Windows Update & Delivery Optimization" -ForegroundColor Yellow

    $stoppedWU   = Stop-ServiceSafe -Name "wuauserv"
    $stoppedBITS = Stop-ServiceSafe -Name "bits"
    $stoppedDO   = Stop-ServiceSafe -Name "DoSvc"

    if ($env:SystemRoot) {
        $total += Remove-FolderContents -Path (Join-Path $env:SystemRoot "SoftwareDistribution\Download") -Label "SoftwareDistribution\Download"

        $doCache = Join-Path $env:SystemRoot "ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        $total += Remove-FolderContents -Path $doCache -Label "Delivery Optimization Cache"
    }

    if ($env:LOCALAPPDATA) {
        $doUser = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\DeliveryOptimization"
        $total += Remove-FolderContents -Path $doUser -Label "Delivery Optimization (User)"
    }

    if ($stoppedWU)   { Start-ServiceSafe -Name "wuauserv" }
    if ($stoppedBITS) { Start-ServiceSafe -Name "bits" }
    if ($stoppedDO)   { Start-ServiceSafe -Name "DoSvc" }

    return $total
}

function Clean-LogsAndReports {
    $total = 0L
    Write-Host ""
    Write-Host ">>> Log & Error Report" -ForegroundColor Yellow

    $werList = @()
    if ($env:ProgramData) { $werList += (Join-Path $env:ProgramData "Microsoft\Windows\WER") }
    if ($env:LOCALAPPDATA) { $werList += (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER") }
    foreach ($p in $werList) {
        $total += Remove-FolderContents -Path $p -Label "Windows Error Reporting"
    }

    if ($env:SystemRoot) {
        $cbs = Join-Path $env:SystemRoot "Logs\CBS"
        $total += Remove-FilesByPattern -Path $cbs -Patterns @("*.cab", "*.log") -Label "CBS Logs"

        $minidump = Join-Path $env:SystemRoot "Minidump"
        $total += Remove-FolderContents -Path $minidump -Label "Minidump"

        $memDump = Join-Path $env:SystemRoot "MEMORY.DMP"
        if (Test-Path -LiteralPath $memDump) {
            try {
                $len = [long](Get-Item -LiteralPath $memDump -Force).Length
                Remove-Item -LiteralPath $memDump -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $memDump)) {
                    $total += $len
                    Write-Host ("  [OK] {0,-42} dibebaskan {1}" -f "MEMORY.DMP", (Format-Size $len)) -ForegroundColor Green
                } else {
                    Write-Host ("  [-] {0,-42} gagal dihapus (terkunci)" -f "MEMORY.DMP") -ForegroundColor DarkGray
                }
            } catch {
                Write-Host ("  [-] {0,-42} gagal dihapus" -f "MEMORY.DMP") -ForegroundColor DarkGray
            }
        }

        $fontSys = Join-Path $env:SystemRoot "ServiceProfiles\LocalService\AppData\Local\FontCache"
        $total += Remove-FolderContents -Path $fontSys -Label "Font Cache"
    }
    return $total
}

function Clean-BrowserCache {
    $total = 0L
    Write-Host ""
    Write-Host ">>> Cache Browser (hanya cache, bukan data login)" -ForegroundColor Yellow

    if (-not $env:LOCALAPPDATA) { return $total }

    $chrome = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default"
    if (Test-Path -LiteralPath $chrome) {
        $total += Remove-FolderContents -Path (Join-Path $chrome "Cache") -Label "Chrome Cache"
        $total += Remove-FolderContents -Path (Join-Path $chrome "Code Cache") -Label "Chrome Code Cache"
        $total += Remove-FolderContents -Path (Join-Path $chrome "GPUCache") -Label "Chrome GPUCache"
        $sw = Join-Path $chrome "Service Worker\CacheStorage"
        $total += Remove-FolderContents -Path $sw -Label "Chrome SW Cache"
    }

    $edge = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default"
    if (Test-Path -LiteralPath $edge) {
        $total += Remove-FolderContents -Path (Join-Path $edge "Cache") -Label "Edge Cache"
        $total += Remove-FolderContents -Path (Join-Path $edge "Code Cache") -Label "Edge Code Cache"
        $total += Remove-FolderContents -Path (Join-Path $edge "GPUCache") -Label "Edge GPUCache"
        $sw = Join-Path $edge "Service Worker\CacheStorage"
        $total += Remove-FolderContents -Path $sw -Label "Edge SW Cache"
    }

    $ffProfiles = Join-Path $env:LOCALAPPDATA "Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ffProfiles) {
        Get-ChildItem -LiteralPath $ffProfiles -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $total += Remove-FolderContents -Path (Join-Path $_.FullName "cache2") -Label ("Firefox Cache ({0})" -f $_.Name)
        }
    }
    return $total
}

function Clean-Dns {
    try {
        $null = ipconfig /flushdns 2>&1
        Write-Host ""
        Write-Host ("  [OK] {0,-42} di-flush" -f "DNS Cache") -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host ("  [-] {0,-42} gagal" -f "DNS Cache") -ForegroundColor DarkGray
    }
    return 0L
}

# ============================================================
# PUBLIC API: Invoke-Cleanup
# Fungsi ini bisa dipanggil in-process setelah dot-source:
#   . .\cleanup_actions.ps1
#   Invoke-Cleanup -Action "full"
# Tidak ada spawn child process, tidak ada exit.
# ============================================================
function Invoke-Cleanup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    $valid = @{
        "full"          = $true
        "user-temp"     = $true
        "windows-temp"  = $true
        "update-cache"  = $true
        "logs"          = $true
        "browser"       = $true
        "dns"           = $true
        "status"        = $true
    }

    $requested = @($Action -split '[,; ]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($requested.Count -eq 0) {
        Write-Host "[ERROR] -Action kosong." -ForegroundColor Red
        return $false
    }

    $unknown = @($requested | Where-Object { -not $valid.ContainsKey($_) })
    if ($unknown.Count -gt 0) {
        Write-Host ("[ERROR] Action tidak dikenal: {0}" -f ($unknown -join ", ")) -ForegroundColor Red
        Write-Host "Gunakan: full, user-temp, windows-temp, update-cache, logs, browser, dns, status"
        return $false
    }

    if ($requested.Count -eq 1 -and $requested[0] -eq "status") {
        Show-DiskSpace
        return $true
    }

    $grand = 0L
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($act in $requested) {
        switch ($act) {
            "status"       { Show-DiskSpace }
            "user-temp"    { $grand += Clean-UserTemp }
            "windows-temp" { $grand += Clean-WindowsTemp }
            "update-cache" { $grand += Clean-UpdateCache }
            "logs"         { $grand += Clean-LogsAndReports }
            "browser"      { $grand += Clean-BrowserCache }
            "dns"          { $null  = Clean-Dns }
            "full" {
                $grand += Clean-UserTemp
                $grand += Clean-WindowsTemp
                $grand += Clean-UpdateCache
                $grand += Clean-LogsAndReports
                $grand += Clean-BrowserCache
                $null   = Clean-Dns
            }
        }
    }

    $sw.Stop()

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ("  SELESAI. Total ruang dibebaskan : {0}" -f (Format-Size $grand)) -ForegroundColor Green
    Write-Host ("  Waktu eksekusi                 : {0:N1} detik" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Gray
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Catatan: Recycle Bin TIDAK disentuh." -ForegroundColor Gray
    Show-DiskSpace
    return $true
}

# ============================================================
# CLI entry point HANYA jika dijalankan via -File (standalone).
# Saat di-dot-source dari menu, $MyInvocation.MyCommand.Path
# tetap terisi tapi skrip TIDAK boleh auto-run / exit,
# karena akan menghentikan proses induk (menu).
# Deteksi: dipanggil standalone bila $Action diberikan ATAU
# dijalankan sebagai file utama dengan argumen.
# ============================================================
if ($PSBoundParameters.ContainsKey('Action') -and -not [string]::IsNullOrWhiteSpace($Action)) {
    $okCli = Invoke-Cleanup -Action $Action
    exit $(if ($okCli) { 0 } else { 1 })
}
