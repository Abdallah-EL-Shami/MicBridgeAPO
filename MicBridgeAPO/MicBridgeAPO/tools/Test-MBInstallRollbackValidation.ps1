$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeRollbackValidation-' + [guid]::NewGuid().ToString('N'))
$tx = Join-Path $root 'transactions-test'
$data = Join-Path $root 'data'
$files = Join-Path $tx 'install-files'
$dlls = Join-Path $data 'dll-backups'
New-Item -ItemType Directory -Force -Path $files,$dlls | Out-Null
try {
    $device = [guid]::NewGuid()
    $fileEntries = @()
    foreach ($name in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
        $path = Join-Path $files $name
        [IO.File]::WriteAllText($path,"snapshot:$name")
        $fileEntries += [pscustomobject]@{ Name=$name; Existed=$true; Backup=$path; Sha256=(Get-FileHash $path -Algorithm SHA256).Hash }
    }
    $shortcut = Join-Path $tx 'MicBridge.lnk'
    [IO.File]::WriteAllText($shortcut,'shortcut')
    $state = [pscustomobject]@{
        DeviceId=$device.ToString('D')
        FxEffect=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='String';Value=$null}
        FxAssociation=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='String';Value='{00000000-0000-0000-0000-000000000000}'}
        FxComposite=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='MultiString';Value=@('{11111111-1111-1111-1111-111111111111}')}
        DevSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxKeyExisted=$true
        ClsidRegExisted=$false
        ClsidRegBackup=$null
        ClsidRegSha256=$null
        ApoRegExisted=$false
        ApoRegBackup=$null
        ApoRegSha256=$null
        DllExisted=$false
        DllOriginalSha256=$null
        IniExisted=$false
        ControlExisted=$false
        DataDirSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        ControlSddl=$null
        InstallFiles=$fileEntries
        ShortcutExisted=$true
        ShortcutBackup=$shortcut
        ShortcutBackupSha256=(Get-FileHash $shortcut -Algorithm SHA256).Hash
        InstallDirExisted=$false
    }

    $valid = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if (-not $valid.IsValid -or -not $valid.ReplaySafe) { throw "FAIL: valid fixture rejected: $($valid.Errors -join '; ')" }

    $wrongDevice = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId ([guid]::NewGuid())
    if ($wrongDevice.IsValid) { throw 'FAIL: wrong device identity accepted' }

    $originalBackup = $state.InstallFiles[0].Backup
    $state.InstallFiles[0].Backup = Join-Path $root 'outside.ps1'
    $pathEscape = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($pathEscape.IsValid -or -not ($pathEscape.Errors -match 'escapes')) { throw 'FAIL: path escape accepted' }
    $state.InstallFiles[0].Backup = $originalBackup

    [IO.File]::AppendAllText($originalBackup,'tampered')
    $hashMismatch = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($hashMismatch.IsValid -or -not ($hashMismatch.Errors -match 'hash')) { throw 'FAIL: modified backup accepted' }
    [IO.File]::WriteAllText($originalBackup,'snapshot:MicBridgeUI.ps1')
    $state.InstallFiles[0].Sha256 = (Get-FileHash $originalBackup -Algorithm SHA256).Hash

    $clsidExport = Join-Path $tx 'clsid.reg'
    [IO.File]::WriteAllText($clsidExport,'Windows Registry Editor Version 5.00')
    $state.ClsidRegExisted = $true
    $state.ClsidRegBackup = $clsidExport
    $state.ClsidRegSha256 = (Get-FileHash $clsidExport -Algorithm SHA256).Hash
    $comValid = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if (-not $comValid.IsValid) { throw "FAIL: valid transaction-bound COM export rejected: $($comValid.Errors -join '; ')" }

    [IO.File]::AppendAllText($clsidExport,'tampered')
    $comTampered = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($comTampered.IsValid -or -not ($comTampered.Errors -match 'COM export snapshot hash')) { throw 'FAIL: modified COM export accepted' }

    Write-Host 'PASS: rollback snapshot identity, path confinement, file hashes, and transaction-bound COM export checks'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
