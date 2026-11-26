$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeDllRollback-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $root 'dll-backups'
$installRoot = Join-Path $root 'install'
$installed = Join-Path $installRoot 'MicBridgeAPO.dll'
New-Item -ItemType Directory -Force -Path $backupRoot,$installRoot | Out-Null
try {
    $originalBytes = [byte[]](1,3,5,7,9,11)
    $newBytes = [byte[]](2,4,6,8,10,12)
    $backup = Join-Path $backupRoot 'previous.dll'
    [IO.File]::WriteAllBytes($backup,$originalBytes)
    $originalHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
    $backupHash = $originalHash
    [IO.File]::WriteAllBytes($installed,$newBytes)

    $restoreArgs = @{
        InstalledDllPath=$installed
        DllExisted=$true
        ReplacementStarted=$true
        OriginalSha256=$originalHash
        BackupPath=$backup
        BackupSha256=$backupHash
        BackupRoot=$backupRoot
        NewDllSha256=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        InstallRoot=$installRoot
    }
    # Hold the destination without delete sharing: atomic rollback must fail closed
    # and leave the currently installed bytes intact while Windows denies replacement.
    $lockedHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
    $lockedStream = [IO.File]::Open($installed,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $lockedRejected = $false
        try { Restore-MBDllSnapshot @restoreArgs | Out-Null } catch { $lockedRejected = $true }
        if (-not $lockedRejected) { throw 'FAIL: rollback replaced a DLL whose destination denied delete sharing' }
    } finally { $lockedStream.Dispose() }
    if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $lockedHash) {
        throw 'FAIL: failed locked-file rollback changed the installed DLL'
    }

    Restore-MBDllSnapshot @restoreArgs | Out-Null
    if (-not (Test-MBDllSnapshotRestored @restoreArgs)) { throw 'FAIL: restored DLL did not satisfy its snapshot verifier' }
    Restore-MBDllSnapshot @restoreArgs | Out-Null
    if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $originalHash) { throw 'FAIL: repeated recovery was not idempotent' }

    # Simulate a crash after the destination copy but before journal completion,
    # followed by loss of the backup file. A verified destination must be enough
    # to recognize that the action already completed.
    Remove-Item -LiteralPath $backup -Force
    Restore-MBDllSnapshot @restoreArgs | Out-Null
    [IO.File]::WriteAllBytes($backup,$originalBytes)
    [IO.File]::WriteAllBytes($installed,[byte[]](31,32,33))
    $foreignInstalledHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
    $foreignInstallRejected = $false
    try { Restore-MBDllSnapshot @restoreArgs | Out-Null } catch { $foreignInstallRejected = $_.Exception.Message -match 'unowned file' }
    if (-not $foreignInstallRejected -or (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $foreignInstalledHash) {
        throw 'FAIL: rollback overwrote a DLL changed outside this transaction'
    }
    [IO.File]::WriteAllBytes($installed,$newBytes)
    # Rejected tampered backup must leave these exact destination bytes unchanged.
    $beforeTamperReject = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
    [IO.File]::AppendAllText($backup,'tampered')
    $rejected = $false
    try { Restore-MBDllSnapshot @restoreArgs | Out-Null } catch { $rejected = $_.Exception.Message -match 'backup hash mismatch' }
    if (-not $rejected) { throw 'FAIL: tampered DLL backup was not rejected' }
    $afterTamperReject = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
    if (-not [string]::Equals($afterTamperReject,$beforeTamperReject,[StringComparison]::OrdinalIgnoreCase)) { throw ('FAIL: rejected tampered backup changed destination DLL (before=' + $beforeTamperReject + ', after=' + $afterTamperReject + ')') }

    $newInstallDll = Join-Path $installRoot 'new-install.dll'
    [IO.File]::WriteAllBytes($newInstallDll,$newBytes)
    $removeArgs = @{
        InstalledDllPath=$newInstallDll
        DllExisted=$false
        ReplacementStarted=$true
        BackupRoot=$backupRoot
        NewDllSha256=(Get-FileHash -LiteralPath $newInstallDll -Algorithm SHA256).Hash
        InstallRoot=$installRoot
    }
    Restore-MBDllSnapshot @removeArgs | Out-Null
    if (Test-Path -LiteralPath $newInstallDll) { throw 'FAIL: newly-created DLL remained after rollback' }
    Restore-MBDllSnapshot @removeArgs | Out-Null

    # A different file appearing at the destination is not owned by this transaction.
    [IO.File]::WriteAllBytes($newInstallDll,[byte[]](21,22,23))
    $foreignHash = (Get-FileHash -LiteralPath $newInstallDll -Algorithm SHA256).Hash
    $foreignRejected = $false
    try { Restore-MBDllSnapshot @removeArgs | Out-Null } catch { $foreignRejected = $_.Exception.Message -match 'unowned file' }
    if (-not $foreignRejected -or (Get-FileHash -LiteralPath $newInstallDll -Algorithm SHA256).Hash -ne $foreignHash) {
        throw 'FAIL: rollback removed or changed a destination not owned by this transaction'
    }
    Remove-Item -LiteralPath $newInstallDll -Force
    $outsideFile = Join-Path $root 'unrelated.dll'
    [IO.File]::WriteAllBytes($outsideFile,$newBytes)
    $outsideRejected = $false
    try { Restore-MBDllSnapshot @{ InstalledDllPath=$outsideFile; DllExisted=$false; ReplacementStarted=$true; InstallRoot=$installRoot } | Out-Null } catch { $outsideRejected = $true }
    if (-not $outsideRejected -or -not (Test-Path -LiteralPath $outsideFile)) { throw 'FAIL: out-of-root DLL destination was not safely rejected' }

    $untouchedArgs = @{
        InstalledDllPath=$installed
        DllExisted=$true
        ReplacementStarted=$false
        OriginalSha256=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        BackupRoot=$backupRoot
        InstallRoot=$installRoot
    }
    if (-not (Test-MBDllSnapshotRestored @untouchedArgs)) { throw 'FAIL: untouched original DLL did not verify' }

    $escapeArgs = $restoreArgs.Clone()
    $escapeArgs.BackupPath = Join-Path $root 'outside.dll'
    $escapeRejected = $false
    try { Restore-MBDllSnapshot @escapeArgs | Out-Null } catch { $escapeRejected = $_.Exception.Message -match 'escapes' }
    if (-not $escapeRejected) { throw 'FAIL: backup path outside the protected directory was not rejected' }

    $rollbackArtifacts = @(Get-ChildItem -LiteralPath $installRoot -Force -ErrorAction Stop | Where-Object { $_.Name -like '.MicBridgeAPO.rollback.*.tmp' -or $_.Name -like '.MicBridgeAPO.rollback.*.bak' })
    if ($rollbackArtifacts.Count -ne 0) { throw 'FAIL: DLL rollback left temporary or replacement-backup artifacts behind' }
    $rollbackModuleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Raw
    if ($rollbackModuleText -notmatch '\[IO\.File\]::Replace\(\$stagedPath,\$InstalledDllPath,\$replacementBackupPath\)') { throw 'FAIL: File.Replace must use a non-empty replacement backup path' }
    if ($rollbackModuleText -match '\[IO\.File\]::Replace\([^\r\n]*,\$null') { throw 'FAIL: File.Replace contains a null backup path' }

    # Exercise a real process death after the DLL restore side effect but
    # before Invoke-MBRecoveryStep can persist Completed. A fresh process must
    # recognize the restored hash and must not invoke the restore action again.
    $recoveryModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
    Import-Module $recoveryModule -Force
    $crashInstalled = Join-Path $installRoot 'crash-resume.dll'
    $crashBackup = Join-Path $backupRoot 'crash-resume-original.dll'
    [IO.File]::WriteAllBytes($crashBackup,$originalBytes)
    [IO.File]::WriteAllBytes($crashInstalled,$newBytes)
    $crashOriginalHash = (Get-FileHash -LiteralPath $crashBackup -Algorithm SHA256).Hash
    $crashNewHash = (Get-FileHash -LiteralPath $crashInstalled -Algorithm SHA256).Hash
    $crashJournal = Join-Path $root 'dll-crash-resume.json'
    $crashDevice = [guid]::NewGuid()
    New-MBRecoveryJournal -Path $crashJournal -Operation InstallRollback -DeviceId $crashDevice -StepIds @('RestoreDll') | Out-Null
    $childScript = Join-Path $root 'dll-crash-child.ps1'
    $childSource = @'
param([string]$RecoveryModule,[string]$DllModule,[string]$Journal,[string]$Installed,[string]$Backup,[string]$BackupRoot,[string]$InstallRoot,[string]$OriginalHash,[string]$NewHash,[string]$Device)
$ErrorActionPreference = 'Stop'
Import-Module $RecoveryModule -Force
Import-Module $DllModule -Force
$argsForRestore = @{
    InstalledDllPath=$Installed; DllExisted=$true; ReplacementStarted=$true
    OriginalSha256=$OriginalHash; BackupPath=$Backup; BackupSha256=$OriginalHash
    BackupRoot=$BackupRoot; NewDllSha256=$NewHash; InstallRoot=$InstallRoot
}
$action = {
    Restore-MBDllSnapshot @argsForRestore | Out-Null
    [Environment]::FailFast('Injected process death after DLL rollback side effect')
}.GetNewClosure()
$verify = { Test-MBDllSnapshotRestored @argsForRestore }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreDll' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreDll') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($childScript,$childSource,(New-Object Text.UTF8Encoding($false)))
    $childProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,
        $recoveryModule,(Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1'),
        $crashJournal,$crashInstalled,$crashBackup,$backupRoot,$installRoot,
        $crashOriginalHash,$crashNewHash,$crashDevice.ToString('D')
    ) -Wait -PassThru
    if ($childProcess.ExitCode -eq 0) { throw 'FAIL: DLL rollback crash-injection child exited successfully' }
    $interrupted = Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreDll')
    if ($interrupted.Steps[0].State -ne 'Running' -or
        -not (Test-MBDllSnapshotRestored @{
            InstalledDllPath=$crashInstalled; DllExisted=$true; ReplacementStarted=$true
            OriginalSha256=$crashOriginalHash; BackupPath=$crashBackup; BackupSha256=$crashOriginalHash
            BackupRoot=$backupRoot; NewDllSha256=$crashNewHash; InstallRoot=$installRoot
        })) {
        throw 'FAIL: process interruption did not leave a Running journal with a verified restored DLL'
    }
    $resumeArgs = @{
        InstalledDllPath=$crashInstalled; DllExisted=$true; ReplacementStarted=$true
        OriginalSha256=$crashOriginalHash; BackupPath=$crashBackup; BackupSha256=$crashOriginalHash
        BackupRoot=$backupRoot; NewDllSha256=$crashNewHash; InstallRoot=$installRoot
    }
    Invoke-MBRecoveryStep -Path $crashJournal -StepId 'RestoreDll' -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreDll') -Action { throw 'DLL restore action repeated after fresh-process recovery' } -Verify { Test-MBDllSnapshotRestored @resumeArgs }
    $resumed = Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreDll')
    if ($resumed.Steps[0].State -ne 'Completed' -or $resumed.Steps[0].Attempts -ne 1) {
        throw 'FAIL: fresh-process DLL recovery did not complete without repeating its external restore action'
    }

    Write-Host 'PASS: DLL rollback restore, postcondition verification, fresh-process crash recovery and idempotent replay, tamper rejection, new-file removal, untouched-file verification, and path confinement'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
