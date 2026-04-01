# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0

# Optional Cisco skill-scanner (https://github.com/cisco-ai-defense/skill-scanner)
# PyPI: cisco-ai-skill-scanner — requires Python 3.10+ and uv.
# Windows-native PowerShell implementation (no WSL/bash required).
#
# Set NACOS_SETUP_SKIP_SKILL_SCANNER=1 to skip entirely.

$script:SkillScannerPypiPackage      = "cisco-ai-skill-scanner"
$script:MinNacosVersionForSkillScanner = "3.2.0"
$script:SkillScannerVenvRelPath      = "ai-infra\.venv"
$script:SkillScannerInstalled        = $false

function Write-SkillScannerTrace($msg) {
    $verbose = $false
    if (Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) {
        $verbose = Test-NacosSetupVerbose
    }
    if ($verbose -or $env:NACOS_DEBUG -eq "1") {
        Write-Host "[nacos-setup/skill-scanner] $msg" -ForegroundColor DarkGray
    }
}

# ============================================================================
# Path helpers
# ============================================================================

function Get-SkillScannerUserHome {
    if ($env:REAL_USER_PROFILE) { return $env:REAL_USER_PROFILE }
    if ($env:USERPROFILE)       { return $env:USERPROFILE }
    return "."
}

function Get-SkillScannerVenvDir {
    return Join-Path (Get-SkillScannerUserHome) $script:SkillScannerVenvRelPath
}

function Get-SkillScannerVenvPython($venvDir) {
    return Join-Path $venvDir "Scripts\python.exe"
}

function Get-SkillScannerVenvBin($venvDir) {
    return Join-Path $venvDir "Scripts"
}

function Get-SkillScannerExePath($venvDir) {
    return Join-Path $venvDir "Scripts\skill-scanner.exe"
}

function Test-SkillScannerInVenv($venvDir) {
    $exe = Get-SkillScannerExePath $venvDir
    return (Test-Path $exe)
}

