# Nacos Setup for Windows (PowerShell)
# Native PowerShell implementation (no WSL required)

$ErrorActionPreference = "Stop"

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

foreach ($libFile in $libFiles) {
    $libFilePath = Join-Path $libPath $libFile
    if (Test-Path $libFilePath) {
        . $libFilePath
    } else {
        Write-ErrorMsg "Failed to load library: $libFile from $libFilePath"
        exit 1
    }
}

# =============================
# Main
# =============================

Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Setup (Windows Native)"
Write-Host "========================================"
Write-Host ""

function Print-SystemInfo {
    Write-Info "System Information:"
    Write-Info "  - OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Info "  - PowerShell: $($PSVersionTable.PSVersion.ToString())"
    Write-Info "  - User: $env:USERNAME"
    Write-Info "  - Nacos Setup Version: $NacosSetupVersion"
    Write-Host ""
}

Print-SystemInfo

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
$DetachMode = $false
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

# Initialize globals with defaults (Parse-Arguments will override)
$Global:Mode = $Mode
$Global:Version = $Version
$Global:AutoStart = $AutoStart
$Global:AdvancedMode = $AdvancedMode
$Global:DetachMode = $DetachMode
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

function Global:Invoke-NacosSetupCleanup {
    if ($Global:CleanupDone) { return }
    $Global:CleanupDone = $true
    
    if (-not $Global:DetachMode -and $Global:StartedPids.Count -gt 0) {
        Write-Host ""
        Write-Info "Stopping Nacos processes..."
        foreach ($p in $Global:StartedPids) {
            Write-Info "Terminating process PID: $p"
            # Try native PowerShell stop
            try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {}
            # Fallback/Ensure with taskkill (forcefully terminates the process and any child processes)
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
    Write-Host "  --detach                 Run in background (detach from terminal)"
    Write-Host "  --no-start               Install configuration only, do not start server"
    Write-Host "  --clean                  Remove existing installation before starting"
    Write-Host "  --kill                   Force kill existing process if port is occupied"
    Write-Host "  -db-conf [FILE]          Use external datasource (default: default.properties)"
    Write-Host "  db-conf edit [FILE]      Edit datasource configuration"
    Write-Host "  db-conf show [FILE]      Show datasource configuration"
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
    Write-Host "  nacos-setup -p 8848 --detach"
    Write-Host "  nacos-setup -c mycluster -n 3"
    Write-Host ""
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
                            Write-Info "Usage: db-conf edit [FILE] | db-conf show [FILE]"
                            exit 1
                        }
                    }
                } else {
                    Write-ErrorMsg "db-conf requires a subcommand: edit or show"
                    exit 1
                }
            }
            "--adv" { $Global:AdvancedMode = $true; $i++ }
            "--detach" { $Global:DetachMode = $true; $i++ }
            "--clean" { $Global:CleanMode = $true; $i++ }
            "--join" { $Global:JoinMode = $true; $i++ }
            "--no-start" { $Global:AutoStart = $false; $i++ }
            "--kill" { $Global:AllowKill = $true; $i++ }
            default { $argsList += $arg; $i++ }
        }
    }

    for ($i=0; $i -lt $argsList.Count; $i++) {
        $a = $argsList[$i]
        switch ($a) {
            "-v" { $Global:Version = $argsList[$i+1]; $script:UserSpecifiedVersion = $true; $i++ }
            "--version" { $Global:Version = $argsList[$i+1]; $script:UserSpecifiedVersion = $true; $i++ }
            "-p" { $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++ }
            "--port" { $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++ }
            "-d" { $Global:InstallDir = $argsList[$i+1]; $i++ }
            "--dir" { $Global:InstallDir = $argsList[$i+1]; $i++ }
            "-c" { $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++ }
            "--cluster" { $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++ }
            "-n" { $Global:ReplicaCount = [int]$argsList[$i+1]; $i++ }
            "--nodes" { $Global:ReplicaCount = [int]$argsList[$i+1]; $i++ }
            "--leave" { $Global:LeaveMode = $true; $Global:NodeIndex = $argsList[$i+1]; $i++ }
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
}

function Get-NodeMainPort($nodeDir, $version) {
    $configFile = Join-Path $nodeDir "conf\application.properties"
    if (-not (Test-Path $configFile)) { return $null }
    $major = [int]($version.Split('.')[0])
    $key = if ($major -ge 3) { "nacos.server.main.port" } else { "server.port" }
    $line = Get-Content -Path $configFile | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if ($line -and $line -match "^$key=(.*)$") { return [int]$Matches[1] }
    return $null
}

function Get-NodeConsolePort($nodeDir) {
    $configFile = Join-Path $nodeDir "conf\application.properties"
    if (-not (Test-Path $configFile)) { return $null }
    $line = Get-Content -Path $configFile | Where-Object { $_ -match "^nacos.console.port=" } | Select-Object -First 1
    if ($line -and $line -match "^nacos.console.port=(.*)$") { return [int]$Matches[1] }
    return $null
}

function Run-Standalone {
    Write-Info "Nacos Standalone Installation"
    if (-not $Global:InstallDir) {
        $Global:InstallDir = Join-Path $DefaultInstallDir "standalone\nacos-$Global:Version"
    }
    Write-Info "Target Nacos version: $Global:Version"
    Write-Info "Installation directory: $Global:InstallDir"

    # Remove existing installation if it exists (fresh install)
    if (Test-Path $Global:InstallDir) {
        Write-Warn "Removing existing installation at $Global:InstallDir"
        
        $lockingProcs = Get-BlockingProcesses $Global:InstallDir
        if ($lockingProcs) {
            Write-Warn "Found processes running from or using this directory:"
            foreach ($p in $lockingProcs) {
                Write-Warn "  PID: $($p.ProcessId) - $($p.Name)"
            }

            if ($Global:AllowKill) {
                Write-Info "Kill mode is enabled. Stopping processes..."
                foreach ($p in $lockingProcs) {
                    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                }
                Start-Sleep -Seconds 2
            } else {
                Write-ErrorMsg "Directory is in use. Use --kill to force remove, or stop processes manually."
                exit 1
            }
        }

        try {
            Remove-Item -Recurse -Force $Global:InstallDir -ErrorAction Stop
        } catch {
            Write-ErrorMsg "Failed to remove directory. One or more files may still be in use."
            Write-ErrorMsg $_.Exception.Message
            exit 1
        }
    }

    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) { exit 1 }

    $zip = Download-Nacos $Global:Version
    $extracted = Extract-NacosToTemp $zip
    Install-Nacos $extracted $Global:InstallDir | Out-Null
    Cleanup-TempDir (Split-Path $extracted -Parent)

    $ports = Allocate-StandalonePorts $Global:Port $Global:Version $Global:AdvancedMode $Global:AllowKill
    $serverPort = $ports[0]
    $consolePort = $ports[1]

    $configFile = Join-Path $Global:InstallDir "conf\application.properties"
    Write-Info "Configuring ports in: $configFile"
    Update-PortConfig $configFile $serverPort $consolePort $Global:Version
    Configure-Standalone-Security $configFile $Global:AdvancedMode

    $ds = Load-GlobalDatasourceConfig
    if ($ds) { 
        Apply-DatasourceConfig $configFile $ds | Out-Null 
        Write-Info "External database configured"
    } else {
        Write-Info "Using embedded Derby database"
        Write-Info "Tip: Run 'nacos-setup --datasource-conf' to configure external database"
    }
    Write-Info "Configuration completed"
    Write-Host ""

    if ($Global:AutoStart) {
        Write-Info "Starting Nacos in standalone mode..."
        Write-Host ""
        
        $startTime = Get-Date
        $nacosPid = Start-NacosProcess $Global:InstallDir "standalone" $false
        if ($nacosPid -is [array]) {
            Write-Info "Nacos started (Wrapper PID: $($nacosPid[0]), Java PID: $($nacosPid[1]))"
            $Global:StartedPids += $nacosPid[1]
        } else {
            Write-Info "Nacos started with PID: $nacosPid"
            $Global:StartedPids += $nacosPid
        }
        Write-Host ""
        if (Wait-ForNacosReady $serverPort $consolePort $Global:Version 60) {
            $endTime = Get-Date
            $elapsed = [int](($endTime - $startTime).TotalSeconds)
            Write-Info "Nacos is ready in ${elapsed}s!"
            Write-Host ""
            
            if ($Global:NACOS_PASSWORD -and $Global:NACOS_PASSWORD -ne "nacos") {
                Write-Info "Initializing admin password..."
                if (Initialize-AdminPassword $serverPort $consolePort $Global:Version $Global:NACOS_PASSWORD) {
                    Write-Info "Admin password initialized successfully"
                } else {
                    Write-Warn "Password initialization failed, you can change it manually after login"
                }
            }
        } else {
            Write-Warn "Nacos may still be starting, please wait a moment"
        }
        $major = [int]($Global:Version.Split('.')[0])
        $consoleUrl = if ($major -ge 3) { "http://localhost:$consolePort/index.html" } else { "http://localhost:$serverPort/nacos/index.html" }
        Print-CompletionInfo $Global:InstallDir $consoleUrl $serverPort $consolePort $Global:Version "nacos" $Global:NACOS_PASSWORD

        if ($Global:NACOS_PASSWORD -and (Copy-PasswordToClipboard $Global:NACOS_PASSWORD)) { 
            Write-Info "✓ Password copied to clipboard!" 
        }
        Open-Browser $consoleUrl | Out-Null

        if (-not $Global:DetachMode -and $nacosPid) {
            Write-Info "Press Ctrl+C to stop Nacos"
            try { Wait-Process -Id $nacosPid } catch {}
        }
    }
}

