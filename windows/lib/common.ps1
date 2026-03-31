# Common utilities for Windows nacos-setup

$Global:ColorInfo = "Cyan"
$Global:ColorWarn = "Yellow"
$Global:ColorError = "Red"
$Global:ColorSuccess = "Green"

function Get-LogTimestamp {
    return Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

function Get-NacosSetupLogDirectory {
    $profile = if ($env:REAL_USER_PROFILE) { $env:REAL_USER_PROFILE }
        elseif ($env:USERPROFILE) { $env:USERPROFILE }
        else { "." }
    Join-Path $profile ".nacos\logs"
}

function Get-NacosSetupLogFile {
    Join-Path (Get-NacosSetupLogDirectory) "nacos-setup.log"
}

# Append one line to ~/.nacos/logs/nacos-setup.log (UTF-8). Safe to call when console closes.
function Write-NacosSetupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO"
    )
    try {
        $dir = Get-NacosSetupLogDirectory
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $logFile = Get-NacosSetupLogFile
        $ts = Get-LogTimestamp
        foreach ($segment in ($Message -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            Add-Content -LiteralPath $logFile -Value "$ts [$Level] $segment" -Encoding UTF8
        }
    } catch {}
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
        # Replace with uncommented version
        $lines = [Regex]::Replace($lines, $pattern, "$key=$value")
    } else {
        if (-not $lines.EndsWith("`n")) { $lines += "`n" }
        $lines += "$key=$value`n"
    }
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
}