function Find-SkillScannerOnPath {
    $cmd = Get-Command "skill-scanner" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ============================================================================
# uv helpers
# ============================================================================

function Normalize-UvCommandOutput($output) {
    if ($null -eq $output) { return '' }
    $lines = foreach ($x in @($output)) {
        if ($x -is [System.Management.Automation.ErrorRecord]) {
            $m = $x.Exception.Message
            if ($m) { $m.Trim() }
        } elseif ($null -ne $x) {
            ([string]$x).Trim()
        }
    }
    $lines = @($lines | Where-Object { $_ })
    if ($lines.Count -eq 0) { return '' }
    foreach ($line in $lines) {
        if ($line -match '^[A-Za-z]:\\' -or $line -match '^\\\\' -or $line -match '\\[^\\]+\.(exe|EXE)$') {
            return $line
        }
    }
    return [string]$lines[0]
}

# Run uv without stderr/progress tripping nacos-setup.ps1's $ErrorActionPreference = Stop.
function Invoke-NacosUv {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$SuppressStreams
    )
    $prevEap = $ErrorActionPreference
    $hadNativePref = $false
    $prevNative = $false
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $hadNativePref = Test-Path variable:global:PSNativeCommandUseErrorActionPreference
        if ($hadNativePref) { $prevNative = $Global:PSNativeCommandUseErrorActionPreference }
        $Global:PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $ErrorActionPreference = 'Continue'
        if (-not ((Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) -and (Test-NacosSetupVerbose))) {
            $env:UV_NO_PROGRESS = '1'
        }
        if ($SuppressStreams) {
            & uv @ArgumentList 1>$null 2>$null
        } else {
            & uv @ArgumentList
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { return -1 }
        return [int]$code
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item Env:UV_NO_PROGRESS -ErrorAction SilentlyContinue
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if ($hadNativePref) {
                $Global:PSNativeCommandUseErrorActionPreference = $prevNative
            } else {
                Remove-Item variable:global:PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-NacosUvTextLines {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $prevEap = $ErrorActionPreference
    $hadNativePref = $false
    $prevNative = $false
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $hadNativePref = Test-Path variable:global:PSNativeCommandUseErrorActionPreference
        if ($hadNativePref) { $prevNative = $Global:PSNativeCommandUseErrorActionPreference }
        $Global:PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $ErrorActionPreference = 'Continue'
        $env:UV_NO_PROGRESS = '1'
        & uv @ArgumentList 2>&1
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item Env:UV_NO_PROGRESS -ErrorAction SilentlyContinue
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if ($hadNativePref) {
                $Global:PSNativeCommandUseErrorActionPreference = $prevNative
            } else {
                Remove-Item variable:global:PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-UvOnPath {
    return ($null -ne (Get-Command "uv" -ErrorAction SilentlyContinue))
}

function Add-PathDirIfMissing($dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return }
    if ($env:PATH -split ';' -contains $dir)  { return }
    $env:PATH = "$dir;$env:PATH"
}

function Refresh-PathForUv {
    # Do not use $home: it is an alias for read-only automatic variable $HOME in PowerShell.
    $skillScannerUserDir = Get-SkillScannerUserHome
    Add-PathDirIfMissing (Join-Path $skillScannerUserDir ".local\bin")
    Add-PathDirIfMissing (Join-Path $skillScannerUserDir ".cargo\bin")
    # uv's own bin directory on Windows (where uv.exe is installed by the PS installer)
    Add-PathDirIfMissing (Join-Path $env:APPDATA "uv\bin")
    Add-PathDirIfMissing (Join-Path $env:LOCALAPPDATA "uv\bin")
}

# Install uv via the official Windows PowerShell installer
function Install-Uv {
    Write-Detail "Installing uv (https://astral.sh/uv/) via official installer..."
    $tmpScript = $null
    try {
        # Avoid Invoke-WebRequest .Content as string: on some hosts it is byte[] and breaks Invoke-Expression.
        $tmpScript = Join-Path $env:TEMP ("uv-official-install-" + [Guid]::NewGuid().ToString() + ".ps1")
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -UseBasicParsing -OutFile $tmpScript
        } finally {
            $ProgressPreference = $prevProgress
        }
        if (-not (Test-Path -LiteralPath $tmpScript) -or ((Get-Item -LiteralPath $tmpScript).Length -lt 32)) {
            Write-Warn "Downloaded uv installer script is missing or too small."
            return $false
        }
        $installScript = Get-Content -LiteralPath $tmpScript -Raw -Encoding UTF8
        if (-not $installScript -or $installScript.Length -lt 32) {
            Write-Warn "Could not read uv installer script as UTF-8 text."
            return $false
        }
        $env:UV_PRINT_QUIET = "1"
        # Simple UI: hide uv install script banner (align with bash quiet install); full output with -x/--verbose
        $verboseInstall = $false
        if (Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) { $verboseInstall = Test-NacosSetupVerbose }
        if ($verboseInstall) {
            Invoke-Expression $installScript
        } else {
            $installLog = Join-Path $env:TEMP ("uv-official-install-out-" + [Guid]::NewGuid().ToString() + ".log")
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                & { Invoke-Expression $installScript } *> $installLog
            } else {
                & { Invoke-Expression $installScript } > $installLog 2>&1
            }
            Remove-Item -LiteralPath $installLog -Force -ErrorAction SilentlyContinue
        }
        Refresh-PathForUv
        if (Test-UvOnPath) {
            Write-Detail "uv installed: $((Get-Command uv).Source)"
            return $true
        }
        Write-Warn "uv was installed but is not on PATH. Open a new terminal or add the install directory to PATH."
        return $false
    } catch {
        Write-Warn "Automatic uv installation failed: $($_.Exception.Message)"
        Write-Warn "Install manually: https://docs.astral.sh/uv/getting-started/installation/"
        return $false
    } finally {
        Remove-Item Env:UV_PRINT_QUIET -ErrorAction SilentlyContinue
        if ($tmpScript -and (Test-Path -LiteralPath $tmpScript)) {
            Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Python 3.10+ helpers
# ============================================================================

function Find-Python310Plus {
    foreach ($cmd in @("python3.13","python3.12","python3.11","python3.10","python3","python")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if (-not $found) { continue }
        try {
            $rc = & $found.Source -c "import sys; raise SystemExit(0 if sys.version_info>=(3,10) else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) { return $found.Source }
        } catch {}
    }
    return $null
}

function Ensure-Python310WithUv {
    $py = Find-Python310Plus
    if ($py) { return $py }

    Write-Detail "No Python 3.10+ on PATH; uv can install Python 3.10."
    try {
        $answer = Read-Host "Install Python 3.10 with uv now? (Y/n)"
        if ($answer -match '^[Nn]') {
            Write-Detail "Skipping uv-managed Python 3.10."
            return $null
        }
    } catch {
        Write-Detail "Non-interactive: skipping uv-managed Python 3.10."
        return $null
    }

    Write-Detail "Installing Python 3.10 with uv (this may take a moment)..."
    $pyExit = Invoke-NacosUv -ArgumentList @('python', 'install', '3.10') -SuppressStreams:(-not (Test-NacosSetupVerbose))
    if ($pyExit -ne 0) {
        Write-Warn "uv python install 3.10 failed (exit code $pyExit)."
        return $null
    }

    # Refresh PATH to find newly installed Python managed by uv
    $skillScannerUserDir = Get-SkillScannerUserHome
    Add-PathDirIfMissing (Join-Path $skillScannerUserDir ".local\share\uv\python")

    $pyLines = Get-NacosUvTextLines -ArgumentList @('python', 'find', '3.10')
    $pyPath = Normalize-UvCommandOutput $pyLines
    if ($pyPath -and (Test-Path -LiteralPath $pyPath)) {
        Write-Detail "Python 3.10 ready: $pyPath"
        return $pyPath
    }

    Write-Warn "Could not locate uv-managed Python 3.10 after installation."
    return $null
}

# ============================================================================
# venv + install
# ============================================================================

function New-SkillScannerVenv($pyExe, $venvDir) {
    $parent = Split-Path $venvDir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $pyArg = $pyExe
    $found310 = Normalize-UvCommandOutput (Get-NacosUvTextLines -ArgumentList @('python', 'find', '3.10'))
    if ($found310 -and (Test-Path -LiteralPath $found310)) { $pyArg = "3.10" }

    Write-SkillScannerTrace "Creating venv at $venvDir with python=$pyArg"

    $attempts = @(
        @{ args = @("venv","--no-project","--python",$pyArg,$venvDir) },
        @{ args = @("venv","--no-project","--clear","--python",$pyArg,$venvDir) },
        @{ env  = @{UV_LINK_MODE="copy"}; args = @("venv","--no-project","--python",$pyArg,$venvDir) },
        @{ env  = @{UV_LINK_MODE="copy"}; args = @("venv","--no-project","--clear","--python",$pyArg,$venvDir) }
    )

    foreach ($attempt in $attempts) {
        try {
            if ($attempt.env) {
                foreach ($k in $attempt.env.Keys) { Set-Item "Env:$k" $attempt.env[$k] }
            }
            $venvExit = Invoke-NacosUv -ArgumentList $attempt.args -SuppressStreams:(-not (Test-NacosSetupVerbose))
            if ($attempt.env) {
                foreach ($k in $attempt.env.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
            }
            if ($venvExit -eq 0 -and (Test-Path (Get-SkillScannerVenvPython $venvDir))) { return $true }
        } catch {}
    }
    return $false
}

function Install-SkillScannerInVenv($venvPython) {
    try {
        $pipExit = Invoke-NacosUv -ArgumentList @('pip', 'install', '--python', $venvPython, $script:SkillScannerPypiPackage, '-qq') -SuppressStreams:(-not (Test-NacosSetupVerbose))
        return ($pipExit -eq 0)
    } catch { return $false }
}

function Add-VenvBinToPath($venvDir) {
    $binDir = Get-SkillScannerVenvBin $venvDir
    Add-PathDirIfMissing $binDir

    # Persist to PowerShell profile (idempotent)
    $profilePath = $PROFILE
    if ($profilePath -and (Test-Path (Split-Path $profilePath -Parent))) {
        if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }
        $exportLine = "`$env:PATH = `"$binDir;`$env:PATH`""
        $existing = Get-Content $profilePath -ErrorAction SilentlyContinue
        if ($existing -notcontains $exportLine) {
            Add-Content -Path $profilePath -Value "`n$exportLine"
            Write-SkillScannerTrace "Added $binDir to PowerShell profile: $profilePath"
        }
    }
}

# ============================================================================
# Nacos application.properties integration
# ============================================================================

function Get-SkillScannerCommandPath {
    $venvDir = Get-SkillScannerVenvDir
    $exe = Get-SkillScannerExePath $venvDir
    if (Test-Path $exe) { return $exe }
    $onPath = Find-SkillScannerOnPath
    if ($onPath) { return $onPath }
    return $null
}

# Java / Nacos read application.properties reliably with forward slashes on Windows (align with typical JVM path handling).
function Convert-SkillScannerCommandPathForNacos([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $path }
    return $path -replace '\\', '/'
}

function Set-SkillScannerProperties($configFile) {
    if (-not $configFile -or -not (Test-Path $configFile)) {
        Write-SkillScannerTrace "skip: config file not found ($configFile)"
        return
    }
    Write-Detail "Configuring skill-scanner plugin properties in $configFile"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.enabled" "true"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.type" "skill-scanner"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.skill-scanner.enabled" "true"

    $scannerCmd = Get-SkillScannerCommandPath
    if ($scannerCmd) {
        $cmdForNacos = Convert-SkillScannerCommandPathForNacos $scannerCmd
        Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.skill-scanner.command" $cmdForNacos
    }
    Write-Detail "skill-scanner plugin properties configured."
}

# ============================================================================
# Main public function
# ============================================================================

# Called after Nacos application.properties is written.
# Set NACOS_SETUP_SKIP_SKILL_SCANNER=1 to skip.
function Invoke-MaybeInstallSkillScannerForNacos($nacosVersion) {
    Write-SkillScannerTrace "Invoke-MaybeInstallSkillScannerForNacos nacosVersion='$nacosVersion'"

    if ($env:NACOS_SETUP_SKIP_SKILL_SCANNER -in @("1","true","TRUE")) {
        Write-SkillScannerTrace "skip: NACOS_SETUP_SKIP_SKILL_SCANNER is set"
        return
    }
    if (-not $nacosVersion) { return }

    if (-not (Get-Command Version-Ge -ErrorAction SilentlyContinue)) { return }
    if (-not (Version-Ge $nacosVersion $script:MinNacosVersionForSkillScanner)) {
        Write-SkillScannerTrace "skip: nacos $nacosVersion < $($script:MinNacosVersionForSkillScanner)"
        return
    }

    $venvDir    = Get-SkillScannerVenvDir
    $venvPython = Get-SkillScannerVenvPython $venvDir

    # Already installed in venv?
    if ((Test-Path $venvPython) -and (Test-SkillScannerInVenv $venvDir)) {
        $script:SkillScannerInstalled = $true
        # Align with bash: one concise [INFO] line in simple UI when stack is already present
        Write-Info "skill-scanner already installed in $venvDir (skip)."
        return
    }

    # Already on PATH?
    if (Find-SkillScannerOnPath) {
        $script:SkillScannerInstalled = $true
        Write-SkillScannerTrace "skill-scanner already on PATH; skip uv/venv install"
        return
    }

    # Environment summary (align with bash interactive skill-scanner flow)
    Refresh-PathForUv
    $hasUv = Test-UvOnPath
    $hasPy = $null -ne (Find-Python310Plus)
    Write-Detail "Skill-scanner prerequisites: uv=$hasUv; Python 3.10+=$hasPy"

    # Prompt user (keep prompts; hide preamble unless -x/--verbose)
    Write-Detail "Optional: Cisco skill-scanner for Nacos $nacosVersion"
    Write-Detail "  This will install: uv + Python 3.10+ + $($script:SkillScannerPypiPackage) under ~/ai-infra/.venv"
    try {
        $answer = Read-Host "Install skill-scanner stack? (Y/n)"
        if ($answer -match '^[Nn]') {
            Write-Detail "Skipping skill-scanner / uv / Python setup. Continuing Nacos startup."
            return
        }
    } catch {
        Write-Detail "Non-interactive: skipping optional skill-scanner setup."
        return
    }

    # Bootstrap uv (interactive Y/n, align with bash _confirm_uv_bootstrap_interactive)
    if (-not (Test-UvOnPath)) {
        Refresh-PathForUv
    }
    if (-not (Test-UvOnPath)) {
        Write-Detail "uv was not found on PATH."
        $doUv = $false
        if (Get-Command Test-NacosSetupInteractive -ErrorAction SilentlyContinue) {
            if (Test-NacosSetupInteractive) {
                try {
                    $u = Read-Host "Download and install uv using the official installer? (Y/n)"
                    if ($u -notmatch '^[Nn]') { $doUv = $true }
                } catch { $doUv = $false }
            }
        }
        if (-not $doUv) {
            Write-Detail "Skipping uv installation."
            Write-Warn "Cannot install $($script:SkillScannerPypiPackage) without uv."
            return
        }
        if (-not (Install-Uv)) {
            Write-Warn "Cannot install $($script:SkillScannerPypiPackage) without uv."
            return
        }
    }

    # Ensure Python 3.10+
    $pyExe = Ensure-Python310WithUv
    if (-not $pyExe) {
        Write-Warn "Could not prepare Python 3.10+. Please install Python 3.10+ and retry."
        Write-Warn "Reference: https://docs.astral.sh/uv/guides/install-python/"
        return
    }

    # Create venv
    if (-not (Test-Path $venvPython)) {
        Write-Detail "Creating uv virtual environment in $venvDir..."
        if (-not (New-SkillScannerVenv $pyExe $venvDir)) {
            Write-Warn "Could not create uv virtual environment at $venvDir."
            return
        }
        $venvPython = Get-SkillScannerVenvPython $venvDir
    }

    # Install skill-scanner
    Write-Detail "Installing $($script:SkillScannerPypiPackage) into $venvDir via uv..."
    if (Install-SkillScannerInVenv $venvPython) {
        $script:SkillScannerInstalled = $true
        Add-VenvBinToPath $venvDir
        $binDir = Get-SkillScannerVenvBin $venvDir
        Write-Detail "Installed $($script:SkillScannerPypiPackage) in $venvDir."
        Write-Detail "Added $binDir to PATH (current session and PowerShell profile)."
        Write-Detail "Run with: $(Get-SkillScannerExePath $venvDir)"
    } else {
        Write-Warn "Could not install $($script:SkillScannerPypiPackage) into $venvDir via uv."
        Write-Warn "Docs: https://github.com/cisco-ai-defense/skill-scanner"
    }
}

# Post-config hook: called after application.properties is written.
function Invoke-PostNacosConfigSkillScannerHook($nacosVersion) {
    if (Get-Command Invoke-MaybeInstallSkillScannerForNacos -ErrorAction SilentlyContinue) {
        Invoke-MaybeInstallSkillScannerForNacos $nacosVersion
    }
}

# Check whether skill-scanner plugin config should be written to application.properties.
function Test-ShouldWriteSkillScannerPluginConfig($nacosVersion) {
    if ($env:NACOS_SETUP_SKIP_SKILL_SCANNER -in @("1","true","TRUE")) { return $false }
    if (-not (Get-Command Version-Ge -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Version-Ge $nacosVersion $script:MinNacosVersionForSkillScanner)) { return $false }
    if ($script:SkillScannerInstalled) { return $true }
    if (Get-SkillScannerCommandPath) { return $true }
    return $false
}
