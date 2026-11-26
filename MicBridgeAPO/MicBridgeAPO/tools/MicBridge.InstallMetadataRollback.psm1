Set-StrictMode -Version Latest

function Get-MBMetadataHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Test-MBMetadataPathNoReparse {
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

function Test-MBInstallMetadataSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$DesktopDirectory
    )
    $errors=[Collections.Generic.List[string]]::new()
    $tx=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $desktop=[IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    if([IO.Path]::GetFileName($tx) -notmatch '^transactions-[A-Za-z0-9-]+$') { [void]$errors.Add('Metadata recovery requires a transaction-owned directory.') }
    foreach($path in @($tx,$data,$desktop)) {
        if(-not (Test-MBMetadataPathNoReparse $path)) { [void]$errors.Add("Metadata path traverses a reparse point: $path") }
    }
    foreach($name in @('IniExisted','ControlExisted','ShortcutExisted')) {
        if($State.$name -isnot [bool]) { [void]$errors.Add("Metadata snapshot field '$name' must be Boolean.") }
    }
    if([string]$State.DataDirSddl -notmatch '^O:') { [void]$errors.Add('DataDirSddl is missing or malformed.') }
    foreach($spec in @(
        [pscustomobject]@{Exists=[bool]$State.IniExisted;Hash=[string]$State.IniOriginalSha256;Name='IniOriginalSha256'},
        [pscustomobject]@{Exists=[bool]$State.ControlExisted;Hash=[string]$State.ControlOriginalSha256;Name='ControlOriginalSha256'}
    )) {
        if($spec.Exists -and $spec.Hash -notmatch '^[A-Fa-f0-9]{64}$') { [void]$errors.Add("$($spec.Name) is missing or malformed.") }
        if(-not $spec.Exists -and -not [string]::IsNullOrWhiteSpace($spec.Hash)) { [void]$errors.Add("$($spec.Name) must be empty when the file was absent.") }
    }
    foreach($name in @('IniNewSha256','ControlNewSha256')) {
        if([string]$State.$name -notmatch '^[A-Fa-f0-9]{64}$') { [void]$errors.Add("$name is missing or malformed.") }
    }
    if($State.ControlExisted -and [string]::IsNullOrWhiteSpace([string]$State.ControlSddl)) { [void]$errors.Add('ControlSddl is required for a pre-existing control.ini.') }

    $shortcutBackup=Join-Path $tx 'MicBridge.lnk'
    if($State.ShortcutExisted) {
        try { $recorded=[IO.Path]::GetFullPath([string]$State.ShortcutBackup) } catch { $recorded='' }
        if(-not $recorded.Equals([IO.Path]::GetFullPath($shortcutBackup),[StringComparison]::OrdinalIgnoreCase)) { [void]$errors.Add('Desktop shortcut backup path is not transaction-owned.') }
        if([string]$State.ShortcutBackupSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $shortcutBackup -PathType Leaf)) {
            [void]$errors.Add('Desktop shortcut backup or hash is missing.')
        } else {
            $item=Get-Item -LiteralPath $shortcutBackup -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-MBMetadataHash $shortcutBackup) -ne [string]$State.ShortcutBackupSha256) {
                [void]$errors.Add('Desktop shortcut backup is a reparse point or has a hash mismatch.')
            }
        }
    } elseif(-not [string]::IsNullOrWhiteSpace([string]$State.ShortcutBackupSha256) -or -not [string]::IsNullOrWhiteSpace([string]$State.ShortcutBackup)) {
        [void]$errors.Add('Desktop shortcut backup metadata exists although the shortcut was originally absent.')
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$State.ShortcutNewSha256) -and [string]$State.ShortcutNewSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [void]$errors.Add('ShortcutNewSha256 is malformed.')
    }
    return [pscustomobject]@{IsValid=($errors.Count -eq 0);Errors=@($errors)}
}

