#Requires -RunAsAdministrator
# تثبيت MicBridge APO على المايك المحدد بالاسم. شغّله من PowerShell كمسؤول.
param(
    [string]$DeviceName = 'AT2040USB',
    [string]$DllSource  = (Join-Path $PSScriptRoot 'MicBridgeAPO.dll')
)
$ErrorActionPreference = 'Stop'

$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$iidApo     = '{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'   # PKEY_FX_EndpointEffectClsid
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'
$backupFile = Join-Path $dataDir 'backup.json'
$audioKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Audio'
$capRoot    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'

if (-not (Test-Path $DllSource)) { throw "لم أجد $DllSource . ابنِ المشروع أولًا وضع MicBridgeAPO.dll بجانب السكربت." }

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

function Grant-Key([string]$subPath) {   # subPath نسبةً إلى HKLM
    [TokenPriv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
    [TokenPriv]::Enable('SeRestorePrivilege') | Out-Null
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $k = $hklm.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetOwner($admins); $k.SetAccessControl($acl); $k.Close()
    $k = $hklm.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
    $acl = $k.GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule); $k.SetAccessControl($acl); $k.Close()
}

# ---- 1) إيجاد المايك بالاسم
$matches_ = @()
foreach ($k in Get-ChildItem $capRoot) {
    $state = (Get-ItemProperty -LiteralPath $k.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState
    if ($state -ne 1) { continue }   # الأجهزة النشطة فقط
    $props = Get-ItemProperty -LiteralPath "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    $names = $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [string] }
    if ($names | Where-Object { $_.Value -like "*$DeviceName*" }) {
        $matches_ += [pscustomobject]@{ Id = $k.PSChildName; Names = (($names | Select-Object -First 3 | ForEach-Object Value) -join ' | ') }
    }
}
if ($matches_.Count -eq 0) { throw "لم أجد مايكًا نشطًا يحتوي الاسم '$DeviceName'. تأكد أنه موصول ومفعّل في Recording." }
if ($matches_.Count -gt 1) { $matches_ | Format-Table | Out-String | Write-Host; throw "أكثر من جهاز يطابق الاسم. اكتب اسمًا أدق عبر -DeviceName" }
$dev = $matches_[0]
Write-Host "تم العثور على: $($dev.Names)  ($($dev.Id))"

# ---- 2) نقطة استعادة (قد تفشل إن كانت الحماية معطلة، لا بأس)
try { Checkpoint-Computer -Description 'قبل MicBridge APO' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Host 'تم إنشاء نقطة استعادة' }
catch { Write-Warning "لم تُنشأ نقطة استعادة: $($_.Exception.Message)" }

# ---- 3) النسخ الاحتياطي (لا نكتب فوق نسخة قديمة حتى لا نفقد الأصل)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
if (Test-Path $backupFile) { $backup = Get-Content $backupFile -Raw | ConvertFrom-Json }
else {
    $prevDis = $null
    if (Test-Path $audioKey) { $prevDis = (Get-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue).DisableProtectedAudioDG }
    $fxPath = "$capRoot\$($dev.Id)\FxProperties"
    $prevFx = $null
    if (Test-Path $fxPath) { $prevFx = (Get-ItemProperty -LiteralPath $fxPath -Name $fxValue -ErrorAction SilentlyContinue).$fxValue }
    $backup = [pscustomobject]@{ DeviceId = $dev.Id; PrevDisableProtectedAudioDG = $prevDis; PrevEndpointEffect = $prevFx }
    $backup | ConvertTo-Json | Set-Content $backupFile -Encoding UTF8
}

# ---- 4) الملفات
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item $DllSource (Join-Path $installDir 'MicBridgeAPO.dll') -Force
$ini = Join-Path $dataDir 'MicBridge.ini'
if (-not (Test-Path $ini)) { Copy-Item (Join-Path $PSScriptRoot 'MicBridge.ini') $ini }
icacls $dataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null   # LOCAL SERVICE يكتب السجل

# ---- 5) تسجيل COM و APO
$dllPath = Join-Path $installDir 'MicBridgeAPO.dll'
New-Item -Force "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -Value 'MicBridge APO' | Out-Null
New-Item -Force "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32" -Value $dllPath | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32" -Name ThreadingModel -Value 'Both'
$apo = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
New-Item -Force $apo | Out-Null
Set-ItemProperty $apo FriendlyName 'MicBridge APO'
Set-ItemProperty $apo Copyright 'MicBridge APO'
foreach ($n in 'MajorVersion','MinInputConnections','MaxInputConnections','MinOutputConnections','MaxOutputConnections','NumAPOInterfaces') { Set-ItemProperty $apo $n 1 -Type DWord }
Set-ItemProperty $apo MinorVersion 0 -Type DWord
Set-ItemProperty $apo Flags 15 -Type DWord               # SAMPLESPERFRAME|FRAMESPERSECOND|BITSPERSAMPLE|INPLACE
Set-ItemProperty $apo MaxInstances 0xFFFFFFFF -Type DWord
Set-ItemProperty $apo APOInterface0 $iidApo

# ---- 6) السماح بتحميل APO غير موقّع داخل audiodg
if (-not (Test-Path $audioKey)) { New-Item -Force $audioKey | Out-Null }
Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value 1 -Type DWord

# ---- 7) ربط الـ APO بالمايك
$devSub = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$($dev.Id)"
Grant-Key $devSub
if (-not (Test-Path "$capRoot\$($dev.Id)\FxProperties")) { New-Item "$capRoot\$($dev.Id)\FxProperties" | Out-Null }
Grant-Key "$devSub\FxProperties"
Set-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxValue -Value $clsid -Type String

# ---- 8) إعادة تشغيل خدمة الصوت
Restart-Service -Name Audiosrv -Force
Write-Host "تم التثبيت. أغلق Chrome وأي برنامج يستخدم المايك ثم افتحه من جديد."
Write-Host "الإعدادات: $ini   |   السجل: $(Join-Path $dataDir 'MicBridge.log')"
Write-Host "إن لم يعمل فأعد تشغيل الجهاز مرة واحدة."
