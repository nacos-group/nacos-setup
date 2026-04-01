# Process management for Windows nacos-setup
. $PSScriptRoot\common.ps1
. $PSScriptRoot\java_manager.ps1

function Find-NacosProcessPid($installDir) {
    try {
        $procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match [Regex]::Escape($installDir) -and $_.CommandLine -match "java" }
        $proc = $procs | Select-Object -First 1
        if ($proc) { return $proc.ProcessId }
    } catch {}
    return $null
}

# Align with lib/process_manager.sh stop_nacos_gracefully: graceful stop, wait, then force kill tree.
function Stop-NacosGracefully {
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        $ProcessId,
        [int]$TimeoutSeconds = 10
    )

    if ($null -eq $ProcessId) { return $true }

    $targetPid = $null
    try {
        if ($ProcessId -is [array]) {
            $ProcessId = $ProcessId | Select-Object -Last 1
        }
        $targetPid = [int]$ProcessId
    } catch {
        return $true
    }

    if ($targetPid -le 0) { return $true }

    if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        return $true
    }

    try {
        Stop-Process -Id $targetPid -ErrorAction SilentlyContinue
    } catch {}

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    try { Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue } catch {}
    try { cmd /c "taskkill /F /PID $targetPid /T >nul 2>&1" } catch {}
    Start-Sleep -Seconds 1

    return -not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)
}

