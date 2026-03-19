# Nacos Setup Installer for Windows (PowerShell)
# Installs nacos-setup (default) or nacos-cli (with -cli flag)

# NEVER exit on errors - always continue and report
$ErrorActionPreference = "Continue"
$WarningPreference = "Continue"
$VerbosePreference = "Continue"

# =============================
# Helpers (Define early for use in initialization)
# =============================
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
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
    # Refresh PATH in current session by combining Machine and User paths
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newPath = "$machinePath;$userPath"
    $env:Path = $newPath
    $env:Path = $newPath + ";$SetupRootDir"
    Write-Info "PATH refreshed in current session"
    Write-Info "You can now use: nacos-setup --help"
}

function Download-File($url, $output) {
    Write-Info "Downloading from $url"
    
    # Set Referer header to match bash script behavior (required by Aliyun OSS CDN)
    $headers = @{
        "Referer" = "https://nacos.io/download/nacos-server/?spm=nacos_install"
    }
    
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -Headers $headers
    } else {
        Invoke-WebRequest -Uri $url -OutFile $output -Headers $headers
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
        try {
            Remove-Item -Recurse -Force $path -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Seconds 1
        }
        $tries++
    }

    Write-ErrorMsg "Failed to remove $path. Please close any running nacos-setup processes and try again."
    Write-ErrorMsg "Error: Failed to remove directory: $path"
    return $false
}

# =============================
# Check Admin and Get Real User
# =============================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Get the actual user directory even when running as admin
$realUserProfile = $env:USERPROFILE

# If running as admin and USERPROFILE points to SYSTEM, try to find real user
if ($isAdmin -and ($env:USERPROFILE -match 'systemprofile|system32')) {
    try {
        # Try to get the logged-in user from Win32_ComputerSystem
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem -and $computerSystem.UserName) {
            $userName = $computerSystem.UserName
            # Extract just the username if it's in DOMAIN\USER format
            if ($userName -match '\\(.+)$') {
                $userName = $matches[1]
            }
            # Verify the user directory exists
            $userDir = "C:\Users\$userName"
            if (Test-Path $userDir) {
                $realUserProfile = $userDir
            }
        }
    } catch {
        # If WMI fails, try alternative methods
    }
    
    # If still not found, try to find from environment or registry
    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            # Try LOGONSERVER environment variable (works in some scenarios)
            if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
                $userDir = "C:\Users\$env:USERNAME"
                if (Test-Path $userDir) {
                    $realUserProfile = $userDir
                }
            }
        } catch {
        }
    }
    
    # Last resort: scan for most recently modified user profile
    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            $profiles = @(Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and
                    (Test-Path (Join-Path $_.FullName 'AppData'))
                } | Sort-Object LastWriteTime -Descending)
            
            if ($profiles.Count -gt 0) {
                $realUserProfile = $profiles[0].FullName
            }
        } catch {
        }
    }
    
    # Final check: if still couldn't determine, use a reasonable fallback
    if ($realUserProfile -match 'systemprofile|system32') {
        Write-Warn "Could not detect real user, using default install location"
        $realUserProfile = "C:\Users\Administrator"
    }
}

# Get real LocalAppData
$realLocalAppData = Join-Path $realUserProfile "AppData\Local"

# =============================
# Parse Arguments
# =============================
$InstallCli = $false
$SetupVersion = $null
$CliVersion = $null

# Parse arguments
for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = $args[$i]
    switch ($arg) {
        "-cli" { $InstallCli = $true }
        "--cli" { $InstallCli = $true }
        "-v" {
            if ($i + 1 -lt $args.Count -and $args[$i + 1] -notmatch "^-") {
                if ($InstallCli) {
                    $CliVersion = $args[$i + 1]
                } else {
                    $SetupVersion = $args[$i + 1]
                }
                $i++
            }
        }
        "--version" {
            if ($i + 1 -lt $args.Count -and $args[$i + 1] -notmatch "^-") {
                if ($InstallCli) {
                    $CliVersion = $args[$i + 1]
                } else {
                    $SetupVersion = $args[$i + 1]
                }
                $i++
            }
        }
    }
}

# =============================
# Embedded Version Management (Self-contained, no external dependencies)
# =============================
$script:DownloadBaseUrl = "https://download.nacos.io"
$script:VersionsUrl = "$script:DownloadBaseUrl/versions"

