$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Join-Path $PSScriptRoot 'MicBridge.InstallFileRollback.psm1'
Import-Module $module -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeFileRollback-'+[guid]::NewGuid().ToString('N'))
$tx=Join-Path $root ('transactions-'+[guid]::NewGuid().ToString('N'))
$backupRoot=Join-Path $tx 'install-files'
$install=Join-Path $root 'install'
New-Item -ItemType Directory -Force -Path $backupRoot,$install | Out-Null
try {
    $names=@('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')
    $entries=@()
    foreach($name in $names) {
        $backup=Join-Path $backupRoot $name
        $target=Join-Path $install $name
        [IO.File]::WriteAllText($backup,"original:$name")
        [IO.File]::WriteAllText($target,"new:$name")
        $entries += [pscustomobject]@{
            Name=$name;Existed=$true;Backup=$backup
            Sha256=(Get-FileHash $backup -Algorithm SHA256).Hash
            InstalledSha256=(Get-FileHash $target -Algorithm SHA256).Hash
        }
    }
    $state=[pscustomobject]@{InstallFiles=$entries}
    $pre=Test-MBInstallFileRollbackState -State $state -TransactionDirectory $tx -InstallDirectory $install
    if(-not $pre.IsValid) { throw "FAIL: valid support-file snapshot rejected: $($pre.Errors -join '; ')" }
    Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null
    if(-not (Test-MBInstallSupportFilesRestored -State $state -InstallDirectory $install)) { throw 'FAIL: previous support files were not restored' }
    Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null

    # New files absent before installation are removed only when their current
    # hashes still match the exact package files recorded in the transaction.
    $newEntries=@()
    foreach($name in $names) {
        $target=Join-Path $install $name
        $newEntries += [pscustomobject]@{Name=$name;Existed=$false;Backup=(Join-Path $backupRoot $name);Sha256=$null;InstalledSha256=(Get-FileHash $target -Algorithm SHA256).Hash}
    }
    $newState=[pscustomobject]@{InstallFiles=$newEntries}
    Restore-MBInstallSupportFiles -State $newState -TransactionDirectory $tx -InstallDirectory $install | Out-Null
    if(-not (Test-MBInstallSupportFilesRestored -State $newState -InstallDirectory $install)) { throw 'FAIL: transaction-created support files were not removed' }

    # Unknown post-install edits must never be overwritten.
    foreach($name in $names) { [IO.File]::WriteAllText((Join-Path $install $name),"new:$name") }
    [IO.File]::WriteAllText((Join-Path $install $names[0]),'third-party modification')
    $rejected=$false
    try { Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null } catch { $rejected=$true }
    if(-not $rejected -or [IO.File]::ReadAllText((Join-Path $install $names[0])) -ne 'third-party modification') { throw 'FAIL: rollback overwrote a modified support file' }

    # Tampered backups are rejected before any destination is changed.
    [IO.File]::WriteAllText((Join-Path $install $names[0]),'new:'+ $names[0])
    [IO.File]::AppendAllText((Join-Path $backupRoot $names[1]),'tamper')
    $rejected=$false
    try { Restore-MBInstallSupportFiles -State $state -TransactionDirectory $tx -InstallDirectory $install | Out-Null } catch { $rejected=$true }
    if(-not $rejected) { throw 'FAIL: tampered support-file backup was accepted' }
    Write-Host 'PASS: support-file snapshot validation, restoration, idempotence, owned-new-file removal, tamper rejection, and foreign-edit preservation'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
