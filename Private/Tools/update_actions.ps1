param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "status",
        "scan",
        "install",
        "reset-wu",
        "winget-list",
        "winget-upgrade",
        "office",
        "browsers"
    )]
    [string]$Action,

    [string]$WingetId = ""
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
    try {
        $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        if ($null -eq $v -or "$v" -eq "") { return $Default }
        return "$v"
    } catch { return $Default }
}

function Format-DateSafe {
    param($Value)
    if ($null -eq $Value) { return "N/A" }
    try {
        if ($Value -is [datetime]) { return $Value.ToString("yyyy-MM-dd HH:mm") }
        return ([datetime]$Value).ToString("yyyy-MM-dd HH:mm")
    } catch { return "$Value" }
}

function Test-Winget {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function Get-WuHresultInfo {
    param($ErrorRecord)
    $code = $null
    $msg  = "$ErrorRecord"
    try {
        if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) {
            if ($ErrorRecord.Exception.PSObject.Properties["ErrorCode"]) {
                $code = [int]$ErrorRecord.Exception.ErrorCode
            } elseif ($ErrorRecord.Exception.HResult -ne 0) {
                $code = [int]$ErrorRecord.Exception.HResult
            }
        }
    } catch {}
    if ($null -eq $code) {
        try {
            if ($msg -match '0x([0-9A-Fa-f]{8})') {
                $code = [int]([uint32]::Parse($Matches[1], [System.Globalization.NumberStyles]::HexNumber))
            }
        } catch {}
    }
    $hex = "N/A"
    if ($null -ne $code) {
        try {
            $u = [uint32]($code -band 0xFFFFFFFF)
            $hex = "0x{0:X8}" -f $u
        } catch {
            try { $hex = "0x{0:X8}" -f [uint32]$code } catch { $hex = "N/A" }
        }
    }
    $map = @{
        "0x80244019" = "WU_E_PT_HTTP_STATUS_NOT_FOUND (HTTP 404) - server update tidak menemukan URI. Sering karena URL WSUS salah, self-update WSUS rusak, atau proxy memotong path update."
        "0x8024402C" = "WU_E_PT_WINHTTP_NAME_NOT_RESOLVED - nama server update tidak bisa di-resolve (DNS)."
        "0x8024402F" = "WU_E_PT_ECP_SUCCEEDED_WITH_ERRORS - pemrosesan cab eksternal error (sering filter web)."
        "0x8024401C" = "WU_E_PT_HTTP_STATUS_REQUEST_TIMEOUT - timeout ke server update."
        "0x8024401B" = "WU_E_PT_HTTP_STATUS_PROXY_AUTH_REQ - proxy minta autentikasi."
        "0x80244018" = "WU_E_PT_HTTP_STATUS_FORBIDDEN (HTTP 403)."
        "0x80244017" = "WU_E_PT_HTTP_STATUS_DENIED (HTTP 401)."
        "0x80244022" = "WU_E_PT_HTTP_STATUS_BAD_GATEWAY / masalah gateway."
        "0x80240438" = "WU_E_PT_ENDPOINT_UNREACHABLE - endpoint update tidak terjangkau."
        "0x80072EE2" = "ERROR_INTERNET_TIMEOUT - koneksi timeout."
        "0x80072EFD" = "ERROR_INTERNET_CANNOT_CONNECT - tidak bisa connect ke server."
        "0x80072EE7" = "ERROR_INTERNET_NAME_NOT_RESOLVED - DNS gagal."
        "0x8024001E" = "WU_E_SERVICE_STOP - service Windows Update dihentikan saat operasi."
        "0x80240022" = "WU_E_ALL_UPDATES_FAILED - semua update gagal."
        "0x8024400A" = "WU_E_PT_SOAPCLIENT_PARSE - respons server tidak valid (sering WSUS)."
        "0x8024400D" = "WU_E_PT_SOAP_INVALID / fault dari server (WSUS)."
        "0x80244011" = "WU_E_PT_INVALID_CONFIG - konfigurasi WU/WSUS tidak valid (WUServer kosong?)."
    }
    $desc = $map[$hex]
    if (-not $desc) { $desc = "Lihat dokumentasi Windows Update error reference." }
    return [PSCustomObject]@{ Hex = $hex; Description = $desc; Raw = $msg }
}

