#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:SubjectPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'claude-code.ps1'
$script:IsWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:Sandboxes = New-Object 'System.Collections.Generic.List[string]'
$script:UniqueKey = 'sk-ant-unique-behavior-test-71c9253f'
$script:OriginalMixedCasePath = [Environment]::GetEnvironmentVariable('Path', 'Process')

$script:OriginalProcessValues = @{}
foreach ($name in @(
    'PATH',
    'HOME',
    'USERPROFILE',
    'AI_ENDPOINT',
    'AI_API_KEY',
    'AI_INSTALL_YES',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'FAKE_BIN',
    'FAKE_FETCH_LOG',
    'FAKE_INSTALL_LOG',
    'FAKE_SECRET_ENV_LOG',
    'FAKE_PROTECT_LOG',
    'FAKE_FINAL_TARGET'
)) {
    $script:OriginalProcessValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$script:OriginalUserValues = @{}
if ($script:IsWindowsPlatform) {
    foreach ($name in @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'Path')) {
        $script:OriginalUserValues[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    [System.IO.File]::AppendAllText($env:FAKE_FETCH_LOG, $Uri + [Environment]::NewLine)
    foreach ($name in @('AI_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            [System.IO.File]::AppendAllText($env:FAKE_SECRET_ENV_LOG, "fetch:$name" + [Environment]::NewLine)
        }
    }
    return @'
foreach ($name in @('AI_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))) {
        [System.IO.File]::AppendAllText($env:FAKE_SECRET_ENV_LOG, "installer:$name" + [Environment]::NewLine)
    }
}
$visibleKey = Get-Variable -Name 'Key' -ValueOnly -ErrorAction SilentlyContinue
if (-not [string]::IsNullOrEmpty([string]$visibleKey)) {
    [System.IO.File]::AppendAllText($env:FAKE_SECRET_ENV_LOG, 'installer:KeyVariable' + [Environment]::NewLine)
}
[System.IO.File]::AppendAllText($env:FAKE_INSTALL_LOG, "installer-ran" + [Environment]::NewLine)
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $commandPath = Join-Path -Path $env:FAKE_BIN -ChildPath 'claude.cmd'
    $commandBody = "@echo off`r`nif `"%~1`"==`"--version`" echo Claude fake 1.0`r`nexit /b 0`r`n"
    [System.IO.File]::WriteAllText($commandPath, $commandBody)
}
else {
    $commandPath = Join-Path -Path $env:FAKE_BIN -ChildPath 'claude'
    $truePath = '/usr/bin/true'
    if (-not (Test-Path -LiteralPath $truePath)) {
        $truePath = '/bin/true'
    }
    Copy-Item -LiteralPath $truePath -Destination $commandPath
}
'@
}

function Add-Failure {
    param([string]$Message)

    $script:Failures++
    [Console]::Error.WriteLine("not ok - $Message")
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        Add-Failure -Message $Message
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        Add-Failure -Message $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Expected,
        [AllowNull()]
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -cne $Actual) {
        Add-Failure -Message $Message
    }
}

function Assert-PathExists {
    param(
        [string]$Path,
        [string]$Message
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message $Message
}

function Assert-PathMissing {
    param(
        [string]$Path,
        [string]$Message
    )

    Assert-False -Condition (Test-Path -LiteralPath $Path) -Message $Message
}

function Assert-FileContains {
    param(
        [string]$Path,
        [string]$Expected,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure -Message $Message
        return
    }

    $content = [System.IO.File]::ReadAllText($Path)
    Assert-True -Condition $content.Contains($Expected) -Message $Message
}

function Assert-FileEmpty {
    param(
        [string]$Path,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure -Message $Message
        return
    }

    Assert-Equal -Expected 0L -Actual (Get-Item -LiteralPath $Path).Length -Message $Message
}

function Assert-PrivateFile {
    param(
        [string]$Path,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure -Message $Message
        return
    }

    if ($script:IsWindowsPlatform) {
        $acl = Get-Acl -LiteralPath $Path
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $allowRules = @($acl.Access | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        })
        $onlyCurrentUser = $allowRules.Count -gt 0
        foreach ($rule in $allowRules) {
            try {
                $ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                if (-not $ruleSid.Equals($currentSid)) {
                    $onlyCurrentUser = $false
                }
            }
            catch {
                $onlyCurrentUser = $false
            }
        }
        Assert-True -Condition ($acl.AreAccessRulesProtected -and $onlyCurrentUser) -Message $Message
    }
    else {
        $mode = [System.IO.File]::GetUnixFileMode($Path)
        $expectedMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        Assert-Equal -Expected $expectedMode -Actual $mode -Message $Message
    }
}

function Get-TestPathEntryFromParent {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if ($script:IsWindowsPlatform) {
        $nameComparer = [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        $nameComparer = [System.StringComparer]::Ordinal
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop)) {
        if ($nameComparer.Equals($entry.Name, $leaf)) {
            return $entry
        }
    }
    return $null
}

