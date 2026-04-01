# Download management for Windows nacos-setup
. $PSScriptRoot\common.ps1

# Ensure TLS 1.2+ for this module (may load before main script sets it)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Write-DebugLog($msg) {
    if ($env:NACOS_DEBUG -eq "1") { Write-Info "[DEBUG] $msg" }
}

$Global:CacheDir = if ($env:NACOS_CACHE_DIR) { $env:NACOS_CACHE_DIR } else { Join-Path $env:USERPROFILE ".nacos\cache" }
# Use a unique variable name to avoid being shadowed by $script:DownloadBaseUrl in versions.ps1
# which sets "https://download.nacos.io" (without /nacos-server). PowerShell scope resolution
# in dot-sourced scripts under `powershell -File` can let $script: shadow $Global: of the same name.
$Global:NacosServerDownloadBaseUrl = "https://download.nacos.io/nacos-server"
$Global:RefererUrl = "https://nacos.io/download/nacos-server/"

function Download-File-WebClient-Lib($url, $output) {
    Write-Info "Downloading (WebClient fallback): $url"
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers.Add("Referer", $Global:RefererUrl)
        $wc.DownloadFile($url, $output)
    } finally {
        if ($wc) { $wc.Dispose() }
    }
}

function Download-File($url, $output) {
    $headers = @{
        "Referer" = $Global:RefererUrl
    }
    Write-DebugLog "Downloading from URL: $url"
    $prevProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -Headers $headers -ErrorAction Stop
        } else {
            Invoke-WebRequest -Uri $url -OutFile $output -Headers $headers -ErrorAction Stop
        }
    } catch {
        Write-Warn "Invoke-WebRequest failed: $($_.Exception.Message)"
        # Retry without Referer header (some CDN anti-hotlink configs reject unexpected Referers)
        try {
            Write-Info "Retrying download without Referer header..."
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $url -OutFile $output -ErrorAction Stop
            }
            return
        } catch {
            Write-Warn "Retry without Referer also failed: $($_.Exception.Message)"
        }
        # Fall back to WebClient (handles TLS/proxy differently from Invoke-WebRequest)
        try {
            Download-File-WebClient-Lib $url $output
        } catch {
            Write-ErrorMsg "All download methods failed for: $url"
            throw
        }
    } finally {
        $ProgressPreference = $prevProgress
    }
}

function Download-Nacos($version) {
    Ensure-Directory $Global:CacheDir
    $zipName = "nacos-server-$version.zip"
    $downloadUrl = "$Global:NacosServerDownloadBaseUrl/$zipName"
    $cached = Join-Path $Global:CacheDir $zipName

    Write-DebugLog "CacheDir: $Global:CacheDir"
    Write-DebugLog "ZipName: $zipName"
    Write-DebugLog "DownloadUrl: $downloadUrl"
    Write-DebugLog "CachedPath: $cached"

    $cachedItem = Get-Item -Path $cached -ErrorAction SilentlyContinue
    if ($cachedItem -and $cachedItem.Length -gt 0) {
        if (-not (Test-ZipArchiveValid $cached)) {
            Write-Warn "Cached package is invalid or incomplete (not a valid zip); removing and re-downloading: $cached"
            Remove-Item -LiteralPath $cached -Force -ErrorAction SilentlyContinue
        } else {
            Write-Detail "Found cached package: $cached"
            try {
                $f = Get-Item $cached
                $mb = [math]::Round($f.Length / 1MB, 2)
                Write-Detail "Package size: $mb MB"
            } catch {}
            if (Test-NacosSetupVerbose) {
                Write-Detail "Skipping download, using cached file"
            }
            return $cached
        }
    }

    Write-Detail "Downloading Nacos version: $version"
    Write-Detail "Download URL: $downloadUrl"
    Write-Detail "Saving to: $cached"
    Download-File $downloadUrl $cached
    Write-Detail "Download completed: $zipName"
    if (-not (Test-ZipArchiveValid $cached)) {
        Remove-Item -LiteralPath $cached -Force -ErrorAction SilentlyContinue
        throw "Downloaded Nacos package is not a valid zip file (network interruption, proxy, or CDN issue). Retry or remove the cache folder under $($Global:CacheDir) and run again."
    }
    return $cached
}

function Extract-NacosToTemp($zipFile) {
    if (-not (Test-Path $zipFile)) { throw "Zip file not found: $zipFile" }
    Write-Detail "Extracting Nacos package..."
    $tmpDir = Join-Path $env:TEMP ("nacos-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $tmpDir
    Expand-Archive -Path $zipFile -DestinationPath $tmpDir -Force
    $extracted = Get-ChildItem -Path $tmpDir -Directory | Where-Object { $_.Name -eq "nacos" } | Select-Object -First 1
    if (-not $extracted) { throw "Could not find extracted nacos directory" }
    return $extracted.FullName
}

function Install-Nacos($sourceDir, $targetDir) {
    if (-not (Test-Path $sourceDir)) { throw "Source directory not found: $sourceDir" }
    Write-Detail "Installing Nacos to: $targetDir"
    if (Test-Path $targetDir) { 
        Write-Detail "Removing old installation: $targetDir"
        if (-not (Remove-DirectoryRobust $targetDir)) {
            throw "Could not remove existing target directory: $targetDir"
        }
    }
    Ensure-Directory (Split-Path $targetDir -Parent)
    Move-Item -Path $sourceDir -Destination $targetDir
    if (-not (Test-Path (Join-Path $targetDir "conf\application.properties"))) {
        throw "Installation verification failed: missing configuration"
    }
    Write-Detail "Installation completed: $targetDir"
    return $true
}

function Cleanup-TempDir($dir) {
    if ($dir -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir }
}