function Run-Cluster {
    # If JoinMode or LeaveMode, delegate to cluster.ps1
    if ($Global:JoinMode -or $Global:LeaveMode) {
        Invoke-ClusterMode
        return
    }
    
    Write-Info "Nacos Cluster Installation"
    $clusterDir = Join-Path $ClusterBaseDir $Global:ClusterId
    if (Test-Path $clusterDir) {
        $shouldRemove = $false
        if ($Global:CleanMode) {
            Write-Warn "Cleaning existing cluster..."
            $shouldRemove = $true
        } else {
            Write-Warn "Removing existing cluster at $clusterDir"
            $shouldRemove = $true
        }

        if ($shouldRemove) {
            $lockingProcs = Get-BlockingProcesses $clusterDir
            if ($lockingProcs) {
                Write-Warn "Found processes running from or using this directory:"
                foreach ($p in $lockingProcs) {
                    Write-Warn "  PID: $($p.ProcessId) - $($p.Name)"
                }

                if ($Global:AllowKill) {
                    Write-Info "Kill mode is enabled. Stopping processes..."
                    foreach ($p in $lockingProcs) {
                        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    Start-Sleep -Seconds 2
                } else {
                    Write-ErrorMsg "Directory is in use. Use --kill to force remove, or stop processes manually."
                    exit 1
                }
            }
            try {
                Remove-Item -Recurse -Force $clusterDir -ErrorAction Stop
            } catch {
                Write-ErrorMsg "Failed to remove directory: $_"
                exit 1
            }
        }
    }
    Ensure-Directory $clusterDir

    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) { exit 1 }

    $zip = Download-Nacos $Global:Version
    Configure-Cluster-Security $clusterDir $Global:AdvancedMode

    $ds = Load-GlobalDatasourceConfig
    $useDerby = -not $ds

    $nodeMain = @()
    $nodeConsole = @()

    $ports = Allocate-ClusterPorts $Global:BasePort $Global:ReplicaCount $Global:Version
    foreach ($pair in $ports) {
        $parts = $pair.Split(':')
        $nodeMain += [int]$parts[0]
        $nodeConsole += [int]$parts[1]
    }

    $localIp = Get-LocalIp
    for ($i=0; $i -lt $Global:ReplicaCount; $i++) {
        $nodeName = "$i-v$($Global:Version)"
        $nodeDir = Join-Path $clusterDir $nodeName

        if (-not (Test-Path $nodeDir)) {
            $tempDir = Extract-NacosToTemp $zip
            Install-Nacos $tempDir $nodeDir | Out-Null
            Cleanup-TempDir (Split-Path $tempDir -Parent)
        }

        $nodeClusterConf = Join-Path $nodeDir "conf\cluster.conf"
        @() | Set-Content -Path $nodeClusterConf -Encoding UTF8
        for ($j=0; $j -le $i; $j++) {
            $port = $nodeMain[$j]
            Add-Content -Path $nodeClusterConf -Value "${localIp}:$port"
        }

        $configFile = Join-Path $nodeDir "conf\application.properties"
        Update-PortConfig $configFile $nodeMain[$i] $nodeConsole[$i] $Global:Version
        Apply-SecurityConfig $configFile $Global:TOKEN_SECRET $Global:IDENTITY_KEY $Global:IDENTITY_VALUE
        if ($ds) { Apply-DatasourceConfig $configFile $ds | Out-Null } elseif ($useDerby) { Configure-Derby-For-Cluster $configFile }
    }

    if ($Global:AutoStart) {
        Write-Info "Starting cluster nodes (sequential start)..."
        Write-Host ""
        
        $pids = @()
        for ($i=0; $i -lt $Global:ReplicaCount; $i++) {
            $nodeDir = Join-Path $clusterDir "$i-v$($Global:Version)"
            $nacosPid = Start-NacosProcess $nodeDir "cluster" $useDerby
            if ($nacosPid) {
                if ($nacosPid -is [array]) {
                    Write-Info "Node $i started (Wrapper PID: $($nacosPid[0]), Java PID: $($nacosPid[1]))"
                    $pids += $nacosPid[1]
                    $Global:StartedPids += $nacosPid[1]
                } else {
                    Write-Info "Node $i started (PID: $nacosPid)"
                    $pids += $nacosPid
                    $Global:StartedPids += $nacosPid
                }
            }

            if (Wait-ForNacosReady $nodeMain[$i] $nodeConsole[$i] $Global:Version 60) {
                Write-Info "Node $i ready"
            }

            if ($i -gt 0) {
                Write-Info "Updating cluster.conf in previous nodes to include node $i..."
                for ($j=0; $j -lt $i; $j++) {
                    $prevConf = Join-Path $clusterDir "$j-v$($Global:Version)\conf\cluster.conf"
                    if (Test-Path $prevConf) {
                        $port = $nodeMain[$i]
                        Add-Content -Path $prevConf -Value "${localIp}:$port"
                    }
                }
            }
        }

        Write-Host ""
        Write-Info "All nodes started successfully!"
        
        if ($Global:NACOS_PASSWORD -and $Global:NACOS_PASSWORD -ne "nacos") {
            Write-Info "Initializing admin password..."
            if (Initialize-AdminPassword $nodeMain[0] $nodeConsole[0] $Global:Version $Global:NACOS_PASSWORD) {
                Write-Info "Admin password initialized successfully"
            } else {
                Write-Warn "Password initialization failed"
            }
        }

        $consoleUrl = Print-ClusterCompletionInfo $clusterDir $Global:ClusterId $nodeMain $nodeConsole $Global:Version "nacos" $Global:NACOS_PASSWORD $Global:TOKEN_SECRET $Global:IDENTITY_KEY $Global:IDENTITY_VALUE
        
        if ($Global:NACOS_PASSWORD -and (Copy-PasswordToClipboard $Global:NACOS_PASSWORD)) { 
            Write-Info "✓ Password copied to clipboard!" 
        }
        Open-Browser $consoleUrl | Out-Null

        if (-not $Global:DetachMode -and $pids.Count -gt 0) {
            Write-Info "Press Ctrl+C to stop cluster"
            foreach ($p in $pids) {
                try { Wait-Process -Id $p } catch {}
            }
        }
    }
}

try {
    Parse-Arguments $args

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
                    $env:DEFAULT_DATASOURCE_CONFIG = $Global:DbConfFile
                }
                # Continue to normal installation flow (will init version below)
            }
        }
    }

    # Initialize version (fetch from remote only if user didn't specify -v)
    Initialize-Version
    Write-Host ""

    # Print external datasource mode info if enabled
    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        Write-Info "External datasource mode enabled: $Global:DefaultDatasourceConfig"
    }

    Validate-Arguments

    switch ($Global:Mode) {
        "standalone" { Run-Standalone }
        "cluster" { Run-Cluster }
        default { Write-ErrorMsg "Unknown mode: $Global:Mode"; exit 1 }
    }
} finally {
    try { Invoke-NacosSetupCleanup } catch {}
}
