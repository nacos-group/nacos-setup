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

# Cluster Mode Implementation
# Main logic for Nacos cluster management

# Load dependencies
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptPath\common.ps1"
. "$scriptPath\port_manager.ps1"
. "$scriptPath\download.ps1"
. "$scriptPath\config_manager.ps1"
. "$scriptPath\java_manager.ps1"
. "$scriptPath\process_manager.ps1"

# ============================================================================
# Global Variables
# ============================================================================

$Global:StartedPids = @()
$Global:CleanupClusterDir = ""
$Global:CleanupDone = $false

# Security configuration (shared across cluster)
$Global:TokenSecret = ""
$Global:IdentityKey = ""
$Global:IdentityValue = ""
$Global:NacosPassword = ""

# ============================================================================
# Cleanup Handler
# ============================================================================

function Invoke-ClusterCleanup {
    param([int]$ExitCode = 0)
    
    if ($Global:CleanupDone) { return }
    $Global:CleanupDone = $true
    
    # Skip cleanup in daemon mode
    if ($Global:DaemonMode) { exit $ExitCode }
    
    # Stop all started processes
    if ($Global:StartedPids.Count -gt 0) {
        Write-Host ""
        Write-Info "Stopping cluster nodes..."
        
        $stoppedPids = @()
        foreach ($p in $Global:StartedPids) {
            Write-Info "Terminating node PID: $p"
            try { 
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue 
                $stoppedPids += $p
            } catch {}
            try { cmd /c "taskkill /F /PID $p /T >NUL 2>&1" } catch {}
        }
    }
    
    exit $ExitCode
}

# Register cleanup trap
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-ClusterCleanup }

# ============================================================================
# Node Startup
# ============================================================================

function Start-ClusterNode {
    param(
        [string]$NodeDir,
        [string]$NodeName,
        [int]$MainPort,
        [int]$ConsolePort,
        [string]$NacosVersion,
        [bool]$UseDerby
    )
    
    $startTime = Get-Date
    
    # Check port availability
    if (-not (Test-PortAvailable $MainPort)) {
        Write-ErrorMsg "Port $MainPort is already in use"
        return $null
    }
    
    $nacosMajor = $NacosVersion.Split('.')[0]
    if ($nacosMajor -ge 3) {
        if (-not (Test-PortAvailable $ConsolePort)) {
            Write-ErrorMsg "Console port $ConsolePort is already in use"
            return $null
        }
    }
    
    # Start the node
    $nacosPid = Start-NacosProcess $NodeDir "cluster" $UseDerby
    
    if (-not $nacosPid) {
        Write-ErrorMsg "Failed to start node $NodeName"
        return $null
    }
    
    # Wait for readiness
    if (Wait-ForNacosReady $MainPort $ConsolePort $NacosVersion 60) {
        $endTime = Get-Date
        $elapsed = ($endTime - $startTime).TotalSeconds
        Write-Info "Node $NodeName ready (PID: $nacosPid, $([int]$elapsed)s)"
        return $nacosPid
    } else {
        Write-ErrorMsg "Node $NodeName startup timeout"
        if (Get-Process -Id $nacosPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $nacosPid -Force -ErrorAction SilentlyContinue
        }
        return $null
    }
}

# ============================================================================
# Cluster Creation
# ============================================================================

