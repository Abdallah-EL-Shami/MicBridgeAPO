Set-StrictMode -Version Latest

function Get-MBRegistryLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)
    if ($RegistryPath -notmatch '^(HKLM|HKCU)\\(.+)$') {
        throw 'RegistryPath must be a fully-qualified HKLM\... or HKCU\... path.'
    }
    $hiveName = $Matches[1]
    $subKey = $Matches[2].TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($subKey) -or $subKey -match '(^|\\)\.\.?($|\\)') {
        throw 'RegistryPath contains an invalid subkey path.'
    }
    $hive = if ($hiveName -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    return [pscustomobject]@{ Hive=$hive; HiveName=$hiveName; SubKey=$subKey; Path=("$hiveName\$subKey") }
}

function ConvertTo-MBRegistryComparableValue {
    param([string]$Kind,$Value)
    switch ($Kind) {
        'MultiString' { return ,([string[]]@($Value)) }
        'Binary' { return ,([byte[]]@($Value)) }
        'DWord' { return [int]$Value }
        'QWord' { return [long]$Value }
        default { return $Value }
    }
}

function Get-MBEndpointRegistrySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string[]]$ValueNames
    )
    $location = Get-MBRegistryLocation $RegistryPath
    if (-not $ValueNames -or @($ValueNames | Select-Object -Unique).Count -ne $ValueNames.Count -or
        @($ValueNames | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '[\\/]'}).Count -gt 0) {
        throw 'ValueNames must be a non-empty list of unique registry value names.'
    }
    $key = $location.Hive.OpenSubKey($location.SubKey,$false)
    $keyExists = ($null -ne $key)
    $values = @()
    try {
        foreach ($name in $ValueNames) {
            if (-not $key -or $key.GetValueNames() -notcontains $name) {
                $values += [pscustomobject]@{ Name=$name; Exists=$false; Kind='String'; Value=$null }
                continue
            }
            $kind = [string]$key.GetValueKind($name)
            $value = $key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $values += [pscustomobject]@{ Name=$name; Exists=$true; Kind=$kind; Value=$value }
        }
    } finally { if ($key) { $key.Close() } }
    return [pscustomobject]@{ RegistryPath=$location.Path; KeyExists=[bool]$keyExists; Values=@($values) }
}

function Test-MBEndpointRegistrySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Snapshot)
    try {
        if ($null -eq $Snapshot.RegistryPath -or $Snapshot.KeyExists -isnot [bool] -or -not $Snapshot.Values) { return $false }
        $location = Get-MBRegistryLocation ([string]$Snapshot.RegistryPath)
        $names = @($Snapshot.Values | ForEach-Object { [string]$_.Name })
        if (-not $names -or @($names | Select-Object -Unique).Count -ne $names.Count) { return $false }
        $actual = Get-MBEndpointRegistrySnapshot -RegistryPath $location.Path -ValueNames $names
        if ($actual.KeyExists -ne [bool]$Snapshot.KeyExists) { return $false }
        foreach ($expected in $Snapshot.Values) {
            if ($expected.Exists -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$expected.Name)) { return $false }
            $found = @($actual.Values | Where-Object { $_.Name -ceq [string]$expected.Name })
            if ($found.Count -ne 1 -or $found[0].Exists -ne [bool]$expected.Exists) { return $false }
            if ($expected.Exists) {
                if ($found[0].Kind -ne [string]$expected.Kind) { return $false }
                $left = ConvertTo-Json -InputObject $found[0].Value -Depth 8 -Compress
                $right = ConvertTo-Json -InputObject $expected.Value -Depth 8 -Compress
                if (-not [string]::Equals($left,$right,[StringComparison]::Ordinal)) { return $false }
            }
        }
        return $true
    } catch { return $false }
}

function Restore-MBEndpointRegistrySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Snapshot)
    if ($null -eq $Snapshot.RegistryPath -or $Snapshot.KeyExists -isnot [bool] -or -not $Snapshot.Values) {
        throw 'Endpoint registry snapshot is incomplete.'
    }
    $location = Get-MBRegistryLocation ([string]$Snapshot.RegistryPath)
    $names = @($Snapshot.Values | ForEach-Object { [string]$_.Name })
    if (-not $names -or @($names | Select-Object -Unique).Count -ne $names.Count) {
        throw 'Endpoint registry snapshot contains missing or duplicate value names.'
    }
    foreach ($entry in $Snapshot.Values) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Name) -or [string]$entry.Name -match '[\\/]' -or $entry.Exists -isnot [bool]) {
            throw 'Endpoint registry snapshot contains an invalid value entry.'
        }
        if ($entry.Exists) {
            try { $parsedKind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$entry.Kind,$true)) }
            catch { throw "Unsupported registry value kind in snapshot: $($entry.Kind)" }
            if ($parsedKind -eq [Microsoft.Win32.RegistryValueKind]::Unknown) { throw "Unsupported registry value kind in snapshot: $($entry.Kind)" }
        }
    }

    # Recovery may already have restored the exact snapshot before the journal
    # was marked complete (for example, after a process interruption). In that
    # case do not request write access or recreate/open the protected key.
    if (Test-MBEndpointRegistrySnapshot -Snapshot $Snapshot) { return $true }

    if ($Snapshot.KeyExists) {
        # Open an existing key for value writes. CreateSubKey is only appropriate
        # when the original snapshot says the key existed but it is now absent.
        $key = $location.Hive.OpenSubKey($location.SubKey,$true)
        if (-not $key) { $key = $location.Hive.CreateSubKey($location.SubKey) }
        if (-not $key) { throw "Could not create or open endpoint registry key: $($location.Path)" }
        try {
            foreach ($entry in $Snapshot.Values) {
                if ($entry.Exists) {
                    $kind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$entry.Kind,$true))
                    $value = ConvertTo-MBRegistryComparableValue -Kind ([string]$entry.Kind) -Value $entry.Value
                    $key.SetValue([string]$entry.Name,$value,$kind)
                } else {
                    $key.DeleteValue([string]$entry.Name,$false)
                }
            }
            $key.Flush()
        } finally { $key.Close() }
    } else {
        $key = $location.Hive.OpenSubKey($location.SubKey,$true)
        if ($key) {
            try {
                foreach ($entry in $Snapshot.Values) { $key.DeleteValue([string]$entry.Name,$false) }
                if ($key.GetValueNames().Count -ne 0 -or $key.GetSubKeyNames().Count -ne 0) {
                    throw 'Refusing to remove endpoint key: it contains values or subkeys not owned by this snapshot.'
                }
            } finally { $key.Close() }
            $location.Hive.DeleteSubKey($location.SubKey,$false)
        }
    }
    if (-not (Test-MBEndpointRegistrySnapshot -Snapshot $Snapshot)) {
        throw 'Endpoint registry snapshot restore did not satisfy its exact postcondition.'
    }
    return $true
}

Export-ModuleMember -Function Get-MBEndpointRegistrySnapshot,Restore-MBEndpointRegistrySnapshot,Test-MBEndpointRegistrySnapshot
