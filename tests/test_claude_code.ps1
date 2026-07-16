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
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'FAKE_BIN',
    'FAKE_FETCH_LOG',
    'FAKE_INSTALL_LOG'
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
    return @'
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

function New-TestSandbox {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("claude-code-tests-" + [Guid]::NewGuid().ToString('N'))
    $homePath = Join-Path -Path $root -ChildPath 'home'
    $binPath = Join-Path -Path $root -ChildPath 'bin'
    $fetchLog = Join-Path -Path $root -ChildPath 'fetch.log'
    $installLog = Join-Path -Path $root -ChildPath 'install.log'
    $processPathSentinel = Join-Path -Path $root -ChildPath 'process-only-path'
    $userPathSentinel = Join-Path -Path $root -ChildPath 'user-only-path'

    $null = New-Item -ItemType Directory -Path $homePath -Force
    $null = New-Item -ItemType Directory -Path $binPath -Force
    $null = New-Item -ItemType Directory -Path $processPathSentinel -Force
    [System.IO.File]::WriteAllText($fetchLog, '')
    [System.IO.File]::WriteAllText($installLog, '')
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
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_BIN', $binPath, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_FETCH_LOG', $fetchLog, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_INSTALL_LOG', $installLog, 'Process')

    return [PSCustomObject]@{
        Root = $root
        Home = $homePath
        Bin = $binPath
        FetchLog = $fetchLog
        InstallLog = $installLog
        Config = Join-Path -Path $homePath -ChildPath '.claude.json'
        ProcessPathSentinel = $processPathSentinel
    }
}

function Invoke-Subject {
    param(
        [hashtable]$Parameters,
        [string]$HomePath
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
        } $script:SubjectPath $Parameters $HomePath *>&1 | ForEach-Object {
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
    Assert-PathExists -Path ($sandbox.Config + '.ai-cli-installers.bak') -Message 'first valid JSON merge creates a backup'
    Assert-PathExists -Path ($sandbox.Config + '.ai-cli-installers.bak.1') -Message 'second valid JSON merge creates another backup'
    if (Test-Path -LiteralPath ($sandbox.Config + '.ai-cli-installers.bak')) {
        Assert-Equal -Expected $originalJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config + '.ai-cli-installers.bak')) -Message 'first valid JSON backup contains the original configuration'
    }
    if (Test-Path -LiteralPath ($sandbox.Config + '.ai-cli-installers.bak.1')) {
        Assert-Equal -Expected $firstMergedJson -Actual ([System.IO.File]::ReadAllText($sandbox.Config + '.ai-cli-installers.bak.1')) -Message 'second valid JSON backup contains the first merged configuration'
    }
    Assert-KeyMasked -Result $firstResult -Message 'first JSON-merge output masks the full key'
    Assert-KeyMasked -Result $secondResult -Message 'second JSON-merge output masks the full key'

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
    Add-Failure -Message ("test harness stopped unexpectedly: " + $_.Exception.Message)
}
finally {
    Restore-TestEnvironment
}

if ($script:Failures -ne 0) {
    exit 1
}

Write-Host 'ok - claude-code PowerShell behavior'
