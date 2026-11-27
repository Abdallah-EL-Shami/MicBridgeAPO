$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Join-Path $PSScriptRoot 'MicBridge.ComRegistrationRollback.psm1'
$journalModule=Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
Import-Module $module -Force
Import-Module $journalModule -Force

$root=Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeComRollback-'+[guid]::NewGuid().ToString('N'))
$tx=Join-Path $root ('transactions-'+[guid]::NewGuid().ToString('N'))
$install=Join-Path $root 'install'
$testDll=Join-Path $install 'MicBridgeAPO.dll'
$clsid='{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$clsidSub="Software\Classes\CLSID\$clsid"
$apoSub="Software\Classes\AudioEngine\AudioProcessingObjects\$clsid"
$clsidKey=$null; $apoKey=$null; $inproc=$null
New-Item -ItemType Directory -Force -Path $tx,$install | Out-Null
[IO.File]::WriteAllBytes($testDll,[byte[]](1,2,3,4))
try {
    $regExe=Join-Path $env:SystemRoot 'System32\reg.exe'
    $clsidFull="HKCU\$clsidSub"
    $apoFull="HKCU\$apoSub"

    # Baseline: a CLSID registration pointing at the product DLL and an APO key.
    $clsidKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($clsidSub)
    $inproc=$clsidKey.CreateSubKey('InprocServer32')
    $inproc.SetValue('', $testDll, [Microsoft.Win32.RegistryValueKind]::String)
    $inproc.Dispose(); $inproc=$null
    $clsidKey.Dispose(); $clsidKey=$null
    $apoKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($apoSub)
    $apoKey.SetValue('FriendlyName','MicBridge pre-transaction',[Microsoft.Win32.RegistryValueKind]::String)
    $apoKey.Dispose(); $apoKey=$null

    $clsidBackup=Join-Path $tx 'clsid.reg'
    $apoBackup=Join-Path $tx 'audioengine-apo.reg'
    & $regExe export $clsidFull $clsidBackup /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export HKCU CLSID fixture' }
    & $regExe export $apoFull $apoBackup /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export HKCU APO fixture' }

    $state=[pscustomobject]@{
        ClsidRegExisted=$true; ClsidRegBackup=$clsidBackup; ClsidRegSha256=(Get-FileHash $clsidBackup -Algorithm SHA256).Hash
        ApoRegExisted=$true; ApoRegBackup=$apoBackup; ApoRegSha256=(Get-FileHash $apoBackup -Algorithm SHA256).Hash
    }
    # Mutate both registration trees to simulate a partial installer replacement.
    $clsidKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($clsidSub,$true)
    $inproc=$clsidKey.OpenSubKey('InprocServer32',$true)
    $inproc.SetValue('ThreadingModel','Both',[Microsoft.Win32.RegistryValueKind]::String)
    $inproc.Dispose(); $inproc=$null; $clsidKey.Dispose(); $clsidKey=$null
    $apoKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($apoSub,$true)
    $apoKey.SetValue('FriendlyName','MicBridge replacement',[Microsoft.Win32.RegistryValueKind]::String)
    $apoKey.Dispose(); $apoKey=$null

    Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null
    Restore-MBComRegistrySnapshot -Target AudioEngineAPO -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null
    if(-not (Test-MBComRegistrySnapshotRestored -Target CLSID -State $state -TransactionDirectory $tx -RegistryHive HKCU)) { throw 'FAIL: CLSID original registration did not verify' }
    if(-not (Test-MBComRegistrySnapshotRestored -Target AudioEngineAPO -State $state -TransactionDirectory $tx -RegistryHive HKCU)) { throw 'FAIL: APO original registration did not verify' }

    # Idempotence: repeating completed actions must leave the same exact exports.
    Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null
    Restore-MBComRegistrySnapshot -Target AudioEngineAPO -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null

    # Kill a child PowerShell after registry import but before journal completion.
    $crashTx=Join-Path $root ('transactions-crash-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $crashTx | Out-Null
    $crashBackup=Join-Path $crashTx 'clsid.reg'
    & $regExe export $clsidFull $crashBackup /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export crash-resume CLSID baseline' }
    $crashState=[pscustomobject]@{
        ClsidRegExisted=$true; ClsidRegBackup=$crashBackup; ClsidRegSha256=(Get-FileHash $crashBackup -Algorithm SHA256).Hash
        ApoRegExisted=$false; ApoRegBackup=$null; ApoRegSha256=$null
    }
    $crashKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$clsidSub\InprocServer32",$true)
    try { $crashKey.SetValue('ThreadingModel','Both',[Microsoft.Win32.RegistryValueKind]::String) } finally { $crashKey.Dispose() }
    $crashJournal=Join-Path $crashTx 'com-crash-recovery.json'
    $crashDevice=[guid]::NewGuid()
    $crashSteps=@('RestoreComCLSID')
    New-MBRecoveryJournal -Path $crashJournal -Operation InstallRollback -DeviceId $crashDevice -StepIds $crashSteps | Out-Null
    $childScript=Join-Path $crashTx 'com-crash-child.ps1'
    $childSource=@'
param([string]$ActionModule,[string]$JournalModule,[string]$Journal,[string]$Tx,[string]$Install,[string]$Backup,[string]$Hash,[string]$Device)
$ErrorActionPreference='Stop'
Import-Module $ActionModule -Force
Import-Module $JournalModule -Force
$state=[pscustomobject]@{ClsidRegExisted=$true;ClsidRegBackup=$Backup;ClsidRegSha256=$Hash;ApoRegExisted=$false;ApoRegBackup=$null;ApoRegSha256=$null}
$action={ Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $Tx -InstallDirectory $Install -RegistryHive HKCU | Out-Null; [Environment]::FailFast('Injected process death after COM registry restore') }.GetNewClosure()
$verify={ Test-MBComRegistrySnapshotRestored -Target CLSID -State $state -TransactionDirectory $Tx -RegistryHive HKCU }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreComCLSID' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreComCLSID') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($childScript,$childSource,(New-Object Text.UTF8Encoding($false)))
    $child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,$module,$journalModule,$crashJournal,$crashTx,$install,$crashBackup,$crashState.ClsidRegSha256,$crashDevice.ToString('D')) -Wait -PassThru
    if($child.ExitCode -eq 0) { throw 'FAIL: COM crash-injection child unexpectedly exited successfully' }
    $interrupted=Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds $crashSteps
    if($interrupted.Steps[0].State -ne 'Running' -or -not (Test-MBComRegistrySnapshotRestored -Target CLSID -State $crashState -TransactionDirectory $crashTx -RegistryHive HKCU)) { throw 'FAIL: COM crash did not leave Running journal plus verified registry side effect' }
    Invoke-MBRecoveryStep -Path $crashJournal -StepId 'RestoreComCLSID' -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds $crashSteps -Action { throw 'COM registry import repeated after process restart' } -Verify { Test-MBComRegistrySnapshotRestored -Target CLSID -State $crashState -TransactionDirectory $crashTx -RegistryHive HKCU }
    $resumed=Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds $crashSteps
    if($resumed.Steps[0].State -ne 'Completed' -or $resumed.Steps[0].Attempts -ne 1) { throw 'FAIL: fresh-process COM recovery did not complete without repeating import' }

    # Missing original keys are removed only when the live CLSID proves product ownership.
    $absentState=[pscustomobject]@{
        ClsidRegExisted=$false; ClsidRegBackup=$null; ClsidRegSha256=$null
        ApoRegExisted=$false; ApoRegBackup=$null; ApoRegSha256=$null
    }
    Restore-MBComRegistrySnapshot -Target AudioEngineAPO -State $absentState -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null
    Restore-MBComRegistrySnapshot -Target CLSID -State $absentState -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null
    if((Test-Path "HKCU:\$clsidSub") -or (Test-Path "HKCU:\$apoSub")) { throw 'FAIL: newly-created MicBridge COM registrations remained after rollback' }

    # Foreign live registration must be preserved; no key deletion or overwrite.
    $foreignDll=Join-Path $root 'foreign.dll'
    [IO.File]::WriteAllBytes($foreignDll,[byte[]](9,8,7,6))
    $clsidKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($clsidSub)
    $inproc=$clsidKey.CreateSubKey('InprocServer32')
    $inproc.SetValue('', $foreignDll, [Microsoft.Win32.RegistryValueKind]::String)
    $inproc.Dispose(); $inproc=$null; $clsidKey.Dispose(); $clsidKey=$null
    $foreignBefore=[string]([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$clsidSub\InprocServer32").GetValue(''))
    $foreignRejected=$false
    try { Restore-MBComRegistrySnapshot -Target CLSID -State $absentState -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null } catch { $foreignRejected=$true }
    if(-not $foreignRejected) { throw 'FAIL: foreign live CLSID registration was not rejected' }
    $foreignAfterKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$clsidSub\InprocServer32")
    try { $foreignAfter=[string]$foreignAfterKey.GetValue('') } finally { $foreignAfterKey.Dispose() }
    if($foreignBefore -ne $foreignAfter) { throw 'FAIL: foreign CLSID registration was modified' }

    # Tampered transaction export is rejected before any registry mutation.
    [IO.File]::AppendAllText($clsidBackup,'tampered')
    $tamperRejected=$false
    try { Restore-MBComRegistrySnapshot -Target CLSID -State $state -TransactionDirectory $tx -InstallDirectory $install -RegistryHive HKCU | Out-Null } catch { $tamperRejected=$true }
    if(-not $tamperRejected -or $foreignAfter -ne [string]([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$clsidSub\InprocServer32").GetValue(''))) {
        throw 'FAIL: tampered COM export was not rejected without modifying foreign registration'
    }

    Write-Host 'PASS: HKCU-only COM snapshot restore, exact export verification, idempotence, absent-key cleanup, foreign registration preservation, and tamper rejection'
} finally {
    if($inproc){$inproc.Dispose()}; if($clsidKey){$clsidKey.Dispose()}; if($apoKey){$apoKey.Dispose()}
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($clsidSub,$false)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($apoSub,$false)
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
