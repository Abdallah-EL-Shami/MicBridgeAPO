Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallFileRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallFileRollback.psm1') -Force -Global -ErrorAction Stop

function Invoke-MBInstallSupportFileRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM'
    )
    $ErrorActionPreference='Stop'
    $tx=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    if([IO.Path]::GetFileName($tx) -notmatch '^transactions-[A-Za-z0-9-]+$') { throw 'Support-file recovery requires a transaction-owned transactions-* directory.' }
    foreach($dir in @($tx,$data,$install)) {
        if(-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Required recovery directory is missing: $dir" }
    }
    $lock=Enter-MBRecoveryOperationLock -Path (Join-Path $data 'operation') -TimeoutSeconds 0
    try {
        $journalPath=Join-Path $tx 'rollback-recovery.json'
        $statePath=Join-Path $tx 'state.json'
        $mainSteps=@('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $preflight=Test-MBInstallRollbackTransaction -JournalPath $journalPath -StatePath $statePath -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $mainSteps -RegistryHive $RegistryHive
        if(-not $preflight.IsValid -or -not $preflight.ReplaySafe) { throw "Support-file recovery preflight failed; no support files changed. $($preflight.Errors -join '; ')" }
        $filePreflight=Test-MBInstallFileRollbackState -State $preflight.State -TransactionDirectory $tx -InstallDirectory $install
        if(-not $filePreflight.IsValid) { throw "Support-file snapshot rejected; no files changed. $($filePreflight.Errors -join '; ')" }
        $componentPath=Join-Path $tx 'install-files-recovery.json'
        $steps=@('RestoreInstallSupportFiles')
        if(Test-Path -LiteralPath $componentPath -PathType Leaf) {
            $component=Read-MBRecoveryJournal -Path $componentPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps
            if([string]$component.TransactionId -ne [string]$preflight.Journal.TransactionId) { throw 'Support-file component journal belongs to another transaction.' }
        } elseif(Test-Path -LiteralPath $componentPath) { throw 'Support-file component journal path is not a regular file.' }
        else { New-MBRecoveryJournal -Path $componentPath -Operation InstallRollback -DeviceId $ExpectedDeviceId -StepIds $steps -TransactionId ([guid]$preflight.Journal.TransactionId) | Out-Null }
        $state=$preflight.State
        $action={ Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null }.GetNewClosure()
        $verify={ Test-MBInstallSupportFilesRestored -State $state -InstallDirectory $install }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $componentPath -StepId 'RestoreInstallSupportFiles' -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps -Action $action -Verify $verify
        $done=Read-MBRecoveryJournal -Path $componentPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps
        if($done.Steps[0].State -ne 'Completed') { throw 'Support-file component journal did not reach Completed.' }
        return [pscustomobject]@{Success=$true;Component='RestoreInstallSupportFiles';TransactionId=[string]$preflight.Journal.TransactionId;JournalPath=$componentPath;MainTransactionStillPending=$true}
    } finally {
        if($lock) { $lock.Dispose() }
    }
}
Export-ModuleMember -Function Invoke-MBInstallSupportFileRecovery
