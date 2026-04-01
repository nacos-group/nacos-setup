# Nacos Setup Installer for Windows (PowerShell)
# Installs nacos-setup + nacos-cli (default), or nacos-cli only (--cli),
# then optionally launches Nacos immediately via nacos-setup.
#
# Usage:
#   iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex
#
# Options:
#   (none)              Install nacos-setup + nacos-cli, then offer to start Nacos
#   --cli               Install nacos-cli only
#   -v, --version VER   Specify nacos-setup (or nacos-cli with --cli) version
#   version             Show installed nacos-setup version
#   uninstall, -u       Uninstall nacos-setup + nacos-cli
#   --help, -h          Show this help message

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# HTTPS to download.nacos.io requires TLS 1.2+ on older Windows / PS 5.1 (defaults to TLS 1.0)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

# ZipFile / Expand-Archive need this assembly in some hosts
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }

Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Setup Installer (Windows)"
Write-Host "========================================"
Write-Host ""
Write-Host "  macOS / Linux:"
Write-Host "    curl -fsSL https://nacos.io/nacos-installer.sh | bash"
Write-Host ""
Write-Host "  Windows (PowerShell):"
Write-Host "    iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex"
Write-Host ""
Write-Host "========================================"
Write-Host ""

# ============================================================
# Helpers
# ============================================================
function Write-Info($msg)     { Write-Host "[INFO] $msg"    -ForegroundColor Cyan }
function Write-Success($msg)  { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg)     { Write-Host "[WARN] $msg"    -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host "[ERROR] $msg"   -ForegroundColor Red }

function Ensure-Directory($path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}

function Get-NormalizedPath($path) {
    if (-not $path) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($path.TrimEnd('\', '/'))
    } catch {
        return $path
    }
}

function Test-PathInPathList($dirNorm, $pathList) {
    if (-not $pathList) { return $false }
    foreach ($seg in ($pathList.Split(';') | Where-Object { $_ })) {
        try {
            if ([string]::Equals((Get-NormalizedPath $seg), $dirNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch { }
    }
    return $false
}

function Add-ToUserPath($dir) {
    $dirNorm = Get-NormalizedPath $dir
    if (-not $dirNorm) { return }
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-PathInPathList $dirNorm $current) {
        Write-Info "PATH already contains: $dir"
        return
    }
    $newPath = if ($current) { "$current;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Success "Added to PATH: $dir"
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    # Avoid leading/trailing ';' when Machine or User is empty (breaks command lookup)
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
    Write-Info "PATH refreshed in current session"
}

function Download-File-WebClient($url, $output) {
    Write-Info "Downloading (WebClient): $url"
    $wc = New-Object System.Net.WebClient
    try {
        $wc.DownloadFile($url, $output)
    } finally {
        if ($wc) { $wc.Dispose() }
    }
}

function Download-File($url, $output) {
    Write-Info "Downloading: $url"
    try {
        # -UseBasicParsing avoids legacy IE parsing; use for all PS versions for binary payloads
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -ErrorAction Stop
    } catch {
        Write-Warn "Invoke-WebRequest failed: $($_.Exception.Message)"
        try {
            Download-File-WebClient $url $output
        } catch {
            Write-ErrorMsg "Download failed: $($_.Exception.Message)"
            throw
        }
    }
}

# ZIP local file header starts with PK (0x50 0x4B); catches HTML error pages saved as .zip
function Test-ZipLocalHeader($path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $buf = New-Object byte[] 4
            $n = $fs.Read($buf, 0, 4)
            if ($n -lt 4) { return $false }
            return ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B)
        } finally { $fs.Close() }
    } catch { return $false }
}

# Test if a zip file is valid (non-empty, PK header, and can be opened by .NET)
function Test-ZipValid($path) {
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item $path).Length
    if ($len -lt 22) { return $false } # minimum zip size
    if (-not (Test-ZipLocalHeader $path)) { return $false }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $zip.Dispose()
        return $true
    } catch { return $false }
}

