# تثبيت MicBridge APO على المايك المحدد بالاسم.
param(
    [string]$DeviceName = 'AT2040USB',
    [string]$DllSource  = (Join-Path $PSScriptRoot 'MicBridgeAPO.dll')
)
$ErrorActionPreference = 'Stop'
Write-InstallLog 'INFO' "Installer started. DeviceName='$DeviceName'; DllSource='$DllSource'."

# رفع الصلاحيات تلقائيًا
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" -DeviceName `"$DeviceName`" -DllSource `"$DllSource`""
    Write-InstallLog 'INFO' 'Requesting administrator elevation.'
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}
Write-InstallLog 'INFO' 'Installer running elevated.'

$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$iidApo     = '{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'   # PKEY_FX_EndpointEffectClsid
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0' # PKEY_FX_Association
$ksNodeTypeAny = '{00000000-0000-0000-0000-000000000000}'
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'
$backupFile = Join-Path $dataDir 'backup.json'
$installLog = Join-Path $dataDir 'Install.log'
$dllBackupPath = $null
$dllReplacementStarted = $false
function Write-InstallLog([string]$Level, [string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Install.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}
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

try {
if (-not (Test-Path $DllSource)) { throw "لم أجد $DllSource . ضع MicBridgeAPO.dll بجانب هذا السكربت." }

# ---- 1) إيجاد المايك بالاسم
$found = @()
foreach ($k in Get-ChildItem $capRoot) {
    $state = (Get-ItemProperty -LiteralPath $k.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState
    if ($state -ne 1) { continue }
    $props = Get-ItemProperty -LiteralPath "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    $names = $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [string] }
    if ($names | Where-Object { $_.Value -like "*$DeviceName*" }) {
        $found += [pscustomobject]@{ Id = $k.PSChildName; Names = (($names | Select-Object -First 3 | ForEach-Object Value) -join ' | ') }
    }
}
if ($found.Count -eq 0) { throw "لم أجد مايكًا نشطًا يحتوي الاسم '$DeviceName'. تأكد أنه موصول ومفعّل في Recording." }
if ($found.Count -gt 1) { $found | Format-Table | Out-String | Write-Host; throw "أكثر من جهاز يطابق الاسم. اكتب اسمًا أدق عبر -DeviceName" }
$dev = $found[0]

# Refuse to reuse a backup created for a different capture endpoint.
# This check happens before checkpoints, file copies, ACL changes, or registry writes.
if (Test-Path -LiteralPath $backupFile) {
    $existingBackup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    if ([string]$existingBackup.DeviceId -ne [string]$dev.Id) {
        throw "ملف النسخة الاحتياطية يخص جهازًا آخر ($($existingBackup.DeviceId)) وليس المايك الحالي ($($dev.Id)). لم يتم إجراء أي تغييرات. لا تحذف backup.json؛ أرسل هذه الرسالة للمراجعة."
    }
    if ($existingBackup.PSObject.Properties.Name -notcontains 'PrevFxAssociation') {
        if (($existingBackup.CreatedFx -eq $true) -and ($null -eq $existingBackup.FxKeySddl)) {
            $existingBackup | Add-Member -NotePropertyName PrevFxAssociation -NotePropertyValue $null
            $existingBackup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupFile -Encoding UTF8
            Write-InstallLog 'WARN' 'Legacy backup safely migrated: original backup proves FxProperties did not exist; original association was absent.'
        } else {
            throw "ملف backup.json قديم ولا يحتوي PrevFxAssociation، ولا توجد بيانات كافية لإثبات قيمتها الأصلية. أوقفت التثبيت دون تخمين أو تعديل النسخة الاحتياطية."
        }
    }
}
Write-Host "تم العثور على: $($dev.Names)  ($($dev.Id))"
$devSub = "$capSub\$($dev.Id)"
$fxSub  = "$devSub\FxProperties"

# ---- 2) نقطة استعادة (قد تفشل، لا بأس)
try { Checkpoint-Computer -Description 'قبل MicBridge APO' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Host 'تم إنشاء نقطة استعادة' }
catch { Write-Warning "لم تُنشأ نقطة استعادة: $($_.Exception.Message)" }

# ---- 3) النسخ الاحتياطي، بما فيه الصلاحيات الأصلية SDDL. لا نكتب فوق نسخة قديمة حتى لا نفقد الأصل.
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
if (-not (Test-Path $backupFile)) {
    $prevDis = $null
    if (Test-Path $audioKey) { $prevDis = (Get-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue).DisableProtectedAudioDG }
    $fxExists = Test-Path "$capRoot\$($dev.Id)\FxProperties"
    $prevFx = $null
    if ($fxExists) { $prevFx = (Get-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxValue -ErrorAction SilentlyContinue).$fxValue }
    $devSddl = Get-Sddl $devSub
    $fxSddl  = if ($fxExists) { Get-Sddl $fxSub } else { $null }
    if (-not $devSddl) { throw 'تعذر قراءة صلاحيات مفتاح المايك، ألغيت التثبيت قبل أي تغيير.' }
    $backup = [pscustomobject]@{
        DeviceId = $dev.Id; PrevDisableProtectedAudioDG = $prevDis; PrevEndpointEffect = $prevFx
        PrevFxAssociation = if ($fxExists) { (Get-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxAssociationValue -ErrorAction SilentlyContinue).$fxAssociationValue } else { $null }
        DevKeySddl = $devSddl; FxKeySddl = $fxSddl; CreatedFx = (-not $fxExists)
    }
    $backup | ConvertTo-Json -Depth 5 | Set-Content $backupFile -Encoding UTF8
    Write-Host "حُفظت القيم والصلاحيات الأصلية في $backupFile"
} else {
    $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    Write-InstallLog 'INFO' 'Existing backup validated and retained; registry state was not used to guess historical values.'
}

# ---- 4) الملفات
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$installedDll = Join-Path $installDir 'MicBridgeAPO.dll'
if (Test-Path -LiteralPath $installedDll) {
    $dllBackupDir = Join-Path $dataDir 'dll-backups'
    New-Item -ItemType Directory -Force -Path $dllBackupDir | Out-Null
    $dllBackupPath = Join-Path $dllBackupDir ("MicBridgeAPO-{0}.dll" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Copy-Item -LiteralPath $installedDll -Destination $dllBackupPath -ErrorAction Stop
    Write-InstallLog 'INFO' "Previous DLL backed up to '$dllBackupPath'. SHA256=$((Get-FileHash -LiteralPath $dllBackupPath -Algorithm SHA256).Hash)"
}
$dllReplacementStarted = $true
Copy-Item -LiteralPath $DllSource -Destination $installedDll -Force -ErrorAction Stop
Write-InstallLog 'INFO' "New DLL copied. SHA256=$((Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash)"
foreach ($f in 'MicBridgeUI.ps1','uninstall.ps1','uninstall.bat') { if (Test-Path (Join-Path $PSScriptRoot $f)) { Copy-Item (Join-Path $PSScriptRoot $f) $installDir -Force } }
$ini = Join-Path $dataDir 'MicBridge.ini'
if (-not (Test-Path $ini)) { Copy-Item (Join-Path $PSScriptRoot 'MicBridge.ini') $ini }
$ctrl = Join-Path $dataDir 'control.ini'
if (-not (Test-Path $ctrl)) { Set-Content $ctrl "[Control]`r`nEnabled=1`r`n" -Encoding ASCII }
icacls $dataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null    # LOCAL SERVICE: يكتب السجل والحالة
icacls $ctrl    /grant '*S-1-5-32-545:M'      | Out-Null    # المستخدمون: يغيّرون التشغيل/الإيقاف من الواجهة

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
Set-ItemProperty $apo Flags 15 -Type DWord
Set-ItemProperty $apo MaxInstances 0xFFFFFFFF -Type DWord
Set-ItemProperty $apo APOInterface0 $iidApo

# ---- 6) السماح بتحميل APO غير موقّع داخل audiodg
if (-not (Test-Path $audioKey)) { New-Item -Force $audioKey | Out-Null }
Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value 1 -Type DWord

# ---- 7) ربط الـ APO بالمايك (مع أخذ ملكية المفتاح مؤقتًا؛ تُعاد عند الإزالة)
[TokenPriv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
[TokenPriv]::Enable('SeRestorePrivilege') | Out-Null
function Grant-Key([string]$sub) {
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $k = $hklm.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetOwner($admins); $k.SetAccessControl($acl); $k.Close()
    $k = $hklm.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
    $acl = $k.GetAccessControl()
    $acl.SetAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
    $k.SetAccessControl($acl); $k.Close()
}
Grant-Key $devSub
if (-not (Test-Path "$capRoot\$($dev.Id)\FxProperties")) { New-Item "$capRoot\$($dev.Id)\FxProperties" | Out-Null }
Grant-Key $fxSub
Set-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxAssociationValue -Value $ksNodeTypeAny -Type String
Set-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxValue -Value $clsid -Type String

# ---- 8) اختصار الواجهة على سطح المكتب
try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk'))
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\MicBridgeUI.ps1`""
    $lnk.Save()
} catch { Write-Warning "لم يُنشأ اختصار سطح المكتب: $($_.Exception.Message)" }

# ---- 9) إعادة تشغيل خدمة الصوت
Write-InstallLog 'INFO' 'Restarting Audiosrv.'
Restart-Service -Name Audiosrv -Force
Write-InstallLog 'INFO' 'Installation completed successfully.'
Write-Host ""
Write-Host "تم التثبيت. أغلق Chrome وأي برنامج يستخدم المايك ثم افتحه من جديد."
Write-Host "الواجهة: اختصار MicBridge على سطح المكتب."
Write-Host "الإعدادات: $ini   |   سجل الصوت: $(Join-Path $dataDir 'MicBridge.log')"
Write-Host "سجل التثبيت: $installLog"
Write-Host "إن لم يعمل فأعد تشغيل الجهاز مرة واحدة."
} catch {
    $failure = $_
    Write-InstallLog 'ERROR' "Installation failed: $($failure.Exception.ToString())"
    Write-InstallLog 'ERROR' "Error position: $($failure.InvocationInfo.PositionMessage)"
    if ($dllReplacementStarted -and $dllBackupPath -and (Test-Path -LiteralPath $dllBackupPath)) {
        try {
            Copy-Item -LiteralPath $dllBackupPath -Destination (Join-Path $installDir 'MicBridgeAPO.dll') -Force -ErrorAction Stop
            Write-InstallLog 'WARN' "Previous DLL restored from '$dllBackupPath'."
        } catch { Write-InstallLog 'CRITICAL' "DLL restoration failed: $($_.Exception.ToString())" }
    }
    Write-InstallLog 'WARN' 'Registry/endpoint changes are not automatically rolled back; retain backup.json and request review.'
    Write-Host ""
    Write-Host "فشل التثبيت: $($failure.Exception.Message)" -ForegroundColor Red
    Write-Host "سجل التثبيت: $installLog" -ForegroundColor Yellow
    Write-Warning "قد تكون بعض تغييرات Registry قد نُفذت. لا تشغّل uninstall.bat ولا تحذف backup.json؛ أرسل Install.log للمراجعة."
}
