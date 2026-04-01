# Nacos Setup for Windows (PowerShell)
# Native PowerShell implementation (no WSL required)

$ErrorActionPreference = "Stop"
# PS 5.1: default progress UI throttles Invoke-WebRequest to ~KB/s on large files; disable for downloads.
$ProgressPreference    = "SilentlyContinue"

# =============================
# Helper functions (define before loading scripts)
# =============================
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }

# =============================
# Configuration
# =============================
# NOTE: This version is automatically updated by package.sh during build
$NacosSetupVersion = "0.0.0-dev"

# Get the actual user directory even when running as SYSTEM
$realUserProfile = $env:USERPROFILE

# Cross-platform fallback for non-Windows environments (for testing)
if (-not $realUserProfile) {
    if ($env:HOME) {
        $realUserProfile = $env:HOME
    } elseif ($env:USERPROFILE) {
        $realUserProfile = $env:USERPROFILE
    } else {
        $realUserProfile = "."
    }
}

# If USERPROFILE points to SYSTEM, try to find real user
if ($realUserProfile -match 'systemprofile|system32') {
    # Get system drive (may not be C:)
    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { $systemDrive = "C:" }
    $usersDir = Join-Path $systemDrive "Users"
    
    try {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem -and $computerSystem.UserName) {
            $userName = $computerSystem.UserName
            if ($userName -match '\\(.+)$') { $userName = $matches[1] }
            $userDir = Join-Path $usersDir $userName
            if (Test-Path $userDir) { $realUserProfile = $userDir }
        }
    } catch {}

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
                $userDir = Join-Path $usersDir $env:USERNAME
                if (Test-Path $userDir) { $realUserProfile = $userDir }
            }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            $profiles = @(Get-ChildItem $usersDir -Directory -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and
                    (Test-Path (Join-Path $_.FullName 'AppData'))
                } | Sort-Object LastWriteTime -Descending)

            if ($profiles.Count -gt 0) {
                $realUserProfile = $profiles[0].FullName
            }
        } catch {}
    }

    if ($realUserProfile -match 'systemprofile|system32') {
        $realUserProfile = Join-Path $usersDir "Administrator"
    }
}

# Ensure cache dir uses real user profile before loading libs
$env:REAL_USER_PROFILE = $realUserProfile
$env:NACOS_CACHE_DIR = Join-Path $realUserProfile ".nacos\cache"

# =============================
# Load helpers
# =============================
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$libPath = Join-Path $scriptRoot "lib"

$libFiles = @(
    "common.ps1"
    "download.ps1"
    "port_manager.ps1"
    "config_manager.ps1"
    "java_manager.ps1"
    "process_manager.ps1"
    "standalone.ps1"
    "cluster.ps1"
)

$optionalLibFiles = @(
    "skill_scanner_install.ps1"
)

foreach ($libFile in $libFiles) {
    $libFilePath = Join-Path $libPath $libFile
    if (Test-Path $libFilePath) {
        . $libFilePath
    } else {
        Write-ErrorMsg "Failed to load library: $libFile from $libFilePath"
        exit 1
    }
}

foreach ($libFile in $optionalLibFiles) {
    $libFilePath = Join-Path $libPath $libFile
    if (Test-Path $libFilePath) { . $libFilePath }
}

# =============================
# Main
# =============================

function Print-SystemInfo {
    Write-Info "System Information:"
    Write-Info "  - OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Info "  - PowerShell: $($PSVersionTable.PSVersion.ToString())"
    Write-Info "  - User: $env:USERNAME"
    Write-Info "  - Nacos Setup Version: $NacosSetupVersion"
    Write-Host ""
}

# =============================
# Load Version Management
# =============================
$LibDir = Join-Path $PSScriptRoot "lib"
if (Test-Path (Join-Path $LibDir "versions.ps1")) {
    . (Join-Path $LibDir "versions.ps1")
}

# Flag to track if user specified version via -v
$UserSpecifiedVersion = $false

function Initialize-Version {
    # Only fetch from remote if user didn't specify -v
    if ($script:UserSpecifiedVersion) {
        return
    }

    # Get server version using unified version manager
    $fetchedVersion = Get-Version -Component server -TimeoutSeconds 1
    if ($fetchedVersion) {
        $script:DefaultVersion = $fetchedVersion
        $script:Version = $fetchedVersion
        $Global:Version = $fetchedVersion
        Write-Detail "Using latest Nacos server version: $fetchedVersion"
    }
}