function Assert-SymbolicLinkSnapshot {
    param(
        [string]$Path,
        [pscustomobject]$ExpectedSnapshot,
        [switch]$RequireTarget,
        [string]$Message
    )

    try {
        $item = Get-TestPathEntryFromParent -Path $Path
        if ($null -eq $item) {
            throw "Link entry is missing: $Path"
        }
        $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        Assert-True -Condition $isLink -Message $Message
        if (-not $isLink) {
            return
        }
        try {
            $target = [string]$item.Target
            if ($ExpectedSnapshot.TargetReadable) {
                Assert-Equal -Expected $ExpectedSnapshot.Target -Actual $target -Message $Message
            }
            else {
                Assert-Equal -Expected $ExpectedSnapshot.RequestedTarget -Actual $target -Message $Message
            }
        }
        catch {
            if ($RequireTarget) {
                Add-Failure -Message $Message
            }
        }
    }
    catch {
        Add-Failure -Message $Message
    }
}

function Assert-KeyMasked {
    param(
        [pscustomobject]$Result,
        [string]$Message
    )

    Assert-False -Condition $Result.Output.Contains($script:UniqueKey) -Message $Message
}

function Assert-InvocationSucceeded {
    param(
        [pscustomobject]$Result,
        [string]$Message
    )

    if (-not $Result.Succeeded) {
        $safeOutput = $Result.Output.Replace($script:UniqueKey, '[masked]')
        Add-Failure -Message ("$Message. Captured output: $safeOutput")
    }
}

function Get-PathEntries {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value -split [regex]::Escape([string][System.IO.Path]::PathSeparator) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
}

function Assert-PathContainsOnce {
    param(
        [string[]]$Entries,
        [string]$Expected,
        [string]$Message
    )

    if ($script:IsWindowsPlatform) {
        $comparer = [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        $comparer = [System.StringComparer]::Ordinal
    }

    $count = 0
    foreach ($entry in $Entries) {
        if ($comparer.Equals($entry, $Expected)) {
            $count++
        }
    }
    Assert-Equal -Expected 1 -Actual $count -Message $Message
}

function Assert-RefreshedPath {
    param(
        [string]$CurrentPath,
        [AllowNull()][string]$MachinePath,
        [AllowNull()][string]$UserPath,
        [string]$FakeBin,
        [string]$ProcessSentinel
    )

    $actualEntries = @(Get-PathEntries -Value $env:Path)
    Assert-PathContainsOnce -Entries $actualEntries -Expected $FakeBin -Message 'refreshed Path preserves the fake command directory exactly once'
    Assert-PathContainsOnce -Entries $actualEntries -Expected $ProcessSentinel -Message 'refreshed Path preserves the process-only sentinel exactly once'

    foreach ($source in @($CurrentPath, $MachinePath, $UserPath)) {
        foreach ($expected in @(Get-PathEntries -Value $source)) {
            Assert-PathContainsOnce -Entries $actualEntries -Expected $expected -Message "refreshed Path merges and de-duplicates entry: $expected"
        }
    }

    foreach ($entry in $actualEntries) {
        Assert-PathContainsOnce -Entries $actualEntries -Expected $entry -Message "refreshed Path has no duplicate entry: $entry"
    }
}

function New-FakeClaudeCommand {
    param([string]$BinPath)

    if ($script:IsWindowsPlatform) {
        $commandPath = Join-Path -Path $BinPath -ChildPath 'claude.cmd'
        $commandBody = "@echo off`r`nif `"%~1`"==`"--version`" echo Claude fake 1.0`r`nexit /b 0`r`n"
        [System.IO.File]::WriteAllText($commandPath, $commandBody)
    }
    else {
        $commandPath = Join-Path -Path $BinPath -ChildPath 'claude'
        $truePath = '/usr/bin/true'
        if (-not (Test-Path -LiteralPath $truePath)) {
            $truePath = '/bin/true'
        }
        Copy-Item -LiteralPath $truePath -Destination $commandPath
    }
}

function New-RelativeSymbolicLink {
    param(
        [string]$Path,
        [string]$Target
    )

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    Push-Location -LiteralPath $parent
    try {
        if ($script:IsWindowsPlatform) {
            if ([string]::IsNullOrEmpty($leaf) -or $leaf -notmatch '^[A-Za-z0-9._-]+$') {
                throw "Unsafe symbolic link leaf for cmd.exe mklink: $leaf"
            }
            if ([string]::IsNullOrEmpty($Target) -or
                [System.IO.Path]::IsPathRooted($Target) -or
                $Target -notmatch '^[A-Za-z0-9._/\\-]+$') {
                throw "Unsafe relative symbolic link target for cmd.exe mklink: $Target"
            }

            $null = & cmd.exe /d /c mklink $leaf $Target 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe mklink failed with exit code ${LASTEXITCODE}: $leaf -> $Target"
            }
        }
        else {
            $null = New-Item -ItemType SymbolicLink -Path $leaf -Target $Target -Force
        }
    }
    finally {
        Pop-Location
    }
    $linkItem = Get-TestPathEntryFromParent -Path $Path
    if ($null -eq $linkItem) {
        throw "Created link entry is missing: $Path"
    }
    $isLink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink) {
        throw "Created path is not a reparse point: $Path"
    }
    $targetReadable = $true
    $capturedTarget = $null
    try {
        $capturedTarget = [string]$linkItem.Target
    }
    catch {
        $targetReadable = $false
    }
    return [PSCustomObject]@{
        TargetReadable = $targetReadable
        Target = $capturedTarget
        RequestedTarget = $Target
    }
}

