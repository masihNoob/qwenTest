# backup_actions.ps1 - Modul aksi backup/restore (dot-source-able, TIDAK auto-run)
# Cara pakai:
#   1) Dari menu (in-process, tanpa child process):
#        . .\backup_actions.ps1
#        Invoke-BackupAction -SourceRoot ... -Destination ... -Username ...
#   2) CLI standalone (opsional, untuk debugging):
#        powershell -File backup_actions.ps1 -Action Backup -SourceRoot ... -Destination ...

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Backup", "Restore", "")]
    [string]$Action = "",

    [string]$SourceRoot = "",
    [string]$Destination = "",
    [string]$Username = "",

    [string]$BackupPath = "",
    [string]$DestRoot = "",
    [switch]$ImportRegistry
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$script:FoldersToBackup = @(
    "Documents", "Desktop", "Downloads", "Pictures", "Videos",
    "Music", "Favorites", "Contacts", "Links", "Saved Games",
    "AppData\Roaming"
)

$script:SpecialFolders = @(
    @{ Name = "Chrome";           Path = "AppData\Local\Google\Chrome\User Data";    ExcludeDirs = @("Cache","Code Cache","GPUCache","ShaderCache","Service Worker\CacheStorage","GrShaderCache","GraphiteDawnCache","BrowserMetrics","Crashpad","Safe Browsing","pnacl","File System","blob_storage") },
    @{ Name = "Edge";             Path = "AppData\Local\Microsoft\Edge\User Data";   ExcludeDirs = @("Cache","Code Cache","GPUCache","ShaderCache","Service Worker\CacheStorage","GrShaderCache","GraphiteDawnCache","BrowserMetrics","Crashpad","Safe Browsing","pnacl","File System","blob_storage") },
    @{ Name = "Outlook Local";    Path = "AppData\Local\Microsoft\Outlook";          ExcludeDirs = @("Temp") },
    @{ Name = "Themes Wallpaper"; Path = "AppData\Roaming\Microsoft\Windows\Themes"; ExcludeDirs = @() },
    @{ Name = "Signatures";       Path = "AppData\Roaming\Microsoft\Signatures";     ExcludeDirs = @() }
)

$script:ExcludeFiles = @(
    "*.tmp", "*.temp", "*.log", "*.bak", "*.old",
    "Thumbs.db", "desktop.ini", "Cache.db", "Cache.db-journal",
    "lockfile", "SingletonLock", "SingletonCookie", "SingletonSocket"
)

$script:GlobalExcludeDirs = @(
    "Temp", "Cache", "Caches", "INetCache", "WebCache",
    "Code Cache", "GPUCache", "ShaderCache", "Recent",
    "Temporary Internet Files", "Crashpad", "BrowserMetrics",
    "Safe Browsing", "Service Worker\CacheStorage",
    "GrShaderCache", "GraphiteDawnCache", "blob_storage", "File System"
)

function Format-Size {
    param ([double]$SizeMB)
    if ($SizeMB -ge 1024) { return "{0:N2} GB" -f ($SizeMB / 1024) }
    return "{0:N2} MB" -f $SizeMB
}

function Get-FolderSize {
    param (
        [string]$Path,
        [string[]]$ExcludeDirs = @()
    )
    if (-not (Test-Path $Path)) { return 0 }
    $exAll = $script:GlobalExcludeDirs + $ExcludeDirs
    $size = 0L
    try {
        $files = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $skip = $false
            foreach ($ex in $exAll) {
                if ($f.FullName -like "*\$ex\*" -or $f.FullName -like "*\$ex") { $skip = $true; break }
            }
            if (-not $skip) { $size += $f.Length }
        }
    } catch {}
    return [math]::Round(($size / 1MB), 2)
}

