$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$journalModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
$validationModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1'
$dllModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1'
$executorModule = Join-Path $PSScriptRoot 'MicBridge.RollbackExecutor.psm1'
foreach ($module in @($journalModule,$validationModule,$dllModule,$executorModule)) {
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw "Missing test dependency: $module" }
}
# Import the executor first: it loads its dependencies into its own module scope.
# Import the journal explicitly afterward for the test's direct journal assertions.
Import-Module $executorModule -Force
Import-Module $journalModule -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeRollbackExecutor-' + [guid]::NewGuid().ToString('N'))
$tx = Join-Path $root ('transactions-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'data'
$install = Join-Path $root 'install'
$installFiles = Join-Path $tx 'install-files'
$dllBackups = Join-Path $data 'dll-backups'
New-Item -ItemType Directory -Force -Path $tx,$data,$install,$installFiles,$dllBackups | Out-Null

try {
    $device = [guid]::NewGuid()
    $transaction = [guid]::NewGuid()
    $originalDll = Join-Path $dllBackups 'previous.dll'
    $installedDll = Join-Path $install 'MicBridgeAPO.dll'
    [IO.File]::WriteAllText($originalDll,'original-dll-bytes')
    [IO.File]::WriteAllText($installedDll,'new-dll-bytes')
    $originalHash = (Get-FileHash -LiteralPath $originalDll -Algorithm SHA256).Hash
    $newHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash

    $fileEntries = @()
    foreach ($name in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
        $backup = Join-Path $installFiles $name
        [IO.File]::WriteAllText($backup,"saved:$name")
        $fileEntries += [pscustomobject]@{
            Name=$name; Existed=$true; Backup=$backup
            Sha256=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
        }
    }

    $state = [pscustomobject]@{
        DeviceId=$device.ToString('D')
        TransactionId=$transaction.ToString('D')
        FxEffect=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='String';Value=$null}
        FxAssociation=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='String';Value='{00000000-0000-0000-0000-000000000000}'}
        FxComposite=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='MultiString';Value=$null}
        DevSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxKeyExisted=$true
        ClsidRegExisted=$false; ClsidRegBackup=$null; ClsidRegSha256=$null
        ApoRegExisted=$false; ApoRegBackup=$null; ApoRegSha256=$null
        DllExisted=$true; DllOriginalSha256=$originalHash
        DllNewSha256=$newHash; DllReplacementStarted=$true
        DllBackupPath=$originalDll; DllBackupSha256=$originalHash
        IniExisted=$false; ControlExisted=$false
        DataDirSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'; ControlSddl=$null
        InstallFiles=$fileEntries
        ShortcutExisted=$false; ShortcutBackup=$null; ShortcutBackupSha256=$null
        InstallDirExisted=$true
    }
    $statePath = Join-Path $tx 'state.json'
    [IO.File]::WriteAllText($statePath,(ConvertTo-Json -InputObject $state -Depth 12),(New-Object Text.UTF8Encoding($false)))

    $primaryJournal = Join-Path $tx 'rollback-recovery.json'
    New-MBRecoveryJournal -Path $primaryJournal -Operation InstallRollback -DeviceId $device -StepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState') -TransactionId $transaction | Out-Null

    $result = Invoke-MBInstallDllRecovery -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -ExpectedDeviceId $device
    if (-not $result.Success -or -not $result.MainTransactionStillPending) { throw 'FAIL: executor returned an invalid completion result' }
    $restoredHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash
    if (-not [string]::Equals($restoredHash,$originalHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'FAIL: executor did not restore the previous DLL bytes'
    }

    $dllJournal = Read-MBRecoveryJournal -Path $result.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreDll')
    if ($dllJournal.Steps[0].State -ne 'Completed' -or $dllJournal.Steps[0].Attempts -ne 1) {
        throw 'FAIL: component journal did not record verified completion'
    }
    $mainJournal = Read-MBRecoveryJournal -Path $primaryJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
    if ($mainJournal.Steps[2].State -ne 'Pending') {
        throw 'FAIL: isolated DLL executor incorrectly marked the grouped main rollback step complete'
    }

    # Re-entry in a fresh invocation must be idempotent and must not overwrite
    # the restored file or increment the action attempt count.
    $again = Invoke-MBInstallDllRecovery -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -ExpectedDeviceId $device
    $after = Read-MBRecoveryJournal -Path $again.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreDll')
    if ($after.Steps[0].State -ne 'Completed' -or $after.Steps[0].Attempts -ne 1) {
        throw 'FAIL: idempotent re-entry repeated the DLL restore side effect'
    }

    Write-Host 'PASS: isolated DLL executor preflight, durable component journal, verified restore, transaction identity binding, idempotent re-entry, and preservation of main fail-closed journal'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
