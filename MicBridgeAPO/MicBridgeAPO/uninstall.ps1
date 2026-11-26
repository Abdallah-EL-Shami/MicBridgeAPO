# إزالة MicBridge APO وإرجاع كل ما غيّره التثبيت، بما فيه مالك المفتاح وصلاحياته.
param()
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}

# Serialize the complete preflight/restoration/COM/file-removal operation.
$recoveryModule = Join-Path $PSScriptRoot 'tools\MicBridge.RecoveryJournal.psm1'
Import-Module -Name $recoveryModule -Force -ErrorAction Stop
$operationLockPath = Join-Path (Join-Path $env:ProgramData 'MicBridgeAPO') 'operation'
$operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0
try {

$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$fxCompositeValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15'
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0'
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'
$backupFile = Join-Path $dataDir 'backup.json'
$compositeBackupFile = Join-Path $dataDir 'composite-efx-backup.json'
$audioKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Audio'
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

if (Test-Path $backupFile) {
    $b = Get-Content $backupFile -Raw | ConvertFrom-Json
    $devSub = "$capSub\$($b.DeviceId)"
    $fxSub  = "$devSub\FxProperties"
    $fxPath = "$capRoot\$($b.DeviceId)\FxProperties"

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
    if ($b.PSObject.Properties.Name -contains 'PrevDisableProtectedAudioDG') {
        if ($null -ne $b.PrevDisableProtectedAudioDG) {
            Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value $b.PrevDisableProtectedAudioDG -Type DWord
        } else {
            Remove-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning 'Backup has no DisableProtectedAudioDG snapshot; leaving the current Windows audio security setting unchanged.'
    }

    # 2) إرجاع المالك والصلاحيات الأصلية (الداخلي أولًا ثم المفتاح الأب)
    try {
        if ($b.FxKeySddl -and (Test-Path $fxPath)) { Restore-Sddl $fxSub $b.FxKeySddl }
        Restore-Sddl $devSub $b.DevKeySddl
        Write-Host 'أُعيد مالك المفتاح وصلاحياته كما كانت.'
    } catch {
        Write-Warning "تعذر إرجاع الصلاحيات الأصلية: $($_.Exception.Message)"
        throw 'Uninstall stopped before COM/DLL removal because endpoint ACL restoration failed. Keep backup.json and retry after resolving the permission error.'
    }
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
# Persist the COM restoration plan before changing either registration.
# Re-running uninstall resumes this exact endpoint-bound plan; completed steps are verified.
$uninstallJournal = Join-Path $dataDir 'uninstall-recovery.json'
$uninstallStepIds = @('RestoreAudioEngineApo','RestoreComClsid')
if (-not (Test-Path -LiteralPath $uninstallJournal -PathType Leaf)) {
    New-MBRecoveryJournal -Path $uninstallJournal -Operation Uninstall -DeviceId $parsedDeviceId -StepIds $uninstallStepIds | Out-Null
} else {
    Read-MBRecoveryJournal -Path $uninstallJournal -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds | Out-Null
}

Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreAudioEngineApo' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
    if (Test-Path -LiteralPath $apoRegistrationPath) { Remove-Item -LiteralPath $apoRegistrationPath -Recurse -Force -ErrorAction Stop }
    if ($b.PrevApoRegistrationExists) {
        & reg.exe import ([string]$b.PrevApoRegistrationFile) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to restore the original AudioEngine APO registration.' }
    }
} -Verify {
    Test-MBRegistrySnapshot -RegistrySubKey "SOFTWARE\\Classes\\AudioEngine\\AudioProcessingObjects\\$clsid" -SnapshotPath ([string]$b.PrevApoRegistrationFile) -ExpectedExists ([bool]$b.PrevApoRegistrationExists)
}

Invoke-MBRecoveryStep -Path $uninstallJournal -StepId 'RestoreComClsid' -ExpectedOperation Uninstall -ExpectedDeviceId $parsedDeviceId -ExpectedStepIds $uninstallStepIds -Action {
    if (Test-Path -LiteralPath $comRegistrationPath) { Remove-Item -LiteralPath $comRegistrationPath -Recurse -Force -ErrorAction Stop }
    if ($b.PrevClsidRegistrationExists) {
        & reg.exe import ([string]$b.PrevClsidRegistrationFile) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to restore the original COM CLSID registration.' }
    }
} -Verify {
    Test-MBRegistrySnapshot -RegistrySubKey "SOFTWARE\\Classes\\CLSID\\$clsid" -SnapshotPath ([string]$b.PrevClsidRegistrationFile) -ExpectedExists ([bool]$b.PrevClsidRegistrationExists)
}
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk') -Force -ErrorAction SilentlyContinue

Restart-Service -Name Audiosrv -Force
Start-Sleep -Seconds 2
if ($b.PrevClsidRegistrationExists -or $b.PrevApoRegistrationExists) {
    Write-Warning 'Original COM registration existed before MicBridge. The installation directory is retained to avoid deleting a DLL that the restored registration may reference.'
} elseif (Test-Path -LiteralPath $installDir) {
    Remove-Item -Recurse -Force $installDir -ErrorAction Stop
}
} finally {
    if ($operationLock) { $operationLock.Dispose() }
}
Write-Host "تمت الإزالة. الإعدادات والسجل ما زالت في $dataDir، احذفه يدويًا إن أردت."
