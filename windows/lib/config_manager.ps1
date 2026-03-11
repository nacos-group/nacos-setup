# Configuration management for Windows nacos-setup
. $PSScriptRoot\common.ps1

# Cross-platform user profile detection
$userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { "." }
$Global:DefaultDatasourceConfig = Join-Path $userProfile "ai-infra\nacos\default.properties"

function Load-DefaultDatasourceConfig {
    $configPath = if ($env:DEFAULT_DATASOURCE_CONFIG) { $env:DEFAULT_DATASOURCE_CONFIG } else { $Global:DefaultDatasourceConfig }
    if (Test-Path $configPath -PathType Leaf) {
        $content = Get-Content -Path $configPath | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
        if ($content -match '^(spring\.(datasource|sql\.init)\.platform|db\.num)') {
            return $configPath
        }
    }
    return $null
}

function Apply-DatasourceConfig($configFile, $datasourceFile) {
    if (-not (Test-Path $configFile)) { throw "Config file not found: $configFile" }
    if (-not $datasourceFile -or -not (Test-Path $datasourceFile)) { return $false }

    $lines = Get-Content -Path $datasourceFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
    foreach ($line in $lines) {
        if ($line -match '^(.*?)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            Update-ConfigProperty $configFile $key $value
        }
    }
    return $true
}

function Configure-Derby-For-Cluster($configFile) {
    Update-ConfigProperty $configFile "spring.sql.init.platform" "derby"
    $lines = Get-Content -Path $configFile -Raw -Encoding UTF8
    $lines = [Regex]::Replace($lines, "(?m)^spring\.datasource\.platform=.*$", "")
    $lines = [Regex]::Replace($lines, "(?m)^db\.(num|url|user|password).*\n?", "")
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
}

function Apply-SecurityConfig($configFile, $tokenSecret, $identityKey, $identityValue) {
    Update-ConfigProperty $configFile "nacos.core.auth.enabled" "true"
    Update-ConfigProperty $configFile "nacos.core.auth.plugin.nacos.token.secret.key" $tokenSecret
    Update-ConfigProperty $configFile "nacos.core.auth.server.identity.key" $identityKey
    Update-ConfigProperty $configFile "nacos.core.auth.server.identity.value" $identityValue
}

function Configure-Standalone-Security($configFile, $advancedMode) {
    if (-not $advancedMode) {
        $Global:TOKEN_SECRET = Generate-SecretKey
        $Global:IDENTITY_KEY = "nacos_identity_" + [int][double]::Parse((Get-Date -UFormat %s))
        $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16)
        $Global:NACOS_PASSWORD = Generate-Password
        
        Write-Host ""
        Write-Info "===================================="
        Write-Info "Auto-Generated Security Configuration"
        Write-Info "===================================="
        Write-Host ""
        Write-Host "JWT Token Secret Key:"
        Write-Host "  $($Global:TOKEN_SECRET)"
        Write-Host ""
        Write-Host "Server Identity Key:"
        Write-Host "  $($Global:IDENTITY_KEY)"
        Write-Host ""
        Write-Host "Server Identity Value:"
        Write-Host "  $($Global:IDENTITY_VALUE)"
        Write-Host ""
        Write-Host "Admin Password:"
        Write-Host "  $($Global:NACOS_PASSWORD)"
        Write-Host ""
        Write-Info "These credentials will be automatically configured"
    } else {
        $Global:TOKEN_SECRET = Read-Host "Enter JWT token secret key (empty for auto)"
        if (-not $Global:TOKEN_SECRET) { $Global:TOKEN_SECRET = Generate-SecretKey }
        $Global:IDENTITY_KEY = Read-Host "Enter server identity key (empty for auto)"
        if (-not $Global:IDENTITY_KEY) { $Global:IDENTITY_KEY = "nacos_identity_" + [int][double]::Parse((Get-Date -UFormat %s)) }
        $Global:IDENTITY_VALUE = Read-Host "Enter server identity value (empty for auto)"
        if (-not $Global:IDENTITY_VALUE) { $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16) }
        $Global:NACOS_PASSWORD = Read-Host "Enter admin password (empty for auto)"
        if (-not $Global:NACOS_PASSWORD) { $Global:NACOS_PASSWORD = Generate-Password }
    }

    Apply-SecurityConfig $configFile $Global:TOKEN_SECRET $Global:IDENTITY_KEY $Global:IDENTITY_VALUE
}

function Configure-Cluster-Security($clusterDir, $advancedMode) {
    Write-Host ""
    
    if (-not $advancedMode) {
        Write-Info "Simplified mode: Auto-generating shared security keys for cluster..."
        
        $Global:TOKEN_SECRET = Generate-SecretKey
        $Global:IDENTITY_KEY = "nacos_cluster_" + [int][double]::Parse((Get-Date -UFormat %s))
        $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16)
        $Global:NACOS_PASSWORD = Generate-Password
        
        Write-Host ""
        Write-Info "==========================================="
        Write-Info "Auto-Generated Cluster Security Configuration"
        Write-Info "==========================================="
        Write-Host ""
        Write-Host "JWT Token Secret Key:"
        Write-Host "  $($Global:TOKEN_SECRET)"
        Write-Host ""
        Write-Host "Server Identity Key:"
        Write-Host "  $($Global:IDENTITY_KEY)"
        Write-Host ""
        Write-Host "Server Identity Value:"
        Write-Host "  $($Global:IDENTITY_VALUE)"
        Write-Host ""
        Write-Info "These credentials will be shared across all cluster nodes"
        Write-Info "Admin password will be set after cluster startup"
        Write-Host ""
    } else {
        $Global:TOKEN_SECRET = Read-Host "Enter JWT token secret key (empty for auto)"
        if (-not $Global:TOKEN_SECRET) { $Global:TOKEN_SECRET = Generate-SecretKey }
        $Global:IDENTITY_KEY = Read-Host "Enter server identity key (empty for auto)"
        if (-not $Global:IDENTITY_KEY) { $Global:IDENTITY_KEY = "nacos_cluster_" + [int][double]::Parse((Get-Date -UFormat %s)) }
        $Global:IDENTITY_VALUE = Read-Host "Enter server identity value (empty for auto)"
        if (-not $Global:IDENTITY_VALUE) { $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16) }
        $Global:NACOS_PASSWORD = Read-Host "Enter admin password (empty for auto)"
        if (-not $Global:NACOS_PASSWORD) { $Global:NACOS_PASSWORD = Generate-Password }
    }

    $shareFile = Join-Path $clusterDir "share.properties"
    @"
