# إزالة MicBridge APO وإرجاع كل ما غيّره التثبيت، بما فيه مالك المفتاح وصلاحياته.
param()
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}

# Prepare the dedicated uninstall log before module loading and lock acquisition.
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir = Join-Path $env:ProgramData 'MicBridgeAPO'
$uninstallLog = Join-Path $dataDir 'Uninstall.log'
function Resolve-MBLogPath([string]$PrimaryPath, [string]$FallbackPath) {
    try {
        $parent = Split-Path -Parent $PrimaryPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null }
        $stream = New-Object IO.FileStream($PrimaryPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stream.Dispose()
        return $PrimaryPath
    } catch {
        try {
            $fallbackParent = Split-Path -Parent $FallbackPath
            if (-not (Test-Path -LiteralPath $fallbackParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $fallbackParent -ErrorAction Stop | Out-Null }
            $stream = New-Object IO.FileStream($FallbackPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $stream.Dispose()
            return $FallbackPath
        } catch {
            throw "Cannot create MicBridge uninstall log at either '$PrimaryPath' or '$FallbackPath'. $($_.Exception.Message)"
        }
    }
}
$uninstallLog = Resolve-MBLogPath $uninstallLog (Join-Path $env:TEMP 'MicBridgeAPO-Uninstall.log')
function Write-UninstallLog([string]$Level,[string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $uninstallLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Uninstall.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}
Write-Host "سجل الإزالة: $uninstallLog"
Write-UninstallLog 'INFO' 'Uninstaller process started.'
$recoveryModule = Join-Path $PSScriptRoot 'tools\MicBridge.RecoveryJournal.psm1'
try {
    Import-Module -Name $recoveryModule -Force -ErrorAction Stop
    $operationLockPath = Join-Path $dataDir 'operation'
    $operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0
} catch {
    Write-UninstallLog 'ERROR' "Uninstaller could not initialize its recovery lock/module; no removal or restoration started. $($_.Exception.ToString())"
    throw
}
try {

$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$fxCompositeValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15'
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0'
$backupFile = Join-Path $dataDir 'backup.json'
$compositeBackupFile = Join-Path $dataDir 'composite-efx-backup.json'
$capSub     = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
$capRoot    = "HKLM:\$capSub"

Add-Type @'
using System; using System.Runtime.InteropServices;
public class TokenPriv {
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr tok);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool LookupPrivilegeValue(string host, string name, ref long luid);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TokPriv1Luid n, int len, IntPtr prev, IntPtr rlen);
  [StructLayout(LayoutKind.Sequential, Pack=1)] struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
  public static bool Enable(string priv) {
    TokPriv1Luid tp; IntPtr tok = IntPtr.Zero;
    tp.Count = 1; tp.Luid = 0; tp.Attr = 2;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, ref tok)) return false;
    if (!LookupPrivilegeValue(null, priv, ref tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
}
'@

$secAll = [System.Security.AccessControl.AccessControlSections]'Owner,Group,Access'
$hklm   = [Microsoft.Win32.Registry]::LocalMachine

function Get-Sddl([string]$sub) {      # يقرأ المالك والصلاحيات بصيغة SDDL
    $k = $hklm.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [System.Security.AccessControl.RegistryRights]::ReadPermissions)
    if (-not $k) { return $null }
    $sd = $k.GetAccessControl($secAll); $k.Close()
    return $sd.GetSecurityDescriptorSddlForm($secAll)
}
function Restore-Sddl([string]$sub, [string]$sddl) {   # يعيد المالك والصلاحيات الأصلية
    [TokenPriv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
    [TokenPriv]::Enable('SeRestorePrivilege') | Out-Null
    $k = $hklm.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'TakeOwnership,ChangePermissions')
    if (-not $k) { throw "تعذر فتح المفتاح $sub" }
    $sec = New-Object System.Security.AccessControl.RegistrySecurity
    $sec.SetSecurityDescriptorSddlForm($sddl)
    $k.SetAccessControl($sec); $k.Close()
}


function Test-MBRegistrySnapshot([string]$RegistrySubKey, [string]$SnapshotPath, [bool]$ExpectedExists) {
    $registryPath = "HKLM:\$RegistrySubKey"
    if (-not $ExpectedExists) {
        return (-not (Test-Path -LiteralPath $registryPath))
    }
    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $registryPath)) { return $false }
    $currentExport = Join-Path $dataDir ("verify-" + [guid]::NewGuid().ToString('N') + ".reg")
    try {
        & reg.exe export "HKLM\$RegistrySubKey" $currentExport /y | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $currentExport -PathType Leaf)) { return $false }
        $expectedLines = @(Get-Content -LiteralPath $SnapshotPath -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        $actualLines = @(Get-Content -LiteralPath $currentExport -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        if ($expectedLines.Count -ne $actualLines.Count) { return $false }
        for ($i=0; $i -lt $expectedLines.Count; $i++) {
            if (-not [string]::Equals([string]$expectedLines[$i],[string]$actualLines[$i],[StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    } catch { return $false }
    finally { Remove-Item -LiteralPath $currentExport -Force -ErrorAction SilentlyContinue }
}

function Test-MBEndpointAclSnapshot([string]$DeviceSubKey, [string]$FxSubKey, [string]$ExpectedDeviceSddl, [string]$ExpectedFxSddl) {
    try {
        $actualDeviceSddl = Get-Sddl $DeviceSubKey
        if (-not $actualDeviceSddl -or -not [string]::Equals($actualDeviceSddl,$ExpectedDeviceSddl,[StringComparison]::Ordinal)) { return $false }
        if ($ExpectedFxSddl) {
            $actualFxSddl = Get-Sddl $FxSubKey
            if (-not $actualFxSddl -or -not [string]::Equals($actualFxSddl,$ExpectedFxSddl,[StringComparison]::Ordinal)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-MBRegistryDwordSnapshot([string]$SubKey, [string]$ValueName, [bool]$ExpectedExists, $ExpectedValue) {
    $key = $hklm.OpenSubKey($SubKey, $false)
    if (-not $key) { return (-not $ExpectedExists) }
    try {
        $exists = $key.GetValueNames() -contains $ValueName
        if ($exists -ne $ExpectedExists) { return $false }
        if (-not $ExpectedExists) { return $true }
        if ($key.GetValueKind($ValueName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { return $false }
        return ([int]$key.GetValue($ValueName) -eq [int]$ExpectedValue)
    } finally { $key.Close() }
}

function Test-MBEndpointValueSnapshot([string]$DeviceSubKey, [string]$LegacyValueName, [string]$AssociationValueName, [string]$CompositeValueName, [string]$Clsid, $Backup, [string]$CompositeBackupPath) {
    $key = $hklm.OpenSubKey($DeviceSubKey + '\\FxProperties', $false)
    if (-not $key) {
        # A missing FxProperties key is the expected original state when MicBridge created it.
        # Treat it as restored only when the immutable first-install snapshot proves that fact.
        return ([bool]$Backup.CreatedFx -and [string]::IsNullOrWhiteSpace([string]$Backup.FxKeySddl))
    }
    try {
        if ($Backup.PSObject.Properties.Name -contains 'PrevFxAssociation') {
            $associationExists = $key.GetValueNames() -contains $AssociationValueName
            $expectedAssociationExists = -not [string]::IsNullOrEmpty([string]$Backup.PrevFxAssociation)
            if ($associationExists -ne $expectedAssociationExists) { return $false }
            if ($expectedAssociationExists -and [string]$key.GetValue($AssociationValueName) -ne [string]$Backup.PrevFxAssociation) { return $false }
        }
        if ($key.GetValueNames() -contains $LegacyValueName) {
            if ([string]$key.GetValue($LegacyValueName) -eq $Clsid) { return $false }
        }
        if (Test-Path -LiteralPath $CompositeBackupPath -PathType Leaf) {
            $snapshot = Get-Content -LiteralPath $CompositeBackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ([string]$snapshot.DeviceId -ne [string]$Backup.DeviceId) { return $false }
            $original = @($snapshot.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $present = $key.GetValueNames() -contains $CompositeValueName
            if ($present -and $key.GetValueKind($CompositeValueName) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) { return $false }
            $current = if ($present) { @($key.GetValue($CompositeValueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) } else { @() }
            if ($original -contains $Clsid) {
                if ($current -notcontains $Clsid) { return $false }
            } elseif ($current -contains $Clsid) { return $false }
        }
        return $true
    } catch { return $false }
    finally { $key.Close() }
}

# Fail closed before any mutation if the original recovery snapshot is unavailable.
if (-not (Test-Path -LiteralPath $backupFile)) {
    throw 'backup.json is missing. Uninstall stopped before changing endpoint registry, COM registration, Windows audio settings, or files.'
}
try {
    $preflightBackup = Get-Content -LiteralPath $backupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "backup.json is unreadable or malformed; uninstall stopped before changes: $($_.Exception.Message)"
}
$parsedDeviceId = [guid]::Empty
if (-not $preflightBackup -or -not [guid]::TryParse([string]$preflightBackup.DeviceId, [ref]$parsedDeviceId)) {
    throw 'backup.json has no valid capture endpoint DeviceId; uninstall stopped before changes.'
}
if ($preflightBackup.PSObject.Properties.Name -notcontains 'ComRegistrationSnapshotVersion' -or [int]$preflightBackup.ComRegistrationSnapshotVersion -ne 1) {
    throw 'This installation has no trustworthy persistent pre-install COM snapshot. Uninstall stopped before changes to avoid deleting a COM registration that may have existed before MicBridge.'
}
foreach ($entry in @(@($preflightBackup.PrevClsidRegistrationExists, $preflightBackup.PrevClsidRegistrationFile), @($preflightBackup.PrevApoRegistrationExists, $preflightBackup.PrevApoRegistrationFile))) {
    if ($entry[0] -and -not (Test-Path -LiteralPath ([string]$entry[1]))) { throw 'A required persistent COM recovery file is missing; uninstall stopped before changes.' }
}
# Validate COM snapshot metadata and constrain imports to installer-owned export files.
# A valid .reg header alone is insufficient: never import a path or registry tree
# supplied by an edited/corrupt recovery JSON file.
foreach ($field in @('PrevClsidRegistrationExists','PrevApoRegistrationExists')) {
    if ($preflightBackup.PSObject.Properties.Name -notcontains $field -or $preflightBackup.$field -isnot [bool]) {
        throw "backup.json has an invalid $field flag; uninstall stopped before changes."
    }
}
$comBackupDir = Join-Path $dataDir 'com-registration-backup'
$expectedComFiles = @(
    [pscustomobject]@{ Field='PrevClsidRegistrationFile'; Name='previous-clsid.reg'; Exists=[bool]$preflightBackup.PrevClsidRegistrationExists; Key="SOFTWARE\Classes\CLSID\$clsid" },
    [pscustomobject]@{ Field='PrevApoRegistrationFile'; Name='previous-audioengine-apo.reg'; Exists=[bool]$preflightBackup.PrevApoRegistrationExists; Key="SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" }
)
# Verify immutable COM export bytes before any endpoint, ACL, COM, or file mutation.
# Legacy snapshots without hashes remain readable; newly-created snapshots are hash-bound.
$hashFields = @(
    [pscustomobject]@{ Exists=[bool]$preflightBackup.PrevClsidRegistrationExists; HashField='PrevClsidRegistrationSha256'; Name='previous-clsid.reg' },
    [pscustomobject]@{ Exists=[bool]$preflightBackup.PrevApoRegistrationExists; HashField='PrevApoRegistrationSha256'; Name='previous-audioengine-apo.reg' }
)
foreach ($entry in $hashFields) {
    if (-not $entry.Exists) { continue }
    if ($preflightBackup.PSObject.Properties.Name -contains $entry.HashField) {
        $expectedHash = [string]$preflightBackup.($entry.HashField)
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "backup.json has an invalid $($entry.HashField); uninstall stopped before changes."
        }
        $backupPath = Join-Path (Join-Path $dataDir 'com-registration-backup') $entry.Name
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Required COM recovery file '$($entry.Name)' is missing; uninstall stopped before changes."
        }
        $actualHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($expectedHash, $actualHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "COM recovery file '$($entry.Name)' failed SHA-256 integrity validation; uninstall stopped before changes."
        }
    }
}
foreach ($item in $expectedComFiles) {
    if ($preflightBackup.PSObject.Properties.Name -notcontains $item.Field) {
        throw "backup.json is missing $($item.Field); uninstall stopped before changes."
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $comBackupDir $item.Name))
    $recordedPath = [IO.Path]::GetFullPath([string]$preflightBackup.($item.Field))
    if (-not [string]::Equals($expectedPath, $recordedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "backup.json points $($item.Field) outside the installer-owned recovery location; uninstall stopped before changes."
    }
    if ($item.Exists) {
        if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
            throw "Required COM recovery file '$($item.Name)' is missing; uninstall stopped before changes."
        }
        $regLines = @(Get-Content -LiteralPath $expectedPath -ErrorAction Stop)
        if ($regLines.Count -lt 2 -or $regLines[0] -ne 'Windows Registry Editor Version 5.00') {
            throw "COM recovery file '$($item.Name)' has an invalid registry export header; uninstall stopped before changes."
        }
        $expectedRoot = 'HKEY_LOCAL_MACHINE\' + $item.Key
        $sections = @()
        foreach ($regLine in $regLines) {
            if ($regLine.StartsWith('[') -and $regLine.EndsWith(']')) {
                $sections += $regLine.Substring(1, $regLine.Length - 2)
            }
        }
        if ($sections.Count -eq 0 -or $sections -notcontains $expectedRoot) {
            throw "COM recovery file '$($item.Name)' does not contain its expected registry root; uninstall stopped before changes."
        }
        foreach ($section in $sections) {
            if (-not [string]::Equals($section, $expectedRoot, [StringComparison]::OrdinalIgnoreCase) -and
                -not $section.StartsWith($expectedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "COM recovery file '$($item.Name)' contains an unexpected registry tree; uninstall stopped before changes."
            }
        }
    }
}
if ([string]::IsNullOrWhiteSpace([string]$preflightBackup.DevKeySddl)) {
    throw 'backup.json has no endpoint ACL snapshot; uninstall stopped before changes to avoid guessing original permissions.'
}

if (-not (Test-Path -LiteralPath $compositeBackupFile)) {
    throw 'Composite EFX recovery record is missing; uninstall stopped before changing endpoint registry, COM registration, Windows audio settings, or files.'
}
try {
    $preflightComposite = Get-Content -LiteralPath $compositeBackupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Composite EFX recovery record is unreadable or malformed; uninstall stopped before changes: $($_.Exception.Message)"
}
if ([string]$preflightComposite.DeviceId -ne [string]$preflightBackup.DeviceId) {
    throw 'Composite EFX recovery record belongs to another endpoint; uninstall stopped before changes.'
}
# Validate the complete recovery-record schema while still in the read-only preflight.
# Never let malformed JSON values reach registry restoration code.
if ($preflightComposite.PSObject.Properties.Name -notcontains 'Exists' -or
    $preflightComposite.Exists -isnot [bool]) {
    throw 'Composite EFX recovery record has an invalid Exists field; uninstall stopped before changes.'
}
if ($preflightComposite.PSObject.Properties.Name -notcontains 'Kind' -or
    [string]$preflightComposite.Kind -ne 'MultiString') {
    throw 'Composite EFX recovery record has an invalid registry Kind; uninstall stopped before changes.'
}
if ($preflightComposite.PSObject.Properties.Name -notcontains 'Value' -or
    $preflightComposite.Value -isnot [array]) {
    throw 'Composite EFX recovery record has an invalid Value list; uninstall stopped before changes.'
}
foreach ($effectId in $preflightComposite.Value) {
    $parsedEffectId = [guid]::Empty
    if ($effectId -isnot [string] -or -not [guid]::TryParse($effectId, [ref]$parsedEffectId)) {
        throw 'Composite EFX recovery record contains an invalid CLSID; uninstall stopped before changes.'
    }
}
if ($preflightBackup.PrevClsidRegistrationExists) {
    $regFile = [string]$preflightBackup.PrevClsidRegistrationFile
    if ([string]::IsNullOrWhiteSpace($regFile) -or -not (Test-Path -LiteralPath $regFile)) {
        throw 'A required persistent COM recovery file is missing; uninstall stopped before changes.'
    }
    $regHeader = Get-Content -LiteralPath $regFile -TotalCount 1 -ErrorAction Stop
    if ($regHeader -ne 'Windows Registry Editor Version 5.00') {
        throw 'A required persistent COM recovery file is invalid; uninstall stopped before changes.'
    }
}
if ($preflightBackup.PrevApoRegistrationExists) {
    $regFile = [string]$preflightBackup.PrevApoRegistrationFile
    if ([string]::IsNullOrWhiteSpace($regFile) -or -not (Test-Path -LiteralPath $regFile)) {
        throw 'A required persistent COM recovery file is missing; uninstall stopped before changes.'
    }
    $regHeader = Get-Content -LiteralPath $regFile -TotalCount 1 -ErrorAction Stop
    if ($regHeader -ne 'Windows Registry Editor Version 5.00') {
        throw 'A required persistent COM recovery file is invalid; uninstall stopped before changes.'
    }
}

# Read-only global preflight: every capture endpoint value must have its documented registry type.
$preflightRoot = $hklm.OpenSubKey($capSub, $false)
if (-not $preflightRoot) { throw 'Cannot enumerate capture endpoints; uninstall stopped before changes.' }
try { $preflightIds = @($preflightRoot.GetSubKeyNames()) }
finally { $preflightRoot.Close() }
foreach ($endpointId in $preflightIds) {
    $key = $hklm.OpenSubKey("$capSub\$endpointId\FxProperties", $false)
    if (-not $key) { continue }
    try {
        $names = @($key.GetValueNames())
        if (($names -contains $fxCompositeValue) -and
            ($key.GetValueKind($fxCompositeValue) -ne [Microsoft.Win32.RegistryValueKind]::MultiString)) {
            throw "Endpoint '$endpointId' has malformed Composite EFX; uninstall stopped before changes."
        }
        if (($names -contains $fxValue) -and
            ($key.GetValueKind($fxValue) -ne [Microsoft.Win32.RegistryValueKind]::String)) {
            throw "Endpoint '$endpointId' has malformed legacy EFX; uninstall stopped before changes."
        }
    } finally { $key.Close() }
}

# Re-audit permanent backup provenance and legacy files before creating the recovery plan
# or mutating endpoint/COM registrations. Ambiguous state is preserved for manual review.
$legacyAuditModule = Join-Path $PSScriptRoot 'tools\MicBridge.LegacyInstallAudit.psm1'
if (-not (Test-Path -LiteralPath $legacyAuditModule -PathType Leaf)) {
    throw "Legacy installation audit module is missing; refusing to uninstall without a safe preflight: $legacyAuditModule"
}
Import-Module -Name $legacyAuditModule -Force -ErrorAction Stop
$legacyAudit = Test-MBLegacyInstallationState -InstallDirectory $installDir -DataDirectory $dataDir -RegistryRoot 'HKLM:\' -ExpectedDeviceId $parsedDeviceId
Write-UninstallLog 'INFO' "Read-only legacy audit completed. Outcome=$($legacyAudit.Outcome); BaselineAssessment=$($legacyAudit.BaselineAssessment)."
if ($legacyAudit.Outcome -eq 'ReviewRequired' -or
    $legacyAudit.OwnershipProven -ne $true -or
    $legacyAudit.OwnershipEvidenceStatus -ne 'Proven') {
    $reviewItems = @($legacyAudit.Findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved','InvalidOrInsufficient','MissingPermanentBackup') })
    $reviewSummary = ($reviewItems | ForEach-Object { "$($_.Kind):$($_.Name) [$($_.Classification)]" }) -join '; '
    throw "Legacy installation audit requires manual review. No Registry, COM, ACL, or file changes were made. Preserve the installation and ProgramData data. $reviewSummary"
}

# Create the uninstall recovery plan after all read-only preflight checks and before the first mutation.
$uninstallJournal = Join-Path $dataDir 'uninstall-recovery.json'
$uninstallStepIds = @('RestoreEndpointValues','RestoreWindowsAudioSetting','RestoreEndpointAcl','RestoreAudioEngineApo','RestoreComClsid')
if (-not (Test-Path -LiteralPath $uninstallJournal -PathType Leaf)) {
    New-MBRecoveryJournal -Path $uninstallJournal -Operation Uninstall -DeviceId $parsedDeviceId -StepIds $uninstallStepIds | Out-Null
} else {
    Read-MBRecoveryJournal -Path $uninstallJournal -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds | Out-Null
}

if (Test-Path $backupFile) {
    $b = Get-Content $backupFile -Raw | ConvertFrom-Json
    $devSub = "$capSub\$($b.DeviceId)"
    $fxSub  = "$devSub\FxProperties"
    $fxPath = "$capRoot\$($b.DeviceId)\FxProperties"

    # Restore endpoint FX values as one durable, verified step.
    Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreEndpointValues' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
        # 1) القيم (والمفاتيح ما زالت بصلاحيات كاملة للمسؤولين)
        if (Test-Path $fxPath) {
            # The current installer leaves the legacy single-CLSID value untouched.
            # Only undo it when it still contains MicBridge from an older installer.
            $currentLegacy = (Get-ItemProperty -LiteralPath $fxPath -Name $fxValue -ErrorAction SilentlyContinue).$fxValue
            if ([string]$currentLegacy -eq $clsid) {
                if ($b.PrevEndpointEffect) { Set-ItemProperty -LiteralPath $fxPath -Name $fxValue -Value $b.PrevEndpointEffect -Type String }
                else { Remove-ItemProperty -LiteralPath $fxPath -Name $fxValue -ErrorAction SilentlyContinue }
            }

            # Restore the association only if it still has the value installed by MicBridge.
            $currentAssociation = (Get-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -ErrorAction SilentlyContinue).$fxAssociationValue
            $expectedAssociation = if ($b.PrevFxAssociation) { [string]$b.PrevFxAssociation } else { '{00000000-0000-0000-0000-000000000000}' }
            if ([string]$currentAssociation -eq $expectedAssociation) {
                if ($b.PSObject.Properties.Name -contains 'PrevFxAssociation') {
                    if ($b.PrevFxAssociation) { Set-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -Value $b.PrevFxAssociation -Type String }
                    else { Remove-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -ErrorAction SilentlyContinue }
                } elseif (($b.CreatedFx -eq $true) -and ($null -eq $b.FxKeySddl)) {
                    # Legacy backup proves FxProperties did not exist before MicBridge's first install.
                    Remove-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -ErrorAction SilentlyContinue
                } else {
                    Write-Warning 'Legacy backup does not prove the original FX association; leaving that property untouched.'
                }
            }

            # The old installer may have created FxProperties. Delete it only if it is empty;
            # never recursively delete driver/vendor properties added later.
            # Remove only MicBridge from the live composite list; retain vendor entries added after installation.
            if (Test-Path -LiteralPath $compositeBackupFile) {
                $compositeState = Get-Content -LiteralPath $compositeBackupFile -Raw | ConvertFrom-Json
                if ([string]$compositeState.DeviceId -ne [string]$b.DeviceId) { throw 'Composite EFX backup endpoint mismatch; refusing to restore another device.' }
                $originalList = @($compositeState.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                $baselineList = @($originalList)
                if (-not $compositeState.Exists -and $b.PrevEndpointEffect -and [string]$b.PrevEndpointEffect -ne $clsid) {
                    $baselineList = @([string]$b.PrevEndpointEffect)
                }
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$capSub\$($b.DeviceId)\FxProperties", $true)
                if (-not $key) { throw 'FxProperties key is missing while restoring composite EFX.' }
                try {
                    $currentList = @()
                    if ($key.GetValueNames() -contains $fxCompositeValue) {
                        if ($key.GetValueKind($fxCompositeValue) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
                            throw 'Current composite EFX value is not REG_MULTI_SZ; refusing to alter it during uninstall.'
                        }
                        $currentList = @($key.GetValue($fxCompositeValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
                    } else {
                        $currentList = @($baselineList)
                    }
                    $originalHadMicBridge = ($originalList -contains $clsid)
                    if ($originalHadMicBridge) {
                        if ($currentList -notcontains $clsid) { $currentList += $clsid }
                    } else {
                        $currentList = @($currentList | Where-Object { [string]$_ -ne $clsid })
                    }

                    $matchesBaseline = ($currentList.Count -eq $baselineList.Count)
                    if ($matchesBaseline) {
                        for ($index = 0; $index -lt $currentList.Count; $index++) {
                            if ([string]$currentList[$index] -ne [string]$baselineList[$index]) { $matchesBaseline = $false; break }
                        }
                    }
                    if (-not $compositeState.Exists -and $matchesBaseline) {
                        # No vendor additions occurred; restore the original absence of the composite property.
                        $key.DeleteValue($fxCompositeValue, $false)
                    } elseif ($currentList.Count -gt 0) {
                        $key.SetValue($fxCompositeValue, [string[]]$currentList, [Microsoft.Win32.RegistryValueKind]::MultiString)
                    } else {
                        $key.DeleteValue($fxCompositeValue, $false)
                    }
                } finally { $key.Close() }
            }

            if ($b.CreatedFx) {
                $relativeFx = "$capSub\$($b.DeviceId)\FxProperties"
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relativeFx)
                if ($key) {
                    $empty = ($key.GetValueNames().Count -eq 0 -and $key.GetSubKeyNames().Count -eq 0)
                    $key.Close()
                    if ($empty) { Remove-Item -LiteralPath $fxPath -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    } -Verify {
        Test-MBEndpointValueSnapshot -DeviceSubKey $devSub -LegacyValueName $fxValue -AssociationValueName $fxAssociationValue -CompositeValueName $fxCompositeValue -Clsid $clsid -Backup $b -CompositeBackupPath $compositeBackupFile
    }

    # Older releases saved this value from the wrong registry path. It is not a
    # trustworthy snapshot of the real Windows setting, so never restore/delete it.
    Write-UninstallLog 'INFO' 'Endpoint FX values cleanup/restoration step completed and verified.'
    Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreWindowsAudioSetting' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
        Write-Warning 'Leaving DisableProtectedAudioDG unchanged: legacy backup data is not a trustworthy snapshot.'
    } -Verify {
        return $true
    }

    Write-UninstallLog 'INFO' 'Windows AudioDG setting deliberately left unchanged; legacy value was not trusted.'
    Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreEndpointAcl' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
        if ($b.FxKeySddl -and (Test-Path $fxPath)) { Restore-Sddl $fxSub $b.FxKeySddl }
        Restore-Sddl $devSub $b.DevKeySddl
    } -Verify {
        Test-MBEndpointAclSnapshot -DeviceSubKey $devSub -FxSubKey $fxSub -ExpectedDeviceSddl ([string]$b.DevKeySddl) -ExpectedFxSddl ([string]$b.FxKeySddl)
    }
    Write-UninstallLog 'INFO' 'Endpoint ACL restoration completed and verified.'
    Write-Host 'أُعيد مالك المفتاح وصلاحياته كما كانت.'
} else { Write-Warning 'لم أجد backup.json، سأزيل التسجيل فقط.' }


# Do not run a broad cleanup over every endpoint: that could erase a CLSID
# that was already present before MicBridge. The selected endpoint has already
# had its original Composite EFX state restored above. Other endpoints are read-only.
$remainingReferences = @()
$cleanupRoot = $hklm.OpenSubKey($capSub, $false)
if (-not $cleanupRoot) { throw 'Cannot enumerate capture endpoints; refusing COM/DLL removal.' }
try { $cleanupIds = @($cleanupRoot.GetSubKeyNames()) } finally { $cleanupRoot.Close() }
foreach ($endpointId in $cleanupIds) {
    $key = $hklm.OpenSubKey("$capSub\$endpointId\FxProperties", $false)
    if (-not $key) { continue }
    try {
        $names = @($key.GetValueNames())
        if ($names -contains $fxCompositeValue) {
            if ($key.GetValueKind($fxCompositeValue) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) { throw "Cannot inspect Composite EFX on '$endpointId'; refusing COM/DLL removal." }
            $values = @($key.GetValue($fxCompositeValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
            if (@($values | Where-Object { [string]$_ -ieq $clsid }).Count -gt 0) { $remainingReferences += $endpointId }
        }
        if ($names -contains $fxValue) {
            if ($key.GetValueKind($fxValue) -ne [Microsoft.Win32.RegistryValueKind]::String) { throw "Cannot inspect legacy EFX on '$endpointId'; refusing COM/DLL removal." }
            if ([string]$key.GetValue($fxValue) -ieq $clsid -and $remainingReferences -notcontains $endpointId) { $remainingReferences += $endpointId }
        }
    } finally { $key.Close() }
}
# If an endpoint still references this CLSID, only proceed when the original COM
# registration existed and can be restored exactly from the persistent snapshot.
if ($remainingReferences.Count -gt 0 -and -not ($b.PrevClsidRegistrationExists -and $b.PrevApoRegistrationExists)) {
    throw ("MicBridge CLSID remains referenced by endpoint(s): {0}. Original COM registration was not present in the backup, so DLL removal is blocked to avoid dangling references." -f ($remainingReferences -join ', '))
}

# The read-only scan above is the safety verification. Preserve any original COM
# registration; remove only MicBridge's registration when no prior registration existed.
$apoRegistrationPath = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
$comRegistrationPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
# The journal was created before endpoint ACL restoration; COM steps continue the same plan.
Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreAudioEngineApo' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
    if (Test-Path -LiteralPath $apoRegistrationPath) { Remove-Item -LiteralPath $apoRegistrationPath -Recurse -Force -ErrorAction Stop }
    if ($b.PrevApoRegistrationExists) {
        & reg.exe import ([string]$b.PrevApoRegistrationFile) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to restore the original AudioEngine APO registration.' }
    }
} -Verify {
    Test-MBRegistrySnapshot -RegistrySubKey "SOFTWARE\\Classes\\AudioEngine\\AudioProcessingObjects\\$clsid" -SnapshotPath ([string]$b.PrevApoRegistrationFile) -ExpectedExists ([bool]$b.PrevApoRegistrationExists)
}

Write-UninstallLog 'INFO' 'AudioEngine APO registration restoration completed and verified.'
Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreComClsid' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
    if (Test-Path -LiteralPath $comRegistrationPath) { Remove-Item -LiteralPath $comRegistrationPath -Recurse -Force -ErrorAction Stop }
    if ($b.PrevClsidRegistrationExists) {
        & reg.exe import ([string]$b.PrevClsidRegistrationFile) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to restore the original COM CLSID registration.' }
    }
} -Verify {
    Test-MBRegistrySnapshot -RegistrySubKey "SOFTWARE\\Classes\\CLSID\\$clsid" -SnapshotPath ([string]$b.PrevClsidRegistrationFile) -ExpectedExists ([bool]$b.PrevClsidRegistrationExists)
}
Write-UninstallLog 'INFO' 'COM CLSID restoration completed and verified.'
# File/shortcut/service cleanup is a separate durable phase. Keep the existing
# registry/COM/ACL journal unchanged so older in-progress uninstall journals remain resumable.
$cleanupJournal = Join-Path $dataDir 'uninstall-cleanup-recovery.json'
$cleanupStepIds = @('RemoveDesktopShortcut','RestartAudioService','RemoveInstallDirectory')
if (-not (Test-Path -LiteralPath $cleanupJournal -PathType Leaf)) {
    New-MBRecoveryJournal -Path $cleanupJournal -Operation Uninstall -DeviceId $parsedDeviceId -StepIds $cleanupStepIds | Out-Null
} else {
    Read-MBRecoveryJournal -Path $cleanupJournal -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $cleanupStepIds | Out-Null
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk'
$shortcutOwnershipFile = Join-Path $dataDir 'desktop-shortcut.sha256'
Invoke-MBRecoveryStep -Path $cleanupJournal -StepId 'RemoveDesktopShortcut' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $cleanupStepIds -Action {
    # The ownership marker is MicBridge data: reject directories/reparse points before reading or deleting it.
    if (Test-Path -LiteralPath $shortcutOwnershipFile) {
        $markerItem = Get-Item -LiteralPath $shortcutOwnershipFile -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Desktop shortcut ownership marker is not a regular file; refusing to follow or remove it.'
        }
        # Only delete a regular shortcut whose bytes still match the install-time ownership hash.
        if (Test-Path -LiteralPath $shortcutPath) {
            $shortcutItem = Get-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
            if ($shortcutItem.PSIsContainer -or (($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                Write-Warning 'Desktop shortcut is not a regular file; preserving it.'
                Write-UninstallLog 'WARN' "Preserved non-regular desktop shortcut: '$shortcutPath'."
            } else {
                $ownedHash = (Get-Content -LiteralPath $shortcutOwnershipFile -Raw -ErrorAction Stop).Trim()
                if ($ownedHash.Length -eq 64 -and $ownedHash -match '^[0-9A-Fa-f]+$') {
                    $currentHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ([string]::Equals($currentHash,$ownedHash,[StringComparison]::OrdinalIgnoreCase)) {
                        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
                        Write-UninstallLog 'INFO' "Removed verified MicBridge-owned desktop shortcut: '$shortcutPath'."
                    } else {
                        Write-Warning 'Desktop shortcut changed after MicBridge created it; preserving the user-modified shortcut.'
                        Write-UninstallLog 'WARN' "Preserved modified desktop shortcut: '$shortcutPath'."
                    }
                } else {
                    Write-Warning 'Desktop shortcut ownership record is invalid; preserving the shortcut.'
                }
            }
        }
        # The decision is complete; remove only the verified regular ownership marker.
        Remove-Item -LiteralPath $shortcutOwnershipFile -Force -ErrorAction Stop
        Write-UninstallLog 'INFO' "Removed MicBridge shortcut ownership marker: '$shortcutOwnershipFile'."
    }
} -Verify {
    -not (Test-Path -LiteralPath $shortcutOwnershipFile)
}

$serviceRestartMarker = "$cleanupJournal.service-restarted"
Invoke-MBRecoveryStep -Path $cleanupJournal -StepId 'RestartAudioService' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $cleanupStepIds -Action {
    Remove-Item -LiteralPath $serviceRestartMarker -Force -ErrorAction SilentlyContinue
    Restart-Service -Name Audiosrv -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    [IO.File]::WriteAllText($serviceRestartMarker,[DateTime]::UtcNow.ToString('o'),(New-Object Text.UTF8Encoding($false)))
} -Verify {
    $audioService = Get-Service -Name Audiosrv -ErrorAction Stop
    (Test-Path -LiteralPath $serviceRestartMarker -PathType Leaf) -and ($audioService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
}
Write-UninstallLog 'INFO' 'Audio service restart step completed and verified.'

$preserveInstallDirectory = [bool]($b.PrevClsidRegistrationExists -or $b.PrevApoRegistrationExists)
Invoke-MBRecoveryStep -Path $cleanupJournal -StepId 'RemoveInstallDirectory' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $cleanupStepIds -Action {
    if ($preserveInstallDirectory) {
        Write-Warning 'Original COM registration existed before MicBridge. The installation directory is retained to avoid deleting a DLL that the restored registration may reference.'
        Write-UninstallLog 'WARN' "Preserved install directory '$installDir' because a pre-existing COM registration may reference its DLL."
    } elseif (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
        Write-UninstallLog 'INFO' "Removed install directory after ownership/preflight checks: '$installDir'."
    }
} -Verify {
    if ($preserveInstallDirectory) {
        Test-Path -LiteralPath $installDir -PathType Container
    } else {
        -not (Test-Path -LiteralPath $installDir)
    }
}
} catch {
    try { Write-UninstallLog 'ERROR' "Uninstall failed or stopped. Error='$($_.Exception.ToString())'; Position='$($_.InvocationInfo.PositionMessage)'" } catch {}
    Write-Host "فشلت الإزالة أو توقفت للحماية. سجل الإزالة: $uninstallLog" -ForegroundColor Red
    throw
} finally {
    if ($operationLock) { $operationLock.Dispose() }
}
Write-UninstallLog 'INFO' 'Uninstall completed. ProgramData settings and diagnostic logs were retained.'
Write-Host "تمت الإزالة. الإعدادات والسجلات محفوظة في $dataDir. سجل الإزالة: $uninstallLog"
