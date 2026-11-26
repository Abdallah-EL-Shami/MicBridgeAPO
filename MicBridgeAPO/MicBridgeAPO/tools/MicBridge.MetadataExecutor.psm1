Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallMetadataRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallMetadataRollback.psm1') -Force -Global -ErrorAction Stop

function Invoke-MBInstallMetadataRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DesktopDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM'
    )
    $ErrorActionPreference='Stop'
    $tx=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $desktop=[IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    if([IO.Path]::GetFileName($tx) -notmatch '^transactions-[A-Za-z0-9-]+$') { throw 'Metadata recovery requires a transaction-owned transactions-* directory.' }
    foreach($dir in @($tx,$data,$install,$desktop)) {
        if(-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Required metadata recovery directory is missing: $dir" }
    }
    $lock=Enter-MBRecoveryOperationLock -Path (Join-Path $data 'operation') -TimeoutSeconds 0
    try {
        $journalPath=Join-Path $tx 'rollback-recovery.json'
        $statePath=Join-Path $tx 'state.json'
        $mainSteps=@('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $preflight=Test-MBInstallRollbackTransaction -JournalPath $journalPath -StatePath $statePath -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $mainSteps -RegistryHive $RegistryHive
        if(-not $preflight.IsValid -or -not $preflight.ReplaySafe) { throw "Metadata recovery preflight failed; no files or ACLs changed. $($preflight.Errors -join '; ')" }
        $metadataPreflight=Test-MBInstallMetadataSnapshot -State $preflight.State -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop
        if(-not $metadataPreflight.IsValid) { throw "Metadata snapshot rejected; no files or ACLs changed. $($metadataPreflight.Errors -join '; ')" }
        $componentPath=Join-Path $tx 'metadata-recovery.json'
        $steps=@('RestoreInstallMetadata')
        if(Test-Path -LiteralPath $componentPath -PathType Leaf) {
            $component=Read-MBRecoveryJournal -Path $componentPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps
            if([string]$component.TransactionId -ne [string]$preflight.Journal.TransactionId) { throw 'Metadata component journal belongs to another transaction.' }
        } elseif(Test-Path -LiteralPath $componentPath) { throw 'Metadata component journal path is not a regular file.' }
        else { New-MBRecoveryJournal -Path $componentPath -Operation InstallRollback -DeviceId $ExpectedDeviceId -StepIds $steps -TransactionId ([guid]$preflight.Journal.TransactionId) | Out-Null }
        $state=$preflight.State
        $action={ Restore-MBInstallMetadataSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null }.GetNewClosure()
        $verify={ Test-MBInstallMetadataRestored -State $state -DataDirectory $data -DesktopDirectory $desktop }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $componentPath -StepId 'RestoreInstallMetadata' -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps -Action $action -Verify $verify
        $done=Read-MBRecoveryJournal -Path $componentPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $steps
        if($done.Steps[0].State -ne 'Completed') { throw 'Metadata component journal did not reach Completed.' }
        return [pscustomobject]@{Success=$true;Component='RestoreInstallMetadata';TransactionId=[string]$preflight.Journal.TransactionId;JournalPath=$componentPath;MainTransactionStillPending=$true}
    } finally {
        if($lock) { $lock.Dispose() }
    }
}
Export-ModuleMember -Function Invoke-MBInstallMetadataRecovery