function New-TestSandbox {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("claude-code-tests-" + [Guid]::NewGuid().ToString('N'))
    $homePath = Join-Path -Path $root -ChildPath 'home'
    $binPath = Join-Path -Path $root -ChildPath 'bin'
    $fetchLog = Join-Path -Path $root -ChildPath 'fetch.log'
    $installLog = Join-Path -Path $root -ChildPath 'install.log'
    $secretEnvironmentLog = Join-Path -Path $root -ChildPath 'secret-environment.log'
    $protectLog = Join-Path -Path $root -ChildPath 'protect.log'
    $processPathSentinel = Join-Path -Path $root -ChildPath 'process-only-path'
    $userPathSentinel = Join-Path -Path $root -ChildPath 'user-only-path'

    $null = New-Item -ItemType Directory -Path $homePath -Force
    $null = New-Item -ItemType Directory -Path $binPath -Force
    $null = New-Item -ItemType Directory -Path $processPathSentinel -Force
    [System.IO.File]::WriteAllText($fetchLog, '')
    [System.IO.File]::WriteAllText($installLog, '')
    [System.IO.File]::WriteAllText($secretEnvironmentLog, '')
    [System.IO.File]::WriteAllText($protectLog, '')
    $script:Sandboxes.Add($root)

    if ($script:IsWindowsPlatform) {
        $controlledPath = @($binPath)
        $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
            $controlledPath += Join-Path -Path $systemRoot -ChildPath 'System32'
            $controlledPath += $systemRoot
            $controlledPath += Join-Path -Path $systemRoot -ChildPath 'System32\Wbem'
            $controlledPath += Join-Path -Path $systemRoot -ChildPath 'System32\WindowsPowerShell\v1.0'
        }
        $testPathEntries = @($binPath, $processPathSentinel, $binPath)
        if ($controlledPath.Count -gt 1) {
            $testPathEntries += $controlledPath[1..($controlledPath.Count - 1)]
        }
        $testPath = $testPathEntries -join [System.IO.Path]::PathSeparator
        $null = New-Item -ItemType Directory -Path $userPathSentinel -Force
        $userTestPath = $binPath.ToUpperInvariant() + [System.IO.Path]::PathSeparator + $userPathSentinel
        [Environment]::SetEnvironmentVariable('Path', $userTestPath, 'User')
    }
    else {
        $testPath = @(
            $binPath,
            $processPathSentinel,
            $binPath,
            '/usr/bin',
            '/bin',
            '/usr/sbin',
            '/sbin'
        ) -join [System.IO.Path]::PathSeparator
    }

    [Environment]::SetEnvironmentVariable('PATH', $testPath, 'Process')
    [Environment]::SetEnvironmentVariable('Path', $testPath, 'Process')
    [Environment]::SetEnvironmentVariable('HOME', $homePath, 'Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE', $homePath, 'Process')
    [Environment]::SetEnvironmentVariable('AI_ENDPOINT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AI_API_KEY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AI_INSTALL_YES', $null, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', $null, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_BIN', $binPath, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_FETCH_LOG', $fetchLog, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_INSTALL_LOG', $installLog, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_SECRET_ENV_LOG', $secretEnvironmentLog, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_PROTECT_LOG', $protectLog, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_FINAL_TARGET', $null, 'Process')

    return [PSCustomObject]@{
        Root = $root
        Home = $homePath
        Bin = $binPath
        FetchLog = $fetchLog
        InstallLog = $installLog
        SecretEnvironmentLog = $secretEnvironmentLog
        ProtectLog = $protectLog
        Config = Join-Path -Path $homePath -ChildPath '.claude.json'
        ProcessPathSentinel = $processPathSentinel
    }
}

function Invoke-Subject {
    param(
        [hashtable]$Parameters,
        [string]$HomePath,
        [string]$TargetPath = $script:SubjectPath
    )

    $records = New-Object System.Collections.ArrayList
    $succeeded = $true
    try {
        & {
            param(
                [string]$TargetPath,
                [hashtable]$Arguments,
                [string]$IsolatedHome
            )

            Set-Variable -Name HOME -Value $IsolatedHome -Scope Local -Force
            & $TargetPath @Arguments
        } $TargetPath $Parameters $HomePath *>&1 | ForEach-Object {
            $null = $records.Add($_)
        }
    }
    catch {
        $succeeded = $false
        $null = $records.Add($_)
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            $null = $records.Add($_.ScriptStackTrace)
        }
    }

    $output = ($records | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    return [PSCustomObject]@{
        Succeeded = $succeeded
        Output = $output
    }
}

function Assert-ProcessConfiguration {
    param(
        [string]$Endpoint,
        [string]$MessagePrefix
    )

    Assert-Equal -Expected $Endpoint -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')) -Message "$MessagePrefix configures Process endpoint"
    Assert-Equal -Expected $script:UniqueKey -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'Process')) -Message "$MessagePrefix configures Process token"

    if ($script:IsWindowsPlatform) {
        Assert-Equal -Expected $Endpoint -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'User')) -Message "$MessagePrefix configures User endpoint on Windows"
        Assert-Equal -Expected $script:UniqueKey -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')) -Message "$MessagePrefix configures User token on Windows"
    }
}

function Restore-TestEnvironment {
    foreach ($name in $script:OriginalProcessValues.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:OriginalProcessValues[$name], 'Process')
    }
    [Environment]::SetEnvironmentVariable('Path', $script:OriginalMixedCasePath, 'Process')

    if ($script:IsWindowsPlatform) {
        foreach ($name in $script:OriginalUserValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:OriginalUserValues[$name], 'User')
        }
    }

    foreach ($sandbox in $script:Sandboxes) {
        if (Test-Path -LiteralPath $sandbox) {
            Remove-Item -LiteralPath $sandbox -Recurse -Force
        }
    }
}

