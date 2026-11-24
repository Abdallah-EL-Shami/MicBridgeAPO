# إزالة MicBridge APO وإرجاع كل ما غيّره التثبيت، بما فيه مالك المفتاح وصلاحياته.
param()
$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}

$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0'
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'
$backupFile = Join-Path $dataDir 'backup.json'
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

if (Test-Path $backupFile) {
    $b = Get-Content $backupFile -Raw | ConvertFrom-Json
    $devSub = "$capSub\$($b.DeviceId)"
    $fxSub  = "$devSub\FxProperties"
    $fxPath = "$capRoot\$($b.DeviceId)\FxProperties"

    # 1) القيم (والمفاتيح ما زالت بصلاحيات كاملة للمسؤولين)
    if (Test-Path $fxPath) {
        # Restore only the property owned by this installer.
        if ($b.PrevEndpointEffect) { Set-ItemProperty -LiteralPath $fxPath -Name $fxValue -Value $b.PrevEndpointEffect -Type String }
        else { Remove-ItemProperty -LiteralPath $fxPath -Name $fxValue -ErrorAction SilentlyContinue }

        # Older backup.json files do not contain this field because the old installer
        # never wrote PKEY_FX_Association. In that case, leave the value untouched.
        if ($b.PSObject.Properties.Name -contains 'PrevFxAssociation') {
            if ($b.PrevFxAssociation) { Set-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -Value $b.PrevFxAssociation -Type String }
            else { Remove-ItemProperty -LiteralPath $fxPath -Name $fxAssociationValue -ErrorAction SilentlyContinue }
        }

        # The old installer may have created FxProperties. Delete it only if it is empty;
        # never recursively delete driver/vendor properties added later.
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
    } catch { Write-Warning "تعذر إرجاع الصلاحيات الأصلية: $($_.Exception.Message)" }
} else { Write-Warning 'لم أجد backup.json، سأزيل التسجيل فقط.' }

Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk') -Force -ErrorAction SilentlyContinue

Restart-Service -Name Audiosrv -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Write-Host "تمت الإزالة. الإعدادات والسجل ما زالت في $dataDir، احذفه يدويًا إن أردت."
