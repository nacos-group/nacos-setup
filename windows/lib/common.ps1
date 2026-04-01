# Common utilities for Windows nacos-setup

$Global:ColorInfo = "Cyan"
$Global:ColorWarn = "Yellow"
$Global:ColorError = "Red"
$Global:ColorSuccess = "Green"

# Align with bash nacos-setup.sh VERBOSE / print_detail.
# Do NOT treat generic $env:VERBOSE as nacos-setup verbose: many shells/CI set VERBOSE=true
# for unrelated tools, which would flood the console with Write-Detail and disable uv stream suppression.
$Global:NacosSetupVerbose = $false

function Test-NacosSetupVerbose {
    if ($Global:NacosSetupVerbose -eq $true) { return $true }
    if ($env:NACOS_SETUP_VERBOSE -in @("1", "true", "TRUE", "yes", "YES")) { return $true }
    return $false
}

function Write-Detail($msg) {
    if (Test-NacosSetupVerbose) {
        Write-Host "[INFO] $msg" -ForegroundColor $Global:ColorInfo
    }
}

function Write-NacosSetupStepOk($current, $total, $desc, $result = "") {
    # ASCII markers only: Unicode checkmarks break PS 5.1 when file is not saved as UTF-8 with BOM.
    if ($result) {
        Write-Host ('[{0}/{1}] {2} OK {3}' -f $current, $total, $desc, $result) -ForegroundColor $Global:ColorSuccess
    } else {
        Write-Host ('[{0}/{1}] {2} OK' -f $current, $total, $desc) -ForegroundColor $Global:ColorSuccess
    }
}

function Write-NacosSetupStepFail($current, $total, $desc, $result = "failed") {
    Write-Host ('[{0}/{1}] {2} FAILED {3}' -f $current, $total, $desc, $result) -ForegroundColor $Global:ColorError
}

# Simple UI: avoid Write-Progress during long steps (Download-Nacos, etc.). On Windows PowerShell 5.1,
# Write-Progress + Invoke-WebRequest commonly causes severe slowdown or a frozen console — a regression
# when generic $env:VERBOSE=true used to skip this path via Test-NacosSetupVerbose. Use one status line
# per step instead (similar to bash step_simple_*).
function Start-NacosSetupStepProgress($current, $total, $desc) {
    if (Test-NacosSetupVerbose) { return }
    Write-Host ("[{0}/{1}] {2}" -f $current, $total, $desc) -ForegroundColor $Global:ColorSuccess
}

function Stop-NacosSetupStepProgress() {
    # No-op: simple UI does not use Write-Progress (see Start-NacosSetupStepProgress).
}

function Test-NacosSetupInteractive {
    return [Environment]::UserInteractive -and ($Host.Name -notmatch "ISE")
}

# Required for Expand-Archive downloads / TLS mirrors bash check_system_commands (subset)
function Test-WindowsNacosSetupPrerequisites {
    Write-Detail "Checking required Windows capabilities..."
    if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "Expand-Archive is not available (requires Windows PowerShell 5+)."
        return $false
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}
    Write-Detail "Windows prerequisites OK"
    return $true
}

function Get-LogTimestamp {
    return Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

function Write-Info($msg) { 
    Write-Host "[INFO] $msg" -ForegroundColor $Global:ColorInfo 
}

function Write-Warn($msg) { 
    Write-Host "[WARN] $msg" -ForegroundColor $Global:ColorWarn 
}

function Write-ErrorMsg($msg) { 
    Write-Host "[ERROR] $msg" -ForegroundColor $Global:ColorError 
}

function Write-Success($msg) { 
    Write-Host "[SUCCESS] $msg" -ForegroundColor $Global:ColorSuccess 
}

function Ensure-Directory($path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

# True if Path is a complete ZIP (EOCD present). Rejects truncated downloads and other non-archives.
function Test-ZipArchiveValid {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    $len = (Get-Item $Path).Length
    if ($len -lt 22) { return $false }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $zip.Dispose()
        return $true
    } catch {
        return $false
    }
}

# Remove a directory tree: retries (handles transient locks), \\?\ long-path prefix, then robocopy /MIR
# to empty deeply nested trees that exceed MAX_PATH or confuse Remove-Item (e.g. Office-schema paths in JAR tooling).
function Remove-DirectoryRobust {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $fullPath = (Get-Item -LiteralPath $Path).FullName

    for ($t = 0; $t -lt 5; $t++) {
        try {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    if ($fullPath -match '^[A-Za-z]:\\') {
        $longPref = "\\?\$fullPath"
        if (Test-Path -LiteralPath $longPref) {
            for ($t = 0; $t -lt 3; $t++) {
                try {
                    Remove-Item -LiteralPath $longPref -Recurse -Force -ErrorAction Stop
                    return $true
                } catch {
                    Start-Sleep -Seconds 1
                }
            }
        }
    }

    $empty = Join-Path $env:TEMP ("nacos-empty-" + [Guid]::NewGuid().ToString())
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
        if ($robocopy) {
            & robocopy.exe $empty $fullPath /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
        }
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $fullPath)) { return $true }
        try {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
            return $true
        } catch {}
        cmd /c "rd /s /q `"$fullPath`"" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $fullPath)) { return $true }
    } catch {}

    return $false
}

function Version-Ge($v1, $v2) {
    if ([string]::IsNullOrWhiteSpace($v1)) { $v1 = "0.0.0" }
    if ([string]::IsNullOrWhiteSpace($v2)) { $v2 = "0.0.0" }
    
    # Extract numeric parts (handle versions like "3.2.0-BETA")
    function Get-NumericParts($ver) {
        $clean = $ver -replace '[^0-9.].*$', ''  # Remove suffixes like -BETA, -ALPHA, etc.
        $parts = $clean.Split('.') | ForEach-Object {
            try { [int]$_ } catch { 0 }
        }
        return $parts
    }
    
    $a = Get-NumericParts $v1
    $b = Get-NumericParts $v2
    for ($i=0; $i -lt 3; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $true
}

function Generate-SecretKey {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

function Generate-Password {
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $bytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        $sb.Append($chars[$b % $chars.Length]) | Out-Null
    }
    return $sb.ToString()
}

function Get-LocalIp {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notmatch "^169\.254\."
        } | Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch {}
    return "127.0.0.1"
}

function Update-ConfigProperty($configFile, $key, $value) {
    if ([string]::IsNullOrWhiteSpace($configFile)) { throw "Config file path cannot be empty" }
    if (-not (Test-Path $configFile)) { throw "Config file not found: $configFile" }
    $lines = Get-Content -Path $configFile -Raw -ErrorAction Stop -Encoding UTF8
    # Match both commented (#key=value) and uncommented (key=value) lines
    $pattern = "(?m)^#?\s*" + [Regex]::Escape($key) + "\s*=.*$"
    if ($lines -match $pattern) {
        # Use MatchEvaluator: Regex.Replace substitution string treats \U, \E, $n etc. as special,
        # so Windows paths like C:\Users\... get corrupted. A scriptblock avoids substitution rules.
        $k = $key
        $v = $value
        $lines = [Regex]::Replace($lines, $pattern, {
            param($match)
            return '{0}={1}' -f $k, $v
        })
    } else {
        $nl = [Environment]::NewLine
        if (-not $lines.EndsWith($nl)) { $lines += $nl }
        $lines += ('{0}={1}{2}' -f $key, $value, $nl)
    }
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
}