# Download a .zip from CDN; retry with WebClient if IWR yields a non-zip (e.g. TLS / HTML error body)
function Download-ZipWithValidation($url, $zipPath) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Download-File $url $zipPath
    if (-not (Test-ZipValid $zipPath)) {
        Write-Warn "First download did not validate as a zip (TLS or proxy issue is common); retrying with WebClient..."
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        try {
            Download-File-WebClient $url $zipPath
        } catch {
            Write-ErrorMsg "Retry download failed: $($_.Exception.Message)"
            return $false
        }
        if (-not (Test-ZipValid $zipPath)) {
            Write-ErrorMsg "Downloaded file is not a valid zip: $zipPath (check URL or delete cache folder and retry)"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    return $true
}

function Remove-DirectorySafe($path) {
    if (-not (Test-Path $path)) { return }
    Write-Warn "Stopping processes using: $path"
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [Regex]::Escape($path) }
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
    } catch {}
    $tries = 0
    while ($tries -lt 5) {
        try { Remove-Item -Recurse -Force $path -ErrorAction Stop; return } catch { Start-Sleep -Seconds 1 }
        $tries++
    }
    Write-ErrorMsg "Failed to remove $path. Please close any running nacos-setup processes and retry."
    throw "Failed to remove directory: $path"
}

# ============================================================
# Version Management
# ============================================================
# Fallback versions — keep aligned with repository `versions` file
$DefaultNacosCliVersion    = "1.0.0"
$DefaultNacosSetupVersion  = "1.0.0"
$DefaultNacosServerVersion = "3.2.0-BETA"

$Global:NacosCliVersion    = $DefaultNacosCliVersion
$Global:NacosSetupVersion  = $DefaultNacosSetupVersion
$Global:NacosServerVersion = $DefaultNacosServerVersion