# Fallback Versions (used when versions file cannot be fetched)
$script:FallbackNacosCliVersion = "0.0.8"
$script:FallbackNacosSetupVersion = "0.0.3"
$script:FallbackNacosServerVersion = "3.2.0-BETA"

# Cached versions
$script:CachedCliVersion = ""
$script:CachedSetupVersion = ""
$script:CachedServerVersion = ""
$script:VersionsFetched = $false

function Fetch-Versions {
    param([int]$TimeoutSeconds = 3)
    
    try {
        # Use Invoke-WebRequest with explicit timeout (more reliable than Invoke-RestMethod)
        $response = Invoke-WebRequest -Uri $script:VersionsUrl -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        
        if ($response.StatusCode -eq 200 -and $response.Content) {
            $content = $response.Content
            $lines = $content -split "`r?`n"
            foreach ($line in $lines) {
                $line = $line.Trim()
                if ($line -match "^NACOS_CLI_VERSION=(.+)$") { $script:CachedCliVersion = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SETUP_VERSION=(.+)$") { $script:CachedSetupVersion = $matches[1].Trim() }
                elseif ($line -match "^NACOS_SERVER_VERSION=(.+)$") { $script:CachedServerVersion = $matches[1].Trim() }
            }
            
            # Only mark as fetched if we got at least one version
            if ($script:CachedCliVersion -or $script:CachedSetupVersion -or $script:CachedServerVersion) {
                $script:VersionsFetched = $true
                Write-Info "Remote versions fetched successfully"
                return $true
            }
        }
        return $false
    }
    catch {
        Write-Warn "Fetch-Versions error: $($_.Exception.Message)"
        return $false
    }
}

function Get-Version {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("cli", "setup", "server")]
        [string]$Component,
        [int]$TimeoutSeconds = 1
    )
    
    $envVarName = "NACOS_$($Component.ToUpper())_VERSION"
    $envValue = [Environment]::GetEnvironmentVariable($envVarName)
    if ($envValue) { return $envValue }
    
    $cachedProp = "Cached$($Component.Substring(0,1).ToUpper() + $Component.Substring(1))Version"
    $cachedValue = Get-Variable -Name $cachedProp -Scope Script -ErrorAction SilentlyContinue
    if ($cachedValue -and $cachedValue.Value) { return $cachedValue.Value }
    
    if (-not $script:VersionsFetched) {
        if (Fetch-Versions -TimeoutSeconds $TimeoutSeconds) {
            $cachedValue = Get-Variable -Name $cachedProp -Scope Script -ErrorAction SilentlyContinue
            if ($cachedValue -and $cachedValue.Value) { return $cachedValue.Value }
        }
    }
    
    $fallbackProp = "FallbackNacos$($Component.Substring(0,1).ToUpper() + $Component.Substring(1))Version"
    $fallbackValue = Get-Variable -Name $fallbackProp -Scope Script -ErrorAction SilentlyContinue
    if ($fallbackValue) { return $fallbackValue.Value }
    return $null
}

function Get-AllVersions {
    param([int]$TimeoutSeconds = 2)
    
    Write-Info "Fetching versions (timeout: ${TimeoutSeconds}s)..."
    
    try {
        # Get versions with short timeout
        $cliVer = Get-Version -Component cli -TimeoutSeconds $TimeoutSeconds
        $setupVer = Get-Version -Component setup -TimeoutSeconds $TimeoutSeconds
        $serverVer = Get-Version -Component server -TimeoutSeconds $TimeoutSeconds
        
        # Set script-level variables
        $script:NacosCliVersion = if ($cliVer) { $cliVer } else { $script:FallbackNacosCliVersion }
        $script:NacosSetupVersion = if ($setupVer) { $setupVer } else { $script:FallbackNacosSetupVersion }
        $script:NacosServerVersion = if ($serverVer) { $serverVer } else { $script:FallbackNacosServerVersion }
        
        # Log result
        if ($script:VersionsFetched) {
            Write-Info "✓ Remote versions fetched"
        } else {
            Write-Warn "⚠ Using fallback versions"
        }
        Write-Info "CLI: $($script:NacosCliVersion) | Setup: $($script:NacosSetupVersion) | Server: $($script:NacosServerVersion)"
    }
    catch {
        Write-Warn "⚠ Version fetch error, using fallback"
        $script:NacosCliVersion = $script:FallbackNacosCliVersion
        $script:NacosSetupVersion = $script:FallbackNacosSetupVersion
        $script:NacosServerVersion = $script:FallbackNacosServerVersion
    }
}