# =============================
# Defaults
# =============================
# Get fallback version from versions.ps1 if available, otherwise use hardcoded
if (Get-Command Get-Version -ErrorAction SilentlyContinue) {
    $DefaultVersion = Get-Version -Component server -TimeoutSeconds 0
} else {
    $DefaultVersion = "3.2.0-BETA"
}
$DefaultInstallDir = Join-Path $realUserProfile "ai-infra\nacos"
$DefaultMode = "standalone"
$DefaultPort = 8848
$DefaultReplicaCount = 3
$MinimumVersion = "2.4.0"

$Mode = $DefaultMode
$Version = $DefaultVersion
$AutoStart = $true
$AdvancedMode = $false
$DaemonMode = $false
$InstallDir = ""
$Port = $DefaultPort
$AllowKill = $false

$ClusterId = ""
$ReplicaCount = $DefaultReplicaCount
$ClusterBaseDir = Join-Path $DefaultInstallDir "cluster"
$BasePort = $DefaultPort
$CleanMode = $false
$JoinMode = $false
$LeaveMode = $false
$NodeIndex = ""

$DatasourceConfMode = $false
$Global:StartedPids = @()
$Global:CleanupDone = $false
$Global:DbConfMode = $null
$Global:NacosSetupVersion = $NacosSetupVersion

# Initialize globals with defaults (Parse-Arguments will override)
$Global:Mode = $Mode
$Global:Version = $Version
$Global:AutoStart = $AutoStart
$Global:AdvancedMode = $AdvancedMode
$Global:DaemonMode = $DaemonMode
$Global:InstallDir = $InstallDir
$Global:Port = $Port
$Global:BasePort = $BasePort
$Global:AllowKill = $AllowKill
$Global:ClusterId = $ClusterId
$Global:ReplicaCount = $ReplicaCount
$Global:ClusterBaseDir = $ClusterBaseDir
$Global:CleanMode = $CleanMode
$Global:JoinMode = $JoinMode
$Global:LeaveMode = $LeaveMode
$Global:NodeIndex = $NodeIndex
$Global:DatasourceConfMode = $DatasourceConfMode
$Global:DefaultInstallDir = $DefaultInstallDir

function Global:Invoke-NacosSetupCleanup {
    if ($Global:CleanupDone) { return }
    $Global:CleanupDone = $true
    
    if ($Global:DaemonMode) { return }

    $pidsToStop = @()
    foreach ($p in @($Global:StartedPids)) { if ($p) { $pidsToStop += $p } }
    if ($Global:StartedNacosPid -and $pidsToStop -notcontains $Global:StartedNacosPid) {
        $pidsToStop += $Global:StartedNacosPid
    }

    if ($pidsToStop.Count -gt 0) {
        Write-Host ""
        Write-Info "Stopping Nacos processes..."
        foreach ($p in $pidsToStop) {
            Write-Info "Terminating process PID: $p"
            try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {}
            try { cmd /c "taskkill /F /PID $p /T >NUL 2>&1" } catch {}
        }
    }
}

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-NacosSetupCleanup }

function Print-Usage {
    Write-Host ""
    Write-Host "Nacos Setup Tool (Windows)" -ForegroundColor Cyan
    Write-Host "==========================" -ForegroundColor Cyan
    Write-Host "Usage: nacos-setup [OPTIONS]"
    Write-Host ""
    Write-Host "General Options:"
    Write-Host "  -v, --version <VER>      Nacos version to install (Default: $DefaultVersion)"
    Write-Host "  -p, --port <PORT>        Main server port (Default: $DefaultPort)"
    Write-Host "  -d, --dir <PATH>         Custom installation directory"
    Write-Host "  --adv                    Enable advanced mode (custom tokens/passwords)"
    Write-Host "  --daemon                 Run in background (daemon mode)"
    Write-Host "  --no-start               Install configuration only, do not start server"
    Write-Host "  --clean                  Remove existing installation before starting"
    Write-Host "  --kill                   Force kill existing process if port is occupied"
    Write-Host "  -db-conf [NAME]          Use external datasource (default: default)"
    Write-Host "  db-conf edit [NAME]      Edit datasource configuration"
    Write-Host "  db-conf show [NAME]      Show datasource configuration"
    Write-Host "  -x, --verbose            Verbose output (detailed logs; or env NACOS_SETUP_VERBOSE=1)"
    Write-Host "  -h, --help               Show this help message"
    Write-Host ""
    Write-Host "Cluster Options:"
    Write-Host "  -c, --cluster <ID>       Enable cluster mode with specified Cluster ID"
    Write-Host "  -n, --nodes <NUM>        Number of cluster nodes (Default: $DefaultReplicaCount)"
    Write-Host "  --join                   Join mode: Add a new node to existing cluster"
    Write-Host "  --leave <INDEX>          Leave mode: Remove specific node index from cluster"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  nacos-setup -v 2.4.3"
    Write-Host "  nacos-setup -p 8848 --daemon"
    Write-Host "  nacos-setup -c mycluster -n 3"
    Write-Host ""
}