function New-Cluster {
    Write-Info "Nacos Cluster Installation"
    Write-Info "===================================="
    Write-Host ""
    
    $clusterDir = Join-Path $Global:ClusterBaseDir $Global:ClusterId
    $Global:CleanupClusterDir = $clusterDir
    
    # Check if cluster exists
    if (Test-Path $clusterDir) {
        $existingNodes = Get-ChildItem -Path $clusterDir -Directory -Filter "*-v*" -ErrorAction SilentlyContinue
        if ($existingNodes.Count -gt 0) {
            if ($Global:CleanMode) {
                Write-Warn "Cleaning existing cluster..."
                Remove-ExistingCluster $clusterDir
            } else {
                Write-ErrorMsg "Cluster '$($Global:ClusterId)' already exists"
                Write-Info "Use --clean flag to recreate"
                Invoke-ClusterCleanup 1
            }
        }
    }
    
    Ensure-Directory $clusterDir
    
    Write-Info "Cluster ID: $($Global:ClusterId)"
    Write-Info "Nacos version: $($Global:Version)"
    Write-Info "Replica count: $($Global:ReplicaCount)"
    Write-Info "Cluster directory: $clusterDir"
    Write-Host ""
    
    # Check Java
    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) {
        Invoke-ClusterCleanup 1
    }
    Write-Host ""
    
    # Download Nacos
    $zipFile = Download-Nacos $Global:Version
    if (-not $zipFile) {
        Invoke-ClusterCleanup 1
    }
    Write-Host ""
    
    # Configure cluster security
    Configure-Cluster-Security $clusterDir $Global:AdvancedMode
    
    # Check datasource (only if explicitly specified via -db-conf)
    $useDerby = $true
    
    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        $datasourceFile = Load-DefaultDatasourceConfig
        if ($datasourceFile) {
            Write-Info "Using external database"
            $useDerby = $false
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
    Write-Host ""
    
    # Allocate ports for all nodes
    Write-Info "Allocating ports for $($Global:ReplicaCount) nodes..."
    $portResult = Allocate-ClusterPorts $Global:BasePort $Global:ReplicaCount $Global:Version
    
    if (-not $portResult) {
        Write-ErrorMsg "Failed to allocate ports"
        Invoke-ClusterCleanup 1
    }
    
    # Parse port allocations
    $nodeMainPorts = @()
    $nodeConsolePorts = @()
    
    foreach ($portPair in $portResult) {
        $ports = $portPair.Split(':')
        $nodeMainPorts += [int]$ports[0]
        $nodeConsolePorts += [int]$ports[1]
    }
    Write-Host ""
    
    # Prepare cluster metadata
    $clusterConf = Join-Path $clusterDir "cluster.conf"
    $localIp = Get-LocalIp
    Write-Info "Local IP: $localIp"
    Write-Host ""
    
    # Extract and configure all nodes first
    Write-Info "Setting up cluster nodes..."
    Write-Host ""
    
    for ($i = 0; $i -lt $Global:ReplicaCount; $i++) {
        $nodeName = "$i-v$($Global:Version)"
        $nodeDir = Join-Path $clusterDir $nodeName
        
        Write-Info "Configuring node $i..."
        
        $tempDir = Extract-NacosToTemp $zipFile
        if (-not $tempDir) {
            Write-ErrorMsg "Failed to extract Nacos package"
            Invoke-ClusterCleanup 1
        }
        
        $installResult = Install-Nacos $tempDir $nodeDir
        Cleanup-TempDir (Split-Path $tempDir -Parent)
        
        if (-not $installResult) {
            Write-ErrorMsg "Failed to install node $nodeName"
            Invoke-ClusterCleanup 1
        }
        
        # Create incremental cluster.conf for each node
        $nodeClusterConf = Join-Path $nodeDir "conf\cluster.conf"
        "" | Out-File -FilePath $nodeClusterConf -Encoding ASCII
        
        for ($j = 0; $j -le $i; $j++) {
            Add-Content -Path $nodeClusterConf -Value "${localIp}:$($nodeMainPorts[$j])" -Encoding ASCII
        }
        
        # Configure node
        $configFile = Join-Path $nodeDir "conf\application.properties"
        if (-not (Test-Path $configFile)) {
            Write-ErrorMsg "Config file not found: $configFile"
            Invoke-ClusterCleanup 1
        }
        
        Copy-Item $configFile "$configFile.original"
        Update-PortConfig $configFile $nodeMainPorts[$i] $nodeConsolePorts[$i] $Global:Version
        Apply-SecurityConfig $configFile $Global:TokenSecret $Global:IdentityKey $Global:IdentityValue

        if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
            $datasourceFile = Load-DefaultDatasourceConfig
            if ($datasourceFile) {
                Apply-DatasourceConfig $configFile $datasourceFile
            }
        } elseif ($useDerby) {
            Configure-Derby-For-Cluster $configFile
        }
        
        Remove-Item "$configFile.bak" -ErrorAction SilentlyContinue
        
        $nacosMajor = $Global:Version.Split('.')[0]
        if ($nacosMajor -ge 3) {
            Write-Info "  ✓ Server: $($nodeMainPorts[$i]) | Console: $($nodeConsolePorts[$i]) | gRPC: $($nodeMainPorts[$i]+1000),$($nodeMainPorts[$i]+1001) | Raft: $($nodeMainPorts[$i]-1000)"
        } else {
            Write-Info "  ✓ Server: $($nodeMainPorts[$i]) | gRPC: $($nodeMainPorts[$i]+1000),$($nodeMainPorts[$i]+1001) | Raft: $($nodeMainPorts[$i]-1000)"
        }
    }
    Write-Host ""
    
    # Create master cluster.conf
    "" | Out-File -FilePath $clusterConf -Encoding ASCII
    for ($i = 0; $i -lt $nodeMainPorts.Count; $i++) {
        Add-Content -Path $clusterConf -Value "${localIp}:$($nodeMainPorts[$i])" -Encoding ASCII
    }
    
    Write-Info "Final cluster configuration:"
    Get-Content $clusterConf | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    
    # Start all nodes
    if ($Global:AutoStart) {
        Write-Info "Starting cluster nodes (sequential start)..."
        Write-Host ""
        
        for ($i = 0; $i -lt $Global:ReplicaCount; $i++) {
            $nodeName = "$i-v$($Global:Version)"
            $nodeDir = Join-Path $clusterDir $nodeName
            
            $nacosPid = Start-ClusterNode $nodeDir $nodeName $nodeMainPorts[$i] $nodeConsolePorts[$i] $Global:Version $useDerby
            
            if ($nacosPid) {
                $Global:StartedPids += $nacosPid
                
                # Update previous nodes' cluster.conf to include new node
                if ($i -gt 0) {
                    Write-Info "Updating cluster.conf in previous nodes to include node $i..."
                    for ($j = 0; $j -lt $i; $j++) {
                        $prevNodeDir = Join-Path $clusterDir "$j-v$($Global:Version)"
                        $prevClusterConf = Join-Path $prevNodeDir "conf\cluster.conf"
                        Add-Content -Path $prevClusterConf -Value "${localIp}:$($nodeMainPorts[$i])" -Encoding ASCII
                    }
                }
            } else {
                Write-ErrorMsg "Failed to start node $nodeName"
                Invoke-ClusterCleanup 1
            }
        }
        
        Write-Host ""
        Write-Info "All nodes started successfully!"
        
        # Initialize password on first node
        if ($Global:NacosPassword -and $Global:NacosPassword -ne "nacos") {
            Initialize-AdminPassword $nodeMainPorts[0] $nodeConsolePorts[0] $Global:Version $Global:NacosPassword
        }
        
        # Print cluster info
        Show-ClusterInfo $clusterDir $Global:Version $Global:ReplicaCount $nodeMainPorts $nodeConsolePorts
        
        # Handle daemon or monitoring
        if ($Global:DaemonMode) {
            Write-Info "Daemon mode: Script will exit"
            $Global:CleanupDone = $true
            exit 0
        } else {
            Write-Info "Press Ctrl+C to stop cluster"
            Write-Host ""
            
            # Monitor all nodes
            while ($true) {
                Start-Sleep -Seconds 5
                $stoppedNodes = @()
                $runningCount = 0
                
                foreach ($idx in 0..($Global:StartedPids.Count - 1)) {
                    if (Get-Process -Id $Global:StartedPids[$idx] -ErrorAction SilentlyContinue) {
                        $runningCount++
                    } else {
                        $stoppedNodes += "Node $idx (PID: $($Global:StartedPids[$idx]))"
                    }
                }
                
                if ($stoppedNodes.Count -gt 0) {
                    Write-Host ""
                    Write-Warn "Detected stopped node(s):"
                    $stoppedNodes | ForEach-Object { Write-Warn "  - $_" }
                    Write-Info "Cluster status: $runningCount/$($Global:StartedPids.Count) nodes running"
                }
                
                if ($runningCount -eq 0) {
                    Write-Host ""
                    Write-ErrorMsg "All cluster nodes have stopped"
                    break
                }
            }
        }
    } else {
        Write-Info "Cluster created (auto-start disabled)"
        Write-Info "To start nodes manually, run startup.cmd in each node directory"
    }
}

