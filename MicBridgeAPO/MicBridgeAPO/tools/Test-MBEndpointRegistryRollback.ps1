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
$crashLeaf = $null
try {
    New-Item -Path $providerPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $providerPath -Name $names[0] -Value '{00000000-0000-0000-0000-000000000001}' -Type String
    Set-ItemProperty -LiteralPath $providerPath -Name $names[1] -Value '{00000000-0000-0000-0000-000000000002}' -Type String
    Set-ItemProperty -LiteralPath $providerPath -Name $names[2] -Value ([string[]]@('{00000000-0000-0000-0000-000000000003}')) -Type MultiString
    $snapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames $names
    if (-not $snapshot.KeyExists -or -not (Test-MBEndpointRegistrySnapshot $snapshot)) { throw 'FAIL: initial endpoint snapshot did not verify' }

    # Exercise the exact-match recovery path with a JSON-round-tripped snapshot
    # containing a one-element REG_MULTI_SZ and a missing string property.
    $productionNames = @($names + 'PreviouslyMissing')
    $productionSnapshot = Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames $productionNames
    $productionJson = ConvertTo-Json -InputObject $productionSnapshot -Depth 10
    $productionRoundTrip = $productionJson | ConvertFrom-Json
    if (-not (Test-MBEndpointRegistrySnapshot $productionRoundTrip)) { throw 'FAIL: JSON-round-tripped production-shaped endpoint snapshot did not verify' }
    Restore-MBEndpointRegistrySnapshot -Snapshot $productionRoundTrip | Out-Null
    if (-not (Test-MBEndpointRegistrySnapshot $productionRoundTrip)) { throw 'FAIL: direct exact-match restore changed or failed to preserve the endpoint snapshot' }
    $noopJournal = Join-Path $root 'endpoint-noop-recovery.json'
    New-MBRecoveryJournal -Path $noopJournal -Operation InstallRollback -DeviceId ([guid]::NewGuid()) -StepIds @('RestoreEndpointValues') | Out-Null
    $noopDevice = (Read-MBRecoveryJournal -Path $noopJournal).DeviceId
    Invoke-MBRecoveryStep -Path $noopJournal -StepId 'RestoreEndpointValues' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$noopDevice) -ExpectedStepIds @('RestoreEndpointValues') -Action { throw 'Exact-match endpoint recovery must not request registry write access' } -Verify { Test-MBEndpointRegistrySnapshot $productionRoundTrip }
    $noopResult = Read-MBRecoveryJournal -Path $noopJournal -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$noopDevice) -ExpectedStepIds @('RestoreEndpointValues')
    if ($noopResult.Steps[0].State -ne 'Completed' -or $noopResult.Steps[0].Attempts -ne 0) { throw 'FAIL: exact-match endpoint recovery did not complete as a zero-attempt no-op' }

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
    if ((Get-MBEndpointRegistrySnapshot -RegistryPath $registryPath -ValueNames @($missingName)).Values[0].Exists) { throw 'FAIL: newly-added value was not removed' }

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
param([string]$Module,[string]$Journal,[string]$SnapshotPath,[string]$Device)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force
Import-Module (Join-Path (Split-Path $Module) 'MicBridge.RecoveryJournal.psm1') -Force
$snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
$action = { Restore-MBEndpointRegistrySnapshot -Snapshot $snapshot | Out-Null; [Environment]::FailFast('Injected endpoint registry rollback interruption') }.GetNewClosure()
$verify = { Test-MBEndpointRegistrySnapshot -Snapshot $snapshot }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreEndpointValues' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreEndpointValues') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($child,$childText,(New-Object Text.UTF8Encoding($false)))
    $snapshotPath = Join-Path $root 'crash-snapshot.json'
    ConvertTo-Json -InputObject $crashSnapshot -Depth 12 | Set-Content -LiteralPath $snapshotPath -Encoding utf8
    $powershell = (Get-Process -Id $PID).Path
    $process = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child,$modulePath,$journal,$snapshotPath,$device) -Wait -PassThru
    if ($process.ExitCode -eq 0) { throw 'FAIL: crash-injection child exited successfully' }
    $interrupted = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues')
    $restoredAfterCrash = Test-MBEndpointRegistrySnapshot $crashSnapshot
    if ($interrupted.Steps[0].State -ne 'Running' -or -not $restoredAfterCrash) { throw "FAIL: crash state mismatch (exit=$($process.ExitCode), journal=$($interrupted.Steps[0].State), restored=$restoredAfterCrash, attempts=$($interrupted.Steps[0].Attempts))" }
    Invoke-MBRecoveryStep -Path $journal -StepId 'RestoreEndpointValues' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues') -Action { throw 'Endpoint registry restore action repeated after interruption' } -Verify { Test-MBEndpointRegistrySnapshot $crashSnapshot }
    $resumed = Read-MBRecoveryJournal -Path $journal -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$device) -ExpectedStepIds @('RestoreEndpointValues')
    if ($resumed.Steps[0].State -ne 'Completed' -or $resumed.Steps[0].Attempts -ne 1) { throw 'FAIL: fresh-process recovery repeated the registry action or did not complete' }

    Write-Host 'PASS: endpoint Fx registry snapshot, JSON round-trip, exact-match zero-write recovery, exact value/type restore, missing-value removal, unrelated-value preservation, absent-key cleanup, and process-crash resume'
} finally {
    Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path 'Registry::HKEY_CURRENT_USER' $leaf) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path 'Registry::HKEY_CURRENT_USER' $crashLeaf) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