function Print-NacosInstallerResolutionLog {
    $localInstaller = Join-Path $PSScriptRoot "nacos-installer.ps1"
    if (Test-Path $localInstaller) {
        Write-Info "nacos-installer: using local: $localInstaller"
    } else {
        Write-Info "nacos-installer: local nacos-installer.ps1 not found under $PSScriptRoot"
        Write-Info "nacos-installer: use: iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex"
    }
}

function Parse-Arguments($argv) {
    $argsList = @()
    $i = 0
    while ($i -lt $argv.Count) {
        $arg = $argv[$i]
        switch ($arg) {
            "-db-conf" {
                $Global:DbConfMode = "use"
                if ($i + 1 -lt $argv.Count -and $argv[$i + 1] -notmatch "^-") {
                    $Global:DbConfFile = $argv[$i + 1]
                    $i++
                } else {
                    $Global:DbConfFile = "default"
                }
                $i++
            }
            "db-conf" {
                $i++
                if ($i -lt $argv.Count) {
                    $subCmd = $argv[$i]
                    switch ($subCmd) {
                        "edit" {
                            $Global:DbConfMode = "edit"
                            $i++
                            if ($i -lt $argv.Count -and $argv[$i] -notmatch "^-") {
                                $Global:DbConfFile = $argv[$i]
                                $i++
                            } else {
                                $Global:DbConfFile = "default"
                            }
                        }
                        "show" {
                            $Global:DbConfMode = "show"
                            $i++
                            if ($i -lt $argv.Count -and $argv[$i] -notmatch "^-") {
                                $Global:DbConfFile = $argv[$i]
                                $i++
                            } else {
                                $Global:DbConfFile = "default"
                            }
                        }
                        default {
                            Write-ErrorMsg "Unknown db-conf subcommand: $subCmd"
                            Write-Info "Usage: db-conf edit [NAME] | db-conf show [NAME]"
                            exit 1
                        }
                    }
                } else {
                    Write-ErrorMsg "db-conf requires a subcommand: edit or show"
                    exit 1
                }
            }
            "--adv" { $Global:AdvancedMode = $true; $i++ }
            "--daemon" { $Global:DaemonMode = $true; $i++ }
            "--clean" { $Global:CleanMode = $true; $i++ }
            "--join" { $Global:JoinMode = $true; $i++ }
            "--no-start" { $Global:AutoStart = $false; $i++ }
            "--kill" { $Global:AllowKill = $true; $i++ }
            "-x" { $Global:NacosSetupVerbose = $true; $env:NACOS_SETUP_VERBOSE = "true"; $i++ }
            "--verbose" { $Global:NacosSetupVerbose = $true; $env:NACOS_SETUP_VERBOSE = "true"; $i++ }
            default { $argsList += $arg; $i++ }
        }
    }

    for ($i=0; $i -lt $argsList.Count; $i++) {
        $a = $argsList[$i]
        switch ($a) {
            "-v" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -v/--version requires a version number"; exit 1 }
                $Global:Version = $argsList[$i+1]; $script:UserSpecifiedVersion = $true; $i++
            }
            "--version" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -v/--version requires a version number"; exit 1 }
                $Global:Version = $argsList[$i+1]; $script:UserSpecifiedVersion = $true; $i++
            }
            "-p" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -p/--port requires a port number"; exit 1 }
                $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++
            }
            "--port" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -p/--port requires a port number"; exit 1 }
                $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++
            }
            "-d" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -d/--dir requires a directory path"; exit 1 }
                $Global:InstallDir = $argsList[$i+1]; $i++
            }
            "--dir" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -d/--dir requires a directory path"; exit 1 }
                $Global:InstallDir = $argsList[$i+1]; $i++
            }
            "-c" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -c/--cluster requires a cluster ID"; exit 1 }
                $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++
            }
            "--cluster" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -c/--cluster requires a cluster ID"; exit 1 }
                $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++
            }
            "-n" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -n/--nodes requires a node count"; exit 1 }
                $Global:ReplicaCount = [int]$argsList[$i+1]; $i++
            }
            "--nodes" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option -n/--nodes requires a node count"; exit 1 }
                $Global:ReplicaCount = [int]$argsList[$i+1]; $i++
            }
            "--leave" {
                if ($i + 1 -ge $argsList.Count -or $argsList[$i + 1] -match "^-") { Write-ErrorMsg "Option --leave requires a node index"; exit 1 }
                $Global:LeaveMode = $true; $Global:NodeIndex = $argsList[$i+1]; $i++
            }
            "-h" { Print-Usage; exit 0 }
            "--help" { Print-Usage; exit 0 }
            default { Write-ErrorMsg "Unknown option: $a"; exit 1 }
        }
    }
}

