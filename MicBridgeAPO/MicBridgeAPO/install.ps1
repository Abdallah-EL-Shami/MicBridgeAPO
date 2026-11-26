# تثبيت MicBridge APO على المايك المحدد بالاسم.
param(
    [string]$DeviceName = 'AT2040USB',
    [string]$DllSource  = (Join-Path $PSScriptRoot 'MicBridgeAPO.dll')
)
$ErrorActionPreference = 'Stop'

# رفع الصلاحيات تلقائيًا
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" -DeviceName `"$DeviceName`" -DllSource `"$DllSource`""
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}

# Serialize the complete installer/rollback operation.
$recoveryModule = Join-Path $PSScriptRoot 'tools\MicBridge.RecoveryJournal.psm1'
Import-Module -Name $recoveryModule -Force -ErrorAction Stop
$operationLockPath = Join-Path (Join-Path $env:ProgramData 'MicBridgeAPO') 'operation'
$operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0

 
$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$iidApo     = '{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'   # PKEY_FX_EndpointEffectClsid
$fxCompositeValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15' # PKEY_CompositeFX_EndpointEffectClsid (REG_MULTI_SZ)
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0' # PKEY_FX_Association
$ksNodeTypeAny = '{00000000-0000-0000-0000-000000000000}'
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'

# Fail closed when a prior install rollback was interrupted. Until the full
# replay handler is available, never start a new transaction over uncertain state.
if (Test-Path -LiteralPath $dataDir -PathType Container) {
    $pendingRollbackJournals = @()
    foreach ($transactionFolder in @(Get-ChildItem -LiteralPath $dataDir -Directory -Filter 'transactions-*' -ErrorAction Stop)) {
        $candidateJournal = Join-Path $transactionFolder.FullName 'rollback-recovery.json'
        if (-not (Test-Path -LiteralPath $candidateJournal -PathType Leaf)) { continue }
        $candidateState = Read-MBRecoveryJournal -Path $candidateJournal -ExpectedOperation InstallRollback
        $candidateSnapshotPath = Join-Path $transactionFolder.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $candidateSnapshotPath -PathType Leaf)) {
            throw "Interrupted install rollback has no transaction snapshot: $candidateSnapshotPath"
        }
        $candidateSnapshot = Get-Content -LiteralPath $candidateSnapshotPath -Raw | ConvertFrom-Json
        $snapshotTransactionId = [guid]::Empty
        if (-not [guid]::TryParse([string]$candidateSnapshot.TransactionId,[ref]$snapshotTransactionId) -or
            $snapshotTransactionId.ToString('D') -ne [string]$candidateState.TransactionId) {
            throw "Interrupted install rollback journal/snapshot transaction identity mismatch: $candidateJournal"
        }
        $unfinished = @($candidateState.Steps | Where-Object { $_.State -ne 'Completed' })
        if ($unfinished.Count -gt 0) {
            $pendingRollbackJournals += $candidateJournal
        }
    }
    if ($pendingRollbackJournals.Count -gt 0) {
        $paths = $pendingRollbackJournals -join '; '
        throw "An interrupted MicBridge installation rollback was detected. A new installation is blocked to protect the previous device state. Recovery replay is not yet automated; preserve these transaction folders and use the recovery procedure: $paths"
    }
}
$compositeBackupFile = Join-Path $dataDir 'composite-efx-backup.json'
$backupFile = Join-Path $dataDir 'backup.json'
$installLog = Join-Path $dataDir 'Install.log'
$dllBackupPath = $null
$dllBackupHash = $null
$dllReplacementStarted = $false
function Write-JsonAtomic([object]$Value, [string]$Path, [int]$Depth = 8) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temp = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $replacementBackup = $null
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth $Depth
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            # File.Replace requires a real backup path on supported .NET runtimes.
            # Keep it beside the target so replacement remains on the same volume.
            $replacementBackup = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.replace.' + [guid]::NewGuid().ToString('N') + '.bak')
            [IO.File]::Replace($temp, $Path, $replacementBackup, $true)
        }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($replacementBackup -and (Test-Path -LiteralPath $replacementBackup)) {
            Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
        }
    }
}
function Write-InstallLog([string]$Level, [string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Install.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}
Write-InstallLog 'INFO' "Installer started with administrative privileges. DeviceName='$DeviceName'; DllSource='$DllSource'."
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

function Get-RegistryValueSnapshot([string]$sub, [string]$name) {
    $key = $hklm.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [Microsoft.Win32.RegistryRights]::ReadKey)
    if (-not $key) { return [pscustomobject]@{ KeyExists=$false; Exists=$false; Kind='String'; Value=$null } }
    try {
        if ($key.GetValueNames() -notcontains $name) { return [pscustomobject]@{ KeyExists=$true; Exists=$false; Kind='String'; Value=$null } }
        $kind = $key.GetValueKind($name)
        $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{ KeyExists=$true; Exists=$true; Kind=[string]$kind; Value=$value }
    } finally { $key.Close() }
}
function Restore-RegistryValueSnapshot([string]$sub, [string]$name, $snapshot) {
    if ($snapshot.Exists) {
        $key = $hklm.CreateSubKey($sub)
        if (-not $key) { throw "تعذر إنشاء/فتح مفتاح Registry: $sub" }
        try {
            $kind = [System.Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$snapshot.Kind)
            $value = $snapshot.Value
            if ($kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) { $value = [string[]]@($value) }
            $key.SetValue($name, $value, $kind)
        } finally { $key.Close() }
    } elseif ($snapshot.KeyExists) {
        $key = $hklm.OpenSubKey($sub, $true)
        if ($key) { try { $key.DeleteValue($name, $false) } finally { $key.Close() } }
    }
}