function Show-WuSource {
    try {
        $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        $au  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        $use = Get-RegValue $au "UseWUServer" "0"
        $srv = Get-RegValue $pol "WUServer" "(tidak diset)"
        $stat = Get-RegValue $pol "WUStatusServer" "(tidak diset)"
        Write-Host "  Update source :" -NoNewline
        if ("$use" -eq "1") {
            Write-Host " WSUS (kebijakan aktif)" -ForegroundColor Yellow
            Write-Host "  WUServer      : $srv"
            Write-Host "  WUStatusServer: $stat"
        } else {
            Write-Host " Microsoft Update / default" -ForegroundColor Green
            if ($srv -ne "(tidak diset)") {
                Write-Host "  (WUServer terisi tapi UseWUServer != 1: $srv)" -ForegroundColor DarkGray
            }
        }
        foreach ($n in @("wuauserv", "bits")) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s) {
                Write-Host ("  Service {0,-10}: {1}" -f $n, $s.Status)
            }
        }
    } catch {
        Write-Host "  (gagal membaca sumber update: $_)" -ForegroundColor DarkGray
    }
}

function Write-WuError {
    param($ErrorRecord, [string]$Context = "Operasi Windows Update")
    try {
        $info = Get-WuHresultInfo -ErrorRecord $ErrorRecord
        Write-Err ("{0} gagal: {1}" -f $Context, $info.Raw)
        Write-Host ("  Kode   : {0}" -f $info.Hex) -ForegroundColor Yellow
        Write-Host ("  Arti   : {0}" -f $info.Description) -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Sumber update saat ini:" -ForegroundColor Cyan
        Show-WuSource
        Write-Host ""
        Write-Host "  Saran langkah:" -ForegroundColor Cyan
        if ($info.Hex -eq "0x80244019") {
            Write-Host "  1. Cek PC mengarah ke WSUS yang benar (Group Policy / registry)."
            Write-Host "  2. Di server WSUS: pastikan Self-Update / ClientWebService sehat."
            Write-Host "  3. Menu Update Tools -> Reset komponen Windows Update, lalu Scan ulang."
            Write-Host "  4. Restart service wuauserv & bits; cek proxy/firewall ke server update."
            Write-Host "  5. (Opsional admin) wuauclt /ResetAuthorization /DetectNow"
        } else {
            Write-Host "  1. Menu Update Tools -> Reset komponen Windows Update."
            Write-Host "  2. Pastikan internet / server WSUS bisa diakses."
            Write-Host "  3. Restart service Windows Update (wuauserv) dan BITS."
        }
    } catch {
        Write-Err ("{0} gagal: {1}" -f $Context, $ErrorRecord)
        Write-Host "  (detail error tambahan tidak bisa ditampilkan)" -ForegroundColor DarkGray
    }
}

