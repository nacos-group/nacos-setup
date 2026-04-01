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

# ============================================================================
# Unified Version Management for PowerShell
# ============================================================================
#
# Usage: . $PSScriptRoot\lib\versions.ps1
#        $version = Get-Version -Component <cli|setup|server> [-TimeoutSeconds <seconds>]
#
# Components: cli, setup, server
#
# Examples:
#   $cliVer = Get-Version -Component cli
#   $setupVer = Get-Version -Component setup
#   $serverVer = Get-Version -Component server
#   $cliVer = Get-Version -Component cli -TimeoutSeconds 2
#
# Environment variables override remote versions:
#   $env:NACOS_CLI_VERSION
#   $env:NACOS_SETUP_VERSION
#   $env:NACOS_SERVER_VERSION
#
# ============================================================================

# Base URL for downloads
$script:DownloadBaseUrl = "https://download.nacos.io"
$script:VersionsUrl = "$script:DownloadBaseUrl/versions"

# ============================================================================
# Fallback Versions (used when versions file cannot be fetched)
# ============================================================================

$script:FallbackNacosCliVersion = "0.0.8"
$script:FallbackNacosSetupVersion = "0.0.3"
$script:FallbackNacosServerVersion = "3.2.0-BETA"

# ============================================================================
# Cached versions (populated on first fetch)
# ============================================================================

$script:CachedCliVersion = ""
$script:CachedSetupVersion = ""
$script:CachedServerVersion = ""
$script:VersionsFetched = $false

# ============================================================================
# Helper Functions
# ============================================================================

function Write-VersionInfo($msg) {
    # Align with bash: remote version fetch chatter is print_detail (only with -x / NACOS_SETUP_VERBOSE)
    if (Get-Command Test-NacosSetupVerbose -ErrorAction SilentlyContinue) {
        if (Test-NacosSetupVerbose) {
            if (Get-Command Write-Detail -ErrorAction SilentlyContinue) { Write-Detail $msg }
            elseif (Get-Command Write-Info -ErrorAction SilentlyContinue) { Write-Info $msg }
            else { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
        }
        return
    }
    if (Get-Command Write-Info -ErrorAction SilentlyContinue) {
        Write-Info $msg
    } else {
        Write-Host "[INFO] $msg" -ForegroundColor Cyan
    }
}

function Write-VersionWarn($msg) {
    if (Get-Command Write-Warn -ErrorAction SilentlyContinue) {
        Write-Warn $msg
    } else {
        Write-Host "[WARN] $msg" -ForegroundColor Yellow
    }
}

# Fetch versions from remote versions file
# Parameters: TimeoutSeconds (default: 1)
# Returns: $true on success, $false on failure
function Fetch-Versions {
    param(
        [int]$TimeoutSeconds = 1
    )

    Write-VersionInfo "Fetching versions from $script:VersionsUrl..."

    $tempFile = [System.IO.Path]::GetTempFileName()
    $fetchSuccess = $false

    try {
        # Try to download with timeout using background job
        $job = Start-Job {
            param($url, $outFile)
            try {
                Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -ErrorAction Stop
                return $true
            } catch {
                return $false
            }
        } -ArgumentList $script:VersionsUrl, $tempFile

        # Wait for completion or timeout
        $completed = $job | Wait-Job -Timeout $TimeoutSeconds

        if ($completed) {
            $result = Receive-Job $job
            if ($result -eq $true -and (Test-Path $tempFile) -and (Get-Item $tempFile).Length -gt 0) {
                $fetchSuccess = $true
            }
        }

        Remove-Job $job -Force -ErrorAction SilentlyContinue

        if (-not $fetchSuccess) {
            return $false
        }

        # Parse versions file
        $content = Get-Content $tempFile -Raw
        $lines = $content -split "`r?`n"

        foreach ($line in $lines) {
            if ($line -match "^NACOS_CLI_VERSION=(.+)$") {
                $script:CachedCliVersion = $matches[1].Trim()
            }
            elseif ($line -match "^NACOS_SETUP_VERSION=(.+)$") {
                $script:CachedSetupVersion = $matches[1].Trim()
            }
            elseif ($line -match "^NACOS_SERVER_VERSION=(.+)$") {
                $script:CachedServerVersion = $matches[1].Trim()
            }
        }

        $script:VersionsFetched = $true
        return $true
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Main Public Function
# ============================================================================

# Get version for specified component
# Parameters:
#   -Component <cli|setup|server>
#   -TimeoutSeconds <seconds> (optional, default: 1)
# Returns: version string
function Get-Version {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("cli", "setup", "server")]
        [string]$Component,

        [int]$TimeoutSeconds = 1
    )

    $envVarName = "NACOS_$($Component.ToUpper())_VERSION"
    $fallbackProp = "FallbackNacos$($Component.Substring(0,1).ToUpper() + $Component.Substring(1))Version"
    $cachedProp = "Cached$($Component.Substring(0,1).ToUpper() + $Component.Substring(1))Version"

    # Check environment variable first (highest priority)
    $envValue = [Environment]::GetEnvironmentVariable($envVarName)
    if ($envValue) {
        return $envValue
    }

    # Check cached value
    $cachedValue = Get-Variable -Name $cachedProp -Scope Script -ErrorAction SilentlyContinue
    if ($cachedValue -and $cachedValue.Value) {
        return $cachedValue.Value
    }

    # Try to fetch from remote (only once per script execution)
    if (-not $script:VersionsFetched) {
        if (Fetch-Versions -TimeoutSeconds $TimeoutSeconds) {
            # Re-check cached value after fetch
            $cachedValue = Get-Variable -Name $cachedProp -Scope Script -ErrorAction SilentlyContinue
            if ($cachedValue -and $cachedValue.Value) {
                return $cachedValue.Value
            }
        }
    }

    # Return fallback version
    $fallbackValue = Get-Variable -Name $fallbackProp -Scope Script -ErrorAction SilentlyContinue
    if ($fallbackValue) {
        return $fallbackValue.Value
    }
    return $null
}

# Get all versions at once (useful for installer)
# Parameters: TimeoutSeconds (optional, default: 1)
# Sets script-level variables: NacosCliVersion, NacosSetupVersion, NacosServerVersion
function Get-AllVersions {
    param(
        [int]$TimeoutSeconds = 1
    )

    $script:NacosCliVersion = Get-Version -Component cli -TimeoutSeconds $TimeoutSeconds
    $script:NacosSetupVersion = Get-Version -Component setup -TimeoutSeconds $TimeoutSeconds
    $script:NacosServerVersion = Get-Version -Component server -TimeoutSeconds $TimeoutSeconds
}

# Print all versions (for debugging)
function Print-Versions {
    Write-Host "Nacos Component Versions:"
    Write-Host "  CLI:    $(Get-Version -Component cli) (fallback: $script:FallbackNacosCliVersion)"
    Write-Host "  Setup:  $(Get-Version -Component setup) (fallback: $script:FallbackNacosSetupVersion)"
    Write-Host "  Server: $(Get-Version -Component server) (fallback: $script:FallbackNacosServerVersion)"
}
