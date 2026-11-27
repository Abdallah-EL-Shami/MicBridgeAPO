Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.ComRegistrationRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.ComRegistrationRollback.psm1') -Force -Global -ErrorAction Stop

function Invoke-MBInstallComRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM'
    )
    $ErrorActionPreference='Stop'
    if($RegistryHive -ne 'HKLM' -and $RegistryHive -ne 'HKCU') { throw 'Unsupported registry hive.' }
    $txRoot=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $dataRoot=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $installRoot=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    if([IO.Path]::GetFileName($txRoot) -notmatch '^transactions-[A-Za-z0-9-]+$') { throw 'COM recovery requires a transaction-owned transactions-* directory.' }
    foreach($dir in @($txRoot,$dataRoot,$installRoot)) {
        if(-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Required recovery directory is missing: $dir" }
    }
    $operationLock=Enter-MBRecoveryOperationLock -Path (Join-Path $dataRoot 'operation') -TimeoutSeconds 0
    try {
        $primaryJournal=Join-Path $txRoot 'rollback-recovery.json'
        $statePath=Join-Path $txRoot 'state.json'
        $mainSteps=@('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $preflight=Test-MBInstallRollbackTransaction -JournalPath $primaryJournal -StatePath $statePath -TransactionDirectory $txRoot -DataDirectory $dataRoot -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $mainSteps -RegistryHive $RegistryHive
        if(-not $preflight.IsValid -or -not $preflight.ReplaySafe) { throw "COM recovery preflight failed; no COM changes attempted. $($preflight.Errors -join '; ')" }
        $state=$preflight.State
        $componentJournal=Join-Path $txRoot 'com-recovery.json'
        $stepIds=@('RestoreComCLSID','RestoreComAudioEngineAPO')
        if(Test-Path -LiteralPath $componentJournal -PathType Leaf) {
            $existing=Read-MBRecoveryJournal -Path $componentJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $stepIds
            if([string]$existing.TransactionId -ne [string]$preflight.Journal.TransactionId) { throw 'COM component journal belongs to a different transaction.' }
        } elseif(Test-Path -LiteralPath $componentJournal) { throw 'COM component journal path is not a regular file.' }
        else { New-MBRecoveryJournal -Path $componentJournal -Operation InstallRollback -DeviceId $ExpectedDeviceId -StepIds $stepIds -TransactionId ([guid]$preflight.Journal.TransactionId) | Out-Null }

        $clsidAction={ Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $txRoot -InstallDirectory $installRoot -RegistryHive $RegistryHive | Out-Null }.GetNewClosure()
        $clsidVerify={ Test-MBComRegistrySnapshotRestored -Target CLSID -State $state -TransactionDirectory $txRoot -RegistryHive $RegistryHive }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $componentJournal -StepId 'RestoreComCLSID' -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $stepIds -Action $clsidAction -Verify $clsidVerify

        $apoAction={ Restore-MBComRegistrySnapshot -Target AudioEngineAPO -State $state -TransactionDirectory $txRoot -InstallDirectory $installRoot -RegistryHive $RegistryHive | Out-Null }.GetNewClosure()
        $apoVerify={ Test-MBComRegistrySnapshotRestored -Target AudioEngineAPO -State $state -TransactionDirectory $txRoot -RegistryHive $RegistryHive }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $componentJournal -StepId 'RestoreComAudioEngineAPO' -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $stepIds -Action $apoAction -Verify $apoVerify

        $done=Read-MBRecoveryJournal -Path $componentJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $stepIds
        if(@($done.Steps | Where-Object State -ne 'Completed').Count -ne 0) { throw 'COM component journal did not complete both verified steps.' }
        return [pscustomobject]@{
            Success=$true
            Component='COM registrations'
            TransactionId=[string]$preflight.Journal.TransactionId
            JournalPath=$componentJournal
            MainTransactionStillPending=$true
        }
    } finally { if($operationLock) { $operationLock.Dispose() } }
}
Export-ModuleMember -Function Invoke-MBInstallComRecovery