function Build-FolderList {
    param ([string]$Root)

    $list = @()
    $total = 0.0

    foreach ($folder in $script:FoldersToBackup) {
        $full = Join-Path $Root $folder
        $sz = Get-FolderSize -Path $full
        $total += $sz
        $list += [PSCustomObject]@{
            Display  = $folder
            SizeMB   = $sz
            Size     = Format-Size $sz
            Status   = if (Test-Path $full) { "OK" } else { "Tidak ada" }
            FullPath = $full
            RelPath  = $folder
            ExtraXD  = @()
        }
    }

    foreach ($spec in $script:SpecialFolders) {
        $full = Join-Path $Root $spec.Path
        $sz = Get-FolderSize -Path $full -ExcludeDirs $spec.ExcludeDirs
        $total += $sz
        $list += [PSCustomObject]@{
            Display  = $spec.Name
            SizeMB   = $sz
            Size     = Format-Size $sz
            Status   = if (Test-Path $full) { "OK" } else { "Tidak ada" }
            FullPath = $full
            RelPath  = $spec.Path
            ExtraXD  = $spec.ExcludeDirs
        }
    }

    return @{ List = $list; TotalMB = $total }
}

function Invoke-RoboCopy {
    param (
        [string]$Source,
        [string]$Dest,
        [string[]]$ExtraExcludeDirs = @(),
        [string]$LogFile = $null
    )
    if (-not (Test-Path $Source)) {
        return @{ Success = $false; Partial = $false; ExitCode = -1; FailedFiles = @() }
    }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null

    $xdList = $script:GlobalExcludeDirs + $ExtraExcludeDirs
    $roboArgs = @(
        "`"$Source`"", "`"$Dest`"",
        "/E", "/COPY:DAT", "/R:2", "/W:2", "/MT:4", "/XJ",
        "/NFL", "/NDL", "/NP"
    )
    foreach ($xd in $xdList) { $roboArgs += "/XD"; $roboArgs += $xd }
    foreach ($xf in $script:ExcludeFiles) { $roboArgs += "/XF"; $roboArgs += $xf }

    $tmpLog = Join-Path $env:TEMP "itools_robo_$(Get-Random).log"
    $roboArgs += "/LOG:`"$tmpLog`""

    $null = & robocopy @roboArgs 2>&1
    $exitCode = $LASTEXITCODE

    $failedFiles = @()
    if (Test-Path $tmpLog) {
        $logLines = Get-Content $tmpLog -ErrorAction SilentlyContinue
        foreach ($line in $logLines) {
            if ($line -match "ERROR|Access is denied|cannot access|Locked") {
                $failedFiles += $line.Trim()
            }
        }
        if ($LogFile) {
            Add-Content -Path $LogFile -Value ("==== {0} -> {1} (code {2}) ====" -f $Source, $Dest, $exitCode)
            Add-Content -Path $LogFile -Value $logLines -ErrorAction SilentlyContinue
        }
        Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue
    }

    return @{
        Success     = ($exitCode -le 7)
        Partial     = ($exitCode -ge 8 -and $exitCode -lt 16)
        ExitCode    = $exitCode
        FailedFiles = $failedFiles
    }
}

function Invoke-BackupAction {
    param (
        [string]$SourceRoot,
        [string]$Destination,
        [string]$Username = ""
    )

    if (-not (Test-Path $SourceRoot)) {
        Write-Host "[ERROR] Sumber tidak ditemukan: $SourceRoot" -ForegroundColor Red
        return 1
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $logFile = Join-Path $Destination "backup_detail.log"

    $meta = @"
Username=$Username
SourceRoot=$SourceRoot
BackupDate=$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
ComputerName=$env:COMPUTERNAME
"@
    Set-Content -Path (Join-Path $Destination "backup_info.txt") -Value $meta -Encoding UTF8

    $data = Build-FolderList -Root $SourceRoot

    Write-Host ""
    Write-Host "Memulai backup ke: $Destination" -ForegroundColor Green
    Write-Host "--------------------------------------------------------"

    $start = Get-Date
    $okCount = 0
    $partialCount = 0
    $failCount = 0
    $allFailedDetails = @()

    foreach ($item in $data.List) {
        if ($item.Status -ne "OK") { continue }
        Write-Host ("Backup: {0,-28}" -f $item.Display) -NoNewline
        $dst = Join-Path $Destination $item.RelPath
        $result = Invoke-RoboCopy -Source $item.FullPath -Dest $dst -ExtraExcludeDirs $item.ExtraXD -LogFile $logFile

        if ($result.Success) {
            Write-Host " [OK]" -ForegroundColor Green
            $okCount++
        }
        elseif ($result.Partial) {
            Write-Host " [SEBAGIAN]" -ForegroundColor Yellow
            $partialCount++
            if ($result.FailedFiles.Count -gt 0) {
                $allFailedDetails += "--- $($item.Display) ---"
                $allFailedDetails += $result.FailedFiles | Select-Object -First 8
            }
        }
        else {
            Write-Host " [ERROR kode $($result.ExitCode)]" -ForegroundColor Red
            $failCount++
            if ($result.FailedFiles.Count -gt 0) {
                $allFailedDetails += "--- $($item.Display) ---"
                $allFailedDetails += $result.FailedFiles | Select-Object -First 8
            }
        }
    }

    $currentProfile = "C:\Users\$env:USERNAME"
    if ($SourceRoot -eq $currentProfile -or $SourceRoot -eq "$currentProfile\") {
        Write-Host ("Backup: {0,-28}" -f "Registry Wallpaper/Desktop") -NoNewline
        $regFile = Join-Path $Destination "UserSettings_Wallpaper_Desktop.reg"
        try {
            $regPaths = @(
                "HKCU\Control Panel\Desktop",
                "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes"
            )
            $combined = "Windows Registry Editor Version 5.00`r`n`r`n"
            foreach ($rp in $regPaths) {
                $tmp = Join-Path $env:TEMP "itools_reg_$(Get-Random).reg"
                reg export $rp $tmp /y >$null 2>&1
                if (Test-Path $tmp) {
                    $c = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
                    $c = $c -replace "(?s)^Windows Registry Editor Version 5\.00\s*", ""
                    $combined += $c.Trim() + "`r`n`r`n"
                    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            Set-Content -Path $regFile -Value $combined -Encoding Unicode
            Write-Host " [OK]" -ForegroundColor Green
            $okCount++
        } catch {
            Write-Host " [SKIP]" -ForegroundColor DarkGray
        }
    }

    $duration = (Get-Date) - $start
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "BACKUP SELESAI" -ForegroundColor Green
    Write-Host "Lokasi     : $Destination" -ForegroundColor White
    Write-Host "Durasi     : $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
    Write-Host "Berhasil   : $okCount" -ForegroundColor White
    if ($partialCount -gt 0) {
        Write-Host "Sebagian   : $partialCount  (ada file terkunci/dilewati)" -ForegroundColor Yellow
    }
    if ($failCount -gt 0) {
        Write-Host "Gagal      : $failCount" -ForegroundColor Red
    }
    Write-Host "Log detail : $logFile" -ForegroundColor Gray
    Write-Host "========================================================" -ForegroundColor Cyan

    if ($allFailedDetails.Count -gt 0) {
        Write-Host ""
        Write-Host "Cuplikan file yang bermasalah:" -ForegroundColor Yellow
        $allFailedDetails | Select-Object -First 20 | ForEach-Object {
            Write-Host "  $_" -ForegroundColor DarkYellow
        }
        if ($allFailedDetails.Count -gt 20) {
            Write-Host "  ... (lihat backup_detail.log untuk lengkap)" -ForegroundColor DarkGray
        }
    }

    return 0
}

function Invoke-RestoreAction {
    param (
        [string]$BackupPath,
        [string]$DestRoot,
        [switch]$ImportRegistry
    )

    if (-not (Test-Path $BackupPath)) {
        Write-Host "[ERROR] Folder backup tidak ditemukan: $BackupPath" -ForegroundColor Red
        return 1
    }
    if (-not (Test-Path $DestRoot)) {
        Write-Host "[ERROR] Folder tujuan tidak ditemukan: $DestRoot" -ForegroundColor Red
        return 1
    }

    $logFile = Join-Path $BackupPath "restore_detail.log"

    Write-Host ""
    Write-Host "Memulai restore..." -ForegroundColor Green
    Write-Host "--------------------------------------------------------"

    $start = Get-Date
    $okCount = 0
    $partialCount = 0
    $failCount = 0

    $toRestore = @()
    foreach ($folder in $script:FoldersToBackup) {
        $src = Join-Path $BackupPath $folder
        if (Test-Path $src) {
            $toRestore += @{ Display = $folder; Src = $src; Dst = Join-Path $DestRoot $folder; ExtraXD = @() }
        }
    }
    foreach ($spec in $script:SpecialFolders) {
        $src = Join-Path $BackupPath $spec.Path
        if (Test-Path $src) {
            $toRestore += @{ Display = $spec.Name; Src = $src; Dst = Join-Path $DestRoot $spec.Path; ExtraXD = $spec.ExcludeDirs }
        }
    }

    foreach ($item in $toRestore) {
        Write-Host ("Restore: {0,-28}" -f $item.Display) -NoNewline
        $result = Invoke-RoboCopy -Source $item.Src -Dest $item.Dst -ExtraExcludeDirs $item.ExtraXD -LogFile $logFile
        if ($result.Success) {
            Write-Host " [OK]" -ForegroundColor Green
            $okCount++
        }
        elseif ($result.Partial) {
            Write-Host " [SEBAGIAN]" -ForegroundColor Yellow
            $partialCount++
        }
        else {
            Write-Host " [ERROR kode $($result.ExitCode)]" -ForegroundColor Red
            $failCount++
        }
    }

    $regFile = Join-Path $BackupPath "UserSettings_Wallpaper_Desktop.reg"
    if ($ImportRegistry -and (Test-Path $regFile)) {
        Write-Host "Import registry..." -NoNewline
        reg import $regFile >$null 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host " [OK]" -ForegroundColor Green }
        else { Write-Host " [Gagal]" -ForegroundColor Yellow }
    }

    $duration = (Get-Date) - $start
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "RESTORE SELESAI" -ForegroundColor Green
    Write-Host "Tujuan     : $DestRoot" -ForegroundColor White
    Write-Host "Durasi     : $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
    Write-Host "Berhasil   : $okCount" -ForegroundColor White
    if ($partialCount -gt 0) {
        Write-Host "Sebagian   : $partialCount" -ForegroundColor Yellow
    }
    if ($failCount -gt 0) {
        Write-Host "Gagal      : $failCount" -ForegroundColor Red
    }
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Catatan: Permission tidak diubah (tanpa takeown/icacls)." -ForegroundColor Gray

    return 0
}

# ============================================================
# CLI entry point HANYA jika dijalankan standalone dengan -Action.
# Saat di-dot-source dari menu, skrip TIDAK boleh auto-run / exit,
# karena exit akan menghentikan proses induk (menu).
# ============================================================
if ($PSBoundParameters.ContainsKey('Action') -and -not [string]::IsNullOrWhiteSpace($Action)) {
    switch ($Action) {
        "Backup" {
            if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($Destination)) {
                Write-Host "[ERROR] Backup memerlukan -SourceRoot dan -Destination" -ForegroundColor Red
                exit 1
            }
            $code = Invoke-BackupAction -SourceRoot $SourceRoot -Destination $Destination -Username $Username
            exit $code
        }
        "Restore" {
            if ([string]::IsNullOrWhiteSpace($BackupPath) -or [string]::IsNullOrWhiteSpace($DestRoot)) {
                Write-Host "[ERROR] Restore memerlukan -BackupPath dan -DestRoot" -ForegroundColor Red
                exit 1
            }
            $code = Invoke-RestoreAction -BackupPath $BackupPath -DestRoot $DestRoot -ImportRegistry:$ImportRegistry
            exit $code
        }
    }
}