try {
    Write-Host 'test: missing Claude invokes mocked official installer and configures'
    $sandbox = New-TestSandbox
    $endpoint = 'https://api.example.test/anthropic'
    $currentPathBeforeRefresh = $env:Path
    $machinePathBeforeRefresh = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPathBeforeRefresh = [Environment]::GetEnvironmentVariable('Path', 'User')
    $result = Invoke-Subject -Parameters @{
        Endpoint = "$endpoint/"
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'missing-command invocation succeeds'
    Assert-FileContains -Path $sandbox.FetchLog -Expected 'https://claude.ai/install.ps1' -Message 'missing command fetches the official installer URL through the mock'
    Assert-FileContains -Path $sandbox.InstallLog -Expected 'installer-ran' -Message 'missing command invokes the mocked installer scriptblock'
    Assert-ProcessConfiguration -Endpoint $endpoint -MessagePrefix 'missing-command invocation'
    Assert-PathExists -Path $sandbox.Config -Message 'missing-command invocation writes Claude configuration'
    Assert-RefreshedPath -CurrentPath $currentPathBeforeRefresh -MachinePath $machinePathBeforeRefresh -UserPath $userPathBeforeRefresh -FakeBin $sandbox.Bin -ProcessSentinel $sandbox.ProcessPathSentinel
    if (Test-Path -LiteralPath $sandbox.Config) {
        $config = [System.IO.File]::ReadAllText($sandbox.Config) | ConvertFrom-Json
        Assert-Equal -Expected $true -Actual $config.hasCompletedOnboarding -Message 'missing-command invocation enables onboarding'
    }
    Assert-KeyMasked -Result $result -Message 'missing-command output masks the full key'

    Write-Host 'test: installer fetch and body cannot inherit API key environments'
    $sandbox = New-TestSandbox
    [Environment]::SetEnvironmentVariable('AI_API_KEY', $script:UniqueKey, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'upstream-api-key-sentinel', 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'upstream-auth-token-sentinel', 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'oauth-token-sentinel', 'Process')
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'environment-key installation succeeds'
    Assert-FileEmpty -Path $sandbox.SecretEnvironmentLog -Message 'fetch and downloaded installer can access neither API key environments nor the caller Key variable'
    Assert-ProcessConfiguration -Endpoint $endpoint -MessagePrefix 'environment-key installation'
    Assert-KeyMasked -Result $result -Message 'environment-key install output masks the full key'

    Write-Host 'test: existing Claude plus -Yes skips installer and still configures'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'existing-command unattended invocation succeeds'
    Assert-FileEmpty -Path $sandbox.FetchLog -Message 'existing command plus -Yes does not fetch the installer'
    Assert-FileEmpty -Path $sandbox.InstallLog -Message 'existing command plus -Yes does not invoke the installer'
    Assert-ProcessConfiguration -Endpoint $endpoint -MessagePrefix 'existing-command unattended invocation'
    Assert-PathExists -Path $sandbox.Config -Message 'installer skip still writes Claude configuration'
    Assert-KeyMasked -Result $result -Message 'existing-command output masks the full key'

    if (-not $script:IsWindowsPlatform) {
        Write-Host 'test: multiple chmod applications on PATH still select one executable'
        $sandbox = New-TestSandbox
        New-FakeClaudeCommand -BinPath $sandbox.Bin
        $chmodA = Join-Path -Path $sandbox.Root -ChildPath 'chmod-a'
        $chmodB = Join-Path -Path $sandbox.Root -ChildPath 'chmod-b'
        $null = New-Item -ItemType Directory -Path $chmodA, $chmodB -Force
        Copy-Item -LiteralPath '/bin/chmod' -Destination (Join-Path -Path $chmodA -ChildPath 'chmod')
        Copy-Item -LiteralPath '/bin/chmod' -Destination (Join-Path -Path $chmodB -ChildPath 'chmod')
        & /bin/chmod 755 (Join-Path -Path $chmodA -ChildPath 'chmod') (Join-Path -Path $chmodB -ChildPath 'chmod')
        $duplicateChmodPath = $chmodA + [System.IO.Path]::PathSeparator + $chmodB + [System.IO.Path]::PathSeparator + $env:PATH
        [Environment]::SetEnvironmentVariable('PATH', $duplicateChmodPath, 'Process')
        [Environment]::SetEnvironmentVariable('Path', $duplicateChmodPath, 'Process')
        $powerShellExecutable = (Get-Process -Id $PID).Path
        $childOutput = & $powerShellExecutable -NoLogo -NoProfile -NonInteractive -File $script:SubjectPath -Endpoint $endpoint -Key $script:UniqueKey -Yes *>&1
        $childExitCode = $LASTEXITCODE
        Assert-Equal -Expected 0 -Actual $childExitCode -Message 'multiple chmod PATH invocation succeeds in a fresh PowerShell process'
        Assert-PrivateFile -Path $sandbox.Config -Message 'multiple chmod PATH invocation still creates a private config'
        Assert-False -Condition ((($childOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Contains($script:UniqueKey)) -Message 'multiple chmod PATH output masks the full key'
    }

    Write-Host 'test: existing Claude plus -Reinstall -Yes invokes installer'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Reinstall = $true
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'forced reinstall invocation succeeds'
    Assert-FileContains -Path $sandbox.FetchLog -Expected 'https://claude.ai/install.ps1' -Message 'forced reinstall fetches the official installer URL through the mock'
    Assert-FileContains -Path $sandbox.InstallLog -Expected 'installer-ran' -Message 'forced reinstall invokes the mocked installer scriptblock'
    Assert-ProcessConfiguration -Endpoint $endpoint -MessagePrefix 'forced reinstall invocation'
    Assert-KeyMasked -Result $result -Message 'forced-reinstall output masks the full key'

    Write-Host 'test: -DryRun invokes and writes nothing and preserves Process environment'
    $sandbox = New-TestSandbox
    $dryRunBase = 'https://sentinel.example.test/base'
    $dryRunToken = 'sentinel-token-before-dry-run'
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $dryRunBase, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $dryRunToken, 'Process')
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        DryRun = $true
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'dry-run invocation succeeds'
    Assert-FileEmpty -Path $sandbox.FetchLog -Message 'dry-run does not fetch the installer'
    Assert-FileEmpty -Path $sandbox.InstallLog -Message 'dry-run does not invoke the installer'
    Assert-PathMissing -Path $sandbox.Config -Message 'dry-run does not write Claude configuration'
    Assert-Equal -Expected $dryRunBase -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')) -Message 'dry-run does not change Process endpoint'
    Assert-Equal -Expected $dryRunToken -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'Process')) -Message 'dry-run does not change Process token'
    Assert-KeyMasked -Result $result -Message 'dry-run output masks the full key'

    Write-Host 'test: repeated valid JSON merge preserves fields and creates backups'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"dark","nested":{"keep":7},"hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $parameters = @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    }
    $firstResult = Invoke-Subject -Parameters $parameters -HomePath $sandbox.Home
    $firstMergedJson = [System.IO.File]::ReadAllText($sandbox.Config)
    $secondResult = Invoke-Subject -Parameters $parameters -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $firstResult -Message 'first valid JSON merge succeeds'
    Assert-InvocationSucceeded -Result $secondResult -Message 'second valid JSON merge succeeds'
    $merged = [System.IO.File]::ReadAllText($sandbox.Config) | ConvertFrom-Json
    Assert-Equal -Expected 'dark' -Actual $merged.theme -Message 'valid JSON merge preserves an unrelated scalar field'
    Assert-Equal -Expected 7 -Actual $merged.nested.keep -Message 'valid JSON merge preserves an unrelated nested field'
    Assert-Equal -Expected $true -Actual $merged.hasCompletedOnboarding -Message 'valid JSON merge enables onboarding'
    Assert-PrivateFile -Path $sandbox.Config -Message 'merged Claude JSON is owner-only'
    Assert-PathExists -Path ($sandbox.Config + '.ai-cli-installers.bak') -Message 'first valid JSON merge creates a backup'
    Assert-PathExists -Path ($sandbox.Config + '.ai-cli-installers.bak.1') -Message 'second valid JSON merge creates another backup'
    if (Test-Path -LiteralPath ($sandbox.Config + '.ai-cli-installers.bak')) {
        Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config + '.ai-cli-installers.bak')) -Message 'first valid JSON backup contains the original configuration'
        Assert-PrivateFile -Path ($sandbox.Config + '.ai-cli-installers.bak') -Message 'first valid JSON backup is owner-only'
    }
    if (Test-Path -LiteralPath ($sandbox.Config + '.ai-cli-installers.bak.1')) {
        Assert-Equal -Expected $firstMergedJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config + '.ai-cli-installers.bak.1')) -Message 'second valid JSON backup contains the first merged configuration'
    }
    Assert-KeyMasked -Result $firstResult -Message 'first JSON-merge output masks the full key'
    Assert-KeyMasked -Result $secondResult -Message 'second JSON-merge output masks the full key'

    Write-Host 'test: backup protection happens while the exclusive file is still empty'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"protect-before-backup-content","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-backup-ordering-probe.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $protectHeader = @'
