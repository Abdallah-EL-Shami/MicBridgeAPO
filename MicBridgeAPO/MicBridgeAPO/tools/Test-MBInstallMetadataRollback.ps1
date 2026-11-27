$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallMetadataRollback.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeMetadataRollback-'+[guid]::NewGuid().ToString('N'))
$tx=Join-Path $root ('transactions-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $root 'data'
$desktop=Join-Path $root 'desktop'
New-Item -ItemType Directory -Force -Path (Join-Path $tx 'install-files'),$data,$desktop | Out-Null
try {
    $iniBytes=[Text.Encoding]::UTF8.GetBytes('new ini')
    $controlText='[Control]'+[char]13+[char]10+'Enabled=1'+[char]13+[char]10
    $controlBytes=[Text.Encoding]::ASCII.GetBytes($controlText)
    $shortcutBytes=[Text.Encoding]::UTF8.GetBytes('new shortcut')
    $state=[pscustomobject]@{
        IniExisted=$false;IniOriginalSha256=$null;IniNewSha256=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($iniBytes)).Replace('-','')
        ControlExisted=$false;ControlOriginalSha256=$null;ControlNewSha256=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($controlBytes)).Replace('-','')
        DataDirSddl=(Get-Acl $data).Sddl;ControlSddl=$null
        ShortcutExisted=$false;ShortcutBackup=$null;ShortcutBackupSha256=$null
        ShortcutNewSha256=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($shortcutBytes)).Replace('-','')
    }
    [IO.File]::WriteAllBytes((Join-Path $data 'MicBridge.ini'),$iniBytes)
    [IO.File]::WriteAllBytes((Join-Path $data 'control.ini'),$controlBytes)
    [IO.File]::WriteAllBytes((Join-Path $desktop 'MicBridge.lnk'),$shortcutBytes)
    $acl=Get-Acl $data
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $data -AclObject $acl
    $valid=Test-MBInstallMetadataSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop
    if(-not $valid.IsValid) { throw "FAIL: valid metadata snapshot rejected: $($valid.Errors -join '; ')" }
    Restore-MBInstallMetadataSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null
    if(-not (Test-MBInstallMetadataRestored -State $state -DataDirectory $data -DesktopDirectory $desktop)) { throw 'FAIL: new configuration files or owned shortcut were not removed and ACL was not restored' }
    Restore-MBInstallMetadataSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null

    $iniOriginal=Join-Path $data 'MicBridge.ini';$controlOriginal=Join-Path $data 'control.ini'
    [IO.File]::WriteAllText($iniOriginal,'old ini')
    [IO.File]::WriteAllText($controlOriginal,'old control')
    $shortcutBackup=Join-Path $tx 'MicBridge.lnk'
    [IO.File]::WriteAllText($shortcutBackup,'old shortcut')
    $shortcutHash=(Get-FileHash $shortcutBackup -Algorithm SHA256).Hash
    $existing=[pscustomobject]@{
        IniExisted=$true;IniOriginalSha256=(Get-FileHash $iniOriginal -Algorithm SHA256).Hash;IniNewSha256=$state.IniNewSha256
        ControlExisted=$true;ControlOriginalSha256=(Get-FileHash $controlOriginal -Algorithm SHA256).Hash;ControlNewSha256=$state.ControlNewSha256
        DataDirSddl=(Get-Acl $data).Sddl;ControlSddl=(Get-Acl $controlOriginal).Sddl
        ShortcutExisted=$true;ShortcutBackup=$shortcutBackup;ShortcutBackupSha256=$shortcutHash;ShortcutNewSha256=$null
    }
    Restore-MBInstallMetadataSnapshot -State $existing -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null
    if(-not (Test-MBInstallMetadataRestored -State $existing -DataDirectory $data -DesktopDirectory $desktop)) { throw 'FAIL: pre-existing shortcut or configuration state was not restored' }

    [IO.File]::WriteAllText($iniOriginal,'third-party edit')
    $rejected=$false
    try { Restore-MBInstallMetadataSnapshot -State $existing -TransactionDirectory $tx -DataDirectory $data -DesktopDirectory $desktop | Out-Null } catch { $rejected=$true }
    if(-not $rejected -or [IO.File]::ReadAllText($iniOriginal) -ne 'third-party edit') { throw 'FAIL: metadata rollback overwrote a foreign configuration edit' }
    Write-Host 'PASS: metadata rollback restores pre-existing shortcut, removes only transaction-owned new config/shortcut files, restores ProgramData ACL, and preserves foreign edits'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