# Runtime versions
$NacosCliVersion = ""
$NacosSetupVersion = ""
$NacosServerVersion = ""

$CacheDir = Join-Path $realUserProfile ".nacos\cache"
$InstallDir = Join-Path $realLocalAppData "Programs\nacos-cli"
$BinName = "nacos-cli.exe"
$SetupRootDir = Join-Path $realLocalAppData "Programs\nacos-setup"
$SetupScriptName = "nacos-setup.ps1"
$SetupCmdName = "nacos-setup.cmd"

# Initialize versions using the unified version manager
function Initialize-Versions {
    # Load all versions with timeout (increased to 5 seconds for reliability)
    try {
        Get-AllVersions -TimeoutSeconds 5
    } catch {
        Write-Warn "Version fetch failed: $($_.Exception.Message)"
        Write-Warn "Using fallback versions"
    }

    # Apply user-specified versions if provided
    if ($SetupVersion) {
        $script:NacosSetupVersion = $SetupVersion
        Write-Info "Using specified nacos-setup version: $SetupVersion"
    }
    if ($CliVersion) {
        $script:NacosCliVersion = $CliVersion
        Write-Info "Using specified nacos-cli version: $CliVersion"
    }

    # Ensure we have valid versions (fallback if empty)
    if (-not $script:NacosSetupVersion) { $script:NacosSetupVersion = $script:FallbackNacosSetupVersion }
    if (-not $script:NacosCliVersion) { $script:NacosCliVersion = $script:FallbackNacosCliVersion }
    if (-not $script:NacosServerVersion) { $script:NacosServerVersion = $script:FallbackNacosServerVersion }

    # Set derived variables after version initialization
    $script:SetupInstallDir = Join-Path $SetupRootDir $script:NacosSetupVersion

    Write-Info "Versions: CLI=$($script:NacosCliVersion), Setup=$($script:NacosSetupVersion), Server=$($script:NacosServerVersion)"
}

# =============================
# Main
# =============================
Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Installer (Windows)"
Write-Host "========================================"
Write-Host ""

# Initialize versions
Initialize-Versions
Write-Host ""

if ($isAdmin) {
    Write-Warn "Running as Administrator detected"
    Write-Info "Installing to user directory: $realUserProfile"
}

if ($InstallCli) {
    Write-Info "Installing nacos-cli only (use 'nacos-cli --help' for usage)"
} else {
    Write-Info "Installing nacos-setup (use 'nacos-setup --help' for usage)"
}

Ensure-Directory $CacheDir

