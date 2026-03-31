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

function Add-ToUserPath($dir) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current -and ($current.Split(';') -contains $dir)) {
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
    $env:Path    = "$machinePath;$userPath"
    Write-Info "PATH refreshed in current session"
}

function Download-File($url, $output) {
    Write-Info "Downloading: $url"
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -ErrorAction Stop
        } else {
            Invoke-WebRequest -Uri $url -OutFile $output -ErrorAction Stop
        }
    } catch {
        Write-ErrorMsg "Download failed: $($_.Exception.Message)"
        throw
    }
}

# Test if a zip file is valid (non-empty and can be opened)
function Test-ZipValid($path) {
    if (-not (Test-Path $path)) { return $false }
    if ((Get-Item $path).Length -eq 0) { return $false }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $zip.Dispose()
        return $true
    } catch { return $false }
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

    # Remove from User PATH
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current) {
        $parts   = $current.Split(';') | Where-Object { $_ -ne $SetupRootDir -and $_ -ne $CliInstallDir }
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
    Write-Warn "Running as Administrator — installing to user directory: $realUserProfile"
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
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Download-File $dlUrl $zipPath
        if (-not (Test-ZipValid $zipPath)) {
            Write-ErrorMsg "Downloaded file is not a valid zip: $zipPath"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
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
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Download-File $dlUrl $zipPath
        if (-not (Test-ZipValid $zipPath)) {
            Write-ErrorMsg "Downloaded file is not a valid zip: $zipPath"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
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
    Install-NacosCli
    Refresh-SessionPath
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
    $setupCmd = Join-Path $SetupRootDir $SetupCmdName
    if (Test-Path $setupCmd) {
        try {
            & cmd /c $setupCmd -v $serverVersion
        } catch {
            Write-Warn "nacos-setup exited with: $($_.Exception.Message)"
        }
    } else {
        # Fallback: invoke PS1 directly
        $setupPs1 = Join-Path $setupInstallDir $SetupScriptName
        if (Test-Path $setupPs1) {
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $setupPs1 -v $serverVersion
            } catch {
                Write-Warn "nacos-setup exited with: $($_.Exception.Message)"
            }
        } else {
            Write-ErrorMsg "nacos-setup script not found. Please run manually: nacos-setup -v $serverVersion"
        }
    }
}
