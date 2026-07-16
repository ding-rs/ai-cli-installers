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

    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
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

function Protect-PrivateFile {
    param([string]$Path)

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($currentIdentity)
        $acl.SetAccessRuleProtection($true, $false)
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $currentIdentity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($accessRule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        $chmodCommand = Get-Command -Name 'chmod' -CommandType Application -ErrorAction Stop
        & $chmodCommand.Source '600' $Path
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not restrict private file permissions.'
        }
    }
}

function Test-PrivateFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $acl = Get-Acl -LiteralPath $Path
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $acl.AreAccessRulesProtected) {
            return $false
        }
        $allowRules = @($acl.Access | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        })
        if ($allowRules.Count -eq 0) {
            return $false
        }
        foreach ($rule in $allowRules) {
            try {
                $ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                if (-not $ruleSid.Equals($currentSid)) {
                    return $false
                }
            }
            catch {
                return $false
            }
        }
        return $true
    }

    $mode = [System.IO.File]::GetUnixFileMode($Path)
    $expectedMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
    return $mode -eq $expectedMode
}

function New-EmptyPrivateFile {
    param([string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    try {
        Protect-PrivateFile -Path $Path
        if (-not (Test-PrivateFile -Path $Path)) {
            throw 'Private file permission verification failed.'
        }
    }
    catch {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        throw
    }
}

function Write-BytesToPrivateFile {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    if (-not (Test-PrivateFile -Path $Path)) {
        throw 'Refusing to write content to a file that is not private.'
    }

    $stream = $null
    $writeFailure = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.SetLength(0)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    }
    catch {
        $writeFailure = $_
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($null -ne $writeFailure) {
        try {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force
            }
        }
        catch {
            throw 'Could not remove a partially written private file.'
        }
        throw $writeFailure
    }
}

function Write-PrivateTextFile {
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding
    )

    New-EmptyPrivateFile -Path $Path
    Write-BytesToPrivateFile -Path $Path -Bytes $Encoding.GetBytes($Content)
}

function Copy-ToPrivateFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $bytes = [System.IO.File]::ReadAllBytes($Source)
    New-EmptyPrivateFile -Path $Destination
    Write-BytesToPrivateFile -Path $Destination -Bytes $bytes
}

function Resolve-ClaudeConfigurationPath {
    param([string]$HomePath)

    $logicalPath = Join-Path -Path $HomePath -ChildPath '.claude.json'
    $currentPath = [System.IO.Path]::GetFullPath($logicalPath)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $pathComparer = [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        $pathComparer = [System.StringComparer]::Ordinal
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $followedLink = $false

    for ($hop = 0; $hop -lt 32; $hop++) {
        $currentPath = [System.IO.Path]::GetFullPath($currentPath)
        if (-not $seen.Add($currentPath)) {
            throw 'Claude configuration symlink is cyclic; no installation or configuration was changed.'
        }

        try {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        }
        catch {
            if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
                if ($followedLink) {
                    throw 'Claude configuration symlink is broken; no installation or configuration was changed.'
                }
                return [PSCustomObject]@{
                    LogicalPath = $logicalPath
                    TargetPath = $currentPath
                    Existed = $false
                }
            }
            throw
        }

        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isReparsePoint) {
            $targets = @($item.Target)
            if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
                throw 'Claude configuration reparse point target could not be resolved safely.'
            }
            $target = [string]$targets[0]
            if ([System.IO.Path]::IsPathRooted($target)) {
                $currentPath = $target
            }
            else {
                $currentPath = Join-Path -Path (Split-Path -Parent $currentPath) -ChildPath $target
            }
            $followedLink = $true
            continue
        }

        if ($item.PSIsContainer) {
            throw "Claude configuration path is not a file: $logicalPath"
        }

        return [PSCustomObject]@{
            LogicalPath = $logicalPath
            TargetPath = $currentPath
            Existed = $true
        }
    }

    throw 'Claude configuration symlink exceeded the safe resolution depth.'
}