function Validate-Arguments {
    if (-not (Version-Ge $Global:Version $MinimumVersion)) {
        Write-ErrorMsg "Nacos version $Global:Version is not supported"
        exit 1
    }
    if ($Global:Mode -eq "cluster") {
        if (-not $Global:ClusterId -and -not $Global:LeaveMode) {
            Write-ErrorMsg "Cluster ID is required"
            exit 1
        }
    }
    if (($Global:JoinMode -or $Global:CleanMode -or $Global:LeaveMode) -and -not $Global:ClusterId) {
        Write-ErrorMsg "Cluster options (--join/--clean/--leave) require -c/--cluster"
        exit 1
    }
}

try {
    Parse-Arguments $args

    if (Test-NacosSetupVerbose) {
        Print-NacosInstallerResolutionLog
        Write-Host ""
        Print-SystemInfo
    }

    # Handle db-conf mode (local modes that don't need version fetching)
    if ($Global:DbConfMode) {
        . $PSScriptRoot\lib\config_manager.ps1
        switch ($Global:DbConfMode) {
            "edit" {
                Edit-DatasourceConfig $Global:DbConfFile
                exit 0
            }
            "show" {
                Show-DatasourceConfig $Global:DbConfFile
                exit 0
            }
            "use" {
                # Enable external datasource mode for installation
                $env:USE_EXTERNAL_DATASOURCE = "true"
                if ($Global:DbConfFile -and $Global:DbConfFile -ne "default") {
                    # Resolve config name to full path
                    $userProfile = if ($env:REAL_USER_PROFILE) { $env:REAL_USER_PROFILE } elseif ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { "." }
                    $env:DEFAULT_DATASOURCE_CONFIG = Join-Path $userProfile "ai-infra\nacos\$($Global:DbConfFile).properties"
                }
                # Continue to normal installation flow (will init version below)
            }
        }
    }

    # Initialize version (fetch from remote only if user didn't specify -v)
    Initialize-Version
    if (Test-NacosSetupVerbose) { Write-Host "" }

    # Print external datasource mode info if enabled
    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        $activeDatasourceConfig = if ($env:DEFAULT_DATASOURCE_CONFIG) { $env:DEFAULT_DATASOURCE_CONFIG } else { $Global:DefaultDatasourceConfig }
        Write-Detail "External datasource mode enabled: $activeDatasourceConfig"
    }

    Validate-Arguments

    if (-not (Test-WindowsNacosSetupPrerequisites)) { exit 1 }

    switch ($Global:Mode) {
        "standalone" { Invoke-StandaloneMode }
        "cluster" { Invoke-ClusterMode }
        default { Write-ErrorMsg "Unknown mode: $Global:Mode"; exit 1 }
    }
} finally {
    try { Invoke-NacosSetupCleanup } catch {}
}
