#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Endpoint,
    [string]$Key,
    [switch]$Yes,
    [switch]$Reinstall,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$InstallUrl = 'https://claude.ai/install.ps1'

function Test-ExactEndpoint {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value) -or
        $Value -match '[\s\\]' -or
        $Value.Contains('?') -or
        $Value.Contains('#')) {
        return $false
    }

    if ($Value -cnotmatch '^https?://') {
        return $false
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    if (($uri.Scheme -cne 'http' -and $uri.Scheme -cne 'https') -or
        [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }

    $authorityStart = $Value.IndexOf('://', [System.StringComparison]::Ordinal) + 3
    $pathStart = $Value.IndexOf('/', $authorityStart)
    if ($pathStart -ge 0) {
        $authority = $Value.Substring($authorityStart, $pathStart - $authorityStart)
    }
    else {
        $authority = $Value.Substring($authorityStart)
    }

    if ($authority.StartsWith('[')) {
        $closingBracket = $authority.IndexOf(']')
        if ($closingBracket -le 1) {
            return $false
        }

        $portSuffix = $authority.Substring($closingBracket + 1)
        if ($portSuffix.Length -gt 0 -and $portSuffix -notmatch '^:[0-9]+$') {
            return $false
        }
    }
    else {
        $firstColon = $authority.IndexOf(':')
        if ($firstColon -ge 0) {
            if ($firstColon -ne $authority.LastIndexOf(':')) {
                return $false
            }

            $port = $authority.Substring($firstColon + 1)
            if ([string]::IsNullOrEmpty($port) -or $port -notmatch '^[0-9]+$') {
                return $false
            }
        }
    }

    return $true
}

function Get-NextBackupPath {
    param([string]$Path)

    $candidate = "$Path.ai-cli-installers.bak"
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$Path.ai-cli-installers.bak.$suffix"
        $suffix++
    }
    return $candidate
}

function Merge-ClaudeConfiguration {
    param([string]$HomePath)

    $configPath = Join-Path -Path $HomePath -ChildPath '.claude.json'
    $config = [PSCustomObject]@{}

    if (Test-Path -LiteralPath $configPath) {
        $configItem = Get-Item -LiteralPath $configPath
        if ($configItem.PSIsContainer) {
            throw "Claude configuration path is not a file: $configPath"
        }

        $backupPath = Get-NextBackupPath -Path $configPath
        Copy-Item -LiteralPath $configPath -Destination $backupPath

        try {
            $rawConfig = [System.IO.File]::ReadAllText($configPath)
            if ($rawConfig -notmatch '^\s*\{') {
                throw 'The top-level JSON value is not an object.'
            }
            $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $config -or $config -isnot [PSCustomObject]) {
                throw 'The top-level JSON value is not an object.'
            }
        }
        catch {
            throw 'Existing Claude configuration is not a valid JSON object; it was backed up and the original was left unchanged.'
        }
    }

    if ($null -eq $config.PSObject.Properties['hasCompletedOnboarding']) {
        $config | Add-Member -NotePropertyName 'hasCompletedOnboarding' -NotePropertyValue $true
    }
    else {
        $config.hasCompletedOnboarding = $true
    }

    $tempPath = "$configPath.ai-cli-installers.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $config | ConvertTo-Json -Depth 100
        $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, $utf8WithoutBom)
        if (Test-Path -LiteralPath $configPath) {
            [System.IO.File]::Replace($tempPath, $configPath, $null)
        }
        else {
            Move-Item -LiteralPath $tempPath -Destination $configPath -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @()

    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $pathParts += $machinePath
    }
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $pathParts += $userPath
    }

    $env:Path = $pathParts -join [System.IO.Path]::PathSeparator
}

if (-not $PSBoundParameters.ContainsKey('Endpoint')) {
    $Endpoint = $env:AI_ENDPOINT
}
if (-not $PSBoundParameters.ContainsKey('Key')) {
    $Key = $env:AI_API_KEY
}
if (-not $PSBoundParameters.ContainsKey('Yes') -and $env:AI_INSTALL_YES -eq '1') {
    $Yes = $true
}

if ([string]::IsNullOrEmpty($Endpoint)) {
    if ($Yes) {
        throw 'Endpoint is required in unattended mode; pass -Endpoint or set AI_ENDPOINT.'
    }
    $Endpoint = Read-Host -Prompt 'Exact API endpoint'
}

if ([string]::IsNullOrEmpty($Key)) {
    if ($Yes) {
        throw 'API key is required in unattended mode; pass -Key or set AI_API_KEY.'
    }
    $secureKey = Read-Host -Prompt 'API key' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new('api', $secureKey)
    $Key = $credential.GetNetworkCredential().Password
}

$Endpoint = $Endpoint.TrimEnd('/')
if (-not (Test-ExactEndpoint -Value $Endpoint)) {
    throw 'Endpoint must be an exact http:// or https:// URL without userinfo, query, fragment, whitespace, or an empty host.'
}
if ([string]::IsNullOrEmpty($Key)) {
    throw 'API key must not be empty.'
}

$existingCommand = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
$installRequested = $false
if ($Reinstall) {
    $installRequested = $true
}
elseif ($null -eq $existingCommand) {
    $installRequested = $true
}
elseif ($Yes) {
    $installRequested = $false
}
else {
    $answer = Read-Host -Prompt 'Claude Code is already installed. Reinstall or update it? [y/N]'
    $installRequested = $answer -match '^(?i:y|yes)$'
}

if ($DryRun) {
    Write-Host 'Dry run: endpoint is valid and the API key is set (masked).'
    if ($installRequested) {
        if ($null -ne $existingCommand) {
            Write-Host "Dry run: would reinstall Claude Code with the official installer from $InstallUrl."
        }
        else {
            Write-Host "Dry run: would install Claude Code with the official installer from $InstallUrl."
        }
    }
    else {
        Write-Host 'Dry run: would keep the existing Claude Code installation.'
    }
    Write-Host 'Dry run: would configure the endpoint, masked token, and onboarding state.'
    return
}

if ($installRequested) {
    Write-Host "Running the official Claude Code installer from $InstallUrl ..."
    try {
        $installerSource = Invoke-RestMethod -Uri $InstallUrl -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$installerSource)) {
            throw 'The installer response was empty.'
        }
        $installerBlock = [ScriptBlock]::Create([string]$installerSource)
        & $installerBlock
    }
    catch {
        throw "The official Claude Code installer failed: $($_.Exception.Message)"
    }

    Refresh-SessionPath
    $installedCommand = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
    if ($null -eq $installedCommand) {
        throw 'Claude Code was not available after installation.'
    }

    & 'claude' '--version' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Claude Code version verification failed after installation.'
    }
}
else {
    Write-Host 'Keeping the existing Claude Code installation.'
}

$homePath = $HOME
if ([string]::IsNullOrWhiteSpace($homePath)) {
    $homePath = $env:USERPROFILE
}
if ([string]::IsNullOrWhiteSpace($homePath)) {
    throw 'Could not determine the user home directory for .claude.json.'
}

Merge-ClaudeConfiguration -HomePath $homePath

[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $Endpoint, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $Endpoint, 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $Key, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $Key, 'User')

Write-Host 'Claude Code configuration is ready. The API key was stored without being displayed.'