function Action-Status {
    Write-Host "========== STATUS SISTEM ==========" -ForegroundColor Cyan
    Write-Host ""

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

    Write-Host "  Komputer      : $($env:COMPUTERNAME)" -ForegroundColor White
    Write-Host "  User          : $($env:USERNAME)"
    if ($os) {
        Write-Host "  Windows       : $($os.Caption)"
        Write-Host "  Versi         : $($os.Version)  Build $($os.BuildNumber)"
        Write-Host "  Arsitektur    : $($os.OSArchitecture)"
        Write-Host "  Install Date  : $(Format-DateSafe $os.InstallDate)"
        Write-Host "  Last Boot     : $(Format-DateSafe $os.LastBootUpTime)"
    }
    if ($cs) {
        Write-Host "  Domain/Workgroup: $($cs.Domain)"
    }
    Write-Host "  Admin session : $(if (Test-IsAdmin) { 'Ya' } else { 'Tidak' })"

    Write-Host ""
    Write-Host "---------- Windows Update ----------" -ForegroundColor Cyan

    $auPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results"
    $lastSuccess = Get-RegValue "$auPath\Install" "LastSuccessTime"
    $lastDetect  = Get-RegValue "$auPath\Detect"  "LastSuccessTime"
    Write-Host "  Last Detect   : $lastDetect"
    Write-Host "  Last Install  : $lastSuccess"

    $pendingReboot = $false
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $pendingReboot = $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $pendingReboot = $true }
    Write-Host "  Pending Reboot: $(if ($pendingReboot) { 'YA - restart diperlukan' } else { 'Tidak' })" -ForegroundColor $(if ($pendingReboot) { "Yellow" } else { "Green" })
    Show-WuSource

    try {
        Write-Info "Memeriksa update tersedia (bisa 10-60 detik)..."
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        $count    = $result.Updates.Count
        Write-Host "  Update tersedia: $count" -ForegroundColor $(if ($count -gt 0) { "Yellow" } else { "Green" })
        if ($count -gt 0 -and $count -le 15) {
            for ($i = 0; $i -lt $count; $i++) {
                $u = $result.Updates.Item($i)
                Write-Host ("    - {0}" -f $u.Title) -ForegroundColor Gray
            }
        } elseif ($count -gt 15) {
            Write-Host "    (terlalu banyak untuk ditampilkan semua; jalankan Scan untuk detail)" -ForegroundColor DarkGray
        }
    } catch {
        Write-WuError -ErrorRecord $_ -Context "Query status update"
    }

    Write-Host ""
    Write-Host "---------- Microsoft Office ----------" -ForegroundColor Cyan
    $officeClick = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    $officeClickx86 = "${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    $c2r = $null
    if (Test-Path $officeClick) { $c2r = $officeClick }
    elseif (Test-Path $officeClickx86) { $c2r = $officeClickx86 }

    if ($c2r) {
        Write-Ok "Office Click-to-Run ditemukan"
        $cfg = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
        $ver = Get-RegValue $cfg "VersionToReport"
        $prod = Get-RegValue $cfg "ProductReleaseIds"
        $upd  = Get-RegValue $cfg "UpdatesEnabled"
        Write-Host "  Versi         : $ver"
        Write-Host "  Produk        : $prod"
        Write-Host "  UpdatesEnabled: $upd"
    } else {
        $found = $false
        foreach ($p in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )) {
            Get-ItemProperty $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Microsoft (365|Office)' } |
                Select-Object -First 3 |
                ForEach-Object {
                    $found = $true
                    Write-Host ("  {0}  v{1}" -f $_.DisplayName, $_.DisplayVersion)
                }
        }
        if (-not $found) { Write-Host "  Office tidak terdeteksi" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "---------- Browser ----------" -ForegroundColor Cyan
    $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edgePath)) { $edgePath = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe" }
    if (Test-Path $edgePath) {
        $edgeVer = (Get-Item $edgePath).VersionInfo.ProductVersion
        Write-Host "  Edge          : $edgeVer"
    } else {
        Write-Host "  Edge          : (tidak ada)" -ForegroundColor DarkGray
    }

    $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) { $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
    if (Test-Path $chromePath) {
        $chromeVer = (Get-Item $chromePath).VersionInfo.ProductVersion
        Write-Host "  Chrome        : $chromeVer"
    } else {
        Write-Host "  Chrome        : (tidak ada)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "---------- Runtime / Framework ----------" -ForegroundColor Cyan
    $ndp = Get-RegValue "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
    $netLabel = "N/A"
    if ($ndp -ne "N/A") {
        $r = [int]$ndp
        if ($r -ge 533320) { $netLabel = "4.8.1+" }
        elseif ($r -ge 528040) { $netLabel = "4.8" }
        elseif ($r -ge 461808) { $netLabel = "4.7.2" }
        elseif ($r -ge 461308) { $netLabel = "4.7.1" }
        else { $netLabel = "4.x ($ndp)" }
    }
    Write-Host "  .NET Framework: $netLabel"

    if (Test-Winget) {
        Write-Ok "winget tersedia"
    } else {
        Write-Host "  winget        : tidak tersedia" -ForegroundColor DarkGray
    }

    Write-Host ""
}

function Action-Scan {
    Write-Host "========== SCAN WINDOWS UPDATE ==========" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Mencari update (IsInstalled=0, Software, tidak hidden)..."
    Write-Host "Proses ini bisa memakan waktu 30 detik - beberapa menit." -ForegroundColor DarkGray
    Write-Host ""
    Show-WuSource
    Write-Host ""

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        try { $null = $searcher.ServerSelection } catch {}
        Write-Host "[INFO] Menghubungi server update..." -ForegroundColor Cyan
        $result   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        $count    = $result.Updates.Count

        if ($count -eq 0) {
            Write-Ok "Tidak ada update yang menunggu."
            Write-Host "Scan selesai." -ForegroundColor DarkGray
            return
        }

        Write-Host ("Ditemukan {0} update:" -f $count) -ForegroundColor Yellow
        Write-Host ""
        Write-Host ("{0,-6} {1,-12} {2}" -f "No", "Ukuran", "Judul") -ForegroundColor White
        Write-Host ("{0,-6} {1,-12} {2}" -f "--", "------", "-----") -ForegroundColor DarkGray

        for ($i = 0; $i -lt $count; $i++) {
            $u = $result.Updates.Item($i)
            $sz = if ($u.MaxDownloadSize -gt 0) {
                if ($u.MaxDownloadSize -ge 1MB) { "{0:N1} MB" -f ($u.MaxDownloadSize / 1MB) }
                else { "{0:N0} KB" -f ($u.MaxDownloadSize / 1KB) }
            } else { "?" }
            Write-Host ("{0,-6} {1,-12} {2}" -f ($i + 1), $sz, $u.Title)
        }
        Write-Host ""
        Write-Info "Gunakan menu Install untuk mengunduh dan menginstal."
        Write-Host "Scan selesai." -ForegroundColor DarkGray
    } catch {
        Write-WuError -ErrorRecord $_ -Context "Scan"
        Write-Host "Scan selesai (dengan error)." -ForegroundColor DarkGray
    }
}