function Restore-MBInstallMetadataSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$DesktopDirectory
    )
    $check=Test-MBInstallMetadataSnapshot -State $State -TransactionDirectory $TransactionDirectory -DataDirectory $DataDirectory -DesktopDirectory $DesktopDirectory
    if(-not $check.IsValid) { throw "Metadata rollback preflight failed: $($check.Errors -join '; ')" }
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $desktop=[IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    $ini=Join-Path $data 'MicBridge.ini'
    $control=Join-Path $data 'control.ini'

    foreach($spec in @(
        [pscustomobject]@{Path=$ini;Existed=[bool]$State.IniExisted;NewHash=[string]$State.IniNewSha256;OriginalHash=[string]$State.IniOriginalSha256;Name='MicBridge.ini'},
        [pscustomobject]@{Path=$control;Existed=[bool]$State.ControlExisted;NewHash=[string]$State.ControlNewSha256;OriginalHash=[string]$State.ControlOriginalSha256;Name='control.ini'}
    )) {
        if($spec.Existed) {
            if(-not (Test-Path -LiteralPath $spec.Path -PathType Leaf) -or (Get-MBMetadataHash $spec.Path) -ne $spec.OriginalHash) {
                throw "$($spec.Name) changed after the transaction snapshot; refusing to overwrite it."
            }
            continue
        }
        if(Test-Path -LiteralPath $spec.Path) {
            $item=Get-Item -LiteralPath $spec.Path -Force -ErrorAction Stop
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$($spec.Name) is not a regular file; refusing removal." }
            if((Get-MBMetadataHash $spec.Path) -ne $spec.NewHash) { throw "$($spec.Name) changed after installation; refusing to delete an unowned file." }
            Remove-Item -LiteralPath $spec.Path -Force -ErrorAction Stop
        }
    }

    $shortcut=Join-Path $desktop 'MicBridge.lnk'
    if([bool]$State.ShortcutExisted) {
        if(Test-Path -LiteralPath $shortcut) {
            $item=Get-Item -LiteralPath $shortcut -Force -ErrorAction Stop
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Desktop shortcut destination is not a regular file.' }
            if((Get-MBMetadataHash $shortcut) -ne [string]$State.ShortcutBackupSha256) {
                throw 'Pre-existing desktop shortcut changed during installation; refusing to overwrite it.'
            }
        } else {
            $stage=Join-Path $desktop ('.MicBridge.rollback.'+[guid]::NewGuid().ToString('N')+'.tmp.lnk')
            try {
                Copy-Item -LiteralPath (Join-Path $tx 'MicBridge.lnk') -Destination $stage -ErrorAction Stop
                if((Get-MBMetadataHash $stage) -ne [string]$State.ShortcutBackupSha256) { throw 'Staged desktop shortcut hash mismatch.' }
                [IO.File]::Move($stage,$shortcut)
            } finally {
                if(Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue }
            }
        }
    } elseif(Test-Path -LiteralPath $shortcut) {
        $item=Get-Item -LiteralPath $shortcut -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'New desktop shortcut is not a regular file.' }
        if([string]::IsNullOrWhiteSpace([string]$State.ShortcutNewSha256) -or (Get-MBMetadataHash $shortcut) -ne [string]$State.ShortcutNewSha256) {
            throw 'Desktop shortcut is not proven to belong to this transaction; preserving it.'
        }
        Remove-Item -LiteralPath $shortcut -Force -ErrorAction Stop
    }

    $dataAcl=Get-Acl -LiteralPath $data -ErrorAction Stop
    $dataAcl.SetSecurityDescriptorSddlForm([string]$State.DataDirSddl)
    Set-Acl -LiteralPath $data -AclObject $dataAcl -ErrorAction Stop
    if([bool]$State.ControlExisted -and (Test-Path -LiteralPath $control -PathType Leaf)) {
        $controlAcl=Get-Acl -LiteralPath $control -ErrorAction Stop
        $controlAcl.SetSecurityDescriptorSddlForm([string]$State.ControlSddl)
        Set-Acl -LiteralPath $control -AclObject $controlAcl -ErrorAction Stop
    }
    if(-not (Test-MBInstallMetadataRestored -State $State -DataDirectory $data -DesktopDirectory $desktop)) {
        $iniExists=Test-Path -LiteralPath $ini
        $controlExists=Test-Path -LiteralPath $control
        $shortcutExists=Test-Path -LiteralPath (Join-Path $desktop 'MicBridge.lnk')
        $actualDataSddl=(Get-Acl -LiteralPath $data -ErrorAction Stop).Sddl
        $dataAclMatch=($actualDataSddl -eq [string]$State.DataDirSddl)
        throw "Metadata rollback verification failed. IniExists=$iniExists; ControlExists=$controlExists; ShortcutExists=$shortcutExists; DataDirAclMatch=$dataAclMatch; ExpectedDataSddl=$($State.DataDirSddl); ActualDataSddl=$actualDataSddl."
    }
    return $true
}

function Test-MBInstallMetadataRestored {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$DesktopDirectory
    )
    $data=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $desktop=[IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    foreach($spec in @(
        [pscustomobject]@{Path=(Join-Path $data 'MicBridge.ini');Existed=[bool]$State.IniExisted;OriginalHash=[string]$State.IniOriginalSha256},
        [pscustomobject]@{Path=(Join-Path $data 'control.ini');Existed=[bool]$State.ControlExisted;OriginalHash=[string]$State.ControlOriginalSha256}
    )) {
        if($spec.Existed) {
            if(-not (Test-Path -LiteralPath $spec.Path -PathType Leaf) -or (Get-MBMetadataHash $spec.Path) -ne $spec.OriginalHash) { return $false }
        } elseif(Test-Path -LiteralPath $spec.Path) { return $false }
    }
    $shortcut=Join-Path $desktop 'MicBridge.lnk'
    if([bool]$State.ShortcutExisted) {
        if(-not (Test-Path -LiteralPath $shortcut -PathType Leaf) -or (Get-MBMetadataHash $shortcut) -ne [string]$State.ShortcutBackupSha256) { return $false }
    } elseif(Test-Path -LiteralPath $shortcut) { return $false }
    if((Get-Acl -LiteralPath $data -ErrorAction Stop).Sddl -ne [string]$State.DataDirSddl) { return $false }
    if([bool]$State.ControlExisted -and (Get-Acl -LiteralPath (Join-Path $data 'control.ini') -ErrorAction Stop).Sddl -ne [string]$State.ControlSddl) { return $false }
    return $true
}

Export-ModuleMember -Function Test-MBInstallMetadataSnapshot,Restore-MBInstallMetadataSnapshot,Test-MBInstallMetadataRestored
