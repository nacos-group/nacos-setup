# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Standalone Mode Implementation
# Main logic for single Nacos instance installation

# Load dependencies
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptPath\common.ps1"
. "$scriptPath\port_manager.ps1"
. "$scriptPath\download.ps1"
. "$scriptPath\config_manager.ps1"
. "$scriptPath\java_manager.ps1"
. "$scriptPath\process_manager.ps1"
. "$scriptPath\data_import.ps1"
$_ssLib = Join-Path $scriptPath "skill_scanner_install.ps1"
if (Test-Path $_ssLib) { . $_ssLib }

# ============================================================================
# Global Variables for Standalone Mode
# ============================================================================

$Global:StartedNacosPid = $null
$Global:CleanupDone = $false

# Security configuration (set by Configure-Standalone-Security)
$Global:TokenSecret = ""
$Global:IdentityKey = ""
$Global:IdentityValue = ""
$Global:NacosPassword = ""

# ============================================================================
# Cleanup Handler
# ============================================================================

function Invoke-StandaloneCleanup {
    param([int]$ExitCode = 0)
    
    if ($Global:CleanupDone) { return }
    $Global:CleanupDone = $true
    
    # Skip cleanup in daemon mode
    if ($Global:DaemonMode) { exit $ExitCode }
    
    # Stop Nacos if running (StartedNacosPid is the Java / primary PID)
    if ($Global:StartedNacosPid -and (Get-Process -Id $Global:StartedNacosPid -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Info "Cleaning up: Stopping Nacos (PID: $($Global:StartedNacosPid))..."
        
        if (Stop-NacosGracefully $Global:StartedNacosPid) {
            Write-Info "Nacos stopped successfully"
        } else {
            Write-Warn "Failed to stop Nacos gracefully"
        }
        
        Write-Host ""
        Write-Info "Tip: Use --daemon flag to run Nacos in background without auto-cleanup"
    }
    
    exit $ExitCode
}

# Do not register PowerShell.Exiting here: this library is dot-sourced by nacos-setup.ps1,
# and calling exit from an Exiting subscriber can terminate the host abruptly. Host cleanup
# is handled by nacos-setup.ps1 (try/finally + its own Exiting handler).

# ============================================================================
# Main Standalone Installation
# ============================================================================

function Get-NacosSetupJavaStepSummary {
    try {
        $j = Get-Command java -ErrorAction SilentlyContinue
        if (-not $j) {
            if ($env:JAVA_HOME) { return "JAVA_HOME=$($env:JAVA_HOME)" }
            return "OK"
        }
        $line = (& java -version 2>&1 | Select-Object -First 1)
        if ($line) { return ([string]$line).Trim() }
    } catch {}
    if ($env:JAVA_HOME) { return "JAVA_HOME=$($env:JAVA_HOME)" }
    return "OK"
}

function Register-StandaloneNacosPid($nacosPid) {
    $primary = $nacosPid
    if ($nacosPid -is [array]) {
        $primary = $nacosPid[1]
        Write-Detail "Nacos started (Wrapper PID: $($nacosPid[0]), Java PID: $($nacosPid[1]))"
    } else {
        Write-Detail "Nacos started with PID: $nacosPid"
    }
    $Global:StartedNacosPid = $primary
    if ($null -eq $Global:StartedPids) { $Global:StartedPids = @() }
    if ($primary -and $Global:StartedPids -notcontains $primary) {
        $Global:StartedPids += $primary
    }
}

function Invoke-StandaloneMode {
    $TOTAL_STEPS = 7
    $verLabel = if ($Global:NacosSetupVersion) { $Global:NacosSetupVersion } else { "dev" }

    if (Test-NacosSetupVerbose) {
        Write-Info "Nacos Standalone Installation"
        Write-Info "===================================="
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "Nacos Standalone Setup (v$verLabel)"
        Write-Host "======================================"
        Write-Host ""
    }

    if (-not $Global:InstallDir -or $Global:InstallDir -eq $Global:DefaultInstallDir) {
        $Global:InstallDir = Join-Path $Global:DefaultInstallDir "standalone\nacos-$($Global:Version)"
    }

    Write-Detail "Target Nacos version: $($Global:Version)"
    Write-Detail "Installation directory: $($Global:InstallDir)"
    if (Test-NacosSetupVerbose) { Write-Host "" }

    if (Test-Path $Global:InstallDir) {
        Write-Warn "Removing existing installation at $($Global:InstallDir)"
        $lockingProcs = Get-BlockingProcesses $Global:InstallDir
        if ($lockingProcs) {
            Write-Warn "Found processes running from or using this directory:"
            foreach ($p in $lockingProcs) { Write-Warn "  PID: $($p.ProcessId) - $($p.Name)" }
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

    # [1/7] Java
    Start-NacosSetupStepProgress 1 $TOTAL_STEPS "Checking Java environment"
    if (-not (Invoke-JavaGateForNacosInstall $Global:Version $Global:AdvancedMode)) {
        Stop-NacosSetupStepProgress
        Write-NacosSetupStepFail 1 $TOTAL_STEPS "Checking Java environment"
        Invoke-StandaloneCleanup 1
    }
    Stop-NacosSetupStepProgress
    Write-NacosSetupStepOk 1 $TOTAL_STEPS "Checking Java environment" (Get-NacosSetupJavaStepSummary)

    # [2/7] Download
    Start-NacosSetupStepProgress 2 $TOTAL_STEPS "Downloading Nacos $($Global:Version)"
    $zipFile = Download-Nacos $Global:Version
    if (-not $zipFile) {
        Stop-NacosSetupStepProgress
        Write-NacosSetupStepFail 2 $TOTAL_STEPS "Downloading Nacos $($Global:Version)"
        Invoke-StandaloneCleanup 1
    }
    Stop-NacosSetupStepProgress
    Write-NacosSetupStepOk 2 $TOTAL_STEPS "Downloading Nacos $($Global:Version)"

    # [3/7] Install (extract + move)
    Start-NacosSetupStepProgress 3 $TOTAL_STEPS "Installing"
    try {
        $extractedDir = Extract-NacosToTemp $zipFile
    } catch {
        Stop-NacosSetupStepProgress
        Write-NacosSetupStepFail 3 $TOTAL_STEPS "Installing"
        Write-ErrorMsg $_.Exception.Message
        Invoke-StandaloneCleanup 1
    }
    if (-not (Install-Nacos $extractedDir $Global:InstallDir)) {
        Stop-NacosSetupStepProgress
        Write-NacosSetupStepFail 3 $TOTAL_STEPS "Installing"
        Cleanup-TempDir (Split-Path $extractedDir -Parent)
        Invoke-StandaloneCleanup 1
    }
    Cleanup-TempDir (Split-Path $extractedDir -Parent)
    Stop-NacosSetupStepProgress
    Write-NacosSetupStepOk 3 $TOTAL_STEPS "Installing" $Global:InstallDir

    # [4/7] Configure
    Start-NacosSetupStepProgress 4 $TOTAL_STEPS "Configuring"
    Write-Detail "Configuring Nacos..."
    $configFile = Join-Path $Global:InstallDir "conf\application.properties"

    $portTuple = Allocate-StandalonePorts $Global:Port $Global:Version $Global:AdvancedMode $Global:AllowKill
    if (-not $portTuple) {
        Stop-NacosSetupStepProgress
        Write-NacosSetupStepFail 4 $TOTAL_STEPS "Configuring"
        Invoke-StandaloneCleanup 1
    }
    $Global:ServerPort, $Global:ConsolePort = $portTuple

    Update-PortConfig $configFile $Global:ServerPort $Global:ConsolePort $Global:Version
    Write-Detail "Ports configured: Server=$($Global:ServerPort), Console=$($Global:ConsolePort)"

    Configure-Standalone-Security $configFile $Global:AdvancedMode
    $Global:NacosPassword = $Global:NACOS_PASSWORD

    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        $datasourceFile = Load-DefaultDatasourceConfig
        if ($datasourceFile) {
            Write-Detail "Applying external datasource configuration..."
            Apply-DatasourceConfig $configFile $datasourceFile
            Write-Detail "External database configured"
        } else {
            Stop-NacosSetupStepProgress
            Write-NacosSetupStepFail 4 $TOTAL_STEPS "Configuring"
            Write-ErrorMsg "External datasource specified but configuration not found at: $Global:DefaultDatasourceConfig"
            Write-Host ""
            Write-Info "To create the configuration, run:"
            Write-Info "  nacos-setup db-conf edit default"
            exit 1
        }
    } else {
        Write-Detail "Using embedded Derby database"
    }

    Remove-Item "$configFile.bak" -ErrorAction SilentlyContinue
    Stop-NacosSetupStepProgress
    Write-NacosSetupStepOk 4 $TOTAL_STEPS "Configuring" "port=$($Global:ServerPort) console=$($Global:ConsolePort)"

    # [5/7] Default data import
    Start-NacosSetupStepProgress 5 $TOTAL_STEPS "Importing default data"
    Write-Detail "Post-config: importing default agentspec / skill data into $($Global:InstallDir)\data..."
    if (Get-Command Invoke-PostNacosConfigDataImportHook -ErrorAction SilentlyContinue) {
        Invoke-PostNacosConfigDataImportHook $Global:InstallDir
    } else {
        Write-Detail "Default data import hook not available, skipping"
    }
    Stop-NacosSetupStepProgress
    Write-NacosSetupStepOk 5 $TOTAL_STEPS "Importing default data"

    # [6/7] Skill-scanner (interactive; no Write-Progress over prompts)
    Stop-NacosSetupStepProgress
    if (-not (Test-NacosSetupVerbose)) {
        Write-Host "[6/${TOTAL_STEPS}] Setting up skill-scanner" -ForegroundColor Green
    }
    Write-Detail "Post-config: optional Cisco skill-scanner step (Nacos $($Global:Version))..."
    if (Get-Command Invoke-PostNacosConfigSkillScannerHook -ErrorAction SilentlyContinue) {
        Invoke-PostNacosConfigSkillScannerHook $Global:Version
        if (Get-Command Test-ShouldWriteSkillScannerPluginConfig -ErrorAction SilentlyContinue) {
            if (Test-ShouldWriteSkillScannerPluginConfig $Global:Version) {
                if (Get-Command Set-SkillScannerProperties -ErrorAction SilentlyContinue) {
                    Set-SkillScannerProperties $configFile
                }
            }
        }
    }
    Write-NacosSetupStepOk 6 $TOTAL_STEPS "Setting up skill-scanner"

    $nacosMajor = [int]($Global:Version.Split('.')[0])
    $consoleUrl = if ($nacosMajor -ge 3) {
        "http://localhost:$($Global:ConsolePort)"
    } else {
        "http://localhost:$($Global:ServerPort)/nacos"
    }

    # [7/7] Start
    if ($Global:AutoStart) {
        $startTime = Get-Date
        Start-NacosSetupStepProgress 7 $TOTAL_STEPS "Starting Nacos"
        Write-Detail "Starting Nacos in standalone mode..."

        $nacosPid = Start-NacosProcess $Global:InstallDir "standalone" $false
        if (-not $nacosPid) {
            Write-Warn "Could not determine Nacos PID"
        } else {
            Register-StandaloneNacosPid $nacosPid
        }

        if (Wait-ForNacosReady $Global:ServerPort $Global:ConsolePort $Global:Version 60) {
            if (-not $Global:StartedNacosPid -and (Get-Command Find-NacosProcessPid -ErrorAction SilentlyContinue)) {
                $recovered = Find-NacosProcessPid $Global:InstallDir
                if ($recovered) {
                    Register-StandaloneNacosPid $recovered
                    Write-Detail "Recovered Nacos PID after readiness: $recovered"
                }
            }
            $elapsed = [int](((Get-Date) - $startTime).TotalSeconds)
            Stop-NacosSetupStepProgress
            Write-NacosSetupStepOk 7 $TOTAL_STEPS "Starting Nacos" "ready in ${elapsed}s (PID: $($Global:StartedNacosPid))"

            if ($Global:NacosPassword -and $Global:NacosPassword -ne "nacos") {
                Write-Detail "Initializing admin password..."
                if (Initialize-AdminPassword $Global:ServerPort $Global:ConsolePort $Global:Version $Global:NacosPassword) {
                    Write-Detail "Admin password initialized successfully"
                } else {
                    Write-Warn "Password initialization failed (may already be set previously)"
                    $Global:NacosPassword = $null
                }
            }
        } else {
            Stop-NacosSetupStepProgress
            Write-NacosSetupStepOk 7 $TOTAL_STEPS "Starting Nacos" "may still be starting"
            Write-Warn "Nacos may still be starting, please wait a moment"
        }

        Show-CompletionInfo $Global:InstallDir $consoleUrl $Global:ServerPort $Global:ConsolePort $Global:Version "nacos" $Global:NacosPassword

        if ($Global:NacosPassword -and (Get-Command Copy-PasswordToClipboard -ErrorAction SilentlyContinue)) {
            if (Copy-PasswordToClipboard $Global:NacosPassword) { Write-Info "Password copied to clipboard!" }
        }
        if (Get-Command Open-Browser -ErrorAction SilentlyContinue) { Open-Browser $consoleUrl | Out-Null }

        if ($Global:DaemonMode) {
            Write-Host ""
            Write-Info "Daemon mode: Nacos running with PID: $($Global:StartedNacosPid)"
            Write-Info "To stop: Stop-Process -Id $($Global:StartedNacosPid) -Force"
            Write-Host ""
            $Global:CleanupDone = $true
            exit 0
        }

        Write-Host ""
        Write-Info "Press Ctrl+C to stop Nacos (PID: $($Global:StartedNacosPid))"
        Write-Host ""

        if ($Global:StartedNacosPid) {
            try { Wait-Process -Id $Global:StartedNacosPid -ErrorAction SilentlyContinue } catch {}
            Write-Warn "Nacos process terminated unexpectedly"
            $Global:StartedNacosPid = $null
        }
    } else {
        Write-NacosSetupStepOk 7 $TOTAL_STEPS "Starting Nacos" "skipped (--no-start)"
        Write-Host ""
        Write-Info "To start manually, run:"
        Write-Info "  cd $($Global:InstallDir)"
        Write-Info "  .\bin\startup.cmd -m standalone"
        Write-Host ""
    }
}

# ============================================================================
# Helper Functions
# ============================================================================

function Show-CompletionInfo {
    param(
        [string]$InstallDir,
        [string]$ConsoleUrl,
        [int]$ServerPort,
        [int]$ConsolePort,
        [string]$Version,
        [string]$Username,
        [string]$Password
    )
    
    Write-Host ""
    Write-Host "========================================"
    Write-Success "Nacos Installation Completed!"
    Write-Host "========================================"
    Write-Host ""
    Write-Info "Installation directory: $InstallDir"
    Write-Host ""
    Write-Info "Console URL: $ConsoleUrl"
    Write-Host ""
    
    if ($Password) {
        Write-Info "Login credentials:"
        Write-Host "  Username: $Username"
        Write-Host "  Password: $Password"
    }
    
    Write-Host ""
    Write-Host "========================================"
    Write-Success "Perfect !"
    Write-Host "========================================"
}

## ============================================================================
## Main Entry Point
## ============================================================================
