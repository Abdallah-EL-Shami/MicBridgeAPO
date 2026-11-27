# تثبيت MicBridge APO على المايك المحدد بالاسم.
param(
    [string]$DeviceName = 'AT2040USB',
    [string]$DllSource  = (Join-Path $PSScriptRoot 'MicBridgeAPO.dll')
)
$ErrorActionPreference = 'Stop'

# Verify the signed release package before elevation, logging, locks, or system mutation.
# This is an integrity gate for the staged package; the PowerShell host/bootstrap itself
# remains outside this script-level trust boundary.
$manifestPath = Join-Path $PSScriptRoot 'install-manifest.json'
$manifestSignaturePath = Join-Path $PSScriptRoot 'install-manifest.p7s'
$provenanceVerifier = Join-Path $PSScriptRoot 'tools\\MicBridge.InstallProvenanceManifest.psm1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $manifestSignaturePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $provenanceVerifier -PathType Leaf)) {
    throw 'A signed MicBridge release package is required. Manifest, signature, or verifier is missing; no elevation or installation was attempted.'
}
Import-Module -Name $provenanceVerifier -Force -ErrorAction Stop
$trustedReleaseThumbprint = '29BAC42BFC53F2586559A9B95D1FEEB658E8891A'
$verifiedPackage = Test-MBInstallProvenanceManifest -ManifestPath $manifestPath -SignaturePath $manifestSignaturePath -InstallDirectory $PSScriptRoot -TrustedSignerThumbprints @($trustedReleaseThumbprint) -PinFiles
if (-not $verifiedPackage.SignatureVerified -or -not $verifiedPackage.ManifestVerified -or
    -not $verifiedPackage.FileProvenanceVerified -or
    $verifiedPackage.SignerThumbprint -ne $trustedReleaseThumbprint -or
    $verifiedPackage.IsExecutionAuthorized -or $verifiedPackage.OwnershipProven -or
    -not $verifiedPackage.PackageFilesPinnedForUse -or $verifiedPackage.RaceSafeForExecution -or $verifiedPackage.BootstrapTrustEstablished) {
    try { Close-MBInstallProvenanceLeases -Verification $verifiedPackage } catch {}
    throw 'Signed package verification did not return the required integrity evidence; installation was blocked.'
}
$expectedPackageDll = @($verifiedPackage.VerifiedFiles | Where-Object {
    [string]::Equals([string]$_.RelativePath,'MicBridgeAPO.dll',[StringComparison]::OrdinalIgnoreCase)
})
if ($expectedPackageDll.Count -ne 1 -or
    -not [string]::Equals([IO.Path]::GetFullPath($DllSource),[IO.Path]::GetFullPath([string]$expectedPackageDll[0].Path),[StringComparison]::OrdinalIgnoreCase)) {
    Close-MBInstallProvenanceLeases -Verification $verifiedPackage
    throw 'DllSource must resolve to the exact MicBridgeAPO.dll covered by the signed release manifest.'
}

# رفع الصلاحيات تلقائيًا
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = "-NoProfile -ExecutionPolicy AllSigned -NoExit -File `"$PSCommandPath`" -DeviceName `"$DeviceName`" -DllSource `"$DllSource`""
    try { Start-Process powershell -Verb RunAs -ArgumentList $a }
    finally { Close-MBInstallProvenanceLeases -Verification $verifiedPackage }
    exit
}

