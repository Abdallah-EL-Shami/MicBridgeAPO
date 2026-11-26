Set-StrictMode -Version Latest

function Get-MBCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Test-MBPathWithinDirectory {
    param([Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Root)
    try {
        $rootFull = (Get-MBCanonicalPath $Root) + [IO.Path]::DirectorySeparatorChar
        $candidateFull = Get-MBCanonicalPath $Candidate
        return $candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-MBNoReparsePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$StopAt)
    try {
        $pathFull = Get-MBCanonicalPath $Path
        $stopFull = Get-MBCanonicalPath $StopAt
        if (-not [string]::Equals($pathFull,$stopFull,[StringComparison]::OrdinalIgnoreCase) -and
            -not (Test-MBPathWithinDirectory -Candidate $pathFull -Root $stopFull)) { return $false }
        # Inspect every existing component up to the volume root, including parents
        # of BackupRoot/InstallRoot; a reparse parent can redirect an apparently safe child.
        $current = $pathFull
        $volumeRoot = [IO.Path]::GetPathRoot($pathFull)
        while ($true) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            if ([string]::Equals($current.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),
                $volumeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = [IO.Directory]::GetParent($current)
            if (-not $parent) { return $false }
            $current = $parent.FullName
        }
        return $true
    } catch { return $false }
}

function Test-MBDllSnapshotRestored {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstalledDllPath,
        [Parameter(Mandatory)][bool]$DllExisted,
        [Parameter(Mandatory)][bool]$ReplacementStarted,
        [string]$OriginalSha256,
        [string]$BackupPath,
        [string]$BackupSha256,
        [string]$BackupRoot,
        [string]$NewDllSha256,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    if (-not (Test-MBPathWithinDirectory -Candidate $InstalledDllPath -Root $InstallRoot) -or
        -not (Test-MBNoReparsePath -Path (Split-Path -Parent $InstalledDllPath) -StopAt $InstallRoot)) { return $false }
    if (-not $DllExisted) { return -not (Test-Path -LiteralPath $InstalledDllPath) }
    if ($OriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $InstalledDllPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return [string]::Equals((Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256 -ErrorAction Stop).Hash,$OriginalSha256,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Restore-MBDllSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstalledDllPath,
        [Parameter(Mandatory)][bool]$DllExisted,
        [Parameter(Mandatory)][bool]$ReplacementStarted,
        [string]$OriginalSha256,
        [string]$BackupPath,
        [string]$BackupSha256,
        [string]$BackupRoot,
        [string]$NewDllSha256,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    if (-not (Test-MBPathWithinDirectory -Candidate $InstalledDllPath -Root $InstallRoot) -or
        -not (Test-MBNoReparsePath -Path (Split-Path -Parent $InstalledDllPath) -StopAt $InstallRoot)) {
        throw 'Installed DLL destination escapes the protected install directory or traverses a reparse point.'
    }
    if (-not $ReplacementStarted) {
        if (Test-MBDllSnapshotRestored @PSBoundParameters) { return $true }
        throw 'Installed DLL differs from its pre-transaction snapshot although replacement was not started.'
    }
    if (-not $DllExisted) {
        if (Test-Path -LiteralPath $InstalledDllPath) {
            if ($NewDllSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw 'New DLL SHA-256 is missing or malformed; refusing to remove an unowned destination.'
            }
            $item = Get-Item -LiteralPath $InstalledDllPath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer) {
                throw 'Refusing to remove a reparse point or non-file at the installed DLL destination.'
            }
            $destinationHash = (Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not [string]::Equals($destinationHash,$NewDllSha256,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Installed DLL does not match this transaction new-file hash; refusing to delete an unowned file.'
            }
            Remove-Item -LiteralPath $InstalledDllPath -Force -ErrorAction Stop
        }
        if (-not (Test-MBDllSnapshotRestored @PSBoundParameters)) { throw 'New DLL removal could not be verified.' }
        return $true
    }
    if ($OriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Original DLL SHA-256 is missing or malformed.' }
    if (Test-MBDllSnapshotRestored @PSBoundParameters) { return $true }
    if ($BackupSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        -not [string]::Equals($BackupSha256,$OriginalSha256,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'DLL backup hash does not match the recorded original DLL snapshot.'
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot) -or [string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-MBPathWithinDirectory -Candidate $BackupPath -Root $BackupRoot) -or
        -not (Test-MBNoReparsePath -Path $BackupPath -StopAt $BackupRoot)) {
        throw 'DLL rollback backup path is missing, traverses a reparse point, or escapes the protected backup directory.'
    }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container) -or -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw 'DLL rollback backup is missing.' }
    $backupItem = Get-Item -LiteralPath $BackupPath -Force -ErrorAction Stop
    if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'DLL rollback backup must not be a reparse point.' }
    $actualBackupHash = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualBackupHash,$BackupSha256,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'DLL rollback backup hash mismatch; refusing to restore an unverified binary.'
    }
    if (-not (Test-MBNoReparsePath -Path $BackupRoot -StopAt $BackupRoot)) { throw 'DLL backup root must not be a reparse point.' }
    if (Test-Path -LiteralPath $InstalledDllPath) {
        $currentItem = Get-Item -LiteralPath $InstalledDllPath -Force -ErrorAction Stop
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $currentItem.PSIsContainer) { throw 'Installed DLL destination is not a regular owned file; refusing rollback replacement.' }
        if ($NewDllSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'New DLL SHA-256 is missing or malformed; refusing to overwrite a destination not proven to belong to this transaction.' }
        $currentHash = (Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($currentHash,$NewDllSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'Installed DLL no longer matches this transaction new-file hash; refusing to overwrite an unowned file.' }
    }
    $installDirectory = Split-Path -Parent $InstalledDllPath
    $stagedPath = Join-Path $installDirectory ('.MicBridgeAPO.rollback.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $replacementBackupPath = Join-Path $installDirectory ('.MicBridgeAPO.rollback.' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        Copy-Item -LiteralPath $BackupPath -Destination $stagedPath -ErrorAction Stop
        $stageStream = [IO.File]::Open($stagedPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        try { $stageStream.Flush($true) } finally { $stageStream.Dispose() }
        $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($stagedHash,$OriginalSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'Staged rollback DLL hash does not match the durable original snapshot.' }
        if (Test-Path -LiteralPath $InstalledDllPath -PathType Leaf) {
            [IO.File]::Replace($stagedPath,$InstalledDllPath,$replacementBackupPath)
        } elseif (Test-Path -LiteralPath $InstalledDllPath) { throw 'Installed DLL destination exists but is not a regular file; refusing replacement.' }
        else { [IO.File]::Move($stagedPath,$InstalledDllPath) }
    } finally {
        if (Test-Path -LiteralPath $stagedPath) { Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $replacementBackupPath) { Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Test-MBDllSnapshotRestored @PSBoundParameters)) {
        throw 'Restored DLL hash does not match the durable pre-transaction snapshot.'
    }
    return $true
}

Export-ModuleMember -Function Test-MBDllSnapshotRestored,Restore-MBDllSnapshot
