Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.EndpointRegistryRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.RegistryAclRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.ComRegistrationRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallFileRollback.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallMetadataRollback.psm1') -Force -ErrorAction Stop

# Recovery ScriptBlocks are reconstructed from transaction state on every
# invocation. Publish action commands into the caller scope for deferred blocks.
foreach($moduleName in @(
    'MicBridge.EndpointRegistryRollback.psm1',
    'MicBridge.RegistryAclRollback.psm1',
    'MicBridge.ComRegistrationRollback.psm1',
    'MicBridge.InstallRollbackActions.psm1',
    'MicBridge.InstallFileRollback.psm1',
    'MicBridge.InstallMetadataRollback.psm1'
)) {
    Import-Module (Join-Path $PSScriptRoot $moduleName) -Force -Global -ErrorAction Stop
}

function Test-MBFullRollbackNoReparse {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $current=[IO.Path]::GetFullPath($Path)
        while($true) {
            if(Test-Path -LiteralPath $current) {
                $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            $parent=[IO.Directory]::GetParent($current)
            if(-not $parent) { return $true }
            $current=$parent.FullName
        }
    } catch { return $false }
}

function Get-MBFullRollbackEndpointSnapshot {
    param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][ValidateSet('HKLM','HKCU')][string]$RegistryHive)
    $device=[guid]::Parse([string]$State.DeviceId).ToString('D')
    $captureRoot='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    $fxPath="$captureRoot\$device\FxProperties"
    return [pscustomobject]@{
        RegistryPath="$RegistryHive\$fxPath"
        KeyExists=[bool]$State.FxKeyExisted
        Values=@(
            [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7';Exists=[bool]$State.FxEffect.Exists;Kind=[string]$State.FxEffect.Kind;Value=$State.FxEffect.Value}
            [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0';Exists=[bool]$State.FxAssociation.Exists;Kind=[string]$State.FxAssociation.Kind;Value=$State.FxAssociation.Value}
            [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15';Exists=[bool]$State.FxComposite.Exists;Kind=[string]$State.FxComposite.Kind;Value=$State.FxComposite.Value}
        )
    }
}

function Get-MBFullRollbackDllArguments {
    param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][string]$DataDirectory,[Parameter(Mandatory)][string]$InstallDirectory)
    $backupPath=$null
    $backupHash=$null
    if($State.PSObject.Properties.Name -contains 'DllBackupPath') { $backupPath=[string]$State.DllBackupPath }
    if($State.PSObject.Properties.Name -contains 'DllBackupSha256') { $backupHash=[string]$State.DllBackupSha256 }
    return @{
        InstalledDllPath=(Join-Path $InstallDirectory 'MicBridgeAPO.dll')
        DllExisted=[bool]$State.DllExisted
        ReplacementStarted=[bool]$State.DllReplacementStarted
        OriginalSha256=[string]$State.DllOriginalSha256
        BackupPath=$backupPath
        BackupSha256=$backupHash
        BackupRoot=(Join-Path $DataDirectory 'dll-backups')
        NewDllSha256=[string]$State.DllNewSha256
        InstallRoot=$InstallDirectory
    }
}

function Test-MBFullRollbackPreviousInstallState {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DesktopDirectory,
        [Parameter(Mandatory)][ValidateSet('HKLM','HKCU')][string]$RegistryHive
    )
    $clsid=Test-MBComRegistrySnapshotRestored -Target CLSID -State $State -TransactionDirectory $TransactionDirectory -RegistryHive $RegistryHive
    $apo=Test-MBComRegistrySnapshotRestored -Target AudioEngineAPO -State $State -TransactionDirectory $TransactionDirectory -RegistryHive $RegistryHive
    $dllArgs=Get-MBFullRollbackDllArguments -State $State -DataDirectory $DataDirectory -InstallDirectory $InstallDirectory
    $dll=Test-MBDllSnapshotRestored @dllArgs
    $files=Test-MBInstallSupportFilesRestored -State $State -InstallDirectory $InstallDirectory
    $metadata=Test-MBInstallMetadataRestored -State $State -DataDirectory $DataDirectory -DesktopDirectory $DesktopDirectory
    $installDirectory=([bool]$State.InstallDirExisted -or -not (Test-Path -LiteralPath $InstallDirectory -PathType Container))
    return ($clsid -and $apo -and $dll -and $files -and $metadata -and $installDirectory)
}