# Establish operation-specific diagnostics before acquiring locks or running preflight.
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir = Join-Path $env:ProgramData 'MicBridgeAPO'
$installLog = Join-Path $dataDir 'Install.log'
$recoveryLog = Join-Path $dataDir 'Recovery.log'
$upgradeLog = Join-Path $dataDir 'Upgrade.log'
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
            throw "Cannot create MicBridge install/recovery/upgrade log at either '$PrimaryPath' or '$FallbackPath'. $($_.Exception.Message)"
        }
    }
}
$installLog = Resolve-MBLogPath $installLog (Join-Path $env:TEMP 'MicBridgeAPO-Install.log')
$recoveryLog = Resolve-MBLogPath $recoveryLog (Join-Path $env:TEMP 'MicBridgeAPO-Recovery.log')
$upgradeLog = Resolve-MBLogPath $upgradeLog (Join-Path $env:TEMP 'MicBridgeAPO-Upgrade.log')
function Write-RecoveryLog([string]$Level,[string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $recoveryLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Recovery.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}
function Write-EarlyInstallLog([string]$Level,[string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Install.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}
Write-Host "سجل التثبيت: $installLog"
Write-Host "سجل الاستعادة: $recoveryLog"
Write-Host "سجل فحص الترقية: $upgradeLog"
Write-EarlyInstallLog 'INFO' "Installer process started. DeviceName='$DeviceName'; DllSource='$DllSource'."
$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$iidApo     = '{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'   # PKEY_FX_EndpointEffectClsid
$fxCompositeValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15' # PKEY_CompositeFX_EndpointEffectClsid (REG_MULTI_SZ)
$fxAssociationValue = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0' # PKEY_FX_Association
$ksNodeTypeAny = '{00000000-0000-0000-0000-000000000000}'
$recoveryModule = Join-Path $PSScriptRoot 'tools\MicBridge.RecoveryJournal.psm1'
try {
    Import-Module -Name $recoveryModule -Force -ErrorAction Stop
    $operationLockPath = Join-Path $dataDir 'operation'
    $operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0
} catch {
    Write-EarlyInstallLog 'ERROR' "Installer could not initialize its recovery lock/module; installation did not start. $($_.Exception.ToString())"
    Write-RecoveryLog 'ERROR' "Installer initialization failed before any installation changes. $($_.Exception.ToString())"
    throw
}
try {
# Fail closed when a prior install rollback was interrupted. Until the full
# replay handler is available, never start a new transaction over uncertain state.
if (Test-Path -LiteralPath $dataDir -PathType Container) {
    $pendingRollbackJournals = @()
    foreach ($transactionFolder in @(Get-ChildItem -LiteralPath $dataDir -Directory -Filter 'transactions-*' -ErrorAction Stop)) {
        $candidateJournal = Join-Path $transactionFolder.FullName 'rollback-recovery.json'
        if (-not (Test-Path -LiteralPath $candidateJournal -PathType Leaf)) { continue }
        $candidateStepIds = @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $candidateState = Read-MBRecoveryJournal -Path $candidateJournal -ExpectedOperation InstallRollback -ExpectedStepIds $candidateStepIds
        $candidateSnapshotPath = Join-Path $transactionFolder.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $candidateSnapshotPath -PathType Leaf)) {
            throw "Interrupted install rollback has no transaction snapshot: $candidateSnapshotPath"
        }
        $candidateDeviceId = [guid]::Empty
        if (-not [guid]::TryParse([string]$candidateState.DeviceId,[ref]$candidateDeviceId)) {
            throw "Interrupted install rollback journal has an invalid endpoint identity: $candidateJournal"
        }
        # Strict read-only preflight before classifying a transaction as pending.
        # This does not replay or mutate Registry, ACLs, COM, DLLs, or files.
        $rollbackValidationModule = Join-Path $PSScriptRoot 'tools\MicBridge.InstallRollbackValidation.psm1'
        if (-not (Test-Path -LiteralPath $rollbackValidationModule -PathType Leaf)) {
            throw "Rollback validation module is missing; refusing to inspect pending transaction: $rollbackValidationModule"
        }
        Import-Module -Name $rollbackValidationModule -Force -ErrorAction Stop
        $candidateValidation = Test-MBInstallRollbackTransaction -JournalPath $candidateJournal -StatePath $candidateSnapshotPath -TransactionDirectory $transactionFolder.FullName -DataDirectory $dataDir -ExpectedDeviceId $candidateDeviceId -ExpectedStepIds $candidateStepIds
        if (-not $candidateValidation.IsValid -or -not $candidateValidation.ReplaySafe) {
            throw "Interrupted install rollback transaction failed read-only preflight; preserve it for manual recovery. $candidateJournal :: $($candidateValidation.Errors -join '; ')"
        }
        $unfinished = @($candidateValidation.Journal.Steps | Where-Object { $_.State -ne 'Completed' })
        if ($unfinished.Count -gt 0) {
            $pendingRollbackJournals += $candidateJournal
        }
    }
    if ($pendingRollbackJournals.Count -gt 1) {
        $paths = $pendingRollbackJournals -join '; '
        if ($operationLock) { $operationLock.Dispose(); $operationLock = $null }
        throw "Multiple interrupted MicBridge rollback transactions were found. Their order is ambiguous; no automatic replay was attempted. Preserve: $paths"
    }
    if ($pendingRollbackJournals.Count -eq 1) {
        $pendingJournalPath = [string]$pendingRollbackJournals[0]
        Write-RecoveryLog 'WARN' "Interrupted rollback found. Journal='$pendingJournalPath'. Automatic replay is starting after strict read-only preflight."
        $pendingTransactionDirectory = Split-Path -Parent $pendingJournalPath
        $pendingJournal = Read-MBRecoveryJournal -Path $pendingJournalPath -ExpectedOperation InstallRollback -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        $pendingDeviceId = [guid]::Parse([string]$pendingJournal.DeviceId)
        $fullRollbackModule = Join-Path $PSScriptRoot 'tools\MicBridge.FullInstallRollbackExecutor.psm1'
        if (-not (Test-Path -LiteralPath $fullRollbackModule -PathType Leaf)) {
            if ($operationLock) { $operationLock.Dispose(); $operationLock = $null }
            throw "Full rollback executor is missing; preserve the pending transaction: $fullRollbackModule"
        }
        Import-Module -Name $fullRollbackModule -Force -ErrorAction Stop
        # Release the installer's outer lock; the full executor acquires the
        # same lock while replaying and verifying the entire durable transaction.
        if ($operationLock) { $operationLock.Dispose(); $operationLock = $null }
        $recoveryResult = Invoke-MBInstallFullRollback -TransactionDirectory $pendingTransactionDirectory -DataDirectory $dataDir -InstallDirectory $installDir -ExpectedDeviceId $pendingDeviceId
        if (-not $recoveryResult.Success) {
            throw "Interrupted MicBridge rollback did not complete. Preserve the transaction directory: $pendingTransactionDirectory"
        }
        Import-Module -Name $recoveryModule -Force -Global -ErrorAction Stop
        $verifiedJournal = Read-MBRecoveryJournal -Path $pendingJournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $pendingDeviceId -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
        if (@($verifiedJournal.Steps | Where-Object { $_.State -ne 'Completed' }).Count -gt 0) {
            throw "Full rollback executor returned without completing every main step. Preserve: $pendingTransactionDirectory"
        }
        # Re-acquire the installer lock before starting a new transaction.
        $operationLock = Enter-MBRecoveryOperationLock -Path $operationLockPath -TimeoutSeconds 0
        Write-RecoveryLog 'INFO' "Interrupted rollback completed and verified. Journal='$pendingJournalPath'."
        Write-Host "Recovered the interrupted MicBridge installation transaction before starting a new installation."
    }
}
} catch {
    if ($verifiedPackage) { try { Close-MBInstallProvenanceLeases -Verification $verifiedPackage } catch {} }
    if ($operationLock) { $operationLock.Dispose(); $operationLock = $null }
    Write-EarlyInstallLog 'ERROR' "Install preflight stopped before a new install transaction began. $($_.Exception.ToString())"
    Write-RecoveryLog 'ERROR' "Pre-install recovery/rollback preflight failed; new installation did not start. $($_.Exception.ToString())"
    throw
}
# Read-only legacy audit gate: never install over unidentified or legacy MicBridge state.
$legacyAuditModule = Join-Path $PSScriptRoot 'tools\MicBridge.LegacyInstallAudit.psm1'
if (-not (Test-Path -LiteralPath $legacyAuditModule -PathType Leaf)) {
    Close-MBInstallProvenanceLeases -Verification $verifiedPackage
    throw "Legacy installation audit module is missing; refusing to start a new install transaction: $legacyAuditModule"
}
try {
    Import-Module -Name $legacyAuditModule -Force -ErrorAction Stop
    $legacyAudit = Test-MBLegacyInstallationState -InstallDirectory $installDir -DataDirectory $dataDir -RegistryRoot 'HKLM:\'
    Write-InstallLog 'INFO' "Read-only legacy audit outcome='$($legacyAudit.Outcome)'; findings=$(@($legacyAudit.Findings).Count)."
    if (-not $legacyAudit.IsReadOnly -or $legacyAudit.CleanupAllowed -ne $false -or
        $legacyAudit.OriginalWindowsBaselineProven -ne $false -or
        $legacyAudit.OwnershipProven -ne $false -or
        $legacyAudit.OwnershipEvidenceStatus -ne 'NotEstablished' -or
        $legacyAudit.Outcome -ne 'NoLegacyResidueDetected') {
        $details = @($legacyAudit.Findings | Where-Object { $_.Classification -notin @('Absent') } |
            ForEach-Object { "$($_.Name): $($_.Classification) [$($_.Path)]" }) -join '; '
        throw "Legacy MicBridge state was detected or could not be ruled out. No cleanup or installation was attempted. Review findings: $details"
    }
} catch {
    Close-MBInstallProvenanceLeases -Verification $verifiedPackage
    Write-InstallLog 'ERROR' "Read-only legacy audit gate blocked installation. $($_.Exception.ToString())"
    throw
}