# Nacos Cluster Shared Security Configuration
nacos.core.auth.plugin.nacos.token.secret.key=$($Global:TOKEN_SECRET)
nacos.core.auth.server.identity.key=$($Global:IDENTITY_KEY)
nacos.core.auth.server.identity.value=$($Global:IDENTITY_VALUE)
admin.password=$($Global:NACOS_PASSWORD)
"@ | Set-Content -Path $shareFile -Encoding UTF8
    
    Write-Info "Security configuration saved to: $shareFile"
}

function Update-PortConfig($configFile, $serverPort, $consolePort, $nacosVersion) {
    if ([string]::IsNullOrWhiteSpace($configFile)) { throw "Update-PortConfig: Config file path is missing" }
    $major = [int]($nacosVersion.Split('.')[0])
    if ($major -ge 3) {
        Update-ConfigProperty $configFile "nacos.server.main.port" $serverPort
        Update-ConfigProperty $configFile "nacos.console.port" $consolePort
    } else {
        Update-ConfigProperty $configFile "server.port" $serverPort
    }
}

function Edit-DatasourceConfig($configFile = $null) {
    $targetFile = if ($configFile -and $configFile -ne "default") { $configFile } else { $Global:DefaultDatasourceConfig }
    Ensure-Directory (Split-Path $targetFile -Parent)

    Write-Host ""
    Write-Info "========================================"
    Write-Info "External Datasource Configuration"
    Write-Info "========================================"
    Write-Host ""
    Write-Host "This will create a datasource configuration for Nacos."
    Write-Host "Supported databases: MySQL, PostgreSQL"
    Write-Host ""

    if (Test-Path $targetFile) {
        Write-Warn "Existing configuration found at: $targetFile"
        $confirm = Read-Host "Overwrite? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Info "Operation cancelled"
            return
        }
    }

    $dbType = Read-Host "Database type (mysql/postgresql)"
    if (-not $dbType) { throw "Database type is required" }
    $dbType = $dbType.ToLower()
    if ($dbType -ne "mysql" -and $dbType -ne "postgresql") { throw "Unsupported database type" }

    $host = Read-Host "Database host (default: localhost)"
    if (-not $host) { $host = "localhost" }

    $defaultPort = if ($dbType -eq "mysql") { "3306" } else { "5432" }
    $port = Read-Host "Database port (default: $defaultPort)"
    if (-not $port) { $port = $defaultPort }

    $dbName = Read-Host "Database name (default: nacos)"
    if (-not $dbName) { $dbName = "nacos" }

    $user = Read-Host "Database username"
    if (-not $user) { throw "Database username is required" }

    $pass = Read-Host "Database password" -AsSecureString
    $passPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

    if ($dbType -eq "mysql") {
        $jdbc = "jdbc:mysql://$host`:$port/$dbName?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useUnicode=true&useSSL=false&serverTimezone=UTC"
    } else {
        $jdbc = "jdbc:postgresql://$host`:$port/$dbName?stringtype=unspecified"
    }

    @"
# Nacos datasource config (auto-generated)
spring.sql.init.platform=$dbType
spring.datasource.platform=$dbType
db.num=1
db.url.0=$jdbc
db.user.0=$user
db.password.0=$passPlain
"@ | Set-Content -Path $targetFile -Encoding UTF8

    Write-Host ""
    Write-Info "Datasource configuration saved to: $targetFile"
    Write-Host ""
    Write-Info "Configuration Summary:"
    Write-Host "  Platform:  $dbType"
    Write-Host "  Host:      $host"
    Write-Host "  Port:      $port"
    Write-Host "  Database:  $dbName"
    Write-Host "  User:      $user"
}

function Show-DatasourceConfig($configFile = $null) {
    $targetFile = if ($configFile -and $configFile -ne "default") { $configFile } else { $Global:DefaultDatasourceConfig }

    Write-Host ""
    Write-Info "========================================"
    Write-Info "Datasource Configuration"
    Write-Info "========================================"
    Write-Host ""

    if (-not (Test-Path $targetFile)) {
        Write-Warn "No datasource configuration found at: $targetFile"
        Write-Host ""
        Write-Info "To create a configuration, run:"
        Write-Info "  nacos-setup db-conf edit [FILE]"
        return
    }

    Write-Info "File: $targetFile"
    Write-Host ""
    Get-Content -Path $targetFile | ForEach-Object { Write-Host $_ }
    Write-Host ""
}
