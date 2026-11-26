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

    $args = @{
        InstalledDllPath=$installed
        DllExisted=$true
        ReplacementStarted=$true
        OriginalSha256=$originalHash
        BackupPath=$backup
        BackupSha256=$backupHash
        BackupRoot=$backupRoot
    }
    Restore-MBDllSnapshot @args | Out-Null
    if (-not (Test-MBDllSnapshotRestored @args)) { throw 'FAIL: restored DLL did not satisfy its snapshot verifier' }
    Restore-MBDllSnapshot @args | Out-Null
    if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $originalHash) { throw 'FAIL: repeated recovery was not idempotent' }

    [IO.File]::WriteAllBytes($installed,$newBytes)
    [IO.File]::AppendAllText($backup,'tampered')
    $rejected = $false
    try { Restore-MBDllSnapshot @args | Out-Null } catch { $rejected = $_.Exception.Message -match 'backup hash mismatch' }
    if (-not $rejected) { throw 'FAIL: tampered DLL backup was not rejected' }

    $newInstallDll = Join-Path $installRoot 'new-install.dll'
    [IO.File]::WriteAllBytes($newInstallDll,$newBytes)
    $removeArgs = @{
        InstalledDllPath=$newInstallDll
        DllExisted=$false
        ReplacementStarted=$true
        BackupRoot=$backupRoot
    }
    Restore-MBDllSnapshot @removeArgs | Out-Null
    if (Test-Path -LiteralPath $newInstallDll) { throw 'FAIL: newly-created DLL remained after rollback' }
    Restore-MBDllSnapshot @removeArgs | Out-Null

    $untouchedArgs = @{
        InstalledDllPath=$installed
        DllExisted=$true
        ReplacementStarted=$false
        OriginalSha256=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        BackupRoot=$backupRoot
    }
    if (-not (Test-MBDllSnapshotRestored @untouchedArgs)) { throw 'FAIL: untouched original DLL did not verify' }

    $escapeArgs = $args.Clone()
    $escapeArgs.BackupPath = Join-Path $root 'outside.dll'
    $escapeRejected = $false
    try { Restore-MBDllSnapshot @escapeArgs | Out-Null } catch { $escapeRejected = $_.Exception.Message -match 'escapes' }
    if (-not $escapeRejected) { throw 'FAIL: backup path outside the protected directory was not rejected' }

    Write-Host 'PASS: DLL rollback restore, postcondition verification, idempotent replay, tamper rejection, new-file removal, untouched-file verification, and path confinement'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