$compositeBackupFile = Join-Path $dataDir 'composite-efx-backup.json'
$backupFile = Join-Path $dataDir 'backup.json'
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
function Write-UpgradeLog([string]$Level,[string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
        Add-Content -LiteralPath $upgradeLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MicBridgeAPO-Upgrade.log') -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
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

$registryAclModule = Join-Path $PSScriptRoot 'tools\MicBridge.RegistryAclRollback.psm1'
Import-Module -Name $registryAclModule -Force -ErrorAction Stop
function Get-Sddl([string]$sub) {
    Get-MBRegistryAclSddl -Hive HKLM -SubKeyPath $sub
}
function Restore-Sddl([string]$sub, [string]$sddl) {
    [TokenPriv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
    [TokenPriv]::Enable('SeRestorePrivilege') | Out-Null
    Restore-MBRegistryAclSddl -Hive HKLM -SubKeyPath $sub -Sddl $sddl
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

function Get-MBTransactionFxRegistrySnapshot($tx) {
    return [pscustomobject]@{
        RegistryPath = "HKLM\$capSub\$($tx.DeviceId)\FxProperties"
        KeyExists = [bool]$tx.FxKeyExisted
        Values = @(
            [pscustomobject]@{ Name=$fxValue; Exists=[bool]$tx.FxEffect.Exists; Kind=[string]$tx.FxEffect.Kind; Value=$tx.FxEffect.Value }
            [pscustomobject]@{ Name=$fxAssociationValue; Exists=[bool]$tx.FxAssociation.Exists; Kind=[string]$tx.FxAssociation.Kind; Value=$tx.FxAssociation.Value }
            [pscustomobject]@{ Name=$fxCompositeValue; Exists=[bool]$tx.FxComposite.Exists; Kind=[string]$tx.FxComposite.Kind; Value=$tx.FxComposite.Value }
        )
    }
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

# Read-only legacy-install audit before restore points, snapshots, COM changes,
# DLL replacement, ACL changes, or endpoint Registry writes.
$legacyAuditModule = Join-Path $PSScriptRoot 'tools\MicBridge.LegacyInstallAudit.psm1'
if (-not (Test-Path -LiteralPath $legacyAuditModule -PathType Leaf)) {
    throw "Legacy installation audit module is missing; refusing to upgrade an existing installation: $legacyAuditModule"
}
Import-Module -Name $legacyAuditModule -Force -ErrorAction Stop
$legacyAudit = Test-MBLegacyInstallationState -InstallDirectory $installDir -DataDirectory $dataDir -RegistryRoot 'HKLM:\' -ExpectedDeviceId ([guid]$dev.Id)
Write-UpgradeLog 'INFO' "Read-only legacy audit completed. Outcome=$($legacyAudit.Outcome); BaselineAssessment=$($legacyAudit.BaselineAssessment)."
foreach ($finding in @($legacyAudit.Findings)) { Write-UpgradeLog 'INFO' "Finding: Kind=$($finding.Kind); Name=$($finding.Name); Classification=$($finding.Classification); Path=$($finding.Path); Detail=$($finding.Detail)" }
if ($legacyAudit.Outcome -ne 'NoLegacyResidueDetected') {
    # InventoryOnly is not permission to upgrade: a structurally valid legacy
    # backup and matching hashes do not prove that it captured the original
    # Windows state before an older MicBridge release changed the machine.
    $reviewItems = @($legacyAudit.Findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved','InvalidOrInsufficient','MissingPermanentBackup','MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeSupportFileCandidate','MicBridgeRecoveryEvidence','StructurallyValidCandidate') })
    $reviewSummary = ($reviewItems | ForEach-Object { "$($_.Kind):$($_.Name) [$($_.Classification)]" }) -join '; '
    Write-InstallLog 'CRITICAL' "Read-only legacy installation audit requires manual review. Outcome=$($legacyAudit.Outcome); BaselineAssessment=$($legacyAudit.BaselineAssessment). $reviewSummary"
    throw "Legacy MicBridge artifacts were detected or the original Windows baseline cannot be established. Upgrade stopped without cleanup or system changes. Preserve ProgramData and install folders for manual review. $reviewSummary"
}
Write-InstallLog 'INFO' 'Read-only legacy audit found no MicBridge residue; proceeding with a first-install snapshot.'

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
    $packageSource = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $packageSource -PathType Leaf)) { throw "Required installer support file is missing from package: $packageSource" }
    $installedPackageHash = (Get-FileHash -LiteralPath $packageSource -Algorithm SHA256 -ErrorAction Stop).Hash
    $backupPath = Join-Path $installFilesDir $name
    $existed = Test-Path -LiteralPath $target
    $backupHash = $null
    if ($existed) {
        Copy-Item -LiteralPath $target -Destination $backupPath -Force -ErrorAction Stop
        $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $installFilesBackup += [pscustomobject]@{ Name=$name; Existed=$existed; Backup=$backupPath; Sha256=$backupHash; InstalledSha256=$installedPackageHash }
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
$iniPackageSource = Join-Path $PSScriptRoot 'MicBridge.ini'
if (-not (Test-Path -LiteralPath $iniPackageSource -PathType Leaf)) { throw "Required MicBridge.ini package file is missing: $iniPackageSource" }
$iniNewSha256 = (Get-FileHash -LiteralPath $iniPackageSource -Algorithm SHA256 -ErrorAction Stop).Hash
$controlTemplate = "[Control]`r`nEnabled=1`r`n"
$controlTemplateBytes = [Text.Encoding]::ASCII.GetBytes($controlTemplate)
$sha256Provider = [Security.Cryptography.SHA256]::Create()
try { $controlNewSha256 = [BitConverter]::ToString($sha256Provider.ComputeHash($controlTemplateBytes)).Replace('-','') } finally { $sha256Provider.Dispose() }
$iniOriginalSha256 = if (Test-Path -LiteralPath (Join-Path $dataDir 'MicBridge.ini') -PathType Leaf) { (Get-FileHash -LiteralPath (Join-Path $dataDir 'MicBridge.ini') -Algorithm SHA256).Hash } else { $null }
$controlOriginalSha256 = if (Test-Path -LiteralPath $controlPath -PathType Leaf) { (Get-FileHash -LiteralPath $controlPath -Algorithm SHA256).Hash } else { $null }
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
    IniOriginalSha256 = $iniOriginalSha256
    IniNewSha256 = $iniNewSha256
    ControlExisted = (Test-Path -LiteralPath (Join-Path $dataDir 'control.ini'))
    ControlOriginalSha256 = $controlOriginalSha256
    ControlNewSha256 = $controlNewSha256
    DataDirSddl = $dataDirSddl
    ControlSddl = $controlSddl
    InstallFiles = $installFilesBackup
    ShortcutExisted = $shortcutExisted
    ShortcutBackup = $shortcutBackup
    ShortcutBackupSha256 = $shortcutBackupSha256
    ShortcutNewSha256 = $null
    InstallDirExisted = (Test-Path -LiteralPath $installDir)
}
if ($transactionState.FxComposite.Exists -and [string]$transactionState.FxComposite.Kind -ne 'MultiString') {
    throw "Current composite EFX value has unexpected type '$($transactionState.FxComposite.Kind)'; refusing to overwrite it."
}
Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10

# Durable rollback journal is created from the verified pre-install snapshot.
$rollbackJournalPath = Join-Path $transactionDir 'rollback-recovery.json'
$rollbackDeviceId = [guid]$dev.Id
$rollbackStepIds = @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
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
if (-not (Test-Path -LiteralPath $ini)) {
    Copy-Item -LiteralPath $iniPackageSource -Destination $ini -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $ini -Algorithm SHA256).Hash -ne [string]$transactionState.IniNewSha256) { throw 'Installed MicBridge.ini does not match the transaction package hash.' }
}
$ctrl = Join-Path $dataDir 'control.ini'
if (-not (Test-Path -LiteralPath $ctrl)) {
    [IO.File]::WriteAllBytes($ctrl,$controlTemplateBytes)
    if ((Get-FileHash -LiteralPath $ctrl -Algorithm SHA256).Hash -ne [string]$transactionState.ControlNewSha256) { throw 'Created control.ini does not match the transaction template hash.' }
}
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

# ---- 8) Create an owned desktop shortcut without overwriting a pre-existing user shortcut.
$shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'MicBridge.lnk'
$shortcutOwnershipFile = Join-Path $dataDir 'desktop-shortcut.sha256'
$shortcutTempPath = Join-Path (Split-Path -Parent $shortcutPath) ('MicBridge.' + [guid]::NewGuid().ToString('N') + '.tmp.lnk')
try {
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcutTempPath)
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\MicBridgeUI.ps1`""
        $lnk.Save()
        $transactionState.ShortcutNewSha256 = (Get-FileHash -LiteralPath $shortcutTempPath -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-JsonAtomic -Value $transactionState -Path $transactionStateFile -Depth 10
        # Persist the expected shortcut hash before publishing it so a fresh
        # recovery process can safely identify the exact file created by this transaction.
        [IO.File]::Move($shortcutTempPath, $shortcutPath)
        $shortcutHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256 -ErrorAction Stop).Hash
        [IO.File]::WriteAllText($shortcutOwnershipFile, $shortcutHash, (New-Object Text.UTF8Encoding($false)))
        Write-InstallLog 'INFO' 'Created and recorded ownership of the MicBridge desktop shortcut.'
    } else {
        Write-InstallLog 'INFO' 'Preserved an existing desktop shortcut; MicBridge did not overwrite it.'
    }
} catch {
    Write-Warning "لم يُنشأ اختصار سطح المكتب أو تعذر تسجيل ملكيته: $($_.Exception.Message)"
} finally {
    if (Test-Path -LiteralPath $shortcutTempPath) { Remove-Item -LiteralPath $shortcutTempPath -Force -ErrorAction SilentlyContinue }
}

# ---- 9) إعادة تشغيل خدمة الصوت
Write-InstallLog 'INFO' 'Restarting Audiosrv.'
Restart-Service -Name Audiosrv -Force
Write-InstallLog 'INFO' 'Audio service restart completed.'

# Persist a machine-bound receipt only after all installed files and registrations
# have reached their successful post-install state. Use a unique path per transaction.
$receiptModule = Join-Path $PSScriptRoot 'tools\\MicBridge.InstallTransactionReceipt.psm1'
if (-not (Test-Path -LiteralPath $receiptModule -PathType Leaf)) {
    throw "Transaction provenance receipt module is missing: $receiptModule"
}
Import-Module -Name $receiptModule -Force -ErrorAction Stop
$receiptFiles = [Collections.Generic.List[object]]::new()
foreach ($name in @('MicBridgeAPO.dll','MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
    $installedPath = Join-Path $installDir $name
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
        throw "Cannot issue install provenance receipt; installed file is missing: $installedPath"
    }
    $receiptFiles.Add([pscustomobject]@{
        RelativePath=$name
        Sha256=(Get-FileHash -LiteralPath $installedPath -Algorithm SHA256 -ErrorAction Stop).Hash
    })
}
$receiptPath = Join-Path $dataDir ('install-transaction-' + [guid]::NewGuid().ToString('N') + '.receipt')
$manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash
$receiptResult = New-MBInstallTransactionReceipt -ReceiptPath $receiptPath -InstallRoot $installDir -ProductVersion $verifiedPackage.ProductVersion -ReleaseManifestSha256 $manifestSha256 -SignerThumbprint $verifiedPackage.SignerThumbprint -TransactionId ([guid]::Parse([string]$rollbackJournal.TransactionId)) -ReleaseManifestTransactionId ([guid]::Parse([string]$verifiedPackage.InstallTransactionId)) -InstalledFiles @($receiptFiles.ToArray())
$receiptCheck = Test-MBInstallTransactionReceipt -ReceiptPath $receiptPath -VerifyInstalledFiles
if (-not $receiptResult.Created -or -not $receiptCheck.ReceiptIntegrityVerified -or
    -not $receiptCheck.InstalledFilesVerified -or $receiptCheck.OwnershipProven -or
    $receiptCheck.ComOwnershipProven -or $receiptCheck.IsExecutionAuthorized) {
    throw 'Post-install provenance receipt could not be independently verified; installation is not considered complete.'
}
Write-InstallLog 'INFO' "Installation provenance receipt created and verified. TransactionId='$($receiptCheck.TransactionId)'; Receipt='$receiptPath'."
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
    $catchJournalPath = if ($transactionStateFile) { Join-Path (Split-Path -Parent $transactionStateFile) 'rollback-recovery.json' } else { $null }
    if ($transactionStateFile -and (Test-Path -LiteralPath $transactionStateFile -PathType Leaf) -and $catchJournalPath -and (Test-Path -LiteralPath $catchJournalPath -PathType Leaf)) {
        try {
            $rollbackSnapshot = Get-Content -LiteralPath $transactionStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $rollbackDeviceId = [guid]::Parse([string]$rollbackSnapshot.DeviceId)
            $fullRollbackModule = Join-Path $PSScriptRoot 'tools\MicBridge.FullInstallRollbackExecutor.psm1'
            if (-not (Test-Path -LiteralPath $fullRollbackModule -PathType Leaf)) {
                throw "Full rollback executor is missing: $fullRollbackModule"
            }
            Import-Module -Name $fullRollbackModule -Force -ErrorAction Stop
            # The installer already owns this lock; release it before the
            # full executor acquires the same operation lock for replay.
            if ($operationLock) { $operationLock.Dispose(); $operationLock = $null }
            $rollbackResult = Invoke-MBInstallFullRollback -TransactionDirectory (Split-Path -Parent $transactionStateFile) -DataDirectory $dataDir -InstallDirectory $installDir -ExpectedDeviceId $rollbackDeviceId
            if (-not $rollbackResult.Success) { throw 'Full rollback executor did not report success.' }
            Import-Module -Name $recoveryModule -Force -Global -ErrorAction Stop
            $verifiedRollbackJournal = Read-MBRecoveryJournal -Path $catchJournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $rollbackDeviceId -ExpectedStepIds @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
            if (@($verifiedRollbackJournal.Steps | Where-Object { $_.State -ne 'Completed' }).Count -gt 0) {
                throw 'Full rollback executor returned before every durable main step reached Completed.'
            }
            Write-InstallLog 'INFO' 'Full transaction rollback completed and all durable endpoint, ACL, COM, DLL, file, configuration and shortcut postconditions were verified.'
            Write-RecoveryLog 'INFO' "Install-failure rollback completed and verified. Transaction='$transactionStateFile'."
        } catch {
            Write-InstallLog 'CRITICAL' "Transaction rollback was incomplete: $($_.Exception.ToString())"
            Write-RecoveryLog 'CRITICAL' "Install-failure rollback incomplete. Transaction='$transactionStateFile'. Error='$($_.Exception.ToString())'"
            Write-Warning "تعذر إكمال التراجع التلقائي: $($_.Exception.Message). احتفظ بمجلد المعاملة وbackup.json."
        }
    } else {
        Write-InstallLog 'WARN' 'No complete durable rollback journal and transaction snapshot were available; no automatic rollback was attempted.'
    }
    Write-InstallLog 'WARN' 'If transaction rollback reported CRITICAL, retain the transaction snapshot and backup.json for manual recovery.'
    Write-Host ""
    Write-Host "فشل التثبيت: $($failure.Exception.Message)" -ForegroundColor Red
    Write-Host "سجل التثبيت: $installLog" -ForegroundColor Yellow
    Write-Warning "قد تكون بعض تغييرات Registry قد نُفذت. لا تشغّل uninstall.bat ولا تحذف backup.json؛ أرسل Install.log للمراجعة."
} finally {
    # Release all verified package handles on success and every rollback/error path.
    # The elevated child re-verifies and acquires its own leases after UAC.
    if ($verifiedPackage) {
        try { Close-MBInstallProvenanceLeases -Verification $verifiedPackage }
        catch { Write-Warning "Could not release one or more package provenance leases cleanly: $($_.Exception.Message)" }
    }
    if ($operationLock) { $operationLock.Dispose() }
}
