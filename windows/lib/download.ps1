# Download management for Windows nacos-setup
. $PSScriptRoot\common.ps1

function Write-DebugLog($msg) {
    if ($env:NACOS_DEBUG -eq "1") { Write-Info "[DEBUG] $msg" }
}

$Global:CacheDir = if ($env:NACOS_CACHE_DIR) { $env:NACOS_CACHE_DIR } else { Join-Path $env:USERPROFILE ".nacos\cache" }
$Global:DownloadBaseUrl = "https://download.nacos.io/nacos-server"
$Global:RefererUrl = "https://nacos.io/download/nacos-server/"

function Download-File($url, $output) {
    # Set Referer header to match bash script behavior (required by some CDNs)
    $headers = @{
        "Referer" = $Global:RefererUrl
    }
    
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -Headers $headers
    } else {
        Invoke-WebRequest -Uri $url -OutFile $output -Headers $headers
    }
}

function Download-Nacos($version) {
    Ensure-Directory $Global:CacheDir
    $zipName = "nacos-server-$version.zip"
    $downloadUrl = "$Global:DownloadBaseUrl/$zipName"
    $cached = Join-Path $Global:CacheDir $zipName

    Write-DebugLog "CacheDir: $Global:CacheDir"
    Write-DebugLog "ZipName: $zipName"
    Write-DebugLog "DownloadUrl: $downloadUrl"
    Write-DebugLog "CachedPath: $cached"

    $cachedItem = Get-Item -Path $cached -ErrorAction SilentlyContinue
    if ($cachedItem -and $cachedItem.Length -gt 0) {
        Write-Info "Found cached package: $cached"
        try {
            $f = Get-Item $cached
            $mb = [math]::Round($f.Length / 1MB, 2)
            Write-Info "Package size: $mb MB"
        } catch {}
        return $cached
    }

    Write-Info "Downloading Nacos version: $version"
    Write-Info "From: $downloadUrl"
    Write-Info "To: $cached"
    Download-File $downloadUrl $cached
    return $cached
}

function Extract-NacosToTemp($zipFile) {
    if (-not (Test-Path $zipFile)) { throw "Zip file not found: $zipFile" }
    Write-Info "Extracting package..."
    $tmpDir = Join-Path $env:TEMP ("nacos-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $tmpDir
    Expand-Archive -Path $zipFile -DestinationPath $tmpDir -Force
    $extracted = Get-ChildItem -Path $tmpDir -Directory | Where-Object { $_.Name -eq "nacos" } | Select-Object -First 1
    if (-not $extracted) { throw "Could not find extracted nacos directory" }
    return $extracted.FullName
}

function Install-Nacos($sourceDir, $targetDir) {
    if (-not (Test-Path $sourceDir)) { throw "Source directory not found: $sourceDir" }
    Write-Info "Installing Nacos to: $targetDir"
    if (Test-Path $targetDir) { 
        Write-Warn "Removing old version..."
        Remove-Item -Recurse -Force $targetDir 
    }
    Ensure-Directory (Split-Path $targetDir -Parent)
    Move-Item -Path $sourceDir -Destination $targetDir
    if (-not (Test-Path (Join-Path $targetDir "conf\application.properties"))) {
        throw "Installation verification failed: missing configuration"
    }
    Write-Success "Installation successful"
    return $true
}

function Cleanup-TempDir($dir) {
    if ($dir -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir }
}