function Invoke-MBInstallFullRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [string]$DesktopDirectory=[Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM'
    )
    $ErrorActionPreference='Stop'
    $tx=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $desktop=[IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    if([IO.Path]::GetFileName($tx) -notmatch '^transactions-[A-Za-z0-9-]+$') { throw 'Full rollback requires a transaction-owned transactions-* directory.' }
    foreach($dir in @($tx,$data,$desktop)) {
        if(-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Required full rollback directory is missing: $dir" }
    }
    $lock=Enter-MBRecoveryOperationLock -Path (Join-Path $data 'operation') -TimeoutSeconds 0
    try {
        $journalPath=Join-Path $tx 'rollback-recovery.json'
        $statePath=Join-Path $tx 'state.json'
        $stepIds=@('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $preflight=Test-MBInstallRollbackTransaction -JournalPath $journalPath -StatePath $statePath -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $stepIds -RegistryHive $RegistryHive
        if(-not $preflight.IsValid -or -not $preflight.ReplaySafe) { throw "Full rollback preflight failed; no recovery actions attempted. $($preflight.Errors -join '; ')" }
        $state=$preflight.State
        if([bool]$state.InstallDirExisted -and -not (Test-Path -LiteralPath $install -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $install | Out-Null
        }
        if((Test-Path -LiteralPath $install -PathType Container) -and -not (Test-MBFullRollbackNoReparse $install)) {
            throw 'Installation directory traverses a reparse point; refusing full rollback.'
        }
        $device=[guid]$state.DeviceId
        $endpointSnapshot=Get-MBFullRollbackEndpointSnapshot -State $state -RegistryHive $RegistryHive
        $captureSub="SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$($device.ToString('D'))"
        $fxSub="$captureSub\FxProperties"
        $dllArgs=Get-MBFullRollbackDllArguments -State $state -DataDirectory $data -InstallDirectory $install

        $endpointAction={ Restore-MBEndpointRegistrySnapshot -Snapshot $endpointSnapshot | Out-Null }.GetNewClosure()
        $endpointVerify={ Test-MBEndpointRegistrySnapshot -Snapshot $endpointSnapshot }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointFxValues' -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds $stepIds -Action $endpointAction -Verify $endpointVerify

        $aclAction={
            if(-not [string]::IsNullOrWhiteSpace([string]$state.FxSddl)) {
                Restore-MBRegistryAclSddl -Hive $RegistryHive -SubKeyPath $fxSub -Sddl ([string]$state.FxSddl)
            }
            Restore-MBRegistryAclSddl -Hive $RegistryHive -SubKeyPath $captureSub -Sddl ([string]$state.DevSddl)
        }.GetNewClosure()
        $aclVerify={
            $deviceAcl=Test-MBRegistryAclSddl -Hive $RegistryHive -SubKeyPath $captureSub -ExpectedSddl ([string]$state.DevSddl)
            if(-not $deviceAcl) { return $false }
            if([string]::IsNullOrWhiteSpace([string]$state.FxSddl)) {
                return ($null -eq (Get-MBRegistryAclSddl -Hive $RegistryHive -SubKeyPath $fxSub))
            }
            return (Test-MBRegistryAclSddl -Hive $RegistryHive -SubKeyPath $fxSub -ExpectedSddl ([string]$state.FxSddl))
        }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointAcl' -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds $stepIds -Action $aclAction -Verify $aclVerify

        $previousStateAction={
            Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive $RegistryHive | Out-Null
            Restore-MBComRegistrySnapshot -Target AudioEngineAPO -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive $RegistryHive | Out-Null
            if([bool]$state.DllReplacementStarted) { Restore-MBDllSnapshot @dllArgs | Out-Null }
            Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null
            Restore-MBInstallMetadataSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null
            if(-not [bool]$state.InstallDirExisted -and (Test-Path -LiteralPath $install -PathType Container)) {
                $remaining=@(Get-ChildItem -LiteralPath $install -Force -ErrorAction Stop)
                if($remaining.Count -eq 0) { Remove-Item -LiteralPath $install -Force -ErrorAction Stop }
            }
        }.GetNewClosure()
        $previousStateVerify={
            Test-MBFullRollbackPreviousInstallState -State $state -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -DesktopDirectory $desktop -RegistryHive $RegistryHive
        }.GetNewClosure()
        Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestorePreviousInstallState' -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds $stepIds -Action $previousStateAction -Verify $previousStateVerify

        $completed=Read-MBRecoveryJournal -Path $journalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds $stepIds
        if(@($completed.Steps | Where-Object State -ne 'Completed').Count -gt 0) { throw 'Full rollback journal did not reach Completed for every main step.' }
        return [pscustomobject]@{Success=$true;TransactionId=[string]$completed.TransactionId;JournalPath=$journalPath;CompletedSteps=@($completed.Steps.StepId)}
    } finally {
        if($lock) { $lock.Dispose() }
    }
}

Export-ModuleMember -Function Invoke-MBInstallFullRollback