function Action-Install {
    Write-Host "========== INSTALL WINDOWS UPDATE ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Butuh hak Administrator untuk menginstal update."
        return
    }

    Write-Info "Mencari update..."
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        $count    = $result.Updates.Count

        if ($count -eq 0) {
            Write-Ok "Tidak ada update yang perlu diinstal."
            return
        }

        Write-Host ("Akan mengunduh & menginstal {0} update." -f $count) -ForegroundColor Yellow
        Write-Host ""

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $count; $i++) {
            $u = $result.Updates.Item($i)
            if ($u.EulaAccepted -eq $false) { $u.AcceptEula() | Out-Null }
            [void]$toInstall.Add($u)
            Write-Host ("  + {0}" -f $u.Title) -ForegroundColor Gray
        }

        Write-Host ""
        Write-Info "Mengunduh..."
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $downResult = $downloader.Download()
        Write-Host ("  Download result code: {0}" -f $downResult.ResultCode)

        Write-Info "Menginstal..."
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult = $installer.Install()

        Write-Host ""
        Write-Host ("  Install result code : {0}" -f $installResult.ResultCode)
        Write-Host ("  Reboot required     : {0}" -f $installResult.RebootRequired) -ForegroundColor $(if ($installResult.RebootRequired) { "Yellow" } else { "Green" })

        if ($installResult.ResultCode -eq 2) {
            Write-Ok "Instalasi selesai (Succeeded)."
        } elseif ($installResult.ResultCode -eq 3) {
            Write-Warn-Host "Selesai dengan error pada sebagian update (SucceededWithErrors)."
        } else {
            Write-Warn-Host "Result code: $($installResult.ResultCode) (2=OK, 3=partial, 4=failed, 5=aborted)"
        }

        if ($installResult.RebootRequired) {
            Write-Warn-Host "Restart komputer diperlukan agar update aktif penuh."
        }
    } catch {
        Write-WuError -ErrorRecord $_ -Context "Install"
    }
}

function Action-ResetWU {
    Write-Host "========== RESET WINDOWS UPDATE ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Err "Butuh hak Administrator."
        return
    }

    Write-Host "Langkah:" -ForegroundColor Yellow
    Write-Host "  1. Stop service: wuauserv, bits, cryptsvc, msiserver"
    Write-Host "  2. Rename SoftwareDistribution & Catroot2"
    Write-Host "  3. Start service kembali"
    Write-Host ""

    $services = @("wuauserv", "bits", "cryptsvc", "msiserver")

    Write-Info "Menghentikan service..."
    foreach ($s in $services) {
        try {
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
            Write-Host ("  Stop {0}" -f $s) -ForegroundColor Gray
        } catch {
            Write-Warn-Host "  Gagal stop $s"
        }
    }
    Start-Sleep -Seconds 2

    $sd = "$env:SystemRoot\SoftwareDistribution"
    $cr = "$env:SystemRoot\System32\Catroot2"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    if (Test-Path $sd) {
        $dest = "${sd}.old_$ts"
        try {
            Rename-Item -LiteralPath $sd -NewName (Split-Path $dest -Leaf) -ErrorAction Stop
            Write-Ok "Rename SoftwareDistribution -> $(Split-Path $dest -Leaf)"
        } catch {
            Write-Warn-Host "Gagal rename SoftwareDistribution: $_"
        }
    }

    if (Test-Path $cr) {
        try {
            Rename-Item -LiteralPath $cr -NewName "Catroot2.old_$ts" -ErrorAction Stop
            Write-Ok "Rename Catroot2 -> Catroot2.old_$ts"
        } catch {
            Write-Warn-Host "Gagal rename Catroot2: $_"
        }
    }

    Write-Info "Menjalankan service kembali..."
    foreach ($s in $services) {
        try {
            Start-Service -Name $s -ErrorAction SilentlyContinue
            Write-Host ("  Start {0}" -f $s) -ForegroundColor Gray
        } catch {}
    }

    Write-Host ""
    Write-Ok "Reset selesai. Disarankan Scan ulang Windows Update."
    Write-Host "Folder .old_* bisa dihapus manual setelah memastikan update normal." -ForegroundColor DarkGray
}