# ============================================================================
# Cluster Info Display
# ============================================================================

function Show-ClusterInfo {
    param(
        [string]$ClusterDir,
        [string]$NacosVersion,
        [int]$NodeCount,
        [array]$MainPorts,
        [array]$ConsolePorts
    )
    
    $nacosMajor = $NacosVersion.Split('.')[0]
    $localIp = Get-LocalIp
    
    Write-Host ""
    Write-Host "========================================"
    Write-Info "Cluster Started Successfully!"
    Write-Host "========================================"
    Write-Host ""
    Write-Info "Cluster ID: $($Global:ClusterId)"
    Write-Info "Nodes: $($Global:StartedPids.Count)"
    Write-Host ""
    Write-Info "Node endpoints:"
    
    for ($i = 0; $i -lt $MainPorts.Count; $i++) {
        if ($nacosMajor -ge 3) {
            Write-Host "  Node $i`: http://${localIp}:$($ConsolePorts[$i])/index.html"
        } else {
            Write-Host "  Node $i`: http://${localIp}:$($MainPorts[$i])/nacos/index.html"
        }
    }
    
    Write-Host ""
    if ($Global:NacosPassword) {
        Write-Host "Login credentials:"
        Write-Host "  Username: nacos"
        Write-Host "  Password: $($Global:NacosPassword)"
    }
    
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Perfect !"
    Write-Host "========================================"
}

