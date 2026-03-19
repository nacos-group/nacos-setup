# Nacos Setup Installer for Windows (PowerShell)
# Installs nacos-setup (default) or nacos-cli (with -cli flag)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Installer (Windows)"
Write-Host "========================================"
Write-Host ""

# =============================
# Helpers
# =============================
function Write-Info($msg)     { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg)  { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg)     { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Ensure-Directory($path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Add-ToUserPath($dir) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current -and $current.Split(';') -contains $dir) {
        Write-Info "PATH already contains: $dir"
        return
    }
    $newPath = if ($current) { "$current;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Success "Added to PATH: $dir"
}

function Refresh-SessionPath() {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$machinePath;$userPath"
    Write-Info "PATH refreshed in current session"
}

function Download-File($url, $output) {
    Write-Info "Downloading from $url"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output
    } else {
        Invoke-WebRequest -Uri $url -OutFile $output
    }
}

function Remove-DirectorySafe($path) {
    if (-not (Test-Path $path)) { return }
    Write-Warn "Attempting to stop processes using: $path"
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
    Write-ErrorMsg "Failed to remove $path. Please close any running nacos-setup processes and try again."
    throw "Failed to remove directory: $path"
}

# =============================
# Version Management
# =============================
# 默认版本号（远端获取失败时使用）
$DefaultNacosCliVersion    = "0.0.2"
$DefaultNacosSetupVersion  = "0.0.1"
$DefaultNacosServerVersion = "3.2.0"

$Global:NacosCliVersion    = $DefaultNacosCliVersion
$Global:NacosSetupVersion  = $DefaultNacosSetupVersion
$Global:NacosServerVersion = $DefaultNacosServerVersion

function Fetch-Versions {
    param([int]$TimeoutSeconds = 3)
    Write-Info "Fetching version info from remote..."
    try {
        $response = Invoke-WebRequest -Uri "https://download.nacos.io/versions" -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.Content) {
            $content = if ($response.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($response.Content)
            } else {
                $response.Content
            }
            foreach ($line in ($content -split "`r?`n")) {
                $line = $line.Trim()
                if     ($line -match "^NACOS_CLI_VERSION=(.+)$")   { $Global:NacosCliVersion    = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SETUP_VERSION=(.+)$") { $Global:NacosSetupVersion  = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SERVER_VERSION=(.+)$"){ $Global:NacosServerVersion = $matches[1].Trim() }
            }
            Write-Success "Version info fetched: CLI=$Global:NacosCliVersion, Setup=$Global:NacosSetupVersion, Server=$Global:NacosServerVersion"
            return
        }
    } catch {
        Write-Warn "Failed to fetch versions: $($_.Exception.Message)"
    }
    Write-Warn "Using default versions: CLI=$Global:NacosCliVersion, Setup=$Global:NacosSetupVersion, Server=$Global:NacosServerVersion"
}

# =============================
# Check Admin and Get Real User
# =============================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$realUserProfile = $env:USERPROFILE

if ($isAdmin -and ($env:USERPROFILE -match 'systemprofile|system32')) {
    try {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem -and $computerSystem.UserName) {
            $userName = $computerSystem.UserName
            if ($userName -match '\\(.+)$') { $userName = $matches[1] }
            $userDir = "C:\Users\$userName"
            if (Test-Path $userDir) { $realUserProfile = $userDir }
        }
    } catch {}

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
                $userDir = "C:\Users\$env:USERNAME"
                if (Test-Path $userDir) { $realUserProfile = $userDir }
            }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            $profiles = @(Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') -and (Test-Path (Join-Path $_.FullName 'AppData')) } |
                Sort-Object LastWriteTime -Descending)
            if ($profiles.Count -gt 0) { $realUserProfile = $profiles[0].FullName }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        Write-Warn "Could not detect real user, using default install location"
        $realUserProfile = "C:\Users\Administrator"
    }
}

$realLocalAppData = Join-Path $realUserProfile "AppData\Local"

# =============================
# Parse Arguments
# =============================
$InstallCli   = $false
$SetupVersion = $null
$CliVersion   = $null

# 第一遍：先确定是否有 -cli（无论顺序）
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "-cli" -or $args[$i] -eq "--cli") {
        $InstallCli = $true
        break
    }
}

# 第二遍：再解析 -v / --version，根据 $InstallCli 决定归属
for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = $args[$i]
    if (($arg -eq "-v" -or $arg -eq "--version") -and ($i + 1 -lt $args.Count) -and ($args[$i + 1] -notmatch "^-")) {
        if ($InstallCli) { $CliVersion = $args[$i + 1] } else { $SetupVersion = $args[$i + 1] }
        $i++
    }
}

# =============================
# Initialize Versions（只执行一次）
# =============================
Fetch-Versions -TimeoutSeconds 3

# 用户手动指定版本时覆盖远端获取的版本
if ($SetupVersion) {
    $Global:NacosSetupVersion = $SetupVersion
    Write-Info "Using specified nacos-setup version: $SetupVersion"
}
if ($CliVersion) {
    $Global:NacosCliVersion = $CliVersion
    Write-Info "Using specified nacos-cli version: $CliVersion"
}

# =============================
# Configuration
# =============================
$DownloadBaseUrl = "https://download.nacos.io"
$CacheDir        = Join-Path $realUserProfile ".nacos\cache"
$InstallDir      = Join-Path $realLocalAppData "Programs\nacos-cli"
$BinName         = "nacos-cli.exe"
$SetupRootDir    = Join-Path $realLocalAppData "Programs\nacos-setup"
$SetupScriptName = "nacos-setup.ps1"
$SetupCmdName    = "nacos-setup.cmd"