function Action-WingetList {
    Write-Host "========== WINGET - Aplikasi bisa di-upgrade ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Winget)) {
        Write-Err "winget tidak ditemukan. Install App Installer dari Microsoft Store."
        return
    }

    Write-Info "Menjalankan: winget upgrade"
    Write-Host ""
    & winget upgrade --accept-source-agreements 2>&1 | ForEach-Object { Write-Host $_ }
}

function Action-WingetUpgrade {
    Write-Host "========== WINGET - Upgrade ==========" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Winget)) {
        Write-Err "winget tidak ditemukan."
        return
    }

    if ($WingetId -and $WingetId.Trim() -ne "") {
        Write-Info "Upgrade paket: $WingetId"
        & winget upgrade --id $WingetId.Trim() -e --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Info "Upgrade semua aplikasi yang tersedia (winget upgrade --all)"
        Write-Host "Ini bisa memakan waktu lama." -ForegroundColor Yellow
        Write-Host ""
        & winget upgrade --all --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host $_ }
    }
}

function Action-Office {
    Write-Host "========== UPDATE MICROSOFT OFFICE ==========" -ForegroundColor Cyan
    Write-Host ""

    $officeClick = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    $officeClickx86 = "${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    $c2r = $null
    if (Test-Path $officeClick) { $c2r = $officeClick }
    elseif (Test-Path $officeClickx86) { $c2r = $officeClickx86 }

    if (-not $c2r) {
        Write-Err "Office Click-to-Run tidak ditemukan."
        Write-Host "Tool ini hanya mendukung Office 365 / 2019+ Click-to-Run." -ForegroundColor DarkGray
        return
    }

    Write-Ok "OfficeC2RClient: $c2r"
    Write-Info "Menjalankan update (updateuser)..."
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
    Write-Host "Versi terlapor saat ini: $ver"
}

function Action-Browsers {
    Write-Host "========== UPDATE BROWSER (Edge / Chrome) ==========" -ForegroundColor Cyan
    Write-Host ""

    if (Test-Winget) {
        Write-Info "Update via winget (jika terdaftar)..."
        foreach ($id in @("Microsoft.Edge", "Google.Chrome")) {
            Write-Host ""
            Write-Host "--- $id ---" -ForegroundColor Cyan
            & winget upgrade --id $id -e --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host $_ }
        }
    } else {
        Write-Warn-Host "winget tidak ada. Mencoba pemicu update native..."

        $edgeUpdate = "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"
        if (Test-Path $edgeUpdate) {
            Write-Info "Menjalankan MicrosoftEdgeUpdate..."
            Start-Process -FilePath $edgeUpdate -ArgumentList "/silent", "/install", "appguid={56EB18F8-B078-11CF-9D21-00AA005FFE4E}&appname=Microsoft%20Edge&needsadmin=True" -Wait -ErrorAction SilentlyContinue
            Write-Ok "Edge update dipicu."
        } else {
            Write-Host "Edge Update tidak ditemukan." -ForegroundColor DarkGray
        }

        $chromeUpdate = "${env:ProgramFiles(x86)}\Google\Update\GoogleUpdate.exe"
        if (-not (Test-Path $chromeUpdate)) { $chromeUpdate = "${env:ProgramFiles}\Google\Update\GoogleUpdate.exe" }
        if (Test-Path $chromeUpdate) {
            Write-Info "Menjalankan GoogleUpdate..."
            Start-Process -FilePath $chromeUpdate -ArgumentList "/ua", "/installsource", "scheduler" -Wait -ErrorAction SilentlyContinue
            Write-Ok "Chrome update dipicu."
        } else {
            Write-Host "Google Update tidak ditemukan." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Info "Versi setelah percobaan update:"
    $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edgePath)) { $edgePath = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe" }
    if (Test-Path $edgePath) {
        Write-Host ("  Edge   : {0}" -f (Get-Item $edgePath).VersionInfo.ProductVersion)
    }
    $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) { $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
    if (Test-Path $chromePath) {
        Write-Host ("  Chrome : {0}" -f (Get-Item $chromePath).VersionInfo.ProductVersion)
    }
}

switch ($Action) {
    "status"         { Action-Status }
    "scan"           { Action-Scan }
    "install"        { Action-Install }
    "reset-wu"       { Action-ResetWU }
    "winget-list"    { Action-WingetList }
    "winget-upgrade" { Action-WingetUpgrade }
    "office"         { Action-Office }
    "browsers"       { Action-Browsers }
}
