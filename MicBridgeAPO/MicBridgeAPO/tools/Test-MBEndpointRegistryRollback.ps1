$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = Join-Path $PSScriptRoot 'MicBridge.EndpointRegistryRollback.psm1'
Import-Module $modulePath -Force
$recoveryModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
Import-Module $recoveryModule -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeEndpointRegistry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$leaf = 'Software\MicBridgeEndpointRollback-' + [guid]::NewGuid().ToString('N')
$registryPath = "HKCU\$leaf"
$providerPath = "Registry::HKEY_CURRENT_USER\$leaf"
$names = @('FxEffect','FxAssociation','FxComposite')
$journal = Join-Path $root 'endpoint-recovery.json'
try {
    New-Item -Path $providerPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $providerPath -Name $names[0] -Value '{00000000-0000-0000-0000-000000000001}' -Type String
    Set-ItemProperty -LiteralPath $providerPath -Name $names[1] -Value '{00000000-0000-0000-0000-000000000002}' -Type String
    Set-ItemProperty -LiteralPath $providerPath -Name $names[2] -Value ([string[]]@('{00000000-0000-0000-0000-000000000003}')) -Type MultiString
    $snapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames $names
    if (-not $snapshot.KeyExists -or -not (Test-MBEndpointRegistrySnapshot $snapshot)) { throw 'FAIL: initial endpoint snapshot did not verify' }

    Set-ItemProperty -LiteralPath $providerPath -Name $names[0] -Value 'changed' -Type String
    Remove-ItemProperty -LiteralPath $providerPath -Name $names[1]
    Set-ItemProperty -LiteralPath $providerPath -Name 'UnrelatedValue' -Value 'preserve-me' -Type String
    Restore-MBEndpointRegistrySnapshot -Snapshot $snapshot | Out-Null
    if (-not (Test-MBEndpointRegistrySnapshot $snapshot)) { throw 'FAIL: endpoint values/kinds were not restored exactly' }
    if ((Get-ItemProperty -LiteralPath $providerPath -Name 'UnrelatedValue').UnrelatedValue -ne 'preserve-me') { throw 'FAIL: unrelated registry value was modified' }
    $actual = Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames $names
    if ($actual.Values[2].Kind -ne 'MultiString' -or @($actual.Values[2].Value).Count -ne 1) { throw 'FAIL: REG_MULTI_SZ type or data was not preserved' }

    # A value absent in the original snapshot must be removed on restore.
    $missingName = 'PreviouslyMissing'
    $missingSnapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames @($missingName)
    Set-ItemProperty -LiteralPath $providerPath -Name $missingName -Value 'temporary' -Type String
    Restore-MBEndpointRegistrySnapshot -Snapshot $missingSnapshot | Out-Null
    if (Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames @($missingName) | Where-Object { $_.Values[0].Exists }) { throw 'FAIL: newly-added value was not removed' }

    # When the endpoint key did not exist, rollback removes only an empty transaction-created key.
    $absentLeaf = 'Software\MicBridgeEndpointAbsent-' + [guid]::NewGuid().ToString('N')
    $absentPath = "HKCU\$absentLeaf"
    $absentProvider = "Registry::HKEY_CURRENT_USER\$absentLeaf"
    $absentSnapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $absentPath -ValueNames $names
    New-Item -Path $absentProvider -Force | Out-Null
    Set-ItemProperty -LiteralPath $absentProvider -Name $names[0] -Value 'temporary' -Type String
    Restore-MBEndpointRegistrySnapshot -Snapshot $absentSnapshot | Out-Null
    if (Test-Path -LiteralPath $absentProvider) { throw 'FAIL: transaction-created empty endpoint key was not removed' }

    # Real process death after the restore side effect and before journal completion.
    $crashLeaf = 'Software\MicBridgeEndpointCrash-' + [guid]::NewGuid().ToString('N')
    $crashRegistryPath = "HKCU\$crashLeaf"
    $crashProviderPath = "Registry::HKEY_CURRENT_USER\$crashLeaf"
    New-Item -Path $crashProviderPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[0] -Value 'before' -Type String
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[1] -Value 'before-association' -Type String
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[2] -Value ([string[]]@('before-composite')) -Type MultiString
    $crashSnapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $crashRegistryPath -ValueNames $names
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[0] -Value 'after' -Type String
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[1] -Value 'after-association' -Type String
    Set-ItemProperty -LiteralPath $crashProviderPath -Name $names[2] -Value ([string[]]@('after-composite')) -Type MultiString
    New-MBRecoveryJournal -Path $journal -Operation InstallRollback -DeviceId ([guid]::NewGuid()) -StepIds @('RestoreEndpointValues') | Out-Null
    $device = (Read-MBRecoveryJournal -Path $journal).DeviceId
    $child = Join-Path $root 'crash-child.ps1'
    $childText = @'
param([string]$Module,[string]$Journal,[string]$SnapshotJson,[string]$Device)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force
Import-Module (Join-Path (Split-Path $Module) 'MicBridge.RecoveryJournal.psm1') -Force
$snapshot = $SnapshotJson | ConvertFrom-Json
$action = { Restore-MBEndpointRegistrySnapshot -Snapshot $snapshot | Out-Null; [Environment]::FailFast('Injected endpoint registry rollback interruption') }.GetNewClosure()
$verify = { Test-MBEndpointRegistrySnapshot -Snapshot $snapshot }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreEndpointValues' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreEndpointValues') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($child,$childText,(New-Object Text.UTF8Encoding($false)))
    $snapshotJson = ConvertTo-Json -InputObject $crashSnapshot -Depth 12 -Compress
    $powershell = (Get-Process -Id $PID).Path
    $process = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child,$modulePath,$journal,$snapshotJson,$device) -Wait -PassThru
    if ($process.ExitCode -eq 0) { throw 'FAIL: crash-injection child exited successfully' }
    $interrupted = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues')
    if ($interrupted.Steps[0].State -ne 'Running' -or -not (Test-MBEndpointRegistrySnapshot $crashSnapshot)) { throw 'FAIL: crash did not leave a Running journal with restored registry state' }
    Invoke-MBRecoveryStep -Path $journal -StepId 'RestoreEndpointValues' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues') -Action { throw 'Endpoint registry restore action repeated after interruption' } -Verify { Test-MBEndpointRegistrySnapshot $crashSnapshot }
    $resumed = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues')
    if ($resumed.Steps[0].State -ne 'Completed' -or $resumed.Steps[0].Attempts -ne 1) { throw 'FAIL: fresh-process recovery repeated the registry action or did not complete' }

    Write-Host 'PASS: endpoint Fx registry snapshot, exact value/type restore, missing-value removal, unrelated-value preservation, absent-key cleanup, and process-crash resume'
} finally {
    Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path 'Registry::HKEY_CURRENT_USER' $leaf) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path 'Registry::HKEY_CURRENT_USER' $crashLeaf) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