# =============================
# Main
# =============================

if ($isAdmin) {
    Write-Warn "Running as Administrator detected"
    Write-Info "Installing to user directory: $realUserProfile"
}

Ensure-Directory $CacheDir

if ($InstallCli) {
    # =============================
    # Install nacos-cli
    # =============================
    Write-Info "Installing nacos-cli (use 'nacos-cli --help' for usage)"

    if (Test-Path $InstallDir) {
        Write-Warn "Removing existing nacos-cli installation at $InstallDir"
        Remove-Item -Recurse -Force $InstallDir
    }
    Ensure-Directory $InstallDir

    Write-Info "Preparing to install nacos-cli version $Global:NacosCliVersion..."
    $os          = "windows"
    $arch        = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $zipName     = "nacos-cli-$Global:NacosCliVersion-$os-$arch.zip"
    $zipPath     = Join-Path $CacheDir $zipName
    $downloadUrl = "$DownloadBaseUrl/$zipName"

    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
        Download-File $downloadUrl $zipPath
    } else {
        Write-Info "Found cached package: $zipPath"
    }

    Write-Info "Extracting nacos-cli..."
    $extractDir = Join-Path $env:TEMP ("nacos-cli-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $extractDir
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $expected   = "nacos-cli-$Global:NacosCliVersion-$os-$arch.exe"
    $binaryPath = Get-ChildItem -Path $extractDir -Recurse -Filter $expected | Select-Object -First 1
    if (-not $binaryPath) {
        Write-ErrorMsg "Binary not found in package. Expected: $expected"
        Get-ChildItem -Path $extractDir -Recurse | ForEach-Object { Write-Info "  $($_.FullName)" }
        throw "Binary file not found in package"
    }

    Copy-Item -Path $binaryPath.FullName -Destination (Join-Path $InstallDir $BinName) -Force
    Add-ToUserPath $InstallDir
    Remove-Item -Recurse -Force $extractDir
    Refresh-SessionPath

    Write-Host ""
    Write-Success "nacos-cli installed successfully!"
    Write-Info "  Location: $InstallDir\$BinName"
    Write-Host ""
} else {
    # =============================
    # Install nacos-setup
    # =============================
    Write-Info "Installing nacos-setup (use 'nacos-setup --help' for usage)"

    $SetupInstallDir = Join-Path $SetupRootDir $Global:NacosSetupVersion
    Write-Info "Preparing to install nacos-setup version $Global:NacosSetupVersion..."

    if (Test-Path $SetupInstallDir) {
        $existingScript = Join-Path $SetupInstallDir $SetupScriptName
        if (Test-Path $existingScript) {
            Write-Info "nacos-setup $Global:NacosSetupVersion is already installed at: $SetupInstallDir"
            $rootCmdPath = Join-Path $SetupRootDir $SetupCmdName
            "@echo off`npowershell -NoProfile -ExecutionPolicy Bypass -File `"${SetupInstallDir}\$SetupScriptName`" %*" | Set-Content -Path $rootCmdPath -Encoding ASCII
            Add-ToUserPath $SetupRootDir
            Refresh-SessionPath
            Write-Host ""
            Write-Success "nacos-setup already installed."
            Write-Info "  Location: $SetupRootDir\$SetupCmdName"
            Write-Host ""
            return
        }
        Write-Warn "nacos-setup directory exists but script is missing. Reinstalling..."
        Remove-DirectorySafe $SetupInstallDir
    }

    Ensure-Directory $SetupInstallDir

    $setupZipName = "nacos-setup-windows-$Global:NacosSetupVersion.zip"
    $setupZipPath = Join-Path $CacheDir $setupZipName
    $setupZipUrl  = "$DownloadBaseUrl/$setupZipName"

    if (-not (Test-Path $setupZipPath) -or (Get-Item $setupZipPath).Length -eq 0) {
        Download-File $setupZipUrl $setupZipPath
    } else {
        Write-Info "Found cached package: $setupZipPath"
    }

    Write-Info "Extracting nacos-setup..."
    $extractDir = Join-Path $env:TEMP ("nacos-setup-windows-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $extractDir
    Expand-Archive -Path $setupZipPath -DestinationPath $extractDir -Force

    $setupDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $setupDir) { throw "Failed to find extracted directory in $setupZipName" }

    $setupScriptInZip = Join-Path $setupDir.FullName $SetupScriptName
    if (-not (Test-Path $setupScriptInZip)) { throw "$SetupScriptName not found in package" }

    Copy-Item -Path (Join-Path $setupDir.FullName "*") -Destination $SetupInstallDir -Recurse -Force

    $setupScriptPath = Join-Path $SetupInstallDir $SetupScriptName
    if (-not (Test-Path $setupScriptPath)) { throw "nacos-setup.ps1 not found after extraction" }

    # 修复编码问题
    $content = Get-Content -Path $setupScriptPath -Raw
    $content = $content -replace "[\u2018\u2019]", "'"
    $content = $content -replace "[\u201C\u201D]", '"'
    Set-Content -Path $setupScriptPath -Value $content -Encoding UTF8

    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue

    Ensure-Directory $SetupRootDir
    $setupCmdPath = Join-Path $SetupRootDir $SetupCmdName
    "@echo off`npowershell -NoProfile -ExecutionPolicy Bypass -File `"${SetupInstallDir}\$SetupScriptName`" %*" | Set-Content -Path $setupCmdPath -Encoding ASCII

    Add-ToUserPath $SetupRootDir
    Refresh-SessionPath

    Write-Host ""
    Write-Success "nacos-setup installed successfully!"
    Write-Info "  Location: $SetupRootDir\$SetupCmdName"
    Write-Host ""
}