function Fetch-Versions {
    param([int]$TimeoutSeconds = 3)
    Write-Info "Fetching version info from remote..."
    try {
        $response = Invoke-WebRequest -Uri "https://download.nacos.io/versions" `
            -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.Content) {
            $content = if ($response.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($response.Content)
            } else { $response.Content }
            foreach ($line in ($content -split "`r?`n")) {
                $line = $line.Trim()
                if     ($line -match "^NACOS_CLI_VERSION=(.+)$")    { $Global:NacosCliVersion    = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SETUP_VERSION=(.+)$")  { $Global:NacosSetupVersion  = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SERVER_VERSION=(.+)$") { $Global:NacosServerVersion = $matches[1].Trim() }
            }
            Write-Success "Versions: CLI=$($Global:NacosCliVersion)  Setup=$($Global:NacosSetupVersion)  Server=$($Global:NacosServerVersion)"
            return
        }
    } catch {
        Write-Warn "Failed to fetch versions: $($_.Exception.Message)"
    }
    Write-Warn "Using fallback versions: CLI=$($Global:NacosCliVersion)  Setup=$($Global:NacosSetupVersion)  Server=$($Global:NacosServerVersion)"
}

# ============================================================
# Detect real user profile (handles running as SYSTEM/admin)
# ============================================================
$isAdmin         = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$realUserProfile = $env:USERPROFILE

if ($isAdmin -and ($realUserProfile -match 'systemprofile|system32')) {
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $usersDir    = Join-Path $systemDrive "Users"

    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.UserName) {
            $uname = $cs.UserName; if ($uname -match '\\(.+)$') { $uname = $matches[1] }
            $d = Join-Path $usersDir $uname
            if (Test-Path $d) { $realUserProfile = $d }
        }
    } catch {}

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
                $d = Join-Path $usersDir $env:USERNAME
                if (Test-Path $d) { $realUserProfile = $d }
            }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            $profiles = @(Get-ChildItem $usersDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') -and
                               (Test-Path (Join-Path $_.FullName 'AppData')) } |
                Sort-Object LastWriteTime -Descending)
            if ($profiles.Count -gt 0) { $realUserProfile = $profiles[0].FullName }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        Write-Warn "Could not detect real user profile; falling back to Administrator"
        $realUserProfile = Join-Path $usersDir "Administrator"
    }
}

$realLocalAppData = Join-Path $realUserProfile "AppData\Local"

# ============================================================
# Paths
# ============================================================
$DownloadBaseUrl  = "https://download.nacos.io"
$CacheDir         = Join-Path $realUserProfile ".nacos\cache"
$CliInstallDir    = Join-Path $realLocalAppData "Programs\nacos-cli"
$CliBinName       = "nacos-cli.exe"
$SetupRootDir     = Join-Path $realLocalAppData "Programs\nacos-setup"
$SetupScriptName  = "nacos-setup.ps1"
$SetupCmdName     = "nacos-setup.cmd"

# ============================================================
# Argument parsing
# ============================================================
$InstallCli    = $false
$ShowHelp      = $false
$ShowVersion   = $false
$DoUninstall   = $false
$SetupVersion  = $null
$CliVersion    = $null

# First pass: detect mode flags (order-independent)
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        { $_ -in @("-cli","--cli") }              { $InstallCli  = $true }
        { $_ -in @("-h","--help") }               { $ShowHelp    = $true }
        { $_ -in @("version","--version-check") } { $ShowVersion = $true }
        { $_ -in @("uninstall","--uninstall","-u") } { $DoUninstall = $true }
    }
}

# Second pass: parse -v / --version value
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = $args[$i]
    if (($a -eq "-v" -or $a -eq "--version") -and
        ($i + 1 -lt $args.Count) -and ($args[$i + 1] -notmatch "^-")) {
        if ($InstallCli) { $CliVersion   = $args[$i + 1] }
        else             { $SetupVersion = $args[$i + 1] }
        $i++
    }
}

# ============================================================
# Help
# ============================================================
function Print-Usage {
    Write-Host ""
    Write-Host "Install nacos-setup and nacos-cli tools for managing Nacos instances." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  macOS / Linux:"
    Write-Host "    curl -fsSL https://nacos.io/nacos-installer.sh | bash"
    Write-Host ""
    Write-Host "  Windows (PowerShell):"
    Write-Host "    iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  (none)              Install nacos-setup + nacos-cli (default)"
    Write-Host "  -v, --version VER   Specify version (nacos-setup, or nacos-cli with --cli)"
    Write-Host "  --cli               Install nacos-cli only"
    Write-Host "  version             Show installed nacos-setup version"
    Write-Host "  uninstall, -u       Uninstall nacos-setup + nacos-cli"
    Write-Host "  --help, -h          Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  iwr ... | iex                        Install nacos-setup + nacos-cli"
    Write-Host "  iwr ... | iex -- -v 1.0.0            Install nacos-setup v1.0.0"
    Write-Host "  iwr ... | iex -- --cli               Install nacos-cli only"
    Write-Host "  iwr ... | iex -- --cli -v 1.0.0      Install nacos-cli v1.0.0 only"
    Write-Host ""
    Write-Host "After installation, use 'nacos-setup' to manage Nacos:"
    Write-Host "  nacos-setup --help"
    Write-Host "  nacos-setup -v 3.2.0-BETA"
    Write-Host "  nacos-setup -c prod -n 3"
    Write-Host ""
}

# ============================================================
# Show installed version
# ============================================================
function Get-InstalledSetupVersion {
    if (-not (Test-Path $SetupRootDir)) { return $null }
    $versionDirs = Get-ChildItem -Path $SetupRootDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName $SetupScriptName) } |
        Sort-Object Name -Descending
    if ($versionDirs.Count -gt 0) { return $versionDirs[0].Name }
    return $null
}

function Show-InstalledVersion {
    $ver = Get-InstalledSetupVersion
    if ($ver) {
        Write-Info "Installed nacos-setup version: $ver"
        Write-Info "Installation location: $(Join-Path $SetupRootDir $ver)"
    } else {
        Write-Warn "nacos-setup is not installed or version information not found"
    }
    $cliPath = Join-Path $CliInstallDir $CliBinName
    if (Test-Path $cliPath) {
        Write-Info "nacos-cli: installed at $cliPath"
    } else {
        Write-Info "nacos-cli: not installed"
    }
}

# ============================================================
# Uninstall
# ============================================================
function Uninstall-NacosSetup {
    Write-Info "Uninstalling nacos-setup..."

    if (Test-Path $SetupRootDir) {
        Remove-Item -Recurse -Force $SetupRootDir -ErrorAction SilentlyContinue
        Write-Success "Removed: $SetupRootDir"
    } else {
        Write-Warn "nacos-setup not found at: $SetupRootDir"
    }

    if (Test-Path $CliInstallDir) {
        Remove-Item -Recurse -Force $CliInstallDir -ErrorAction SilentlyContinue
        Write-Success "Removed: $CliInstallDir"
    } else {
        Write-Warn "nacos-cli not found at: $CliInstallDir"
    }

    # Remove from User PATH (normalize so removal matches Add-ToUserPath)
    $setupNorm = Get-NormalizedPath $SetupRootDir
    $cliNorm   = Get-NormalizedPath $CliInstallDir
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current) {
        $parts = foreach ($seg in ($current.Split(';') | Where-Object { $_ })) {
            $sn = Get-NormalizedPath $seg
            if ($sn -and $setupNorm -and [string]::Equals($sn, $setupNorm, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($sn -and $cliNorm   -and [string]::Equals($sn, $cliNorm,   [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $seg
        }
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
        Write-Success "Removed install directories from PATH"
    }

    Write-Success "Uninstallation completed!"
    Write-Host ""
}

# ============================================================
# Handle early-exit subcommands
# ============================================================
if ($ShowHelp) {
    Print-Usage
    exit 0
}

if ($ShowVersion) {
    Show-InstalledVersion
    exit 0
}

if ($DoUninstall) {
    Uninstall-NacosSetup
    exit 0
}

# ============================================================
# Fetch versions and apply user overrides
# ============================================================
Fetch-Versions -TimeoutSeconds 3

if ($SetupVersion) {
    $Global:NacosSetupVersion = $SetupVersion
    Write-Info "Using specified nacos-setup version: $SetupVersion"
}
if ($CliVersion) {
    $Global:NacosCliVersion = $CliVersion
    Write-Info "Using specified nacos-cli version: $CliVersion"
}

# ============================================================
# Admin notice
# ============================================================
Ensure-Directory $CacheDir

if ($isAdmin) {
    Write-Warn "Running as Administrator - installing to user directory: $realUserProfile"
}

# ============================================================
# nacos-cli installer
# ============================================================
function Install-NacosCli {
    Write-Info "Preparing to install nacos-cli $($Global:NacosCliVersion)..."
    $os   = "windows"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $zipName = "nacos-cli-$($Global:NacosCliVersion)-$os-$arch.zip"
    $zipPath = Join-Path $CacheDir $zipName
    $dlUrl   = "$DownloadBaseUrl/$zipName"

    # Download with cache
    if (Test-ZipValid $zipPath) {
        Write-Info "Found cached package: $zipPath"
    } else {
        if (-not (Download-ZipWithValidation $dlUrl $zipPath)) {
            return $false
        }
    }

    Write-Info "Extracting nacos-cli..."
    $extractDir = Join-Path $env:TEMP ("nacos-cli-extract-" + [Guid]::NewGuid())
    Ensure-Directory $extractDir
    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    } catch {
        Write-ErrorMsg "Extraction failed: $($_.Exception.Message)"
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    $expected = "nacos-cli-$($Global:NacosCliVersion)-$os-$arch.exe"
    $binary   = Get-ChildItem -Path $extractDir -Recurse -Filter $expected | Select-Object -First 1
    if (-not $binary) {
        Write-ErrorMsg "Binary not found in package. Expected: $expected"
        Get-ChildItem -Path $extractDir -Recurse | ForEach-Object { Write-Info "  $($_.FullName)" }
        Remove-Item $extractDir -Recurse -Force
        return $false
    }

    if (Test-Path $CliInstallDir) {
        Write-Warn "Removing existing nacos-cli at $CliInstallDir"
        Remove-Item -Recurse -Force $CliInstallDir
    }
    Ensure-Directory $CliInstallDir
    Copy-Item -Path $binary.FullName -Destination (Join-Path $CliInstallDir $CliBinName) -Force
    Remove-Item $extractDir -Recurse -Force

    Add-ToUserPath $CliInstallDir

    if ($realUserProfile -and $env:USERPROFILE -and
        -not [string]::Equals((Get-NormalizedPath $realUserProfile), (Get-NormalizedPath $env:USERPROFILE), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "Binaries are under $realUserProfile but User PATH applies to this account ($env:USERPROFILE). If nacos-cli is not found, add this folder to PATH for the account that owns the install: $CliInstallDir"
    }

    Write-Host ""
    Write-Success "nacos-cli $($Global:NacosCliVersion) installed!"
    Write-Info "  Location: $CliInstallDir\$CliBinName"
    Write-Host ""
    return $true
}

# ============================================================
# nacos-setup installer
# ============================================================
function Install-NacosSetup {
    $ver            = $Global:NacosSetupVersion
    $setupInstallDir = Join-Path $SetupRootDir $ver
    Write-Info "Preparing to install nacos-setup $ver..."

    # Already installed?
    if (Test-Path (Join-Path $setupInstallDir $SetupScriptName)) {
        Write-Info "nacos-setup $ver is already installed at: $setupInstallDir"
        $cmdPath = Join-Path $SetupRootDir $SetupCmdName
        "@echo off`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$setupInstallDir\$SetupScriptName`" %*" |
            Set-Content -Path $cmdPath -Encoding ASCII
        Add-ToUserPath $SetupRootDir
        Write-Host ""
        Write-Success "nacos-setup $ver is ready."
        Write-Info "  Command: $cmdPath"
        Write-Host ""
        return $setupInstallDir
    }

    # Remove incomplete/stale directory
    if (Test-Path $setupInstallDir) {
        Write-Warn "Incomplete nacos-setup directory found. Reinstalling..."
        Remove-DirectorySafe $setupInstallDir
    }
    Ensure-Directory $setupInstallDir

    $zipName = "nacos-setup-windows-$ver.zip"
    $zipPath = Join-Path $CacheDir $zipName
    $dlUrl   = "$DownloadBaseUrl/$zipName"

    # Download with cache + validation
    if (Test-ZipValid $zipPath) {
        Write-Info "Found cached package: $zipPath"
    } else {
        if (-not (Download-ZipWithValidation $dlUrl $zipPath)) {
            throw "Invalid package: $zipPath"
        }
        Write-Info "Download completed: $zipName"
    }

    Write-Info "Extracting nacos-setup..."
    $extractDir = Join-Path $env:TEMP ("nacos-setup-extract-" + [Guid]::NewGuid())
    Ensure-Directory $extractDir
    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    } catch {
        Write-ErrorMsg "Extraction failed: $($_.Exception.Message)"
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    $srcDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $srcDir) { throw "Could not find extracted directory in $zipName" }
    if (-not (Test-Path (Join-Path $srcDir.FullName $SetupScriptName))) {
        throw "$SetupScriptName not found in package"
    }

    Copy-Item -Path (Join-Path $srcDir.FullName "*") -Destination $setupInstallDir -Recurse -Force
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    # Fix smart-quotes (can appear in some editors/CDNs)
    $scriptPath = Join-Path $setupInstallDir $SetupScriptName
    if (Test-Path $scriptPath) {
        $content = Get-Content -Path $scriptPath -Raw
        $content = $content -replace "[\u2018\u2019]", "'"
        $content = $content -replace "[\u201C\u201D]", '"'
        Set-Content -Path $scriptPath -Value $content -Encoding UTF8
    }

    # Create .cmd wrapper for cmd.exe / bat compatibility
    Ensure-Directory $SetupRootDir
    $cmdPath = Join-Path $SetupRootDir $SetupCmdName
    "@echo off`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$setupInstallDir\$SetupScriptName`" %*" |
        Set-Content -Path $cmdPath -Encoding ASCII

    Add-ToUserPath $SetupRootDir

    Write-Host ""
    Write-Success "nacos-setup $ver installed!"
    Write-Info "  Command: $cmdPath"
    Write-Host ""
    return $setupInstallDir
}

# ============================================================
# Post-install usage info
# ============================================================
function Print-UsageInfo {
    param([string]$InstalledVer, [bool]$CliInstalled)
    $cliStatus = if ($CliInstalled) { "installed" } else { "not installed" }

    Write-Host "========================================"
    Write-Success "Nacos Setup Installation Complete"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "  nacos-setup version : $InstalledVer"
    Write-Host "  nacos-cli           : $cliStatus"
    Write-Host "  Install location    : $(Join-Path $SetupRootDir $InstalledVer)"
    Write-Host ""
    Write-Host "Quick Start:"
    Write-Host ""
    Write-Host "  # Show help"
    Write-Host "  nacos-setup --help"
    Write-Host ""
    Write-Host "  # Install Nacos standalone (default version)"
    Write-Host "  nacos-setup"
    Write-Host ""
    Write-Host "  # Install specific version"
    Write-Host "  nacos-setup -v 3.2.0-BETA"
    Write-Host ""
    Write-Host "  # Install Nacos cluster"
    Write-Host "  nacos-setup -c prod -n 3"
    Write-Host ""
    Write-Host "  # Configure external datasource"
    Write-Host "  nacos-setup db-conf edit"
    Write-Host ""
    Write-Host "Documentation: https://nacos.io"
    Write-Host ""
    Write-Host "========================================"
}

# ============================================================
# Main flow
# ============================================================

if ($InstallCli) {
    # --cli: install nacos-cli only
    Write-Info "Installing nacos-cli only..."
    if (-not (Install-NacosCli)) {
        Write-ErrorMsg "nacos-cli installation failed."
        exit 1
    }
    Refresh-SessionPath
    Write-Info "You can run nacos-cli in this PowerShell window now. If you used a separate window to start the installer, open a new terminal so PATH picks up the user environment."
    exit 0
}

# Default: install nacos-setup + nacos-cli
$setupInstallDir = Install-NacosSetup

# Also install nacos-cli (bundled by default)
Write-Info "Bundling nacos-cli..."
$cliOk = Install-NacosCli
if (-not $cliOk) {
    Write-Warn "nacos-cli installation failed, but nacos-setup is ready"
}

Refresh-SessionPath

# Print usage summary
Print-UsageInfo -InstalledVer $Global:NacosSetupVersion -CliInstalled $cliOk

# ============================================================
# Offer to launch Nacos immediately
# ============================================================
$serverVersion = $Global:NacosServerVersion
Write-Host ""

try {
    $reply = Read-Host "Do you want to install and start Nacos $serverVersion now? (Y/n)"
} catch {
    # Non-interactive (piped) — skip prompt
    $reply = "n"
}

Write-Host ""
if ($reply -match '^[Nn]$') {
    Write-Info "Skipping Nacos installation."
    Write-Info "To install later, run:"
    Write-Info "  nacos-setup -v $serverVersion"
} else {
    Write-Info "Starting Nacos $serverVersion via nacos-setup..."
    $setupPs1 = Join-Path $setupInstallDir $SetupScriptName
    if (Test-Path $setupPs1) {
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $setupPs1 -v $serverVersion
        } catch {
            Write-Warn "nacos-setup exited with: $($_.Exception.Message)"
        }
    } else {
        $setupCmd = Join-Path $SetupRootDir $SetupCmdName
        if (Test-Path $setupCmd) {
            try {
                & cmd /c "`"$setupCmd`"" -v $serverVersion
            } catch {
                Write-Warn "nacos-setup exited with: $($_.Exception.Message)"
            }
        } else {
            Write-ErrorMsg "nacos-setup script not found. Please run manually: nacos-setup -v $serverVersion"
        }
    }
}