# ============================================================================
# Clean Existing Cluster
# ============================================================================

function Remove-ExistingCluster {
    param([string]$ClusterDir)
    
    Write-Info "Cleaning existing cluster nodes..."
    
    $nodeDirs = Get-ChildItem -Path $ClusterDir -Directory -Filter "*-v*" -ErrorAction SilentlyContinue
    
    if ($nodeDirs.Count -eq 0) { return }
    
    # Stop all running nodes
    foreach ($nodeDir in $nodeDirs) {
        $processes = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$($nodeDir.FullName)*" }
        foreach ($proc in $processes) {
            Write-Info "Stopping $($nodeDir.Name) (PID: $($proc.Id))"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    
    Start-Sleep -Seconds 3
    
    # Remove directories
    foreach ($nodeDir in $nodeDirs) {
        Remove-Item -Path $nodeDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    Remove-Item -Path (Join-Path $ClusterDir "cluster.conf") -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $ClusterDir "share.properties") -ErrorAction SilentlyContinue
    
    Write-Info "Cleaned $($nodeDirs.Count) nodes"
    Write-Host ""
}

# ============================================================================
# Join Cluster
# ============================================================================

function Join-ClusterMode {
    Write-Info "Join Cluster Mode"
    Write-Info "===================================="
    Write-Host ""
    
    $clusterDir = Join-Path $Global:ClusterBaseDir $Global:ClusterId
    
    if (-not (Test-Path $clusterDir)) {
        Write-ErrorMsg "Cluster not found: $($Global:ClusterId)"
        Invoke-ClusterCleanup 1
    }
    
    $existingNodes = @(Get-ChildItem -Path $clusterDir -Directory -Filter "*-v*" -ErrorAction SilentlyContinue | Sort-Object Name)
    
    if ($existingNodes.Count -eq 0) {
        Write-ErrorMsg "No existing nodes found"
        Invoke-ClusterCleanup 1
    }
    
    Write-Info "Existing nodes: $($existingNodes.Count)"
    
    # Determine next node index
    $maxIndex = -1
    foreach ($node in $existingNodes) {
        $idx = [int]($node.Name -split '-' | Select-Object -First 1)
        if ($idx -gt $maxIndex) { $maxIndex = $idx }
    }
    
    $newIndex = $maxIndex + 1
    $newNodeName = "$newIndex-v$($Global:Version)"
    
    Write-Info "New node: $newNodeName"
    Write-Host ""
    
    # Check Java
    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) {
        Invoke-ClusterCleanup 1
    }
    
    # Load security configuration
    $shareProperties = Join-Path $clusterDir "share.properties"
    if (-not (Test-Path $shareProperties)) {
        Write-ErrorMsg "Security configuration not found"
        Invoke-ClusterCleanup 1
    }
    
    $props = @{}
    Get-Content $shareProperties | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $props[$matches[1]] = $matches[2]
        }
    }
    
    $Global:TokenSecret = $props["nacos.core.auth.plugin.nacos.token.secret.key"]
    $Global:IdentityKey = $props["nacos.core.auth.server.identity.key"]
    $Global:IdentityValue = $props["nacos.core.auth.server.identity.value"]
    $Global:NacosPassword = $props["admin.password"]
    
    # Download and extract
    $zipFile = Download-Nacos $Global:Version
    if (-not $zipFile) {
        Invoke-ClusterCleanup 1
    }
    
    $newNodeDir = Join-Path $clusterDir $newNodeName
    
    $tempDir = Extract-NacosToTemp $zipFile
    if (-not $tempDir) {
        Write-ErrorMsg "Failed to extract Nacos package"
        Invoke-ClusterCleanup 1
    }
    
    $installResult = Install-Nacos $tempDir $newNodeDir
    Cleanup-TempDir (Split-Path $tempDir -Parent)
    
    if (-not $installResult) {
        Write-ErrorMsg "Failed to install node $newNodeName"
        Invoke-ClusterCleanup 1
    }
    
    # Allocate ports
    $clusterConf = Get-Content (Join-Path $clusterDir "cluster.conf")
    $maxPort = 0
    $clusterConf | ForEach-Object {
        if ($_ -match ":(\d+)$") {
            $port = [int]$matches[1]
            if ($port -gt $maxPort) { $maxPort = $port }
        }
    }
    
    $newMainPort = $maxPort + 10
    $newConsolePort = 8080 + $newIndex * 10
    
    if (-not (Test-PortAvailable $newMainPort)) {
        $newMainPort = Find-AvailablePort $newMainPort
    }
    
    if (-not (Test-PortAvailable $newConsolePort)) {
        $newConsolePort = Find-AvailablePort $newConsolePort
    }
    
    Write-Info "Ports: main=$newMainPort, console=$newConsolePort"
    Write-Host ""
    
    # Update cluster.conf
    $localIp = Get-LocalIp
    Add-Content -Path (Join-Path $clusterDir "cluster.conf") -Value "${localIp}:${newMainPort}" -Encoding ASCII
    
    # Configure node
    $useDerby = $true
    
    Copy-Item (Join-Path $clusterDir "cluster.conf") (Join-Path $newNodeDir "conf\cluster.conf")
    
    $configFile = Join-Path $newNodeDir "conf\application.properties"
    if (-not (Test-Path $configFile)) {
        Write-ErrorMsg "Config file not found: $configFile"
        Invoke-ClusterCleanup 1
    }
    
    Copy-Item $configFile "$configFile.original"
    Update-PortConfig $configFile $newMainPort $newConsolePort $Global:Version
    Apply-SecurityConfig $configFile $Global:TokenSecret $Global:IdentityKey $Global:IdentityValue
    
    if ($env:USE_EXTERNAL_DATASOURCE -eq "true") {
        $datasourceFile = Load-DefaultDatasourceConfig
        if ($datasourceFile) {
            Apply-DatasourceConfig $configFile $datasourceFile
            $useDerby = $false
        }
    }
    
    if ($useDerby) {
        Configure-Derby-For-Cluster $configFile
    }
    
    Remove-Item "$configFile.bak" -ErrorAction SilentlyContinue
    Write-Info "Node configured: main=$newMainPort, console=$newConsolePort"
    Write-Host ""
    
    # Update cluster.conf in existing nodes
    Write-Info "Updating cluster.conf in existing nodes..."
    foreach ($existingNode in $existingNodes) {
        Copy-Item (Join-Path $clusterDir "cluster.conf") (Join-Path $clusterDir $existingNode.Name "conf\cluster.conf")
    }
    Write-Host ""
    
    # Start new node
    if ($Global:AutoStart) {
        $nacosPid = Start-ClusterNode $newNodeDir $newNodeName $newMainPort $newConsolePort $Global:Version $useDerby
        
        if ($nacosPid) {
            Write-Info "Node joined successfully!"
            
            if ($Global:DaemonMode) {
                Write-Info "Daemon mode: Script will exit"
                $Global:CleanupDone = $true
                exit 0
            } else {
                Write-Info "Press Ctrl+C to stop node"
                while (Get-Process -Id $nacosPid -ErrorAction SilentlyContinue) {
                    Start-Sleep -Seconds 5
                }
            }
        } else {
            Write-ErrorMsg "Failed to start new node"
            Invoke-ClusterCleanup 1
        }
    }
}