function Merge-ClaudeConfiguration {
    param([pscustomobject]$PathState)

    $configPath = $PathState.LogicalPath
    $configTarget = $PathState.TargetPath
    $config = [PSCustomObject]@{}
    $configExisted = $PathState.Existed
    $backupPath = $null

    if ($configExisted) {
        $backupPath = Get-NextBackupPath -Path $configPath
        try {
            Copy-ToPrivateFile -Source $configTarget -Destination $backupPath
        }
        catch {
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            throw
        }

        try {
            $rawConfig = [System.IO.File]::ReadAllText($configTarget)
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

    $tempPath = "$configTarget.ai-cli-installers.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    $replacementBackupPath = "$configTarget.ai-cli-installers.replace.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $config | ConvertTo-Json -Depth 100
        $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
        Write-PrivateTextFile -Path $tempPath -Content ($json + [Environment]::NewLine) -Encoding $utf8WithoutBom
        if ($configExisted) {
            Protect-PrivateFile -Path $configTarget
            if (-not (Test-PrivateFile -Path $configTarget)) {
                throw 'Existing Claude configuration could not be made private before replacement.'
            }
            New-EmptyPrivateFile -Path $replacementBackupPath
            $replacementCompleted = $false
            try {
                [System.IO.File]::Replace($tempPath, $configTarget, $replacementBackupPath)
                $replacementCompleted = $true
                if (-not (Test-PrivateFile -Path $configTarget) -or
                    -not (Test-PrivateFile -Path $replacementBackupPath) -or
                    -not (Test-PrivateFile -Path $backupPath)) {
                    throw 'Claude configuration replacement did not preserve private permissions.'
                }
                Remove-Item -LiteralPath $replacementBackupPath -Force
            }
            catch {
                if ($replacementCompleted -and (Test-Path -LiteralPath $backupPath)) {
                    try {
                        Restore-ClaudeConfigurationTarget -TargetPath $configTarget -BackupPath $backupPath
                    }
                    catch {
                        throw 'Could not restore Claude configuration after backup permission hardening failed.'
                    }
                }
                throw
            }
        }
        else {
            Move-Item -LiteralPath $tempPath -Destination $configTarget
            if (-not (Test-PrivateFile -Path $configTarget)) {
                Remove-Item -LiteralPath $configTarget -Force
                throw 'New Claude configuration did not preserve private permissions.'
            }
        }
    }
    finally {
        foreach ($path in @($tempPath, $replacementBackupPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    return [PSCustomObject]@{
        Path = $configTarget
        LogicalPath = $configPath
        Existed = $configExisted
        BackupPath = $backupPath
    }
}

function Restore-ClaudeConfigurationTarget {
    param(
        [string]$TargetPath,
        [string]$BackupPath
    )

    if (-not (Test-PrivateFile -Path $BackupPath)) {
        throw 'Claude configuration backup is not private enough for rollback.'
    }

    $restorePath = "$TargetPath.ai-cli-installers.restore.$PID.$([Guid]::NewGuid().ToString('N'))"
    $discardPath = "$TargetPath.ai-cli-installers.discard.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-ToPrivateFile -Source $BackupPath -Destination $restorePath
        if (Test-Path -LiteralPath $TargetPath) {
            try {
                Protect-PrivateFile -Path $TargetPath
            }
            catch {
                Remove-Item -LiteralPath $TargetPath -Force
                Move-Item -LiteralPath $restorePath -Destination $TargetPath
                if (-not (Test-PrivateFile -Path $TargetPath)) {
                    Remove-Item -LiteralPath $TargetPath -Force
                    throw 'Restored Claude configuration is not private.'
                }
                return
            }

            New-EmptyPrivateFile -Path $discardPath
            [System.IO.File]::Replace($restorePath, $TargetPath, $discardPath)
            if (-not (Test-PrivateFile -Path $TargetPath)) {
                throw 'Restored Claude configuration is not private.'
            }
        }
        else {
            Move-Item -LiteralPath $restorePath -Destination $TargetPath
        }
    }
    finally {
        foreach ($path in @($restorePath, $discardPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
}

function Restore-ClaudeConfiguration {
    param([pscustomobject]$State)

    if ($State.Existed) {
        if ([string]::IsNullOrWhiteSpace([string]$State.BackupPath) -or
            -not (Test-Path -LiteralPath $State.BackupPath)) {
            throw 'Claude configuration backup is unavailable for rollback.'
        }
        Restore-ClaudeConfigurationTarget -TargetPath $State.Path -BackupPath $State.BackupPath
    }
    elseif (Test-Path -LiteralPath $State.Path) {
        Remove-Item -LiteralPath $State.Path -Force
    }
}

function Refresh-SessionPath {
    $currentPath = $env:Path
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $pathComparer = [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        $pathComparer = [System.StringComparer]::Ordinal
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $pathParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sourcePath in @($currentPath, $machinePath, $userPath)) {
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            continue
        }

        foreach ($entry in $sourcePath.Split([System.IO.Path]::PathSeparator)) {
            if (-not [string]::IsNullOrWhiteSpace($entry) -and $seen.Add($entry)) {
                $pathParts.Add($entry)
            }
        }
    }

    $env:Path = $pathParts.ToArray() -join [System.IO.Path]::PathSeparator
}

function Invoke-ClaudeInstaller {
    param([string]$Uri)

    $secretEnvironmentNames = @(
        'AI_API_KEY',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'CLAUDE_CODE_OAUTH_TOKEN'
    )
    $savedSecretEnvironment = @{}
    $installerScriptPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("claude-installer-$PID-$([Guid]::NewGuid().ToString('N')).ps1")
    foreach ($name in $secretEnvironmentNames) {
        $savedSecretEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        foreach ($name in $secretEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }

        $installerSource = Invoke-RestMethod -Uri $Uri -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$installerSource)) {
            throw 'The installer response was empty.'
        }
        $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
        Write-PrivateTextFile -Path $installerScriptPath -Content ([string]$installerSource) -Encoding $utf8WithBom

        $powerShellExecutable = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($powerShellExecutable)) {
            throw 'Could not locate the current PowerShell executable.'
        }
        & $powerShellExecutable -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installerScriptPath
        if ($LASTEXITCODE -ne 0) {
            throw 'The downloaded installer process failed.'
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
    finally {
        if (Test-Path -LiteralPath $installerScriptPath) {
            Remove-Item -LiteralPath $installerScriptPath -Force
        }
        foreach ($name in $secretEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $savedSecretEnvironment[$name], 'Process')
        }
    }
}

function Restore-ClaudeEnvironment {
    param(
        [hashtable]$ProcessValues,
        [hashtable]$UserValues
    )

    $rollbackFailures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL')) {
        try {
            [Environment]::SetEnvironmentVariable($name, $UserValues[$name], 'User')
        }
        catch {
            $rollbackFailures.Add("User:$name")
        }
        try {
            [Environment]::SetEnvironmentVariable($name, $ProcessValues[$name], 'Process')
        }
        catch {
            $rollbackFailures.Add("Process:$name")
        }
    }

    if ($rollbackFailures.Count -gt 0) {
        throw 'One or more Claude environment values could not be restored.'
    }
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
    throw 'Endpoint must be an exact http:// or https:// URL without userinfo, query, fragment, whitespace, control characters, backslashes, or an empty host.'
}
if ([string]::IsNullOrEmpty($Key)) {
    throw 'API key must not be empty.'
}

$homePath = $HOME
if ([string]::IsNullOrWhiteSpace($homePath)) {
    $homePath = $env:USERPROFILE
}
if ([string]::IsNullOrWhiteSpace($homePath)) {
    throw 'Could not determine the user home directory for .claude.json.'
}
$configurationPathState = Resolve-ClaudeConfigurationPath -HomePath $homePath

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
        Invoke-ClaudeInstaller -Uri $InstallUrl
    }
    catch {
        throw "The official Claude Code installer failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host 'Keeping the existing Claude Code installation.'
}

$environmentNames = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN')
$originalProcessEnvironment = @{}
$originalUserEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalProcessEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    $originalUserEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
}

$configurationState = $null
try {
    $configurationState = Merge-ClaudeConfiguration -PathState $configurationPathState

    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $Endpoint, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $Endpoint, 'User')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $Key, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $Key, 'User')
}
catch {
    $configurationFailure = $_
    $rollbackFailed = $false
    try {
        Restore-ClaudeEnvironment -ProcessValues $originalProcessEnvironment -UserValues $originalUserEnvironment
    }
    catch {
        $rollbackFailed = $true
    }
    if ($null -ne $configurationState) {
        try {
            Restore-ClaudeConfiguration -State $configurationState
        }
        catch {
            $rollbackFailed = $true
        }
    }

    if ($rollbackFailed) {
        throw 'Claude configuration failed and could not be fully rolled back; preserved backups were left in place.'
    }
    throw $configurationFailure
}

Write-Host 'Claude Code configuration is ready. The API key was stored without being displayed.'