if ($InstallCli) {
    # =============================
    # Install nacos-cli only
    # =============================
    # Remove existing installation directory if it exists (fresh install)
    if (Test-Path $InstallDir) {
        Write-Warn "Removing existing nacos-cli installation at $InstallDir"
        Remove-Item -Recurse -Force $InstallDir
    }
    
    Ensure-Directory $InstallDir
    Write-Info "Preparing to install nacos-cli version $NacosCliVersion..."
    
    $os = "windows"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $zipName = "nacos-cli-$NacosCliVersion-$os-$arch.zip"
    $zipPath = Join-Path $CacheDir $zipName
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
    
    $expected = "nacos-cli-$NacosCliVersion-$os-$arch.exe"
    $binaryPath = Get-ChildItem -Path $extractDir -Recurse -Filter $expected | Select-Object -First 1
    if (-not $binaryPath) {
        Write-ErrorMsg "Binary file not found in package. Expected: $expected"
        Write-Info "Available files in package:"
        Get-ChildItem -Path $extractDir -Recurse | ForEach-Object { "  $($_.FullName)" }
        Write-ErrorMsg 'Binary file not found in package'
        return
    }
    
    Copy-Item -Path $binaryPath.FullName -Destination (Join-Path $InstallDir $BinName) -Force
    Add-ToUserPath $InstallDir
    Remove-Item -Recurse -Force $extractDir
    
    Refresh-SessionPath
    
    Write-Host ""
    Write-Success "nacos-cli installed successfully!"
    Write-Host ""
    Write-Info "Installation Summary:"
    Write-Info "  Location: $InstallDir\\$BinName"
    Write-Host ""
    Write-Success "You can now use the command:"
    Write-Info "  nacos-cli --help"
    Write-Host ""
} else {
    # =============================
    # Install nacos-setup (default)
    # =============================
    Write-Info "Preparing to install nacos-setup version $NacosSetupVersion..."
    
    if (Test-Path $SetupInstallDir) {
        $existingScript = Join-Path $SetupInstallDir $SetupScriptName
        if (Test-Path $existingScript) {
            Write-Info "nacos-setup $NacosSetupVersion is already installed at: $SetupInstallDir"
            Ensure-Directory $SetupRootDir
            $rootCmdPath = Join-Path $SetupRootDir $SetupCmdName
            @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "${SetupInstallDir}\$SetupScriptName" %*
"@ | Set-Content -Path $rootCmdPath -Encoding ASCII
            Add-ToUserPath $SetupRootDir
            Refresh-SessionPath
            Write-Host ""
            Write-Success "nacos-setup already installed."
            Write-Host ""
            Write-Info "Installation Summary:"
            Write-Info "  Location: $SetupRootDir\\$SetupCmdName"
            Write-Host ""
            Write-Success "You can now use the command:"
            Write-Info "  nacos-setup --help"
            Write-Host ""
            return
        }
        Write-Warn "nacos-setup directory exists but script is missing. Reinstalling..."
    }
    
    Ensure-Directory $CacheDir
    
    # Remove existing installation directory only if reinstalling this version
    if (Test-Path $SetupInstallDir) {
        Write-Warn "Removing existing nacos-setup installation at $SetupInstallDir"
        Remove-DirectorySafe $SetupInstallDir
    }
    
    Ensure-Directory $SetupInstallDir
    
    $setupZipName = "nacos-setup-windows-$NacosSetupVersion.zip"
    $setupZipPath = Join-Path $CacheDir $setupZipName
    $setupZipUrl = "$DownloadBaseUrl/$setupZipName"
    
    if (-not (Test-Path $setupZipPath) -or (Get-Item $setupZipPath).Length -eq 0) {
        Download-File $setupZipUrl $setupZipPath
    } else {
        Write-Info "Found cached package: $setupZipPath"
    }
    
    Write-Info "Extracting nacos-setup windows scripts..."
    $extractDir = Join-Path $env:TEMP ("nacos-setup-windows-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $extractDir
    Expand-Archive -Path $setupZipPath -DestinationPath $extractDir -Force
    
    $setupDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $setupDir) {
        Write-ErrorMsg "Failed to find extracted directory in $setupZipName"
        Write-ErrorMsg 'Failed to find extracted directory'
        return
    }
    
    $setupScriptInZip = Join-Path $setupDir.FullName $SetupScriptName
    if (-not (Test-Path $setupScriptInZip)) {
        Write-ErrorMsg "$SetupScriptName not found in package"
        Write-ErrorMsg '$SetupScriptName not found in package'
        return
    }
    
    Copy-Item -Path (Join-Path $setupDir.FullName "*") -Destination $SetupInstallDir -Recurse -Force
    
    $setupScriptPath = Join-Path $SetupInstallDir $SetupScriptName
    if (-not (Test-Path $setupScriptPath)) {
        Write-ErrorMsg "nacos-setup.ps1 not found after extraction"
        Write-ErrorMsg 'nacos-setup.ps1 not found after extraction'
        return
    }
    
    $content = Get-Content -Path $setupScriptPath -Raw
    $content = $content -replace "[\u2018\u2019]", "'"
    $content = $content -replace "[\u201C\u201D]", '"'
    Set-Content -Path $setupScriptPath -Value $content -Encoding UTF8
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    
    Ensure-Directory $SetupRootDir
    $setupCmdPath = Join-Path $SetupRootDir $SetupCmdName
    @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "${SetupInstallDir}\$SetupScriptName" %*
"@ | Set-Content -Path $setupCmdPath -Encoding ASCII
    
    Add-ToUserPath $SetupRootDir
    Refresh-SessionPath
    
    Write-Host ""
    Write-Success "nacos-setup installed successfully!"
    Write-Host ""
    Write-Info "Installation Summary:"
    Write-Info "  Location: $SetupRootDir\\$SetupCmdName"
    Write-Host ""
    Write-Success "You can now use the command:"
    Write-Info "  nacos-setup --help"
    Write-Host ""
}

