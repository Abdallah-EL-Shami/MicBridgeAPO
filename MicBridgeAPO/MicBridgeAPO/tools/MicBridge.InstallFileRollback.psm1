Set-StrictMode -Version Latest

$script:MBInstallSupportNames=@('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')

function Get-MBInstallFileHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Test-MBInstallFileRollbackState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory
    )
    $errors=[Collections.Generic.List[string]]::new()
    $tx=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $entries=@($State.InstallFiles)
    if($entries.Count -ne $script:MBInstallSupportNames.Count) { [void]$errors.Add('Support-file snapshot must contain exactly four fixed entries.') }
    foreach($name in $script:MBInstallSupportNames) {
        $matches=@($entries | Where-Object { [string]$_.Name -ceq $name })
        if($matches.Count -ne 1) { [void]$errors.Add("Support-file snapshot '$name' is missing or duplicated."); continue }
        $entry=$matches[0]
        if($entry.Existed -isnot [bool]) { [void]$errors.Add("Support-file '$name' Existed flag is invalid."); continue }
        if([string]$entry.InstalledSha256 -notmatch '^[A-Fa-f0-9]{64}$') { [void]$errors.Add("Support-file '$name' installed SHA-256 is missing or invalid.") }
        $expectedBackup=[IO.Path]::GetFullPath((Join-Path (Join-Path $tx 'install-files') $name))
        if($entry.Existed) {
            if([string]::IsNullOrWhiteSpace([string]$entry.Backup) -or
                -not [IO.Path]::GetFullPath([string]$entry.Backup).Equals($expectedBackup,[StringComparison]::OrdinalIgnoreCase)) {
                [void]$errors.Add("Support-file '$name' backup path is not its fixed transaction path."); continue
            }
            if([string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $expectedBackup -PathType Leaf)) {
                [void]$errors.Add("Support-file '$name' backup or original SHA-256 is missing."); continue
            }
            $item=Get-Item -LiteralPath $expectedBackup -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-MBInstallFileHash $expectedBackup) -ne [string]$entry.Sha256) {
                [void]$errors.Add("Support-file '$name' backup is a reparse point or has a hash mismatch.")
            }
        } elseif(-not [string]::IsNullOrWhiteSpace([string]$entry.Sha256)) {
            [void]$errors.Add("Support-file '$name' has an original hash although it was absent.")
        }
    }
    return [pscustomobject]@{IsValid=($errors.Count -eq 0);Errors=@($errors)}
}

function Restore-MBInstallSupportFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$InstallDirectory
    )
    $validation=Test-MBInstallFileRollbackState -State $State -TransactionDirectory $TransactionDirectory -InstallDirectory $InstallDirectory
    if(-not $validation.IsValid) { throw "Support-file rollback preflight failed: $($validation.Errors -join '; ')" }
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    foreach($name in $script:MBInstallSupportNames) {
        $entry=@($State.InstallFiles | Where-Object { [string]$_.Name -ceq $name })[0]
        $target=Join-Path $install $name
        if(Test-Path -LiteralPath $target) {
            $item=Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Support-file destination '$name' is not a regular file." }
            $currentHash=Get-MBInstallFileHash $target
            $allowed=@([string]$entry.InstalledSha256)
            if($entry.Existed) { $allowed += [string]$entry.Sha256 }
            if($currentHash -notin $allowed) { throw "Support-file '$name' changed after this transaction; refusing to overwrite an unowned file." }
        }
        if($entry.Existed) {
            if((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-MBInstallFileHash $target) -eq [string]$entry.Sha256) { continue }
            $stage=Join-Path $install ('.'+$name+'.rollback.'+[guid]::NewGuid().ToString('N')+'.tmp')
            try {
                Copy-Item -LiteralPath ([string]$entry.Backup) -Destination $stage -ErrorAction Stop
                if((Get-MBInstallFileHash $stage) -ne [string]$entry.Sha256) { throw "Staged support-file '$name' hash mismatch." }
                if(Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::Replace($stage,$target,$null) }
                else { [IO.File]::Move($stage,$target) }
            } finally { if(Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
        } elseif(Test-Path -LiteralPath $target) {
            if((Get-MBInstallFileHash $target) -ne [string]$entry.InstalledSha256) { throw "New support-file '$name' no longer matches this transaction; refusing deletion." }
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        }
    }
    if(-not (Test-MBInstallSupportFilesRestored -State $State -InstallDirectory $InstallDirectory)) { throw 'Support-file rollback verification failed.' }
    return $true
}

function Test-MBInstallSupportFilesRestored {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][string]$InstallDirectory)
    $install=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    foreach($name in $script:MBInstallSupportNames) {
        $entry=@($State.InstallFiles | Where-Object { [string]$_.Name -ceq $name })[0]
        $target=Join-Path $install $name
        if([bool]$entry.Existed) {
            if(-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
            if((Get-MBInstallFileHash $target) -ne [string]$entry.Sha256) { return $false }
        } elseif(Test-Path -LiteralPath $target) { return $false }
    }
    return $true
}

Export-ModuleMember -Function Test-MBInstallFileRollbackState,Restore-MBInstallSupportFiles,Test-MBInstallSupportFilesRestored
