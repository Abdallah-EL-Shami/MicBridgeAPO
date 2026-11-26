Set-StrictMode -Version Latest

$script:MBComClsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$script:MBComTargets = @{
    CLSID = [pscustomobject]@{ RelativeKey="SOFTWARE\Classes\CLSID\$($script:MBComClsid)"; SnapshotName='clsid.reg'; ExistsField='ClsidRegExisted'; BackupField='ClsidRegBackup'; HashField='ClsidRegSha256' }
    AudioEngineAPO = [pscustomobject]@{ RelativeKey="SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$($script:MBComClsid)"; SnapshotName='audioengine-apo.reg'; ExistsField='ApoRegExisted'; BackupField='ApoRegBackup'; HashField='ApoRegSha256' }
}

function Get-MBComRegistryKeyPath {
    param([ValidateSet('HKLM','HKCU')][string]$RegistryHive,[string]$RelativeKey)
    if ($RelativeKey -notin @($script:MBComTargets.CLSID.RelativeKey,$script:MBComTargets.AudioEngineAPO.RelativeKey)) { throw 'COM rollback target is not one of the fixed MicBridge keys.' }
    return "$RegistryHive\$RelativeKey"
}
function Get-MBComPowerShellPath {
    param([string]$RegistryKey)
    if ($RegistryKey -notmatch '^(HKLM|HKCU)\\(.+)$') { throw 'Invalid fixed COM registry key.' }
    $hive=$Matches[1]; $sub=$Matches[2]
    if ($hive -eq 'HKLM') { return "HKLM:\$sub" }
    return "HKCU:\$sub"
}
function Test-MBComRegExportBounds {
    param([string]$Path,[string]$ExpectedRegistryKey)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $lines=[IO.File]::ReadAllLines($Path)
        $first=@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($first.Count -ne 1 -or $first[0].TrimStart([char]0xFEFF) -notin @('Windows Registry Editor Version 5.00','REGEDIT4')) { return $false }
        $keys=@()
        foreach($line in $lines) {
            $v=$line.Trim()
            if($v.StartsWith('[HKEY_',[StringComparison]::OrdinalIgnoreCase) -and $v.EndsWith(']')) { $keys += $v.Substring(1,$v.Length-2) }
        }
        if($keys.Count -eq 0 -or -not ($keys | Where-Object { $_.Equals($ExpectedRegistryKey,[StringComparison]::OrdinalIgnoreCase) })) { return $false }
        foreach($key in $keys) {
            if(-not $key.Equals($ExpectedRegistryKey,[StringComparison]::OrdinalIgnoreCase) -and -not $key.StartsWith($ExpectedRegistryKey+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Get-MBComSnapshotServerPath {
    param([string]$SnapshotPath,[string]$ExpectedRegistryKey)
    $lines=[IO.File]::ReadAllLines($SnapshotPath); $inside=$false
    foreach($line in $lines) {
        $v=$line.Trim()
        if($v.StartsWith('[HKEY_',[StringComparison]::OrdinalIgnoreCase) -and $v.EndsWith(']')) {
            $inside=$v.Substring(1,$v.Length-2).Equals($ExpectedRegistryKey+'\InprocServer32',[StringComparison]::OrdinalIgnoreCase)
            continue
        }
        if($inside -and $v -match '^@="((?:[^"\\]|\\.)*)"$') { return $Matches[1].Replace('\\','\').Replace('\\"','"') }
    }
    return $null
}
function Test-MBComProductServerPath {
    param([string]$ServerPath,[string]$InstallDirectory)
    if([string]::IsNullOrWhiteSpace($ServerPath)) { return $false }
    try {
        $server=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ServerPath.Trim('"')))
        $root=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')+'\'
        return $server.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($server) -ieq 'MicBridgeAPO.dll'
    } catch { return $false }
}
function Test-MBComNoReparsePath {
    param([string]$Path,[string]$Root)
    try {
        $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
        $pathFull=[IO.Path]::GetFullPath($Path)
        if(-not $pathFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and
            -not $pathFull.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current=$pathFull
        $volume=[IO.Path]::GetPathRoot($pathFull)
        while($true) {
            if(Test-Path -LiteralPath $current) {
                $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            if($current.TrimEnd('\').Equals($volume.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { break }
            $parent=[IO.Directory]::GetParent($current)
            if(-not $parent) { return $false }
            $current=$parent.FullName
        }
        return $true
    } catch { return $false }
}
function Get-MBComCanonicalRegFileHash {
    param([string]$Path)
    $lines=[IO.File]::ReadAllLines($Path)
    $canonical=[Collections.Generic.List[string]]::new()
    foreach($line in $lines) {
        $v=$line.Trim()
        if([string]::IsNullOrWhiteSpace($v) -or $v -in @('Windows Registry Editor Version 5.00','REGEDIT4')) { continue }
        if($v.StartsWith('[HKEY_',[StringComparison]::OrdinalIgnoreCase) -and $v.EndsWith(']')) {
            $canonical.Add('['+$v.Substring(1,$v.Length-2).ToUpperInvariant()+']')
        } else {
            $canonical.Add($v)
        }
    }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes([string]::Join([string][char]10,$canonical))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
}
function Get-MBComRegistryExportHash {
    param([string]$RegistryKey,[string]$TemporaryDirectory)
    $temp=Join-Path $TemporaryDirectory ('com-verify-'+[guid]::NewGuid().ToString('N')+'.reg')
    try {
        & reg.exe export $RegistryKey $temp /y | Out-Null
        if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp -PathType Leaf)) { return $null }
        return Get-MBComCanonicalRegFileHash -Path $temp
    } finally { if(Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Test-MBComRegistrySnapshotRestored {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('CLSID','AudioEngineAPO')][string]$Target,[Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][string]$TransactionDirectory,[ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM')
    $spec=$script:MBComTargets[$Target]
    $registryKey=Get-MBComRegistryKeyPath $RegistryHive $spec.RelativeKey
    $psPath=Get-MBComPowerShellPath $registryKey
    $existed=[bool]$State.($spec.ExistsField)
    if(-not $existed) { return -not (Test-Path -LiteralPath $psPath) }
    $backup=[string]$State.($spec.BackupField); $hash=[string]$State.($spec.HashField)
    if($hash -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) { return $false }
    $hiveName=if($RegistryHive -eq 'HKLM'){'HKEY_LOCAL_MACHINE'}else{'HKEY_CURRENT_USER'}
    if(-not (Test-MBComRegExportBounds $backup "$hiveName\$($spec.RelativeKey)")) { return $false }
    try {
        $backupHash=(Get-FileHash -LiteralPath $backup -Algorithm SHA256 -ErrorAction Stop).Hash
        if(-not $backupHash.Equals($hash,[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $expectedCanonical=Get-MBComCanonicalRegFileHash -Path $backup
        $actual=Get-MBComRegistryExportHash $registryKey $TransactionDirectory
        return $null -ne $actual -and $actual.Equals($expectedCanonical,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Restore-MBComRegistrySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('CLSID','AudioEngineAPO')][string]$Target,[Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][string]$TransactionDirectory,[Parameter(Mandatory)][string]$InstallDirectory,[ValidateSet('HKLM','HKCU')][string]$RegistryHive='HKLM')
    $spec=$script:MBComTargets[$Target]
    $registryKey=Get-MBComRegistryKeyPath $RegistryHive $spec.RelativeKey
    $psPath=Get-MBComPowerShellPath $registryKey
    $existed=[bool]$State.($spec.ExistsField)
    $backup=[string]$State.($spec.BackupField); $hash=[string]$State.($spec.HashField)
    $hiveName=if($RegistryHive -eq 'HKLM'){'HKEY_LOCAL_MACHINE'}else{'HKEY_CURRENT_USER'}
    $expectedRoot="$hiveName\$($spec.RelativeKey)"
    $backupFull=$null
    if($existed) {
        $transactionRoot=[IO.Path]::GetFullPath($TransactionDirectory).TrimEnd('\')
        $backupFull=[IO.Path]::GetFullPath($backup)
        if(-not (Test-MBComNoReparsePath -Path $backupFull -Root $transactionRoot) -or
            -not [IO.Path]::GetDirectoryName($backupFull).Equals($transactionRoot,[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($backupFull) -cne $spec.SnapshotName) { throw "$Target snapshot is not the fixed transaction-owned file or traverses a reparse point." }
        if($hash -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $backupFull -PathType Leaf)) { throw "$Target snapshot is missing or has invalid hash." }
        $item=Get-Item -LiteralPath $backupFull -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Target snapshot is a reparse point." }
        $actualHash=(Get-FileHash -LiteralPath $backupFull -Algorithm SHA256 -ErrorAction Stop).Hash
        if(-not $actualHash.Equals($hash,[StringComparison]::OrdinalIgnoreCase)) { throw "$Target snapshot hash mismatch." }
        if(-not (Test-MBComRegExportBounds $backupFull $expectedRoot)) { throw "$Target snapshot contains an unexpected registry root." }
        if($Target -eq 'CLSID') {
            $snapshotServer=Get-MBComSnapshotServerPath $backupFull $expectedRoot
            if(-not (Test-MBComProductServerPath $snapshotServer $InstallDirectory)) { throw 'Saved CLSID registration does not point to MicBridgeAPO.dll inside the fixed install directory; preserving ambiguous registration.' }
        }
    } elseif($null -ne $State.($spec.BackupField) -and -not [string]::IsNullOrWhiteSpace([string]$State.($spec.BackupField))) {
        throw "$Target snapshot unexpectedly has a backup path although the key was absent."
    }
    if(Test-MBComRegistrySnapshotRestored -Target $Target -State $State -TransactionDirectory $TransactionDirectory -RegistryHive $RegistryHive) { return $true }

    $liveClsidPath=Get-MBComPowerShellPath (Get-MBComRegistryKeyPath $RegistryHive $script:MBComTargets.CLSID.RelativeKey)
    if(Test-Path -LiteralPath $liveClsidPath) {
        $liveServer=$null
        try { $liveKey=Get-Item -LiteralPath (Join-Path $liveClsidPath 'InprocServer32') -ErrorAction Stop; try{$liveServer=[string]$liveKey.GetValue('')}finally{$liveKey.Close()} } catch {}
        if(-not (Test-MBComProductServerPath $liveServer $InstallDirectory)) { throw 'Live CLSID registration is not proven to belong to MicBridge; refusing COM mutation.' }
    } elseif($Target -eq 'AudioEngineAPO' -and (Test-Path -LiteralPath $psPath)) {
        throw 'AudioEngine APO key exists without a MicBridge-owned CLSID; refusing COM mutation.'
    }

    if($existed) {
        # reg.exe import merges values; remove only the exact fixed, ownership-verified
        # product key first so values introduced by the failed attempt cannot survive.
        if(Test-Path -LiteralPath $psPath) { Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction Stop }
        & reg.exe import $backupFull | Out-Null
        if($LASTEXITCODE -ne 0) { throw "$Target COM snapshot import failed." }
    } elseif(Test-Path -LiteralPath $psPath) {
        Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction Stop
    }
    if(-not (Test-MBComRegistrySnapshotRestored -Target $Target -State $State -TransactionDirectory $TransactionDirectory -RegistryHive $RegistryHive)) {
        $actualAfterImport=Get-MBComRegistryExportHash -RegistryKey $registryKey -TemporaryDirectory $TransactionDirectory
        $backupAfterImport=(Get-FileHash -LiteralPath $backupFull -Algorithm SHA256 -ErrorAction Stop).Hash
        throw "$Target COM snapshot postcondition failed (live export SHA256='$actualAfterImport'; snapshot SHA256='$backupAfterImport')."
    }
    return $true
}
Export-ModuleMember -Function Test-MBComRegistrySnapshotRestored,Restore-MBComRegistrySnapshot