function Protect-PrivateFile {
    param([string]$Path)
'@
    $backupProbe = @'
    if ($Path -like '*.ai-cli-installers.bak*') {
        $length = (Get-Item -LiteralPath $Path -Force).Length
        [System.IO.File]::AppendAllText($env:FAKE_PROTECT_LOG, "$Path|$length" + [Environment]::NewLine)
        if ($length -ne 0) { throw 'backup content existed before protection' }
    }
'@
    $faultInjectedSource = $subjectSource.Replace($protectHeader, $protectHeader + $backupProbe)
    Assert-False -Condition ($faultInjectedSource -ceq $subjectSource) -Message 'backup ordering probe is injected into protection'
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-InvocationSucceeded -Result $result -Message 'backup ordering probe invocation succeeds'
    $protectEntries = @([System.IO.File]::ReadAllLines($sandbox.ProtectLog))
    Assert-True -Condition ($protectEntries.Count -gt 0 -and $protectEntries[0].EndsWith('|0')) -Message 'backup is empty when its first permission protection is attempted'
    Assert-KeyMasked -Result $result -Message 'backup protection ordering output masks the full key'

    Write-Host 'test: temp protection happens before any merged JSON content is written'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"protect-before-temp-content","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-temp-ordering-probe.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $tempProbe = @'
    if ($Path -like '*.ai-cli-installers.tmp.*') {
        $length = (Get-Item -LiteralPath $Path -Force).Length
        [System.IO.File]::AppendAllText($env:FAKE_PROTECT_LOG, "$Path|$length" + [Environment]::NewLine)
        if ($length -ne 0) { throw 'temp content existed before protection' }
    }
'@
    $faultInjectedSource = $subjectSource.Replace($protectHeader, $protectHeader + $tempProbe)
    Assert-False -Condition ($faultInjectedSource -ceq $subjectSource) -Message 'temp ordering probe is injected into protection'
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-InvocationSucceeded -Result $result -Message 'temp ordering probe invocation succeeds'
    $tempProtectEntries = @([System.IO.File]::ReadAllLines($sandbox.ProtectLog))
    Assert-True -Condition ($tempProtectEntries.Count -gt 0 -and $tempProtectEntries[0].EndsWith('|0')) -Message 'temp file is empty when its permission protection is attempted'
    Assert-KeyMasked -Result $result -Message 'temp protection ordering output masks the full key'

    Write-Host 'test: temp protection failure removes the empty temp and leaves the original unchanged'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"temp-protection-failure","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-temp-protection-failure.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $tempFailure = @'
    if ($Path -like '*.ai-cli-installers.tmp.*') { throw 'injected temp protection failure' }
'@
    $faultInjectedSource = $subjectSource.Replace($protectHeader, $protectHeader + $tempFailure)
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-False -Condition $result.Succeeded -Message 'temp protection failure aborts configuration'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config)) -Message 'temp protection failure leaves original JSON byte-for-byte unchanged'
    $tempRemnants = @(Get-ChildItem -LiteralPath $sandbox.Home -Force | Where-Object { $_.Name -like '*.ai-cli-installers.tmp.*' })
    Assert-Equal -Expected 0 -Actual $tempRemnants.Count -Message 'temp protection failure removes the empty temp file'
    Assert-KeyMasked -Result $result -Message 'temp protection failure output masks the full key'

    Write-Host 'test: final permission verification failure restores original content without replacing the backup'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"final-permission-rollback","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    [Environment]::SetEnvironmentVariable('FAKE_FINAL_TARGET', $sandbox.Config, 'Process')
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-final-permission-failure.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $privateTestHeader = @'
function Test-PrivateFile {
    param([string]$Path)
'@
    $finalPermissionFailure = @'
    if ($Path -ceq $env:FAKE_FINAL_TARGET -and (Test-Path -LiteralPath $Path)) {
        $candidate = [System.IO.File]::ReadAllText($Path)
        try {
            $parsedCandidate = $candidate | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsedCandidate.PSObject.Properties['hasCompletedOnboarding'] -and
                $parsedCandidate.hasCompletedOnboarding -eq $true) {
                return $false
            }
        }
        catch { }
    }