# ============================================================================
# Leave Cluster
# ============================================================================

function Leave-ClusterMode {
    Write-Info "Leave Cluster Mode"
    Write-Info "===================================="
    Write-Host ""
    
    $clusterDir = Join-Path $Global:ClusterBaseDir $Global:ClusterId
    
    if (-not (Test-Path $clusterDir)) {
        Write-ErrorMsg "Cluster not found: $($Global:ClusterId)"
        exit 1
    }
    
    $existingNodes = @(Get-ChildItem -Path $clusterDir -Directory -Filter "*-v*" -ErrorAction SilentlyContinue | Sort-Object Name)
    $targetNode = $null
    
    foreach ($node in $existingNodes) {
        $idx = [int]($node.Name -split '-' | Select-Object -First 1)
        if ($idx -eq $Global:NodeIndex) {
            $targetNode = $node
            break
        }
    }
    
    if (-not $targetNode) {
        Write-ErrorMsg "Node $($Global:NodeIndex) not found"
        exit 1
    }
    
    $targetNodeDir = $targetNode.FullName
    
    Write-Info "Removing node: $($targetNode.Name)"
    
    # Get node port
    $nodeConfig = Join-Path $targetNodeDir "conf\application.properties"
    $nodePort = $null
    
    Get-Content $nodeConfig | ForEach-Object {
        if ($_ -match "^nacos.server.main.port=(\d+)") {
            $nodePort = [int]$matches[1]
        } elseif ($_ -match "^server.port=(\d+)" -and -not $nodePort) {
            $nodePort = [int]$matches[1]
        }
    }
    
    # Update cluster.conf (remove this node)
    if ($nodePort) {
        $clusterConfPath = Join-Path $clusterDir "cluster.conf"
        $content = Get-Content $clusterConfPath | Where-Object { $_ -notmatch ":${nodePort}$" }
        $content | Out-File -FilePath $clusterConfPath -Encoding ASCII
        
        # Update all remaining nodes
        foreach ($existingNode in $existingNodes) {
            if ($existingNode.Name -ne $targetNode.Name) {
                Copy-Item $clusterConfPath (Join-Path $clusterDir $existingNode.Name "conf\cluster.conf")
            }
        }
    }
    
    # Stop node
    $processes = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$targetNodeDir*" }
    foreach ($proc in $processes) {
        Write-Info "Stopping node (PID: $($proc.Id))"
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    
    # Remove directory
    Remove-Item -Path $targetNodeDir -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Info "Node removed successfully"
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Invoke-ClusterMode {
    if ($Global:JoinMode) {
        Join-ClusterMode
    } elseif ($Global:LeaveMode) {
        Leave-ClusterMode
    } else {
        New-Cluster
    }
}
