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

# Security configuration (set by New-StandaloneSecurity)
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
    
    # Stop Nacos if running
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

# Register cleanup trap
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-StandaloneCleanup }

# ============================================================================
# Main Standalone Installation
# ============================================================================

function Invoke-StandaloneMode {
    Write-Info "Nacos Standalone Installation"
    Write-Info "===================================="
    Write-Host ""
    
    # Set installation directory (append version if using default)
    if (-not $Global:InstallDir -or $Global:InstallDir -eq $Global:DefaultInstallDir) {
        $Global:InstallDir = Join-Path $Global:DefaultInstallDir "standalone\nacos-$($Global:Version)"
    }
    
    Write-Info "Target Nacos version: $($Global:Version)"
    Write-Info "Installation directory: $($Global:InstallDir)"
    Write-Host ""
    
    # Check Java requirements
    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) {
        Invoke-StandaloneCleanup 1
    }
    Write-Host ""
    
    # Download Nacos
    $zipFile = Get-NacosZip $Global:Version
    if (-not $zipFile) {
        Write-ErrorMsg "Failed to download Nacos"
        Invoke-StandaloneCleanup 1
    }
    Write-Host ""
    
    # Extract to temp directory
    $extractedDir = New-TempExtraction $zipFile
    if (-not $extractedDir) {
        Write-ErrorMsg "Failed to extract Nacos"
        Invoke-StandaloneCleanup 1
    }
    
    # Install to target directory
    if (-not (Install-Nacos $extractedDir $Global:InstallDir)) {
        Write-ErrorMsg "Failed to install Nacos"
        Remove-Item -Path (Split-Path $extractedDir) -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-StandaloneCleanup 1
    }
    
    # Cleanup temp directory
    Cleanup-TempDir (Split-Path $extractedDir)
    Write-Host ""
    
    # Configure Nacos
    Write-Info "Configuring Nacos..."
    $configFile = Join-Path $Global:InstallDir "conf\application.properties"
    
    # Allocate ports
    $portResult = Get-StandalonePorts $Global:Port $Global:Version $Global:AdvancedMode $Global:AllowKill
    if (-not $portResult) {
        Write-ErrorMsg "Failed to allocate ports"
        Invoke-StandaloneCleanup 1
    }
    
    $Global:ServerPort, $Global:ConsolePort = $portResult
    Write-Host ""
    
    # Update port configuration
    Update-PortConfig $configFile $Global:ServerPort $Global:ConsolePort $Global:Version
    Write-Info "Ports configured: Server=$($Global:ServerPort), Console=$($Global:ConsolePort)"
    
    # Configure security
    New-StandaloneSecurity $configFile $Global:AdvancedMode
    
    # Load and apply datasource configuration only if explicitly specified via -db-conf
    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        $datasourceFile = Load-DefaultDatasourceConfig
        if ($datasourceFile) {
            Write-Info "Applying external datasource configuration..."
            Apply-DatasourceConfig $configFile $datasourceFile
            Write-Info "External database configured"
        } else {
            Write-ErrorMsg "External datasource specified but configuration not found at: $Global:DefaultDatasourceConfig"
            Write-Host ""
            Write-Info "To create the configuration, run:"
            Write-Info "  nacos-setup db-conf edit $Global:DefaultDatasourceConfig"
            exit 1
        }
    } else {
        Write-Info "Using embedded Derby database"
        Write-Info "Tip: Run 'nacos-setup -db-conf' to use external datasource"
    }
    
    Remove-Item "$configFile.bak" -ErrorAction SilentlyContinue
    Write-Info "Configuration completed"
    Write-Host ""

    Write-Info "Post-config: importing default agentspec / skill data into $($Global:InstallDir)\data..."
    Invoke-PostNacosConfigDataImportHook $Global:InstallDir
    Write-Host ""

    # skill-scanner post-config hook
    if (Get-Command Invoke-PostNacosConfigSkillScannerHook -ErrorAction SilentlyContinue) {
        Invoke-PostNacosConfigSkillScannerHook $Global:Version
        if (Get-Command Test-ShouldWriteSkillScannerPluginConfig -ErrorAction SilentlyContinue) {
            if (Test-ShouldWriteSkillScannerPluginConfig $Global:Version) {
                if (Get-Command Set-SkillScannerProperties -ErrorAction SilentlyContinue) {
                    Set-SkillScannerProperties $configFile
                }
            }
        }
        Write-Host ""
    }

    # Start Nacos if auto-start is enabled
    if ($Global:AutoStart) {
        Write-Info "Starting Nacos in standalone mode..."
        Write-Host ""
        
        # Record start time
        $startTime = Get-Date
        
        $nacosPid = Start-NacosProcess $Global:InstallDir "standalone" $false
        if (-not $nacosPid) {
            Write-Warn "Could not determine Nacos PID"
        } else {
            $Global:StartedNacosPid = $nacosPid
            Write-Info "Nacos started with PID: $($Global:StartedNacosPid)"
        }
        Write-Host ""
        
        # Wait for readiness and initialize password
        if (Wait-ForNacosReady $Global:ServerPort $Global:ConsolePort $Global:Version 60) {
            $endTime = Get-Date
            $elapsed = [int]($endTime - $startTime).TotalSeconds
            Write-Info "Nacos is ready in ${elapsed}s!"
            Write-Host ""
            
            if ($Global:NacosPassword -and $Global:NacosPassword -ne "nacos") {
                Write-Info "Initializing admin password..."
                if (Initialize-AdminPassword $Global:ServerPort $Global:ConsolePort $Global:Version $Global:NacosPassword) {
                    Write-Info "Admin password initialized successfully"
                    Write-Host ""
                    Write-Info "Auto-Generated Admin Password:"
                    Write-Host "  $($Global:NacosPassword)"
                    Write-Host ""
                } else {
                    Write-Warn "Password initialization failed (may already be set previously)"
                    # Clear password so it won't be shown in completion info
                    $Global:NacosPassword = $null
                }
            }
        } else {
            Write-Warn "Nacos may still be starting, please wait a moment"
        }
        
        # Print completion info
        $nacosMajor = $Global:Version.Split('.')[0]
        $consoleUrl = if ($nacosMajor -ge 3) {
            "http://localhost:$($Global:ConsolePort)"
        } else {
            "http://localhost:$($Global:ServerPort)/nacos"
        }
        
        Show-CompletionInfo $Global:InstallDir $consoleUrl $Global:ServerPort $Global:ConsolePort $Global:Version "nacos" $Global:NacosPassword
        
        # Handle daemon or monitoring mode
        if ($Global:DaemonMode) {
            Write-Host ""
            Write-Info "Daemon mode: Script will exit now"
            Write-Info "Nacos is running with PID: $($Global:StartedNacosPid)"
            Write-Info "To stop Nacos, run: Stop-Process -Id $($Global:StartedNacosPid) -Force"
            Write-Host ""
            
            $Global:CleanupDone = $true
            exit 0
        } else {
            Write-Host ""
            Write-Info "Script will keep running. Press Ctrl+C to stop and cleanup Nacos."
            Write-Info "Nacos is running with PID: $($Global:StartedNacosPid)"
            Write-Host ""
            
            # Monitor process
            if ($Global:StartedNacosPid) {
                while (Get-Process -Id $Global:StartedNacosPid -ErrorAction SilentlyContinue) {
                    Start-Sleep -Seconds 5
                }
                
                Write-Warn "Nacos process terminated unexpectedly"
                $Global:StartedNacosPid = $null
            }
        }
    } else {
        Write-Info "Installation completed (auto-start disabled)"
        Write-Info "To start manually, run:"
        Write-Info "  cd $($Global:InstallDir)"
        Write-Info "  .\bin\startup.cmd"
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