'@
    $faultInjectedSource = $subjectSource.Replace($privateTestHeader, $privateTestHeader + $finalPermissionFailure)
    Assert-False -Condition ($faultInjectedSource -ceq $subjectSource) -Message 'final permission verification failure is injected'
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-False -Condition $result.Succeeded -Message 'final permission verification failure aborts configuration'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config)) -Message 'final permission verification failure restores original JSON byte-for-byte'
    $finalFailureBackup = $sandbox.Config + '.ai-cli-installers.bak'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($finalFailureBackup)) -Message 'final permission verification failure preserves the original private backup'
    Assert-PrivateFile -Path $finalFailureBackup -Message 'final permission verification failure leaves no broad backup'
    Assert-KeyMasked -Result $result -Message 'final permission verification failure output masks the full key'

    Write-Host 'test: relative config symlink remains a link while its physical target is merged'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $dotfiles = Join-Path -Path $sandbox.Home -ChildPath 'dotfiles'
    $null = New-Item -ItemType Directory -Path $dotfiles -Force
    $relativeTarget = 'dotfiles/claude.json'
    $physicalTarget = Join-Path -Path $sandbox.Home -ChildPath $relativeTarget
    $originalJson = '{"theme":"relative-link","nested":{"keep":23},"hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($physicalTarget, $originalJson)
    $createdLinkSnapshot = New-RelativeSymbolicLink -Path $sandbox.Config -Target $relativeTarget
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-InvocationSucceeded -Result $result -Message 'relative config symlink invocation succeeds'
    Assert-SymbolicLinkSnapshot -Path $sandbox.Config -ExpectedSnapshot $createdLinkSnapshot -RequireTarget -Message 'relative config symlink remains unchanged'
    $linkedConfig = [System.IO.File]::ReadAllText($physicalTarget) | ConvertFrom-Json
    Assert-Equal -Expected 'relative-link' -Actual $linkedConfig.theme -Message 'relative symlink target preserves unrelated JSON'
    Assert-Equal -Expected 23 -Actual $linkedConfig.nested.keep -Message 'relative symlink target preserves nested JSON'
    Assert-Equal -Expected $true -Actual $linkedConfig.hasCompletedOnboarding -Message 'relative symlink physical target receives onboarding merge'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config + '.ai-cli-installers.bak')) -Message 'relative symlink backup contains the original physical target'
    Assert-KeyMasked -Result $result -Message 'relative symlink output masks the full key'

    Write-Host 'test: broken and cyclic config symlinks fail before installer or writes'
    $sandbox = New-TestSandbox
    $brokenLinkSnapshot = New-RelativeSymbolicLink -Path $sandbox.Config -Target 'dotfiles/missing-claude.json'
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-False -Condition $result.Succeeded -Message 'broken config symlink fails closed'
    Assert-FileEmpty -Path $sandbox.FetchLog -Message 'broken config symlink is rejected before installer fetch'
    Assert-FileEmpty -Path $sandbox.InstallLog -Message 'broken config symlink is rejected before installer execution'
    Assert-SymbolicLinkSnapshot -Path $sandbox.Config -ExpectedSnapshot $brokenLinkSnapshot -Message 'broken config symlink remains unchanged'
    Assert-KeyMasked -Result $result -Message 'broken config symlink output masks the full key'

    $sandbox = New-TestSandbox
    $cyclePartner = Join-Path -Path $sandbox.Home -ChildPath 'cycle-partner'
    $cycleConfigSnapshot = New-RelativeSymbolicLink -Path $sandbox.Config -Target 'cycle-partner'
    $cyclePartnerSnapshot = New-RelativeSymbolicLink -Path $cyclePartner -Target '.claude.json'
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-False -Condition $result.Succeeded -Message 'cyclic config symlink fails closed'
    Assert-FileEmpty -Path $sandbox.FetchLog -Message 'cyclic config symlink is rejected before installer fetch'
    Assert-FileEmpty -Path $sandbox.InstallLog -Message 'cyclic config symlink is rejected before installer execution'
    Assert-SymbolicLinkSnapshot -Path $sandbox.Config -ExpectedSnapshot $cycleConfigSnapshot -Message 'cyclic config symlink remains unchanged'
    Assert-SymbolicLinkSnapshot -Path $cyclePartner -ExpectedSnapshot $cyclePartnerSnapshot -Message 'cyclic config symlink partner remains unchanged'
    Assert-KeyMasked -Result $result -Message 'cyclic config symlink output masks the full key'

    Write-Host 'test: environment failure restores a symlink physical target and preserves the link'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $dotfiles = Join-Path -Path $sandbox.Home -ChildPath 'dotfiles'
    $null = New-Item -ItemType Directory -Path $dotfiles -Force
    $relativeTarget = 'dotfiles/claude.json'
    $physicalTarget = Join-Path -Path $sandbox.Home -ChildPath $relativeTarget
    $originalJson = '{"theme":"symlink-rollback","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($physicalTarget, $originalJson)
    $rollbackLinkSnapshot = New-RelativeSymbolicLink -Path $sandbox.Config -Target $relativeTarget
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-symlink-environment-failure.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $lastEnvironmentWrite = "[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', `$Key, 'User')"
    $faultInjectedSource = $subjectSource.Replace($lastEnvironmentWrite, "throw 'injected environment write failure'")
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-False -Condition $result.Succeeded -Message 'symlink environment failure aborts configuration'
    Assert-SymbolicLinkSnapshot -Path $sandbox.Config -ExpectedSnapshot $rollbackLinkSnapshot -RequireTarget -Message 'symlink environment rollback preserves the logical link'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($physicalTarget)) -Message 'symlink environment rollback restores the physical target byte-for-byte'
    Assert-KeyMasked -Result $result -Message 'symlink environment rollback output masks the full key'

    Write-Host 'test: backup permission failure aborts before replacing JSON'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"backup-permission-sentinel","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-backup-permission-failure.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $backupFailure = @'
    if ($Path -like '*.ai-cli-installers.bak*') { throw 'injected backup permission failure' }
