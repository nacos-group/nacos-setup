# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Import default agentspec / skill data into the Nacos data directory.

$script:DefaultSkillsDataUrl = if ($env:NACOS_SETUP_SKILLS_DATA_URL) {
    $env:NACOS_SETUP_SKILLS_DATA_URL
} else {
    "https://download.nacos.io/nacos-server-data/skills-data.zip"
}

$script:DefaultAgentspecDataUrl = if ($env:NACOS_SETUP_AGENTSPEC_DATA_URL) {
    $env:NACOS_SETUP_AGENTSPEC_DATA_URL
} else {
    "https://download.nacos.io/nacos-server-data/agentspec-data.zip"
}

$script:NacosDataCacheDir = if ($env:NACOS_DATA_CACHE_DIR) {
    $env:NACOS_DATA_CACHE_DIR
} elseif ($env:NACOS_CACHE_DIR) {
    Join-Path $env:NACOS_CACHE_DIR "data"
} else {
    Join-Path $env:USERPROFILE ".nacos\cache\data"
}

function Test-DefaultDataImportSkipRequested {
    return $env:NACOS_SETUP_SKIP_DEFAULT_DATA -in @("1", "true", "TRUE", "yes", "YES")
}

function Test-DefaultDataImportForceRequested {
    return $env:NACOS_SETUP_FORCE_DEFAULT_DATA_IMPORT -in @("1", "true", "TRUE", "yes", "YES")
}

function Test-ZipArchiveValid {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $zip.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Get-DefaultDataArchive {
    param(
        [string]$ArchiveName,
        [string]$ArchiveUrl
    )

    Ensure-Directory $script:NacosDataCacheDir
    $cachedFile = Join-Path $script:NacosDataCacheDir "${ArchiveName}.zip"

    if ((Test-Path $cachedFile) -and (Get-Item $cachedFile).Length -gt 0 -and (Test-ZipArchiveValid $cachedFile)) {
        return $cachedFile
    }

    if (Test-Path $cachedFile) {
        Remove-Item -Path $cachedFile -Force -ErrorAction SilentlyContinue
    }

    Write-Info "Downloading $ArchiveName from $ArchiveUrl"
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $cachedFile
        } else {
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $cachedFile
        }
    } catch {
        Write-Warn "Failed to download $ArchiveName from $ArchiveUrl"
        Remove-Item -Path $cachedFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    if (Test-ZipArchiveValid $cachedFile) {
        return $cachedFile
    }

    Write-Warn "Downloaded $ArchiveName archive is invalid, skipping import"
    Remove-Item -Path $cachedFile -Force -ErrorAction SilentlyContinue
    return $null
}

function Import-DefaultDataArchive {
    param(
        [string]$InstallDir,
        [string]$ArchiveName,
        [string]$ArchiveUrl
    )

    $dataDir = Join-Path $InstallDir "data"
    $markerFile = Join-Path $dataDir ".nacos-setup-$ArchiveName.url"

    Ensure-Directory $dataDir

    if (-not (Test-DefaultDataImportForceRequested) -and (Test-Path $markerFile)) {
        $markerValue = (Get-Content $markerFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($markerValue -eq $ArchiveUrl) {
            Write-Info "$ArchiveName already imported into $dataDir, skipping"
            return
        }
    }

    $archiveFile = Get-DefaultDataArchive $ArchiveName $ArchiveUrl
    if (-not $archiveFile) { return }

    Write-Info "Importing $ArchiveName into $dataDir"
    try {
        Expand-Archive -Path $archiveFile -DestinationPath $dataDir -Force
        Set-Content -Path $markerFile -Value $ArchiveUrl -Encoding ASCII
    } catch {
        Write-Warn "Failed to extract $ArchiveName into $dataDir"
    }
}

function Import-DefaultDataForNacos {
    param([string]$InstallDir)

    if (Test-DefaultDataImportSkipRequested) {
        Write-Info "Skipping default data import because NACOS_SETUP_SKIP_DEFAULT_DATA is set"
        return
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir) -or -not (Test-Path $InstallDir)) {
        Write-Warn "Default data import skipped: install dir not found: $InstallDir"
        return
    }

    Import-DefaultDataArchive $InstallDir "skills-data" $script:DefaultSkillsDataUrl
    Import-DefaultDataArchive $InstallDir "agentspec-data" $script:DefaultAgentspecDataUrl
}

function Invoke-PostNacosConfigDataImportHook {
    param([string]$InstallDir)
    Import-DefaultDataForNacos $InstallDir
}
