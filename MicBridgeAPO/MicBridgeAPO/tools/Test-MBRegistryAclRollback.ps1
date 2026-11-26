$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeAclRollback-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$module = Join-Path $PSScriptRoot 'MicBridge.RegistryAclRollback.psm1'
$recovery = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
Import-Module $module -Force
Import-Module $recovery -Force
$subKey = 'Software\MicBridgeAcl-' + [guid]::NewGuid().ToString('N')
$registryKey = $null
try {
    if ($subKey -notlike 'Software\MicBridgeAcl-*') { throw 'Fixture escaped its HKCU test namespace.' }
    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
    if (-not $registryKey) { throw 'Could not create HKCU ACL fixture.' }
    $registryKey.Close(); $registryKey = $null

    $originalSddl = Get-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey
    if ([string]::IsNullOrWhiteSpace($originalSddl)) { throw 'Could not snapshot original HKCU ACL.' }

    # Make the fixture ACL observably different while retaining the current user's access.
    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey,$true)
    $acl = $registryKey.GetAccessControl([System.Security.AccessControl.AccessControlSections]'Owner,Group,Access')
    $acl.SetAccessRuleProtection($true,$false)
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($rule in @($acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier]))) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sid,[System.Security.AccessControl.RegistryRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    $registryKey.SetAccessControl($acl)
    $registryKey.Close(); $registryKey = $null
    $changedSddl = Get-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey
    if ($changedSddl -eq $originalSddl) { throw 'Fixture ACL mutation did not change the SDDL.' }

    Restore-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -Sddl $originalSddl
    if (-not (Test-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -ExpectedSddl $originalSddl)) {
        throw ("ACL restore did not reproduce original SDDL. Expected=[$originalSddl] Actual=[{0}]" -f (Get-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey))
    }
    # Idempotency: restoring the same descriptor twice must preserve exact state.
    Restore-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -Sddl $originalSddl
    if (-not (Test-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -ExpectedSddl $originalSddl)) {
        throw 'ACL restore is not idempotent.'
    }

    # Crash after the ACL side effect but before the journal can mark the step Completed.
    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey,$true)
    $acl = $registryKey.GetAccessControl([System.Security.AccessControl.AccessControlSections]'Owner,Group,Access')
    $acl.SetAccessRuleProtection($true,$false)
    # Keep the test process able to perform the rollback (TakeOwnership/ChangePermissions),
    # while still changing the descriptor so crash recovery has a real side effect to replay.
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sid,[System.Security.AccessControl.RegistryRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow)
    $acl.ResetAccessRule($rule)
    $registryKey.SetAccessControl($acl)
    $registryKey.Close(); $registryKey = $null

    $journal = Join-Path $root 'acl-crash-resume.json'
    $device = [guid]::NewGuid()
    New-MBRecoveryJournal -Path $journal -Operation InstallRollback -DeviceId $device -StepIds @('RestoreEndpointAcl') | Out-Null
    $child = Join-Path $root 'acl-crash-child.ps1'
    $childSource = @'
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'Crash test configuration file is missing.' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Module = [string]$config.Module
$Journal = [string]$config.Journal
$SubKey = [string]$config.SubKey
$Sddl = [string]$config.Sddl
$Device = [string]$config.Device
Import-Module $Module -Force
Import-Module (Join-Path (Split-Path -Parent $Module) 'MicBridge.RecoveryJournal.psm1') -Force
$action = { Restore-MBRegistryAclSddl -Hive HKCU -SubKeyPath $SubKey -Sddl $Sddl; [Environment]::FailFast('Injected crash after ACL restore') }.GetNewClosure()
$verify = { Test-MBRegistryAclSddl -Hive HKCU -SubKeyPath $SubKey -ExpectedSddl $Sddl }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreEndpointAcl' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreEndpointAcl') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($child,$childSource,(New-Object Text.UTF8Encoding($false)))
    $childStdout = Join-Path $root 'acl-child.stdout.txt'
    $childStderr = Join-Path $root 'acl-child.stderr.txt'
    $configPath = Join-Path $root 'acl-crash-config.json'
    $config = [ordered]@{
        Module = $module
        Journal = $journal
        SubKey = $subKey
        Sddl = $originalSddl
        Device = $device.ToString('D')
    }
    [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$child,$configPath
    ) -Wait -PassThru -RedirectStandardOutput $childStdout -RedirectStandardError $childStderr
    if ($process.ExitCode -eq 0) { throw 'Crash-injection child exited successfully.' }
    $interrupted = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointAcl')
    if ($interrupted.Steps[0].State -ne 'Running') {
        $stdoutText = if (Test-Path $childStdout) { Get-Content -Raw $childStdout } else { '' }
        $stderrText = if (Test-Path $childStderr) { Get-Content -Raw $childStderr } else { '' }
        throw ("Journal state after child exit was [{0}], expected [Running]. Child exit={1}; stdout=[{2}]; stderr=[{3}]" -f $interrupted.Steps[0].State,$process.ExitCode,$stdoutText,$stderrText)
    }
    $postCrashSddl = Get-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey
    if (-not (Test-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -ExpectedSddl $originalSddl)) {
        throw ("ACL side effect was not durable after process death. Expected=[$originalSddl] Actual=[$postCrashSddl]")
    }
    Invoke-MBRecoveryStep -Path $journal -StepId 'RestoreEndpointAcl' -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointAcl') -Action { throw 'ACL restore action repeated after crash.' } -Verify { Test-MBRegistryAclSddl -Hive HKCU -SubKeyPath $subKey -ExpectedSddl $originalSddl }
    $resumed = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointAcl')
    if ($resumed.Steps[0].State -ne 'Completed' -or $resumed.Steps[0].Attempts -ne 1) { throw 'ACL recovery did not resume without repeating its action.' }

    Write-Host 'PASS: HKCU ACL snapshot, restore, exact SDDL verification, idempotency, and fresh-process crash recovery.'
} finally {
    if ($registryKey) { $registryKey.Close() }
    try {
        $cleanup = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$true)
        if ($cleanup) { $cleanup.DeleteSubKeyTree(($subKey -replace '^Software\\',''),$false); $cleanup.Close() }
    } catch {}
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