'@
    $faultInjectedSource = $subjectSource.Replace($protectHeader, $protectHeader + $backupFailure)
    Assert-False -Condition ($faultInjectedSource -ceq $subjectSource) -Message 'fault injection replaces backup permission hardening'
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-False -Condition $result.Succeeded -Message 'backup permission failure aborts configuration'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config)) -Message 'backup permission failure leaves JSON unchanged'
    Assert-PathMissing -Path ($sandbox.Config + '.ai-cli-installers.bak') -Message 'failed backup is removed instead of left permissive'
    Assert-KeyMasked -Result $result -Message 'backup permission failure output masks the full key'

    Write-Host 'test: malformed JSON is backed up and left unchanged on failure'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $malformedJson = '{"keep":true,'
    [System.IO.File]::WriteAllText($sandbox.Config, $malformedJson)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home
    Assert-False -Condition $result.Succeeded -Message 'malformed JSON invocation fails'
    Assert-Equal -Expected $malformedJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config)) -Message 'malformed JSON original remains unchanged'
    $malformedBackup = $sandbox.Config + '.ai-cli-installers.bak'
    Assert-PathExists -Path $malformedBackup -Message 'malformed JSON is backed up before failure'
    if (Test-Path -LiteralPath $malformedBackup) {
        Assert-Equal -Expected $malformedJson -Actual ([System.IO.File]::ReadAllText($malformedBackup)) -Message 'malformed JSON backup matches the original'
    }
    Assert-KeyMasked -Result $result -Message 'malformed-JSON failure output masks the full key'

    Write-Host 'test: environment write failure rolls back JSON and prior environment changes'
    $sandbox = New-TestSandbox
    New-FakeClaudeCommand -BinPath $sandbox.Bin
    $originalJson = '{"theme":"rollback-sentinel","hasCompletedOnboarding":false}'
    [System.IO.File]::WriteAllText($sandbox.Config, $originalJson)
    $originalProcessEndpoint = 'https://process-before.example.test/v1'
    $originalProcessToken = 'process-token-before'
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $originalProcessEndpoint, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $originalProcessToken, 'Process')
    if ($script:IsWindowsPlatform) {
        $originalUserEndpoint = 'https://user-before.example.test/v1'
        $originalUserToken = 'user-token-before'
        [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $originalUserEndpoint, 'User')
        [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $originalUserToken, 'User')
    }
    $faultInjectedSubject = Join-Path -Path $sandbox.Root -ChildPath 'claude-code-environment-failure.ps1'
    $subjectSource = [System.IO.File]::ReadAllText($script:SubjectPath)
    $lastEnvironmentWrite = "[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', `$Key, 'User')"
    $faultInjectedSource = $subjectSource.Replace($lastEnvironmentWrite, "throw 'injected environment write failure'")
    Assert-False -Condition ($faultInjectedSource -ceq $subjectSource) -Message 'fault injection replaces the final environment write'
    [System.IO.File]::WriteAllText($faultInjectedSubject, $faultInjectedSource)
    $result = Invoke-Subject -Parameters @{
        Endpoint = $endpoint
        Key = $script:UniqueKey
        Yes = $true
    } -HomePath $sandbox.Home -TargetPath $faultInjectedSubject
    Assert-False -Condition $result.Succeeded -Message 'injected environment write causes configuration failure'
    Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config)) -Message 'environment failure restores the original JSON byte-for-byte'
    $rollbackBackup = $sandbox.Config + '.ai-cli-installers.bak'
    Assert-PathExists -Path $rollbackBackup -Message 'environment failure preserves the JSON backup'
    if (Test-Path -LiteralPath $rollbackBackup) {
        Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($rollbackBackup)) -Message 'environment failure backup contains the original JSON'
    }
    Assert-Equal -Expected $originalProcessEndpoint -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')) -Message 'environment failure restores the Process endpoint'
    Assert-Equal -Expected $originalProcessToken -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'Process')) -Message 'environment failure restores the Process token'
    if ($script:IsWindowsPlatform) {
        Assert-Equal -Expected $originalUserEndpoint -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'User')) -Message 'environment failure restores the User endpoint'
        Assert-Equal -Expected $originalUserToken -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')) -Message 'environment failure restores the User token'
    }
    Assert-KeyMasked -Result $result -Message 'environment rollback failure output masks the full key'

    Write-Host 'test: valid endpoints preserve their exact trimmed values'
    foreach ($validEndpoint in @(
        'http://127.0.0.1:8080/v1',
        'https://[2001:db8::1]:8443/v1'
    )) {
        $sandbox = New-TestSandbox
        New-FakeClaudeCommand -BinPath $sandbox.Bin
        $result = Invoke-Subject -Parameters @{
            Endpoint = "$validEndpoint/"
            Key = $script:UniqueKey
            Yes = $true
        } -HomePath $sandbox.Home
        Assert-InvocationSucceeded -Result $result -Message "valid endpoint is accepted: $validEndpoint"
        Assert-Equal -Expected $validEndpoint -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')) -Message "valid endpoint remains exact after trailing-slash trimming: $validEndpoint"
        Assert-KeyMasked -Result $result -Message "valid-endpoint output masks the full key: $validEndpoint"
    }

    Write-Host 'test: invalid endpoints fail without installer or configuration writes'
    foreach ($invalidEndpoint in @(
        'ftp://api.example.test/v1',
        'https://user@example.test/v1',
        'http://:8080/v1',
        'https://[]:8443/v1',
        'http://2001:db8::1/v1',
        'https://example.test:/v1',
        'https://example.test:abc/v1',
        'https://api.example.test/v1?mode=test',
        'https://api.example.test/v1#fragment',
        'https://api.example.test/v 1',
        'https://api.example.test\evil/v1',
        'https://api.example.test/v1\evil',
        ([string]::Concat('https://api.example.test/v1', [char]1, 'evil')),
        ([string]::Concat('https://api.example.test/v1', [char]127, 'evil')),
        'https:///missing-host'
    )) {
        $sandbox = New-TestSandbox
        $invalidSentinel = 'https://sentinel.example.test/unchanged'
        [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $invalidSentinel, 'Process')
        $result = Invoke-Subject -Parameters @{
            Endpoint = $invalidEndpoint
            Key = $script:UniqueKey
            DryRun = $true
            Yes = $true
        } -HomePath $sandbox.Home
        Assert-False -Condition $result.Succeeded -Message "invalid endpoint is rejected: $invalidEndpoint"
        Assert-FileEmpty -Path $sandbox.FetchLog -Message "invalid endpoint does not fetch the installer: $invalidEndpoint"
        Assert-FileEmpty -Path $sandbox.InstallLog -Message "invalid endpoint does not invoke the installer: $invalidEndpoint"
        Assert-PathMissing -Path $sandbox.Config -Message "invalid endpoint does not write configuration: $invalidEndpoint"
        Assert-Equal -Expected $invalidSentinel -Actual ([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')) -Message "invalid endpoint leaves Process environment unchanged: $invalidEndpoint"
        Assert-KeyMasked -Result $result -Message "invalid-endpoint output masks the full key: $invalidEndpoint"
    }
}
catch {
    $failureDetails = "test harness stopped unexpectedly: " + $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        $failureDetails += [Environment]::NewLine + $_.ScriptStackTrace
    }
    Add-Failure -Message $failureDetails
}
finally {
    Restore-TestEnvironment
}

if ($script:Failures -ne 0) {
    exit 1
}

Write-Host 'ok - claude-code PowerShell behavior'
