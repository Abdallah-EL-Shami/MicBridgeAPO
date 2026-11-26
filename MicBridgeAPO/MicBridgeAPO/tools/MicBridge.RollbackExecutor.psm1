Set-StrictMode -Version Latest

# Import dependencies when this module is loaded, into this module's own
# session state. Imports performed inside Invoke-MBInstallDllRecovery are
# scoped to that call and are not reliably visible to its deferred ScriptBlocks.
Import-Module (Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Force -ErrorAction Stop
# Deferred recovery ScriptBlocks execute outside this module's session state;
# publish the action/verifier commands to the caller session as well.
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Force -Global -ErrorAction Stop

function Invoke-MBInstallDllRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId
    )

    $ErrorActionPreference = 'Stop'
    $transactionRoot = [IO.Path]::GetFullPath($TransactionDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $dataRoot = [IO.Path]::GetFullPath($DataDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $expectedTransactionName = [IO.Path]::GetFileName($transactionRoot)
    if ($expectedTransactionName -notmatch '^transactions-[A-Za-z0-9-]+$') {
        throw 'DLL recovery requires a transaction-owned transactions-* directory.'
    }
    if (-not (Test-Path -LiteralPath $transactionRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $dataRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $installRoot -PathType Container)) {
        throw 'Transaction, ProgramData, or installation directory is missing.'
    }

    $validationModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1'
    $journalModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
    $dllModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1'
    foreach ($modulePath in @($validationModule,$journalModule,$dllModule)) {
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Required rollback module is missing: $modulePath"
        }
    }
    # Use the same exclusive operation lock as install.ps1 across the full
    # preflight, DLL side effect, verification, and journal completion.
    $operationLockPath = Join-Path $dataRoot 'operation'
    $operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0
    try {
        $primaryJournal = Join-Path $transactionRoot 'rollback-recovery.json'
        $statePath = Join-Path $transactionRoot 'state.json'
        $legacyStepIds = @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')

        # Existing transaction format only. Never reinterpret its grouped
        # RestorePreviousInstallState step or mark it complete here.
        $preflight = Test-MBInstallRollbackTransaction -JournalPath $primaryJournal -StatePath $statePath -TransactionDirectory $transactionRoot -DataDirectory $dataRoot -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $legacyStepIds
        if (-not $preflight.IsValid -or -not $preflight.ReplaySafe) {
            throw "DLL recovery preflight failed; no DLL changes were attempted. $($preflight.Errors -join '; ')"
        }

        $state = $preflight.State
        $backupPath = $null
        $backupSha256 = $null
        if ($state.PSObject.Properties.Name -contains 'DllBackupPath') { $backupPath = [string]$state.DllBackupPath }
        if ($state.PSObject.Properties.Name -contains 'DllBackupSha256') { $backupSha256 = [string]$state.DllBackupSha256 }
        $dllArgs = @{
            InstalledDllPath=(Join-Path $installRoot 'MicBridgeAPO.dll')
            DllExisted=[bool]$state.DllExisted
            ReplacementStarted=[bool]$state.DllReplacementStarted
            OriginalSha256=[string]$state.DllOriginalSha256
            BackupPath=$backupPath
            BackupSha256=$backupSha256
            BackupRoot=(Join-Path $dataRoot 'dll-backups')
            NewDllSha256=[string]$state.DllNewSha256
            InstallRoot=$installRoot
        }

        # A separate journal records only this independently verifiable
        # component. The main three-step journal remains pending and fail-closed.
        $dllJournalPath = Join-Path $transactionRoot 'dll-recovery.json'
        $dllStepIds = @('RestoreDll')
        if (Test-Path -LiteralPath $dllJournalPath -PathType Leaf) {
            $dllJournal = Read-MBRecoveryJournal -Path $dllJournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $dllStepIds
            if ([string]$dllJournal.TransactionId -ne [string]$preflight.Journal.TransactionId) {
                throw 'DLL recovery journal belongs to another transaction.'
            }
        } elseif (Test-Path -LiteralPath $dllJournalPath) {
            throw 'DLL recovery journal path is not a regular file.'
        } else {
            New-MBRecoveryJournal -Path $dllJournalPath -Operation InstallRollback -DeviceId $ExpectedDeviceId -StepIds $dllStepIds -TransactionId ([guid]$preflight.Journal.TransactionId) | Out-Null
        }

        $action = { Restore-MBDllSnapshot @dllArgs | Out-Null }.GetNewClosure()
        $verify = { Test-MBDllSnapshotRestored @dllArgs }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $dllJournalPath -StepId 'RestoreDll' -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $dllStepIds -Action $action -Verify $verify

        $completed = Read-MBRecoveryJournal -Path $dllJournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $dllStepIds
        if ($completed.Steps[0].State -ne 'Completed') {
            throw 'DLL recovery journal did not reach Completed after verification.'
        }

        return [pscustomobject]@{
            Success = $true
            Component = 'RestoreDll'
            TransactionId = [string]$preflight.Journal.TransactionId
            JournalPath = $dllJournalPath
            MainTransactionStillPending = $true
        }
    } finally {
        if ($operationLock) { $operationLock.Dispose() }
    }
}

Export-ModuleMember -Function Invoke-MBInstallDllRecovery