function Test-RegistryValueSnapshot([string]$sub, [string]$name, $snapshot) {
    $actual = Get-RegistryValueSnapshot $sub $name
    if ([bool]$actual.KeyExists -ne [bool]$snapshot.KeyExists -or [bool]$actual.Exists -ne [bool]$snapshot.Exists) { return $false }
    if (-not $snapshot.Exists) { return $true }
    if ([string]$actual.Kind -ne [string]$snapshot.Kind) { return $false }
    $left = ConvertTo-Json -InputObject $actual.Value -Depth 8 -Compress
    $right = ConvertTo-Json -InputObject $snapshot.Value -Depth 8 -Compress
    return [string]::Equals($left,$right,[StringComparison]::Ordinal)
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
    if ($existingBackup.PSObject.Properties.Name -notcontains 'ComRegistrationSnapshotVersion' -or [int]$existingBackup.ComRegistrationSnapshotVersion -ne 1) {
        throw 'The existing backup predates persistent COM recovery data. Its original COM state cannot be reconstructed safely; refusing an in-place upgrade that would make uninstall destructive.'
    }
    if ([string]$existingBackup.DeviceId -ne [string]$dev.Id) {
        throw "ملف النسخة الاحتياطية يخص جهازًا آخر ($($existingBackup.DeviceId)) وليس المايك الحالي ($($dev.Id)). لم يتم إجراء أي تغييرات. لا تحذف backup.json؛ أرسل هذه الرسالة للمراجعة."
    }
    if ($existingBackup.PSObject.Properties.Name -notcontains 'PrevFxAssociation') {
        if (($existingBackup.CreatedFx -eq $true) -and ($null -eq $existingBackup.FxKeySddl)) {
            $existingBackup | Add-Member -NotePropertyName PrevFxAssociation -NotePropertyValue $null
            Write-InstallLog 'WARN' 'Legacy backup compatibility field added in memory only; original backup.json was left byte-for-byte unchanged.'
        } else {
            throw "ملف backup.json قديم ولا يحتوي PrevFxAssociation، ولا توجد بيانات كافية لإثبات قيمتها الأصلية. أوقفت التثبيت دون تخمين أو تعديل النسخة الاحتياطية."
        }
    }
    $backup = $existingBackup
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
    $fxExists = Test-Path "$capRoot\$($dev.Id)\FxProperties"
    $prevFx = $null
    if ($fxExists) { $prevFx = (Get-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxValue -ErrorAction SilentlyContinue).$fxValue }
    $devSddl = Get-Sddl $devSub
    $fxSddl  = if ($fxExists) { Get-Sddl $fxSub } else { $null }
    if (-not $devSddl) { throw 'تعذر قراءة صلاحيات مفتاح المايك، ألغيت التثبيت قبل أي تغيير.' }
    # Persist the pre-MicBridge COM registrations outside the temporary transaction directory.
    # These files survive successful installation and are consumed by the uninstaller.
    $comBackupDir = Join-Path $dataDir 'com-registration-backup'
    New-Item -ItemType Directory -Force -Path $comBackupDir | Out-Null
    $comClsidPath = "HKLM\SOFTWARE\Classes\CLSID\$clsid"
    $comApoPath = "HKLM\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
    $prevClsidRegistrationExists = Test-Path -LiteralPath "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
    $prevApoRegistrationExists = Test-Path -LiteralPath "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
    $prevClsidRegistrationFile = Join-Path $comBackupDir 'previous-clsid.reg'
    $prevApoRegistrationFile = Join-Path $comBackupDir 'previous-audioengine-apo.reg'
    if ($prevClsidRegistrationExists) { & reg.exe export $comClsidPath $prevClsidRegistrationFile /y | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Could not persist the original COM CLSID registration.' } }
    if ($prevApoRegistrationExists) { & reg.exe export $comApoPath $prevApoRegistrationFile /y | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Could not persist the original AudioEngine APO registration.' } }
    $backup = [pscustomobject]@{
        ComRegistrationSnapshotVersion = 1
        PrevClsidRegistrationExists = $prevClsidRegistrationExists
        PrevApoRegistrationExists = $prevApoRegistrationExists
        PrevClsidRegistrationFile = $prevClsidRegistrationFile
        PrevApoRegistrationFile = $prevApoRegistrationFile
        PrevClsidRegistrationSha256 = if ($prevClsidRegistrationExists) { (Get-FileHash -LiteralPath $prevClsidRegistrationFile -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
        PrevApoRegistrationSha256 = if ($prevApoRegistrationExists) { (Get-FileHash -LiteralPath $prevApoRegistrationFile -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
        DeviceId = $dev.Id; PrevEndpointEffect = $prevFx
        PrevFxAssociation = if ($fxExists) { (Get-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxAssociationValue -ErrorAction SilentlyContinue).$fxAssociationValue } else { $null }
        DevKeySddl = $devSddl; FxKeySddl = $fxSddl; CreatedFx = (-not $fxExists)
    }
    Write-JsonAtomic -Value $backup -Path $backupFile -Depth 8
    Write-Host "حُفظت القيم والصلاحيات الأصلية في $backupFile"
} else {
    Write-InstallLog 'INFO' 'Existing backup validated and retained; registry state was not used to guess historical values.'
}

# Preserve the composite EFX list separately from the immutable first-install backup.
# This value is REG_MULTI_SZ on Windows 10 1803+ and allows coexisting endpoint APOs.
if (-not (Test-Path -LiteralPath $compositeBackupFile)) {
    $fxKey = $hklm.OpenSubKey($fxSub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [Microsoft.Win32.RegistryRights]::ReadKey)
    $compositeExists = $false; $compositeKind = 'MultiString'; $compositeValue = @()
    if ($fxKey) {
        try {
            if ($fxKey.GetValueNames() -contains $fxCompositeValue) {
                $compositeExists = $true
                $compositeKind = [string]$fxKey.GetValueKind($fxCompositeValue)
                if ($compositeKind -ne 'MultiString') { throw "Composite EFX registry value has unexpected type '$compositeKind'; refusing to overwrite it." }
                $compositeValue = @($fxKey.GetValue($fxCompositeValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
            }
        } finally { $fxKey.Close() }
    }
    if (-not $compositeExists -and $backup.PrevEndpointEffect -and [string]$backup.PrevEndpointEffect -ne $clsid) {
        $compositeValue = @([string]$backup.PrevEndpointEffect)
    }
    Write-JsonAtomic -Value ([pscustomobject]@{ DeviceId=$dev.Id; Exists=$compositeExists; Kind=$compositeKind; Value=$compositeValue }) -Path $compositeBackupFile -Depth 5
    Write-InstallLog 'INFO' 'Captured original composite EFX state in a separate recovery record.'
} else {
    $compositeState = Get-Content -LiteralPath $compositeBackupFile -Raw | ConvertFrom-Json
    if ([string]$compositeState.DeviceId -ne [string]$dev.Id) { throw 'Composite EFX recovery record belongs to a different endpoint; refusing installation.' }
}

# Verify the package DLL before creating any transaction state.
if (-not (Test-Path -LiteralPath $DllSource -PathType Leaf)) { throw "DLL source is missing or is not a regular file: $DllSource" }
$dllSourceHash = (Get-FileHash -LiteralPath $DllSource -Algorithm SHA256 -ErrorAction Stop).Hash
$installedDllCandidate = Join-Path $installDir 'MicBridgeAPO.dll'
if ((Test-Path -LiteralPath $installedDllCandidate) -and -not (Test-Path -LiteralPath $installedDllCandidate -PathType Leaf)) {
    throw 'Installed DLL destination exists but is not a regular file; refusing to replace it.'
}

# Snapshot the currently installed state for transaction rollback. This is separate
# from backup.json, which remains the immutable pre-first-install recovery record.
$transactionId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$transactionDir = Join-Path $dataDir ("transactions-" + $transactionId)
New-Item -ItemType Directory -Force -Path $transactionDir | Out-Null
$transactionStateFile = Join-Path $transactionDir 'state.json'
$clsidRegBackup = Join-Path $transactionDir 'clsid.reg'
$apoRegBackup = Join-Path $transactionDir 'audioengine-apo.reg'
$clsidRegExisted = Test-Path -LiteralPath "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
$apoRegExisted = Test-Path -LiteralPath "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
if ($clsidRegExisted) { & reg.exe export "HKLM\SOFTWARE\Classes\CLSID\$clsid" $clsidRegBackup /y | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Could not snapshot the existing COM CLSID registration.' } }
if ($apoRegExisted) { & reg.exe export "HKLM\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" $apoRegBackup /y | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Could not snapshot the existing AudioEngine APO registration.' } }
$fxNowSub = "$capSub\$($dev.Id)\FxProperties"
$installFilesBackup = @()
$installFilesDir = Join-Path $transactionDir 'install-files'
New-Item -ItemType Directory -Force -Path $installFilesDir | Out-Null
foreach ($name in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
    $target = Join-Path $installDir $name
    $backupPath = Join-Path $installFilesDir $name
    $existed = Test-Path -LiteralPath $target
    $backupHash = $null
    if ($existed) {
        Copy-Item -LiteralPath $target -Destination $backupPath -Force -ErrorAction Stop
        $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $installFilesBackup += [pscustomobject]@{ Name=$name; Existed=$existed; Backup=$backupPath; Sha256=$backupHash }
}
$shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk'
$shortcutBackup = Join-Path $transactionDir 'MicBridge.lnk'
$shortcutExisted = Test-Path -LiteralPath $shortcutPath
$shortcutBackupSha256 = $null
if ($shortcutExisted) {
    Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup -Force -ErrorAction Stop
    $shortcutBackupSha256 = (Get-FileHash -LiteralPath $shortcutBackup -Algorithm SHA256 -ErrorAction Stop).Hash
}
$controlPath = Join-Path $dataDir 'control.ini'
$controlSddl = if (Test-Path -LiteralPath $controlPath) { (Get-Acl -LiteralPath $controlPath).Sddl } else { $null }
$dataDirSddl = (Get-Acl -LiteralPath $dataDir).Sddl
$transactionState = [pscustomobject]@{
    DeviceId = $dev.Id
    FxEffect = (Get-RegistryValueSnapshot $fxNowSub $fxValue)
    FxAssociation = (Get-RegistryValueSnapshot $fxNowSub $fxAssociationValue)
    FxComposite = (Get-RegistryValueSnapshot $fxNowSub $fxCompositeValue)
    DevSddl = (Get-Sddl $devSub)
    FxSddl = (Get-Sddl $fxSub)
    FxKeyExisted = (Test-Path -LiteralPath "$capRoot\$($dev.Id)\FxProperties")
    ClsidRegExisted = $clsidRegExisted
    ClsidRegBackup = if ($clsidRegExisted) { $clsidRegBackup } else { $null }
    ClsidRegSha256 = if ($clsidRegExisted) { (Get-FileHash -LiteralPath $clsidRegBackup -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
    ApoRegExisted = $apoRegExisted
    ApoRegBackup = if ($apoRegExisted) { $apoRegBackup } else { $null }
    ApoRegSha256 = if ($apoRegExisted) { (Get-FileHash -LiteralPath $apoRegBackup -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
    DllExisted = (Test-Path -LiteralPath (Join-Path $installDir 'MicBridgeAPO.dll'))
    DllOriginalSha256 = if (Test-Path -LiteralPath (Join-Path $installDir 'MicBridgeAPO.dll') -PathType Leaf) { (Get-FileHash -LiteralPath (Join-Path $installDir 'MicBridgeAPO.dll') -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
    DllNewSha256 = $dllSourceHash
    DllReplacementStarted = $false
    IniExisted = (Test-Path -LiteralPath (Join-Path $dataDir 'MicBridge.ini'))
    ControlExisted = (Test-Path -LiteralPath (Join-Path $dataDir 'control.ini'))
    DataDirSddl = $dataDirSddl
    ControlSddl = $controlSddl
    InstallFiles = $installFilesBackup
    ShortcutExisted = $shortcutExisted
    ShortcutBackup = $shortcutBackup
    ShortcutBackupSha256 = $shortcutBackupSha256
    InstallDirExisted = (Test-Path -LiteralPath $installDir)
}
if ($transactionState.FxComposite.Exists -and [string]$transactionState.FxComposite.Kind -ne 'MultiString') {
    throw "Current composite EFX value has unexpected type '$($transactionState.FxComposite.Kind)'; refusing to overwrite it."
}
Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10

# Durable rollback journal is created from the verified pre-install snapshot.
$rollbackJournalPath = Join-Path $transactionDir 'rollback-recovery.json'
$rollbackDeviceId = [guid]$dev.Id
$rollbackStepIds = @('RestorePreviousInstallState')
$rollbackJournal = New-MBRecoveryJournal -Path $rollbackJournalPath -Operation InstallRollback -DeviceId $rollbackDeviceId -StepIds $rollbackStepIds
$transactionState.TransactionId = [string]$rollbackJournal.TransactionId
Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10


# ---- 4) الملفات
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$installedDll = Join-Path $installDir 'MicBridgeAPO.dll'
if (Test-Path -LiteralPath $installedDll) {
    $dllBackupDir = Join-Path $dataDir 'dll-backups'
    New-Item -ItemType Directory -Force -Path $dllBackupDir | Out-Null
    $dllBackupPath = Join-Path $dllBackupDir ("MicBridgeAPO-{0}.dll" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Copy-Item -LiteralPath $installedDll -Destination $dllBackupPath -ErrorAction Stop
    $dllBackupHash = (Get-FileHash -LiteralPath $dllBackupPath -Algorithm SHA256).Hash
    # Persist rollback-critical DLL provenance before replacing the installed binary.
    $transactionState.DllBackupPath = $dllBackupPath
    $transactionState.DllBackupSha256 = $dllBackupHash
    $transactionState.DllReplacementStarted = $false
    Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10
    Write-InstallLog 'INFO' "Previous DLL backed up to '$dllBackupPath'. SHA256=$dllBackupHash"
}
# Stage on the same volume, verify bytes, then atomically publish the new DLL.
# File.Replace fails closed if Windows has the current image mapped/locked.
$stagedDll = Join-Path $installDir ('.MicBridgeAPO.install.' + [guid]::NewGuid().ToString('N') + '.tmp')
$publishBackup = $null
try {
    Copy-Item -LiteralPath $DllSource -Destination $stagedDll -ErrorAction Stop
    $stageStream = [IO.File]::Open($stagedDll,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try { $stageStream.Flush($true) } finally { $stageStream.Dispose() }
    $stagedDllHash = (Get-FileHash -LiteralPath $stagedDll -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($stagedDllHash,$dllSourceHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged DLL hash differs from the verified package source.'
    }
    # Persist the intent and exact new-file identity before the atomic publish.
    $transactionState.DllReplacementStarted = $true
    Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10
    if ([bool]$transactionState.DllExisted) {
        if (-not (Test-Path -LiteralPath $installedDll -PathType Leaf)) {
            throw 'Previously installed DLL disappeared before publish; refusing to change an unexpected destination state.'
        }
        $currentInstalledHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($currentInstalledHash,[string]$transactionState.DllOriginalSha256,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Installed DLL changed after transaction snapshot; refusing to overwrite an unowned file.'
        }
    } elseif (Test-Path -LiteralPath $installedDll) {
        throw 'A DLL appeared at the installation destination after transaction snapshot; refusing to overwrite it.'
    }
    if (Test-Path -LiteralPath $installedDll -PathType Leaf) {
        # Preserve the replaced image until the published DLL hash is verified.
        $publishBackup = Join-Path $installDir ('.MicBridgeAPO.publish.' + [guid]::NewGuid().ToString('N') + '.bak')
        [IO.File]::Replace($stagedDll,$installedDll,$publishBackup,$false)
    } elseif (Test-Path -LiteralPath $installedDll) {
        throw 'Installed DLL destination changed to a non-file before publish.'
    } else {
        [IO.File]::Move($stagedDll,$installedDll)
    }
} finally {
    if (Test-Path -LiteralPath $stagedDll) { Remove-Item -LiteralPath $stagedDll -Force -ErrorAction SilentlyContinue }
}
$publishedDllHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256 -ErrorAction Stop).Hash
if (-not [string]::Equals($publishedDllHash,$dllSourceHash,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Published DLL hash differs from the verified package source.'
}
if ($publishBackup -and (Test-Path -LiteralPath $publishBackup -PathType Leaf)) {
    Remove-Item -LiteralPath $publishBackup -Force -ErrorAction Stop
}
Write-InstallLog 'INFO' "New DLL atomically published. SHA256=$publishedDllHash"
foreach ($f in 'MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat') { if (Test-Path (Join-Path $PSScriptRoot $f)) { Copy-Item (Join-Path $PSScriptRoot $f) $installDir -Force } }
$ini = Join-Path $dataDir 'MicBridge.ini'
if (-not (Test-Path $ini)) { Copy-Item (Join-Path $PSScriptRoot 'MicBridge.ini') $ini }
$ctrl = Join-Path $dataDir 'control.ini'
if (-not (Test-Path $ctrl)) { Set-Content $ctrl "[Control]`r`nEnabled=1`r`n" -Encoding ASCII }
& icacls.exe $dataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed for $dataDir with exit code $LASTEXITCODE" }
& icacls.exe $ctrl /grant '*S-1-5-32-545:M' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed for $ctrl with exit code $LASTEXITCODE" }

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

# ---- 6) إعداد حماية Windows AudioDG
# MicBridge never changes DisableProtectedAudioDG. Older releases captured it from an incorrect path.
Write-InstallLog 'INFO' 'Windows AudioDG protection setting left unchanged.'

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
$associationToUse = if ($transactionState.FxAssociation.Exists) { [string]$transactionState.FxAssociation.Value } else { $ksNodeTypeAny }
Set-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxAssociationValue -Value $associationToUse -Type String

# Build the live EFX chain from the endpoint's CURRENT driver state, never from
# backup.json. On a clean endpoint with no vendor EFX this naturally starts empty.
# Keep the legacy single-CLSID property untouched; CompositeFX is the multi-APO
# registration used on Windows 10 version 1803 and later.
$efxList = @()
if ($transactionState.FxComposite.Exists) {
    $efxList = @($transactionState.FxComposite.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
} elseif ($transactionState.FxEffect.Exists -and [string]$transactionState.FxEffect.Value -ne $clsid) {
    $efxList = @([string]$transactionState.FxEffect.Value)
}
# Replace only our own CLSID and retain the current vendor list, including later driver updates.
$efxList = @($efxList | Where-Object { [string]$_ -ne $clsid })
$efxList += $clsid
Set-ItemProperty -LiteralPath "$capRoot\$($dev.Id)\FxProperties" -Name $fxCompositeValue -Value ([string[]]$efxList) -Type MultiString
Write-InstallLog 'INFO' ("Registered composite EFX list: {0}" -f ($efxList -join '; '))

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
try { Remove-Item -LiteralPath $transactionDir -Recurse -Force -ErrorAction Stop } catch { Write-InstallLog 'WARN' "Could not remove completed transaction snapshot: $($_.Exception.Message)" }
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
    if ($transactionStateFile -and (Test-Path -LiteralPath $transactionStateFile)) {
        try {
            # Validate every durable rollback input before touching Registry, ACLs, COM, or files.
            $rollbackValidationModule = Join-Path $PSScriptRoot 'tools\MicBridge.InstallRollbackValidation.psm1'
            Import-Module -Name $rollbackValidationModule -Force -ErrorAction Stop
            $rollbackSnapshot = Get-Content -LiteralPath $transactionStateFile -Raw | ConvertFrom-Json
            $rollbackValidation = Test-MBInstallRollbackSnapshot -State $rollbackSnapshot -TransactionDirectory $transactionDir -DataDirectory $dataDir -ExpectedDeviceId $rollbackDeviceId
            if (-not $rollbackValidation.IsValid -or -not $rollbackValidation.ReplaySafe) {
                throw "Rollback snapshot validation failed; no rollback mutations were attempted. $($rollbackValidation.Errors -join '; ')"
            }
            $rollbackJournal = Read-MBRecoveryJournal -Path $rollbackJournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $rollbackDeviceId -ExpectedStepIds $rollbackStepIds
            if ([string]$rollbackSnapshot.TransactionId -ne [string]$rollbackJournal.TransactionId) {
                throw 'Rollback journal and snapshot belong to different transactions; no rollback mutations were attempted.'
            }
            Invoke-MBRecoveryStep -Path $rollbackJournalPath -StepId 'RestorePreviousInstallState' -ExpectedOperation InstallRollback -ExpectedDeviceId $rollbackDeviceId -ExpectedStepIds $rollbackStepIds -Action {
                        # Reload the durable snapshot: process-local variables are not recovery evidence.
                        $tx = Get-Content -LiteralPath $transactionStateFile -Raw | ConvertFrom-Json
                        if ([bool]$tx.DllReplacementStarted) {
                            $dllRollbackModule = Join-Path $PSScriptRoot 'tools\MicBridge.InstallRollbackActions.psm1'
                            Import-Module -Name $dllRollbackModule -Force -ErrorAction Stop
                            $dllRollbackArgs = @{
                                InstalledDllPath=(Join-Path $installDir 'MicBridgeAPO.dll')
                                DllExisted=[bool]$tx.DllExisted
                                ReplacementStarted=$true
                                OriginalSha256=[string]$tx.DllOriginalSha256
                                BackupPath=[string]$tx.DllBackupPath
                                BackupSha256=[string]$tx.DllBackupSha256
                                BackupRoot=(Join-Path $dataDir 'dll-backups')
                                NewDllSha256=[string]$tx.DllNewSha256
                                InstallRoot=$installDir
                            }
                            Restore-MBDllSnapshot @dllRollbackArgs | Out-Null
                            Write-InstallLog 'INFO' 'DLL rollback action completed and verified against transaction hashes.'
                        }
                        # Roll back this installation attempt to the immediately preceding installed state.
                            $fxNowSub = "$capSub\$($tx.DeviceId)\FxProperties"
                            Restore-RegistryValueSnapshot $fxNowSub $fxValue $tx.FxEffect
                            Restore-RegistryValueSnapshot $fxNowSub $fxAssociationValue $tx.FxAssociation
                            Restore-RegistryValueSnapshot $fxNowSub $fxCompositeValue $tx.FxComposite
                            if ($tx.FxSddl -and (Test-Path -LiteralPath "$capRoot\$($tx.DeviceId)\FxProperties")) { Restore-Sddl "$capSub\$($tx.DeviceId)\FxProperties" $tx.FxSddl }
                            if ($tx.DevSddl) { Restore-Sddl "$capSub\$($tx.DeviceId)" $tx.DevSddl }
                            if (-not $tx.FxKeyExisted) {
                                $fxNowPath = "$capRoot\$($tx.DeviceId)\FxProperties"
                                if (Test-Path -LiteralPath $fxNowPath) {
                                    $fxKey = $hklm.OpenSubKey("$capSub\$($tx.DeviceId)\FxProperties")
                                    if ($fxKey) { $empty = ($fxKey.GetValueNames().Count -eq 0 -and $fxKey.GetSubKeyNames().Count -eq 0); $fxKey.Close(); if ($empty) { Remove-Item -LiteralPath $fxNowPath -Force } }
                                }
                            }
                            $clsidPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
                            $apoPath = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
                            Remove-Item -LiteralPath $clsidPath -Recurse -Force -ErrorAction SilentlyContinue
                            Remove-Item -LiteralPath $apoPath -Recurse -Force -ErrorAction SilentlyContinue
                            if ($tx.ClsidRegExisted -and (Test-Path -LiteralPath (Join-Path $transactionDir 'clsid.reg'))) { & reg.exe import (Join-Path $transactionDir 'clsid.reg') | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Failed to restore prior COM CLSID registration.' } }
                            if ($tx.ApoRegExisted -and (Test-Path -LiteralPath (Join-Path $transactionDir 'audioengine-apo.reg'))) { & reg.exe import (Join-Path $transactionDir 'audioengine-apo.reg') | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Failed to restore prior AudioEngine APO registration.' } }
                            if (-not $tx.IniExisted) { Remove-Item -LiteralPath (Join-Path $dataDir 'MicBridge.ini') -Force -ErrorAction SilentlyContinue }
                            if (-not $tx.ControlExisted) { Remove-Item -LiteralPath (Join-Path $dataDir 'control.ini') -Force -ErrorAction SilentlyContinue }
                            foreach ($fileState in @($tx.InstallFiles)) {
                                $target = Join-Path $installDir $fileState.Name
                                if ($fileState.Existed -and (Test-Path -LiteralPath $fileState.Backup)) {
                                    Copy-Item -LiteralPath $fileState.Backup -Destination $target -Force -ErrorAction Stop
                                } elseif (-not $fileState.Existed) {
                                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                                }
                            }
                            if ($tx.ShortcutExisted -and (Test-Path -LiteralPath $tx.ShortcutBackup)) {
                                Copy-Item -LiteralPath $tx.ShortcutBackup -Destination $shortcutPath -Force -ErrorAction Stop
                            } elseif (-not $tx.ShortcutExisted) {
                                Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
                            }
                            if ($tx.DataDirSddl) {
                                $acl = Get-Acl -LiteralPath $dataDir
                                $acl.SetSecurityDescriptorSddlForm([string]$tx.DataDirSddl)
                                Set-Acl -LiteralPath $dataDir -AclObject $acl
                            }
                            if ($tx.ControlSddl -and (Test-Path -LiteralPath $controlPath)) {
                                $acl = Get-Acl -LiteralPath $controlPath
                                $acl.SetSecurityDescriptorSddlForm([string]$tx.ControlSddl)
                                Set-Acl -LiteralPath $controlPath -AclObject $acl
                            }
                            if (-not $tx.InstallDirExisted -and (Test-Path -LiteralPath $installDir)) {
                                $remaining = @(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)
                                if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $installDir -Force -ErrorAction SilentlyContinue }
                            }
                            try { Restart-Service -Name Audiosrv -Force -ErrorAction Stop; Write-InstallLog 'INFO' 'Audio service restarted after transaction rollback.' }
                            catch { Write-InstallLog 'CRITICAL' "Audio service restart after rollback failed: $($_.Exception.Message)" }
                            Write-InstallLog 'INFO' 'Registry endpoint, COM registration, files, ACLs, and newly-created configuration state rolled back to the pre-attempt snapshot.'
                
            } -Verify {
                $tx = Get-Content -LiteralPath $transactionStateFile -Raw | ConvertFrom-Json
                $fxNowSub = "$capSub\$($tx.DeviceId)\FxProperties"
                if (-not (Test-RegistryValueSnapshot $fxNowSub $fxValue $tx.FxEffect)) { return $false }
                if (-not (Test-RegistryValueSnapshot $fxNowSub $fxAssociationValue $tx.FxAssociation)) { return $false }
                if (-not (Test-RegistryValueSnapshot $fxNowSub $fxCompositeValue $tx.FxComposite)) { return $false }
                $fxKeyPath = "$capRoot\$($tx.DeviceId)\FxProperties"
                if (-not [bool]$tx.FxKeyExisted -and (Test-Path -LiteralPath $fxKeyPath)) { return $false }
                if ([bool]$tx.IniExisted -ne [bool](Test-Path -LiteralPath (Join-Path $dataDir 'MicBridge.ini'))) { return $false }
                if ([bool]$tx.ControlExisted -ne [bool](Test-Path -LiteralPath $controlPath)) { return $false }
                if (-not [bool]$tx.InstallDirExisted -and (Test-Path -LiteralPath $installDir)) { return $false }
                if ($tx.DevSddl -and (Get-Sddl "$capSub\$($tx.DeviceId)") -ne [string]$tx.DevSddl) { return $false }
                if ($tx.FxSddl -and (Get-Sddl "$capSub\$($tx.DeviceId)\FxProperties") -ne [string]$tx.FxSddl) { return $false }
                $clsidPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
                $apoPath = "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
                if ((Test-Path -LiteralPath $clsidPath) -ne [bool]$tx.ClsidRegExisted) { return $false }
                if ((Test-Path -LiteralPath $apoPath) -ne [bool]$tx.ApoRegExisted) { return $false }
                if ([bool]$tx.ClsidRegExisted) {
                    if (-not (Test-MBRegistryExportSnapshot -RegistryPath "HKLM\SOFTWARE\Classes\CLSID\$clsid" -ExpectedSha256 ([string]$tx.ClsidRegSha256) -TemporaryDirectory $transactionDir)) { return $false }
                }
                if ([bool]$tx.ApoRegExisted) {
                    if (-not (Test-MBRegistryExportSnapshot -RegistryPath "HKLM\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" -ExpectedSha256 ([string]$tx.ApoRegSha256) -TemporaryDirectory $transactionDir)) { return $false }
                }
                $installedDllPath = Join-Path $installDir 'MicBridgeAPO.dll'
                if ([bool]$tx.DllExisted) {
                    if (-not (Test-Path -LiteralPath $installedDllPath -PathType Leaf)) { return $false }
                    $expectedDllHash = if ([bool]$tx.DllReplacementStarted) { [string]$tx.DllBackupSha256 } else { [string]$tx.DllOriginalSha256 }
                    if ([string]::IsNullOrWhiteSpace($expectedDllHash) -or (Get-FileHash -LiteralPath $installedDllPath -Algorithm SHA256).Hash -ne $expectedDllHash) { return $false }
                } elseif ([bool]$tx.DllReplacementStarted -and (Test-Path -LiteralPath $installedDllPath)) { return $false }
                foreach ($fileState in @($tx.InstallFiles)) {
                    $target = Join-Path $installDir $fileState.Name
                    if ([bool]$fileState.Existed -ne [bool](Test-Path -LiteralPath $target)) { return $false }
                    if ([bool]$fileState.Existed) {
                        if ([string]::IsNullOrWhiteSpace([string]$fileState.Sha256) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne [string]$fileState.Sha256) { return $false }
                    }
                }
                if ([bool]$tx.ShortcutExisted) {
                    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { return $false }
                    if ([string]::IsNullOrWhiteSpace([string]$tx.ShortcutBackupSha256) -or (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash -ne [string]$tx.ShortcutBackupSha256) { return $false }
                } elseif (Test-Path -LiteralPath $shortcutPath) { return $false }
                if ($tx.DataDirSddl -and (Get-Acl -LiteralPath $dataDir).Sddl -ne [string]$tx.DataDirSddl) { return $false }
                if ($tx.ControlSddl) {
                    if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) { return $false }
                    if ((Get-Acl -LiteralPath $controlPath).Sddl -ne [string]$tx.ControlSddl) { return $false }
                } elseif (-not [bool]$tx.ControlExisted -and (Test-Path -LiteralPath $controlPath)) { return $false }
                return $true
            }
        } catch {
            Write-InstallLog 'CRITICAL' "Transaction rollback was incomplete: $($_.Exception.ToString())"
            Write-Warning "تعذر إكمال التراجع التلقائي: $($_.Exception.Message). احتفظ بمجلد المعاملة وbackup.json."
        }
    }
    Write-InstallLog 'WARN' 'If transaction rollback reported CRITICAL, retain the transaction snapshot and backup.json for manual recovery.'
    Write-Host ""
    Write-Host "فشل التثبيت: $($failure.Exception.Message)" -ForegroundColor Red
    Write-Host "سجل التثبيت: $installLog" -ForegroundColor Yellow
    Write-Warning "قد تكون بعض تغييرات Registry قد نُفذت. لا تشغّل uninstall.bat ولا تحذف backup.json؛ أرسل Install.log للمراجعة."
} finally {
    if ($operationLock) { $operationLock.Dispose() }
}
