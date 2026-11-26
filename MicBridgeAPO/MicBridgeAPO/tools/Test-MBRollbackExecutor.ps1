$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$journalModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
$validationModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1'
$dllModule = Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1'
$executorModule = Join-Path $PSScriptRoot 'MicBridge.RollbackExecutor.psm1'
$comExecutorModule = Join-Path $PSScriptRoot 'MicBridge.ComRegistrationExecutor.psm1'
$fileExecutorModule = Join-Path $PSScriptRoot 'MicBridge.InstallFileExecutor.psm1'
foreach ($module in @($journalModule,$validationModule,$dllModule,$executorModule,$comExecutorModule,$fileExecutorModule)) {
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw "Missing test dependency: $module" }
}
# Import the executor first: it loads its dependencies into its own module scope.
# Import the journal explicitly afterward for the test's direct journal assertions.
Import-Module $executorModule -Force
Import-Module $comExecutorModule -Force
Import-Module $fileExecutorModule -Force
Import-Module $journalModule -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeRollbackExecutor-' + [guid]::NewGuid().ToString('N'))
$tx = Join-Path $root ('transactions-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'data'
$install = Join-Path $root 'install'
$installFiles = Join-Path $tx 'install-files'
$dllBackups = Join-Path $data 'dll-backups'
$comClsidSub = $null
$comApoSub = $null
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
        $current = Join-Path $install $name
        [IO.File]::WriteAllText($backup,"saved:$name")
        [IO.File]::WriteAllText($current,"published:$name")
        $fileEntries += [pscustomobject]@{
            Name=$name; Existed=$true; Backup=$backup
            Sha256=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
            InstalledSha256=(Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
        }
    }

    # Build a transaction-owned COM snapshot using HKCU only. The production
    # executor uses the same fixed CLSID/APO key names under HKLM by default.
    $comClsid='{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
    $comClsidSub="Software\Classes\CLSID\$comClsid"
    $comApoSub="Software\Classes\AudioEngine\AudioProcessingObjects\$comClsid"
    $comClsidKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($comClsidSub)
    $comInproc=$comClsidKey.CreateSubKey('InprocServer32')
    $comInproc.SetValue('', $installedDll, [Microsoft.Win32.RegistryValueKind]::String)
    $comInproc.Dispose(); $comClsidKey.Dispose()
    $comApoKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($comApoSub)
    $comApoKey.SetValue('FriendlyName','MicBridge previous APO',[Microsoft.Win32.RegistryValueKind]::String)
    $comApoKey.Dispose()
    $clsidBackup=Join-Path $tx 'clsid.reg'
    $apoBackup=Join-Path $tx 'audioengine-apo.reg'
    $regExe=Join-Path $env:SystemRoot 'System32\reg.exe'
    & $regExe export "HKCU\$comClsidSub" $clsidBackup /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export transaction CLSID fixture' }
    & $regExe export "HKCU\$comApoSub" $apoBackup /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export transaction APO fixture' }

    $state = [pscustomobject]@{
        DeviceId=$device.ToString('D')
        TransactionId=$transaction.ToString('D')
        FxEffect=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='String';Value=$null}
        FxAssociation=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='String';Value='{00000000-0000-0000-0000-000000000000}'}
        FxComposite=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='MultiString';Value=$null}
        DevSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxKeyExisted=$true
        ClsidRegExisted=$true; ClsidRegBackup=$clsidBackup; ClsidRegSha256=(Get-FileHash $clsidBackup -Algorithm SHA256).Hash
        ApoRegExisted=$true; ApoRegBackup=$apoBackup; ApoRegSha256=(Get-FileHash $apoBackup -Algorithm SHA256).Hash
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

    # Restore the four installer support files from the durable transaction snapshot.
    $fileResult=Invoke-MBInstallSupportFileRecovery -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -ExpectedDeviceId $device -RegistryHive HKCU
    if(-not $fileResult.Success -or -not $fileResult.MainTransactionStillPending) { throw 'FAIL: support-file executor returned an invalid result' }
    if(-not (Test-MBInstallSupportFilesRestored -State $state -InstallDirectory $install)) { throw 'FAIL: support-file executor did not restore the previous files' }
    Import-Module $journalModule -Force -Global
    $fileJournal=Read-MBRecoveryJournal -Path $fileResult.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreInstallSupportFiles')
    if($fileJournal.Steps[0].State -ne 'Completed') { throw 'FAIL: support-file component journal did not complete' }
    $mainAfterFiles=Read-MBRecoveryJournal -Path $primaryJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
    if($mainAfterFiles.Steps[2].State -ne 'Pending') { throw 'FAIL: support-file executor incorrectly marked grouped main step complete' }

    # Mutate only values beneath the product-owned HKCU CLSID/APO fixture.
    $comClsidKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($comClsidSub,$true)
    $comInproc=$comClsidKey.OpenSubKey('InprocServer32',$true)
    $comInproc.SetValue('ThreadingModel','Both',[Microsoft.Win32.RegistryValueKind]::String)
    $comInproc.Dispose(); $comClsidKey.Dispose()
    $comApoKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($comApoSub,$true)
    $comApoKey.SetValue('FriendlyName','MicBridge failed update',[Microsoft.Win32.RegistryValueKind]::String)
    $comApoKey.Dispose()

    $comResult=Invoke-MBInstallComRecovery -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -ExpectedDeviceId $device -RegistryHive HKCU
    if(-not $comResult.Success -or -not $comResult.MainTransactionStillPending) { throw 'FAIL: COM executor returned an invalid result' }
    Import-Module $journalModule -Force -Global
    $comJournal=Read-MBRecoveryJournal -Path $comResult.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreComCLSID','RestoreComAudioEngineAPO')
    if(@($comJournal.Steps | Where-Object State -ne 'Completed').Count -ne 0) { throw 'FAIL: COM executor did not complete both registration restores' }
    $mainAfterCom=Read-MBRecoveryJournal -Path $primaryJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
    if($mainAfterCom.Steps[2].State -ne 'Pending') { throw 'FAIL: COM executor incorrectly marked the grouped main rollback step complete' }

    $result = Invoke-MBInstallDllRecovery -TransactionDirectory $tx -DataDirectory $data -InstallDirectory $install -ExpectedDeviceId $device -RegistryHive HKCU
    if (-not $result.Success -or -not $result.MainTransactionStillPending) { throw 'FAIL: executor returned an invalid completion result' }
    $restoredHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash
    if (-not [string]::Equals($restoredHash,$originalHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'FAIL: executor did not restore the previous DLL bytes'
    }

    # The executor's module-scoped dependency imports can shadow the test's
    # imported command binding; re-import in the test scope before assertions.
    Import-Module $journalModule -Force -Global
    $dllJournal = Read-MBRecoveryJournal -Path $result.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreDll')
    if ($dllJournal.Steps[0].State -ne 'Completed' -or $dllJournal.Steps[0].Attempts -ne 1) {
        throw 'FAIL: component journal did not record verified completion'
    }
    $mainJournal = Read-MBRecoveryJournal -Path $primaryJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
    if ($mainJournal.Steps[2].State -ne 'Pending') {
        throw 'FAIL: isolated DLL executor incorrectly marked the grouped main rollback step complete'
    }

    # Re-enter from a distinct PowerShell process. This proves the executor
    # reconstructs its action from the durable transaction files, not closures
    # left behind in the process that performed the first restore.
    $childScript = Join-Path $tx 'dll-executor-reentry-child.ps1'
    $childSource = @'
param([string]$ExecutorModule,[string]$ComExecutorModule,[string]$FileExecutorModule,[string]$TransactionDirectory,[string]$DataDirectory,[string]$InstallDirectory,[string]$DeviceId)
$ErrorActionPreference = 'Stop'
Import-Module $FileExecutorModule -Force
$file = Invoke-MBInstallSupportFileRecovery -TransactionDirectory $TransactionDirectory -DataDirectory $DataDirectory -InstallDirectory $InstallDirectory -ExpectedDeviceId ([guid]$DeviceId) -RegistryHive HKCU
if (-not $file.Success -or -not $file.MainTransactionStillPending) { throw 'Fresh-process support-file executor returned an invalid result.' }
Import-Module $ComExecutorModule -Force
$com = Invoke-MBInstallComRecovery -TransactionDirectory $TransactionDirectory -DataDirectory $DataDirectory -InstallDirectory $InstallDirectory -ExpectedDeviceId ([guid]$DeviceId) -RegistryHive HKCU
if (-not $com.Success -or -not $com.MainTransactionStillPending) { throw 'Fresh-process COM executor returned an invalid result.' }
Import-Module $ExecutorModule -Force
$result = Invoke-MBInstallDllRecovery -TransactionDirectory $TransactionDirectory -DataDirectory $DataDirectory -InstallDirectory $InstallDirectory -ExpectedDeviceId ([guid]$DeviceId) -RegistryHive HKCU
if (-not $result.Success -or -not $result.MainTransactionStillPending) { throw 'Fresh-process DLL executor returned an invalid result.' }
'@
    [IO.File]::WriteAllText($childScript,$childSource,(New-Object Text.UTF8Encoding($false)))
    $childProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,
        $executorModule,$comExecutorModule,$fileExecutorModule,$tx,$data,$install,$device.ToString('D')
    ) -Wait -PassThru
    if ($childProcess.ExitCode -ne 0) { throw "FAIL: fresh-process executor re-entry failed with exit code $($childProcess.ExitCode)" }

    $after = Read-MBRecoveryJournal -Path $result.JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $device -ExpectedStepIds @('RestoreDll')
    if ($after.Steps[0].State -ne 'Completed' -or $after.Steps[0].Attempts -ne 1) {
        throw 'FAIL: fresh-process idempotent re-entry repeated the DLL restore side effect'
    }

    Write-Host 'PASS: isolated COM, support-file and DLL executors, HKCU COM snapshot restoration, durable component journals, transaction identity binding, fresh-process idempotent re-entry, and preservation of main fail-closed journal'
} finally {
    if ($comClsidSub) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($comClsidSub,$false) }
    if ($comApoSub) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($comApoSub,$false) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
