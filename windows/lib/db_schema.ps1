# Database Schema Export Module (Windows PowerShell)
# Exports full schema SQL for a given Nacos version and database type

# Supported database types
$Script:SupportedDbTypes = @("mysql", "postgresql")

# Cache directory for downloaded schema files
$Script:DbSchemaCacheDir = if ($env:NACOS_CACHE_DIR) {
    $env:NACOS_CACHE_DIR
} else {
    $userHome = if ($realUserProfile) { $realUserProfile } elseif ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { "." }
    Join-Path $userHome ".nacos\cache"
}

# ============================================================================
# Schema File Name Mapping
# ============================================================================

function Get-SchemaFilename([string]$DbType) {
    switch ($DbType) {
        "postgresql" { return "pg-schema.sql" }
        default      { return "${DbType}-schema.sql" }
    }
}

# ============================================================================
# Validation
# ============================================================================

function Test-DbType([string]$DbType) {
    if (-not $DbType) {
        Write-ErrorMsg "Database type is required"
        return $false
    }
    if ($DbType -in $Script:SupportedDbTypes) {
        return $true
    }
    Write-ErrorMsg "Unsupported database type: $DbType"
    Write-Info "Supported types: $($Script:SupportedDbTypes -join ', ')"
    return $false
}

# ============================================================================
# Local Schema Lookup
# ============================================================================

function Find-LocalSchema([string]$Version, [string]$DbType) {
    $userHome = if ($realUserProfile) { $realUserProfile } elseif ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { "." }
    $installBase = if ($env:NACOS_INSTALL_BASE) { $env:NACOS_INSTALL_BASE } else { Join-Path $userHome ".nacos\nacos-server-$Version" }
    $nacosHome = Join-Path $installBase "nacos"
    $filename = Get-SchemaFilename $DbType

    # New-style: plugin-ext directory (Nacos >3.1.1)
    $newPath = Join-Path $nacosHome "plugin-ext\nacos-datasource-plugin-${DbType}\${filename}"
    if (Test-Path $newPath) {
        return $newPath
    }

    # Old-style: conf directory (Nacos <=3.1.1)
    $oldPath = Join-Path $nacosHome "conf\${filename}"
    if (Test-Path $oldPath) {
        return $oldPath
    }

    return $null
}

# ============================================================================
# Remote Schema Download
# ============================================================================

function Get-SchemaCachePath([string]$Version, [string]$DbType) {
    return Join-Path $Script:DbSchemaCacheDir "${Version}-${DbType}-schema.sql"
}

function Get-SchemaGithubUrls([string]$Version, [string]$DbType) {
    $filename = Get-SchemaFilename $DbType
    return @(
        # New path (Nacos >=3.2.0, after plugin refactor)
        "https://raw.githubusercontent.com/alibaba/nacos/${Version}/plugin-default-impl/nacos-default-datasource-plugin/nacos-datasource-plugin-${DbType}/src/main/resources/META-INF/${filename}"
        # Old path (Nacos <3.2.0)
        "https://raw.githubusercontent.com/alibaba/nacos/${Version}/distribution/conf/${filename}"
    )
}

function Download-Schema([string]$Version, [string]$DbType) {
    $cacheFile = Get-SchemaCachePath $Version $DbType

    # Check cache first
    if ((Test-Path $cacheFile) -and (Get-Item $cacheFile).Length -gt 0) {
        Write-Info "Using cached schema: $cacheFile"
        return $cacheFile
    }

    # Ensure cache directory exists
    $cacheDir = Split-Path $cacheFile -Parent
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    # Try each URL in order
    $urls = Get-SchemaGithubUrls $Version $DbType
    foreach ($url in $urls) {
        Write-Info "Downloading schema from: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $cacheFile -UseBasicParsing -ErrorAction Stop
            if ((Test-Path $cacheFile) -and (Get-Item $cacheFile).Length -gt 0) {
                # Verify it's not a 404 page
                $content = Get-Content $cacheFile -First 1 -ErrorAction SilentlyContinue
                if ($content -and $content -notmatch "^404:") {
                    Write-Info "Schema cached to: $cacheFile"
                    return $cacheFile
                }
            }
        } catch {
            # Download failed, try next URL
        }
        if (Test-Path $cacheFile) { Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue }
    }

    Write-ErrorMsg "Failed to download schema for Nacos $Version ($DbType)"
    Write-Info "Check that version tag '$Version' exists at https://github.com/alibaba/nacos"
    return $null
}

# ============================================================================
# Interactive Prompts
# ============================================================================

function Read-DbTypePrompt {
    # Check if running in non-interactive mode
    if (-not [Environment]::UserInteractive) {
        Write-ErrorMsg "Database type (--type) is required in non-interactive mode"
        return $null
    }
    Write-Host "Select database type:"
    Write-Host "  1. MySQL"
    Write-Host "  2. PostgreSQL"
    $choice = Read-Host "Enter choice (1/2)"
    switch ($choice) {
        "1" { return "mysql" }
        "2" { return "postgresql" }
        default {
            Write-ErrorMsg "Invalid choice: $choice"
            return $null
        }
    }
}

function Read-VersionPrompt {
    if (-not [Environment]::UserInteractive) {
        Write-ErrorMsg "Version (--version/-v) is required in non-interactive mode"
        return $null
    }
    $version = Read-Host "Enter Nacos version"
    if (-not $version) {
        Write-ErrorMsg "Version cannot be empty"
        return $null
    }
    return $version
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Export-DbSchema([string]$Version, [string]$DbType) {
    # Resolve missing arguments via interactive prompts
    if (-not $DbType) {
        $DbType = Read-DbTypePrompt
        if (-not $DbType) { return $false }
    }

    if (-not $Version) {
        # Try to detect locally installed version
        $userHome = if ($realUserProfile) { $realUserProfile } elseif ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { "." }
        $installDir = Join-Path $userHome ".nacos"
        $detectedVersion = $null
        if (Test-Path $installDir) {
            $serverDirs = Get-ChildItem -Path $installDir -Directory -Filter "nacos-server-*" -ErrorAction SilentlyContinue |
                Sort-Object Name |
                Select-Object -Last 1
            if ($serverDirs) {
                $detectedVersion = $serverDirs.Name -replace '^nacos-server-', ''
            }
        }
        if ($detectedVersion) {
            Write-Info "Detected installed version: $detectedVersion"
            $Version = $detectedVersion
        } else {
            $Version = Read-VersionPrompt
            if (-not $Version) { return $false }
        }
    }

    # Validate
    if (-not (Test-DbType $DbType)) { return $false }

    Write-Info "Exporting $DbType schema for Nacos $Version..."

    # Try local first
    $schemaFile = Find-LocalSchema $Version $DbType

    # Fallback to download
    if (-not $schemaFile) {
        $schemaFile = Download-Schema $Version $DbType
        if (-not $schemaFile) { return $false }
    }

    # Output SQL to stdout
    Get-Content $schemaFile -Raw
    return $true
}