function Get-BlockingProcesses($targetDir) {
    try {
        $escapedPath = [Regex]::Escape($targetDir)
        $escapedFwd = [Regex]::Escape($targetDir.Replace('\', '/'))
        return Get-CimInstance Win32_Process | Where-Object { 
            ($_.CommandLine -and ($_.CommandLine -match $escapedPath -or $_.CommandLine -match $escapedFwd)) -or
            ($_.ExecutablePath -and $_.ExecutablePath -match $escapedPath)
        }
    } catch { return @() }
}

# Stop any process whose command line or executable lives under the install dir (e.g. leftover Java after closing the console).
# Uses taskkill /T so child JVM/cmd trees are torn down together.
function Stop-ProcessesUsingInstallDir {
    param([Parameter(Mandatory = $true)][string]$InstallDir)
    if (-not (Test-Path -LiteralPath $InstallDir)) { return }

    $fullPath = (Get-Item -LiteralPath $InstallDir).FullName
    $escaped = [Regex]::Escape($fullPath)
    $escapedFwd = [Regex]::Escape($fullPath.Replace('\', '/'))

    $toKill = @()
    try {
        $toKill = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            if ($_.ExecutablePath -and ($_.ExecutablePath -match $escaped -or $_.ExecutablePath -match $escapedFwd)) { return $true }
            if (-not $_.CommandLine) { return $false }
            if ($_.CommandLine -match $escaped -or $_.CommandLine -match $escapedFwd) { return $true }
            return $false
        })
    } catch {}

    $seen = @{}
    foreach ($p in $toKill) {
        if ($seen.ContainsKey([int]$p.ProcessId)) { continue }
        $seen[[int]$p.ProcessId] = $true
        try { cmd /c "taskkill /F /PID $($p.ProcessId) /T >nul 2>&1" } catch {}
    }

    if (Get-Command Find-NacosProcessPid -ErrorAction SilentlyContinue) {
        $np = Find-NacosProcessPid $fullPath
        if ($np) {
            try { cmd /c "taskkill /F /PID $np /T >nul 2>&1" } catch {}
        }
    }

    Start-Sleep -Seconds 2
}


function Start-NacosProcess($installDir, $mode, $useDerby) {
    if (-not (Test-Path $installDir)) { throw "Install dir not found: $installDir" }
    $startup = Join-Path $installDir "bin\startup.cmd"
    if (-not (Test-Path $startup)) { throw "startup.cmd not found" }

    $javaOpts = Get-JavaRuntimeOptions
    if ($javaOpts) { $env:JAVA_OPT = $javaOpts }

    $args = @("-m", $mode)
    if ($useDerby -and $mode -eq "cluster") { $args += @("-p", "embedded") }

    # Create a wrapper to auto-answer batch prompts
    $cmdLine = "echo Y | cmd /c `"$startup`" $($args -join ' ')"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmdLine -WorkingDirectory $installDir -WindowStyle Hidden -PassThru
    $wrapperPid = $proc.Id
    Start-Sleep -Seconds 2
    $nacosPid = $null
    $retry = 0
    while ($retry -lt 10 -and -not $nacosPid) {
        Start-Sleep -Seconds 1
        $nacosPid = Find-NacosProcessPid $installDir
        $retry++
    }

    Remove-Item Env:JAVA_OPT -ErrorAction SilentlyContinue
    
    if ($nacosPid) {
        return @($wrapperPid, $nacosPid)
    }
    return $wrapperPid
}

function Wait-ForNacosReady($mainPort, $consolePort, $version, $maxWait) {
    if (-not $maxWait) { $maxWait = 60 }
    $major = [int]($version.Split('.')[0])
    $healthUrl = if ($major -ge 3) { "http://localhost:$consolePort/v3/console/health/readiness" } else { "http://localhost:$mainPort/nacos/v2/console/health/readiness" }

    $verboseWait = $false
    if (Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) { $verboseWait = Test-NacosSetupVerbose }

    # Align with bash wait_for_nacos_ready: progress line only when VERBOSE
    if ($verboseWait) {
        Write-Host -NoNewline "[INFO] Waiting for Nacos to be ready..."
    }
    for ($i = 0; $i -lt $maxWait; $i++) {
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -Method Get -TimeoutSec 5
            } else {
                $r = Invoke-WebRequest -Uri $healthUrl -Method Get -TimeoutSec 5
            }
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
                if ($verboseWait) { Write-Host " Done." -ForegroundColor Green }
                return $true
            }
        } catch {}
        if ($verboseWait) { Write-Host -NoNewline "." }
        Start-Sleep -Seconds 1
    }
    if ($verboseWait) { Write-Host " Timeout!" -ForegroundColor Red }
    return $false
}

function Initialize-AdminPassword($mainPort, $consolePort, $version, $password) {
    if (-not $password -or $password -eq "nacos") { return $true }
    $major = [int]($version.Split('.')[0])
    $apiUrl = if ($major -ge 3) { "http://localhost:$consolePort/v3/auth/user/admin" } else { "http://localhost:$mainPort/nacos/v1/auth/users/admin" }
    try {
        $body = "password=$password"
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $apiUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body
        } else {
            $resp = Invoke-WebRequest -Uri $apiUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body
        }
        return $true
    } catch { return $false }
}

function Print-CompletionInfo($installDir, $consoleUrl, $serverPort, $consolePort, $version, $username, $password) {
    $nacosMajor = [int]($version.Split('.')[0])
    $verbose = $false
    if (Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) { $verbose = Test-NacosSetupVerbose }

    Write-Host ""
    Write-Host "========================================"
    Write-Info "Nacos Started Successfully!"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "  Console URL: $consoleUrl"
    Write-Host ""
    if ($verbose) {
        Write-Host "  Installation: $installDir"
        Write-Host ""
        Write-Info "Port allocation:"
        Write-Host "  - Server Port: $serverPort"
        Write-Host "  - Client gRPC Port: $($serverPort + 1000)"
        Write-Host "  - Server gRPC Port: $($serverPort + 1001)"
        Write-Host "  - Raft Port: $($serverPort - 1000)"
        if ($nacosMajor -ge 3) { Write-Host "  - Console Port: $consolePort" }
        Write-Host ""
    }
    if ($password -and $password -ne "nacos") {
        Write-Host "Authentication is enabled. Please login with:"
        Write-Host "  Username: $username"
        Write-Host "  Password: $password"
    } elseif ($password -eq "nacos") {
        Write-Host "Default login credentials:"
        Write-Host "  Username: nacos"
        Write-Host "  Password: nacos"
        Write-Host ""
        Write-Warn "SECURITY WARNING: Using default password!"
        Write-Info "Please change the password after login for security"
    } else {
        Write-Host "Authentication is enabled."
        Write-Host "Please login with your previously set credentials."
        Write-Host ""
        Write-Info "If you forgot the password, please reset it manually"
    }
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Perfect !"
    Write-Host "========================================"
}

function Copy-PasswordToClipboard($password) {
    try {
        if ($password) {
            Set-Clipboard -Value $password
            return $true
        }
    } catch {}
    return $false
}

function Open-Browser($url) {
    try {
        Start-Process $url | Out-Null
        return $true
    } catch { return $false }
}

function Print-ClusterCompletionInfo($clusterDir, $clusterId, $nodeMain, $nodeConsole, $version, $username, $password, $tokenSecret, $identityKey, $identityValue) {
    if (-not $nodeMain) { return }
    $count = $nodeMain.Count
    $major = [int]($version.Split('.')[0])
    $localIp = Get-LocalIp

    Write-Host ""
    Write-Host "========================================"
    Write-Info "Cluster Started Successfully!"
    Write-Host "========================================"
    Write-Host ""
    Write-Info "Cluster ID: $clusterId"
    Write-Info "Nodes: $count"
    Write-Host ""
    Write-Info "Node endpoints:"
    for ($i=0; $i -lt $count; $i++) {
        $mp = $nodeMain[$i]
        $cp = $nodeConsole[$i]
        
        $url = if ($major -ge 3) { 
            "http://${localIp}:${cp}" 
        } else { 
            "http://${localIp}:${mp}/nacos" 
        }
        Write-Host "  Node ${i}: $url"
    }

    Write-Host ""
    if ($password -and $password -ne "nacos") {
        Write-Host "Login credentials:"
        Write-Host "  Username: $username"
        Write-Host "  Password: $password"
    } elseif ($password -eq "nacos") {
        Write-Host "Login credentials:"
        Write-Host "  Username: $username"
        Write-Host "  Password: $password"
        Write-Host ""
        Write-Warn "SECURITY WARNING: Using default password!"
        Write-Info "Please change the password after login for security"
    } else {
        # Password is empty - means initialization failed, password was set previously
        Write-Host "Authentication is enabled."
        Write-Host "Please login with your previously set credentials."
        Write-Host ""
        Write-Info "If you forgot the password, please reset it manually"
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Perfect !"
    Write-Host "========================================"
    
    return "http://${localIp}:$(if($major -ge 3) { $nodeConsole[0] } else { $nodeMain[0] })$(if($major -lt 3) { '/nacos' } else { '' })"
}
