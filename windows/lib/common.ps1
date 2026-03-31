# Common utilities for Windows nacos-setup

$Global:ColorInfo = "Cyan"
$Global:ColorWarn = "Yellow"
$Global:ColorError = "Red"
$Global:ColorSuccess = "Green"

# Align with bash nacos-setup.sh VERBOSE / print_detail
$Global:NacosSetupVerbose = $false

function Test-NacosSetupVerbose {
    return ($Global:NacosSetupVerbose -eq $true) -or ($env:VERBOSE -eq "true")
}

function Write-Detail($msg) {
    if (Test-NacosSetupVerbose) {
        Write-Host "[INFO] $msg" -ForegroundColor $Global:ColorInfo
    }
}

function Write-NacosSetupStepOk($current, $total, $desc, $result = "") {
    if ($result) {
        Write-Host "[$current/${total}] ${desc} ✓ ${result}" -ForegroundColor $Global:ColorSuccess
    } else {
        Write-Host "[$current/${total}] ${desc} ✓" -ForegroundColor $Global:ColorSuccess
    }
}

function Write-NacosSetupStepFail($current, $total, $desc, $result = "failed") {
    Write-Host "[$current/${total}] ${desc} ✗ ${result}" -ForegroundColor $Global:ColorError
}

$script:NacosSetupProgressSlot = 0
function Start-NacosSetupStepProgress($current, $total, $desc) {
    if (Test-NacosSetupVerbose) { return }
    $pct = [math]::Min(100, [math]::Max(0, [int](100.0 * $current / $total)))
    Write-Progress -Id $script:NacosSetupProgressSlot -Activity "Nacos Setup" -Status "[$current/$total] $desc" -PercentComplete $pct
}

function Stop-NacosSetupStepProgress() {
    Write-Progress -Id $script:NacosSetupProgressSlot -Activity "Nacos Setup" -Completed
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
