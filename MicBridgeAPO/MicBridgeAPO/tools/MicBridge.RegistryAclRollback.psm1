Set-StrictMode -Version Latest

function Get-MBRegistryBaseKey([ValidateSet('HKCU','HKLM')][string]$Hive) {
    if ($Hive -eq 'HKCU') { return [Microsoft.Win32.Registry]::CurrentUser }
    return [Microsoft.Win32.Registry]::LocalMachine
}

function Assert-MBRegistrySubKeyPath([string]$SubKeyPath) {
    if ([string]::IsNullOrWhiteSpace($SubKeyPath) -or
        $SubKeyPath.StartsWith('\') -or $SubKeyPath.EndsWith('\') -or
        $SubKeyPath -match '(^|\\)\.\.?($|\\)' -or $SubKeyPath -match '[:/]') {
        throw 'Registry subkey path is not a safe relative path.'
    }
}

function Get-MBRegistryAclSddl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('HKCU','HKLM')][string]$Hive,
        [Parameter(Mandatory)][string]$SubKeyPath
    )
    Assert-MBRegistrySubKeyPath $SubKeyPath
    $base = Get-MBRegistryBaseKey $Hive
    $key = $base.OpenSubKey($SubKeyPath,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,[System.Security.AccessControl.RegistryRights]::ReadPermissions)
    if (-not $key) { return $null }
    try {
        $sections = [System.Security.AccessControl.AccessControlSections]'Owner,Group,Access'
        $security = $key.GetAccessControl($sections)
        return $security.GetSecurityDescriptorSddlForm($sections)
    } finally { $key.Close() }
}

function Restore-MBRegistryAclSddl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('HKCU','HKLM')][string]$Hive,
        [Parameter(Mandatory)][string]$SubKeyPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Sddl
    )
    Assert-MBRegistrySubKeyPath $SubKeyPath
    $base = Get-MBRegistryBaseKey $Hive
    $rights = [System.Security.AccessControl.RegistryRights]'TakeOwnership,ChangePermissions'
    $key = $base.OpenSubKey($SubKeyPath,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,$rights)
    if (-not $key) { throw "Registry key does not exist: $Hive\$SubKeyPath" }
    try {
        $security = New-Object System.Security.AccessControl.RegistrySecurity
        $security.SetSecurityDescriptorSddlForm($Sddl)
        $key.SetAccessControl($security)
    } finally { $key.Close() }
}

function Test-MBRegistryAclSddl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('HKCU','HKLM')][string]$Hive,
        [Parameter(Mandatory)][string]$SubKeyPath,
        [Parameter(Mandatory)][AllowNull()][string]$ExpectedSddl
    )
    $actual = Get-MBRegistryAclSddl -Hive $Hive -SubKeyPath $SubKeyPath
    if ($null -eq $ExpectedSddl) { return ($null -eq $actual) }
    return [string]::Equals([string]$actual,$ExpectedSddl,[StringComparison]::Ordinal)
}

Export-ModuleMember -Function Get-MBRegistryAclSddl,Restore-MBRegistryAclSddl,Test-MBRegistryAclSddl
