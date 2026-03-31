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
    Write-Info "Installing uv (https://astral.sh/uv/) via official installer..."
    try {
        $installScript = (Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -UseBasicParsing).Content
        $env:UV_PRINT_QUIET = "1"
        Invoke-Expression $installScript
        Remove-Item Env:UV_PRINT_QUIET -ErrorAction SilentlyContinue
        Refresh-PathForUv
        if (Test-UvOnPath) {
            Write-Info "uv installed: $((Get-Command uv).Source)"
            return $true
        }
        Write-Warn "uv was installed but is not on PATH. Open a new terminal or add the install directory to PATH."
        return $false
    } catch {
        Write-Warn "Automatic uv installation failed: $($_.Exception.Message)"
        Write-Warn "Install manually: https://docs.astral.sh/uv/getting-started/installation/"
        return $false
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

    Write-Info "No Python 3.10+ on PATH; uv can install Python 3.10."
    try {
        $answer = Read-Host "Install Python 3.10 with uv now? (Y/n)"
        if ($answer -match '^[Nn]') {
            Write-Info "Skipping uv-managed Python 3.10."
            return $null
        }
    } catch {
        Write-Info "Non-interactive: skipping uv-managed Python 3.10."
        return $null
    }

    Write-Info "Installing Python 3.10 with uv (this may take a moment)..."
    try {
        $env:UV_NO_PROGRESS = "1"
        & uv python install 3.10 2>&1 | Out-Null
        Remove-Item Env:UV_NO_PROGRESS -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "uv python install 3.10 failed: $($_.Exception.Message)"
        return $null
    }

    # Refresh PATH to find newly installed Python managed by uv
    $skillScannerUserDir = Get-SkillScannerUserHome
    Add-PathDirIfMissing (Join-Path $skillScannerUserDir ".local\share\uv\python")

    try {
        $pyPath = (& uv python find 3.10 2>$null).Trim()
        if ($pyPath -and (Test-Path $pyPath)) {
            Write-Info "Python 3.10 ready: $pyPath"
            return $pyPath
        }
    } catch {}

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
    try {
        $found310 = (& uv python find 3.10 2>$null).Trim()
        if ($found310 -and (Test-Path $found310)) { $pyArg = "3.10" }
    } catch {}

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
            $env:UV_NO_PROGRESS = "1"
            & uv @($attempt.args) 2>&1 | Out-Null
            Remove-Item Env:UV_NO_PROGRESS -ErrorAction SilentlyContinue
            if ($attempt.env) {
                foreach ($k in $attempt.env.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
            }
            if (Test-Path (Get-SkillScannerVenvPython $venvDir)) { return $true }
        } catch {}
    }
    return $false
}

function Install-SkillScannerInVenv($venvPython) {
    try {
        $env:UV_NO_PROGRESS = "1"
        & uv pip install --python $venvPython $script:SkillScannerPypiPackage -qq 2>&1 | Out-Null
        Remove-Item Env:UV_NO_PROGRESS -ErrorAction SilentlyContinue
        return ($LASTEXITCODE -eq 0)
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

function Set-SkillScannerProperties($configFile) {
    if (-not $configFile -or -not (Test-Path $configFile)) {
        Write-SkillScannerTrace "skip: config file not found ($configFile)"
        return
    }
    Write-Info "Configuring skill-scanner plugin properties in $configFile"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.enabled" "true"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.type" "skill-scanner"
    Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.skill-scanner.enabled" "true"

    $scannerCmd = Get-SkillScannerCommandPath
    if ($scannerCmd) {
        Update-ConfigProperty $configFile "nacos.plugin.ai-pipeline.skill-scanner.command" $scannerCmd
    }
    Write-Info "skill-scanner plugin properties configured."
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
    Write-Info "Skill-scanner prerequisites: uv=$hasUv; Python 3.10+=$hasPy"

    # Prompt user
    Write-Info "Optional: Cisco skill-scanner for Nacos $nacosVersion"
    Write-Info "  This will install: uv + Python 3.10+ + $($script:SkillScannerPypiPackage) under ~/ai-infra/.venv"
    try {
        $answer = Read-Host "Install skill-scanner stack? (Y/n)"
        if ($answer -match '^[Nn]') {
            Write-Info "Skipping skill-scanner / uv / Python setup. Continuing Nacos startup."
            return
        }
    } catch {
        Write-Info "Non-interactive: skipping optional skill-scanner setup."
        return
    }

    # Bootstrap uv (interactive Y/n, align with bash _confirm_uv_bootstrap_interactive)
    if (-not (Test-UvOnPath)) {
        Refresh-PathForUv
    }
    if (-not (Test-UvOnPath)) {
        Write-Info "uv was not found on PATH."
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
            Write-Info "Skipping uv installation."
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
        Write-Info "Creating uv virtual environment in $venvDir..."
        if (-not (New-SkillScannerVenv $pyExe $venvDir)) {
            Write-Warn "Could not create uv virtual environment at $venvDir."
            return
        }
        $venvPython = Get-SkillScannerVenvPython $venvDir
    }

    # Install skill-scanner
    Write-Info "Installing $($script:SkillScannerPypiPackage) into $venvDir via uv..."
    if (Install-SkillScannerInVenv $venvPython) {
        $script:SkillScannerInstalled = $true
        Add-VenvBinToPath $venvDir
        $binDir = Get-SkillScannerVenvBin $venvDir
        Write-Info "Installed $($script:SkillScannerPypiPackage) in $venvDir."
        Write-Info "Added $binDir to PATH (current session and PowerShell profile)."
        Write-Info "Run with: $(Get-SkillScannerExePath $venvDir)"
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
