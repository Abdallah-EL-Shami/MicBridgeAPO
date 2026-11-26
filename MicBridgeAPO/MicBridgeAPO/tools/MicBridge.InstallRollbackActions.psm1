Set-StrictMode -Version Latest

function Test-MBPathWithinDirectory {
    param([Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Root)
    try {
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $candidateFull = [IO.Path]::GetFullPath($Candidate)
        return $candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)
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
        [string]$BackupRoot
    )
    if (-not $ReplacementStarted) {
        if (-not $DllExisted) { return -not (Test-Path -LiteralPath $InstalledDllPath) }
        if ($OriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { return $false }
        try { return [string]::Equals((Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256 -ErrorAction Stop).Hash,$OriginalSha256,[StringComparison]::OrdinalIgnoreCase) }
        catch { return $false }
    }
    if (-not $DllExisted) { return -not (Test-Path -LiteralPath $InstalledDllPath) }
    if ($OriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { return $false }
    try { return [string]::Equals((Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256 -ErrorAction Stop).Hash,$OriginalSha256,[StringComparison]::OrdinalIgnoreCase) }
    catch { return $false }
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
        [string]$BackupRoot
    )
    if (-not $ReplacementStarted) {
        if (Test-MBDllSnapshotRestored @PSBoundParameters) { return $true }
        throw 'Installed DLL differs from its pre-transaction snapshot although replacement was not started.'
    }
    if (-not $DllExisted) {
        if (Test-Path -LiteralPath $InstalledDllPath) {
            Remove-Item -LiteralPath $InstalledDllPath -Force -ErrorAction Stop
        }
        if (-not (Test-MBDllSnapshotRestored @PSBoundParameters)) { throw 'New DLL removal could not be verified.' }
        return $true
    }
    if ($OriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Original DLL SHA-256 is missing or malformed.' }
    if ([string]::IsNullOrWhiteSpace($BackupRoot) -or [string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-MBPathWithinDirectory -Candidate $BackupPath -Root $BackupRoot)) {
        throw 'DLL rollback backup path is missing or escapes the protected backup directory.'
    }
    if ($BackupSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw 'DLL rollback backup or its SHA-256 is missing.'
    }
    $backupItem = Get-Item -LiteralPath $BackupPath -Force -ErrorAction Stop
    if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'DLL rollback backup must not be a reparse point.' }
    $actualBackupHash = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualBackupHash,$BackupSha256,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'DLL rollback backup hash mismatch; refusing to restore an unverified binary.'
    }
    $destinationFull = [IO.Path]::GetFullPath($InstalledDllPath)
    $backupFull = [IO.Path]::GetFullPath($BackupPath)
    if ([string]::Equals($destinationFull,$backupFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'DLL rollback source and destination must be different files.'
    }
    Copy-Item -LiteralPath $BackupPath -Destination $InstalledDllPath -Force -ErrorAction Stop
    if (-not (Test-MBDllSnapshotRestored @PSBoundParameters)) {
        throw 'Restored DLL hash does not match the durable pre-transaction snapshot.'
    }
    return $true
}

Export-ModuleMember -Function Test-MBDllSnapshotRestored,Restore-MBDllSnapshot
