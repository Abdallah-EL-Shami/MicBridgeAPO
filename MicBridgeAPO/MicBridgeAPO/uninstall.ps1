# إزالة MicBridge APO وإرجاع كل ما غيّره التثبيت، بما فيه مالك المفتاح وصلاحياته.
param()
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}

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


# Fail closed before touching endpoint state if the recovery record is missing or unsafe.
if (-not (Test-Path -LiteralPath $backupFile)) {
    throw 'backup.json is missing. No endpoint, COM registration, Windows audio setting, or DLL was changed. Restore the matching backup before uninstall.'
}
try {
    $preflightBackup = Get-Content -LiteralPath $backupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "backup.json is unreadable or malformed; uninstall stopped before changes: $($_.Exception.Message)"
}
$guidPattern = '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?
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
    if ($null -ne $b.PrevDisableProtectedAudioDG) { Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value $b.PrevDisableProtectedAudioDG -Type DWord }
    else { Remove-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue }

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


# Scan every capture endpoint. Preflight all relevant registry value types before
# writing anything, then remove only this APO's exact CLSID while preserving vendor entries.
$captureRoot = $hklm.OpenSubKey($capSub, $false)
if (-not $captureRoot) { throw 'Cannot enumerate capture endpoints; COM/DLL removal is blocked.' }
try { $captureEndpointIds = @($captureRoot.GetSubKeyNames()) }
finally { $captureRoot.Close() }

$endpointCleanup = @()
foreach ($endpointId in $captureEndpointIds) {
    $relativeFx = "$capSub\$endpointId\FxProperties"
    $key = $hklm.OpenSubKey($relativeFx, $false)
    if (-not $key) { continue }
    try {
        $names = @($key.GetValueNames())
        $hasComposite = $names -contains $fxCompositeValue
        $hasLegacy = $names -contains $fxValue
        if ($hasComposite -and $key.GetValueKind($fxCompositeValue) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
            throw "Endpoint '$endpointId' has a malformed Composite EFX value; no COM/DLL removal is allowed."
        }
        if ($hasLegacy -and $key.GetValueKind($fxValue) -ne [Microsoft.Win32.RegistryValueKind]::String) {
            throw "Endpoint '$endpointId' has a malformed legacy EFX value; no COM/DLL removal is allowed."
        }
        $endpointCleanup += [pscustomobject]@{
            Id = $endpointId
            Composite = if ($hasComposite) { @($key.GetValue($fxCompositeValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) } else { $null }
            HasComposite = $hasComposite
            Legacy = if ($hasLegacy) { [string]$key.GetValue($fxValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
            HasLegacy = $hasLegacy
        }
    } finally { $key.Close() }
}

foreach ($state in $endpointCleanup) {
    $key = $hklm.OpenSubKey("$capSub\$($state.Id)\FxProperties", $true)
    if (-not $key) { throw "Cannot open endpoint '$($state.Id)' for safe EFX cleanup; COM/DLL removal is blocked." }
    try {
        if ($state.HasComposite -and @($state.Composite | Where-Object { [string]$_ -ieq $clsid }).Count -gt 0) {
            $kept = @($state.Composite | Where-Object { [string]$_ -ine $clsid })
            if ($kept.Count -gt 0) {
                $key.SetValue($fxCompositeValue, [string[]]$kept, [Microsoft.Win32.RegistryValueKind]::MultiString)
            } else {
                $key.DeleteValue($fxCompositeValue, $false)
            }
        }
        if ($state.HasLegacy -and [string]$state.Legacy -ieq $clsid) {
            $key.DeleteValue($fxValue, $false)
        }
    } finally { $key.Close() }
}

# Verify independently that no capture endpoint still references this APO.
foreach ($endpointId in $captureEndpointIds) {
    $key = $hklm.OpenSubKey("$capSub\$endpointId\FxProperties", $false)
    if (-not $key) { continue }
    try {
        $names = @($key.GetValueNames())
        if ($names -contains $fxCompositeValue) {
            if ($key.GetValueKind($fxCompositeValue) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
                throw "Cannot verify Composite EFX on '$endpointId'; COM/DLL removal is blocked."
            }
            $values = @($key.GetValue($fxCompositeValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
            if (@($values | Where-Object { [string]$_ -ieq $clsid }).Count -gt 0) {
                throw "MicBridge remains in Composite EFX on '$endpointId'; COM/DLL removal is blocked."
            }
        }
        if ($names -contains $fxValue) {
            if ($key.GetValueKind($fxValue) -ne [Microsoft.Win32.RegistryValueKind]::String) {
                throw "Cannot verify legacy EFX on '$endpointId'; COM/DLL removal is blocked."
            }
            if ([string]$key.GetValue($fxValue) -ieq $clsid) {
                throw "MicBridge remains in legacy EFX on '$endpointId'; COM/DLL removal is blocked."
            }
        }
    } finally { $key.Close() }
}

$apoRegistrationPath = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
$comRegistrationPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
if (Test-Path -LiteralPath $apoRegistrationPath) { Remove-Item -LiteralPath $apoRegistrationPath -Recurse -Force -ErrorAction Stop }
if (Test-Path -LiteralPath $comRegistrationPath) { Remove-Item -LiteralPath $comRegistrationPath -Recurse -Force -ErrorAction Stop }
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk') -Force -ErrorAction SilentlyContinue

Restart-Service -Name Audiosrv -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Write-Host "تمت الإزالة. الإعدادات والسجل ما زالت في $dataDir، احذفه يدويًا إن أردت."

if (-not $preflightBackup -or [string]$preflightBackup.DeviceId -notmatch $guidPattern) {
    throw 'backup.json has no valid capture endpoint DeviceId; uninstall stopped before changes.'
}
if ([string]::IsNullOrWhiteSpace([string]$preflightBackup.DevKeySddl)) {
    throw 'backup.json has no endpoint ACL snapshot; uninstall stopped before changes to avoid guessing original permissions.'
}
if (Test-Path -LiteralPath $compositeBackupFile) {
    try {
        $preflightComposite = Get-Content -LiteralPath $compositeBackupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Composite EFX recovery record is unreadable or malformed; uninstall stopped before changes: $($_.Exception.Message)"
    }
    if ([string]$preflightComposite.DeviceId -ne [string]$preflightBackup.DeviceId) {
        throw 'Composite EFX recovery record belongs to another endpoint; uninstall stopped before changes.'
    }
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
    if ($null -ne $b.PrevDisableProtectedAudioDG) { Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value $b.PrevDisableProtectedAudioDG -Type DWord }
    else { Remove-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue }

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

$apoRegistrationPath = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
$comRegistrationPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
if (Test-Path -LiteralPath $apoRegistrationPath) { Remove-Item -LiteralPath $apoRegistrationPath -Recurse -Force -ErrorAction Stop }
if (Test-Path -LiteralPath $comRegistrationPath) { Remove-Item -LiteralPath $comRegistrationPath -Recurse -Force -ErrorAction Stop }
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk') -Force -ErrorAction SilentlyContinue

Restart-Service -Name Audiosrv -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Write-Host "تمت الإزالة. الإعدادات والسجل ما زالت في $dataDir، احذفه يدويًا إن أردت."
