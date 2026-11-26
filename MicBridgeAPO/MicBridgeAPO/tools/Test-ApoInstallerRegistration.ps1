$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
$uninstaller = Get-Content -LiteralPath (Join-Path $root 'uninstall.ps1') -Raw
$rollbackModule = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackActions.psm1') -Raw
$fullExecutor = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MicBridge.FullInstallRollbackExecutor.psm1') -Raw
$rollbackValidationModule = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Raw

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

Assert-Contains $installer '\$fxAssociationValue\s*=\s*''\{d04e05a6-594b-4fb6-a80d-01af5eed7d1d\},0''' 'Installer declares PKEY_FX_Association'
Assert-Contains $installer '\$ksNodeTypeAny\s*=\s*''\{00000000-0000-0000-0000-000000000000\}''' 'Installer uses the documented KSNODETYPE_ANY GUID'
Assert-Contains $installer 'PrevFxAssociation\s*=' 'Fresh backup records the previous association value'
Assert-Contains $installer 'PSObject\.Properties\.Name\s+-notcontains\s+''PrevFxAssociation''' 'Installer migrates legacy backup.json files'
Assert-Contains $installer 'Name\s+\$fxAssociationValue\s+-Value\s+\$associationToUse' 'Installer preserves or initializes the association property'
Assert-Contains $installer '\$associationToUse\s*=\s*if \(\$transactionState\.FxAssociation\.Exists\)' 'Installer preserves the currently configured KS node association'
Assert-Contains $installer 'else \{ \$ksNodeTypeAny \}' 'Clean install initializes a missing association to KSNODETYPE_ANY'
Assert-NotContains $installer 'elseif \(\$backup\.PrevFxAssociation\)' 'Installer never derives active association defaults from backup history'
Assert-Contains $uninstaller 'PSObject\.Properties\.Name\s+-contains\s+''PrevFxAssociation''' 'Uninstaller distinguishes legacy backups'
Assert-Contains $uninstaller 'Name\s+\$fxAssociationValue\s+-Value\s+\$b\.PrevFxAssociation' 'Uninstaller restores a prior association value'
Assert-Contains $uninstaller 'Remove-ItemProperty\s+-LiteralPath\s+\$fxPath\s+-Name\s+\$fxAssociationValue' 'Uninstaller removes only its association value when no prior value existed'
Assert-Contains $uninstaller 'GetValueNames\(\)\.Count\s+-eq\s+0' 'Uninstaller checks that a created FxProperties key is empty before deleting it'
Assert-Contains $uninstaller 'return \(\[bool\]\$Backup\.CreatedFx -and \[string\]::IsNullOrWhiteSpace\(\[string\]\$Backup\.FxKeySddl\)\)' 'Uninstaller accepts an absent FxProperties key only when the original snapshot proves MicBridge created it'
Assert-NotContains $uninstaller 'Remove-Item\s+-LiteralPath\s+\$fxPath\s+-Recurse' 'Uninstaller never recursively deletes FxProperties and unrelated driver values'

Assert-Contains $installer 'DllSource\s+`"\$DllSource`"' 'Elevated installer relaunch preserves the selected DLL source path'
Assert-Contains $installer 'Refuse to reuse a backup created for a different capture endpoint' 'Installer documents the backup/device identity guard'
Assert-Contains $installer '\[string\]\$existingBackup\.DeviceId\s+-ne\s+\[string\]\$dev\.Id' 'Installer refuses a backup belonging to another endpoint'
Assert-Contains $installer 'قد تكون بعض تغييرات Registry قد نُفذت' 'Installer warns that a failed run may have made partial changes'
Assert-NotContains $installer 'شغّل uninstall\.bat للتراجع' 'Installer does not recommend broad uninstall as automatic partial rollback'


Assert-Contains $installer "'MicBridgeUI.bat'" 'Installer backs up and restores the UI launcher transactionally'
Assert-Contains $installer 'function Write-InstallLog' 'Installer defines diagnostic logging'
Assert-Contains $installer 'Installation failed:' 'Installer logs detailed failure exceptions'
Assert-Contains $installer 'dll-backups' 'Installer preserves the previous DLL before replacement'
Assert-Contains $installer '\$transactionState\.DllBackupPath\s*=\s*\$dllBackupPath' 'Installer durably records the previous DLL backup path'
Assert-Contains $installer '\$transactionState\.DllBackupSha256\s*=\s*\$dllBackupHash' 'Installer durably records the previous DLL backup hash'
Assert-Contains $installer '\$transactionState\.DllReplacementStarted\s*=\s*\$true' 'Installer durably marks the DLL replacement boundary before mutation'
Assert-Contains $rollbackModule 'Test-MBPathWithinDirectory.{0,200}BackupPath' 'Rollback rejects DLL backups outside its dedicated directory'
Assert-Contains $rollbackModule 'Test-MBNoReparsePath.{0,200}BackupPath' 'Rollback rejects DLL backups traversing reparse points'
Assert-Contains $rollbackModule 'Restored DLL hash does not match the durable pre-transaction snapshot' 'Rollback verifies the restored DLL bytes against the durable snapshot'
Assert-Contains $installer '\$backupHash\s*=\s*\(Get-FileHash\s+-LiteralPath\s+\$backupPath' 'Installer records SHA-256 for each existing UI and uninstaller file snapshot'
Assert-Contains $installer 'ShortcutBackupSha256\s*=\s*\$shortcutBackupSha256' 'Installer records the original desktop shortcut hash'
Assert-Contains $installer 'Preserved an existing desktop shortcut; MicBridge did not overwrite it.' 'Installer preserves pre-existing desktop shortcuts'
Assert-Contains $installer '\[IO\.File\]::Move\(\$shortcutTempPath, \$shortcutPath\)' 'Installer publishes its shortcut without overwriting a concurrently-created file'
Assert-Contains $installer 'desktop-shortcut\.sha256' 'Installer records a hash ownership marker for its created shortcut'
Assert-Contains $uninstaller 'user-modified shortcut' 'Uninstaller preserves a desktop shortcut modified after installation'
Assert-Contains $uninstaller '\[string\]::Equals\(\$currentHash,\$ownedHash' 'Uninstaller removes a desktop shortcut only when its content hash matches the ownership record'
Assert-Contains $uninstaller 'ownership marker is not a regular file' 'Uninstaller rejects directory or reparse-point shortcut ownership markers'
Assert-Contains $uninstaller 'Remove-Item -LiteralPath \$shortcutOwnershipFile -Force -ErrorAction Stop' 'Uninstaller removes the verified shortcut ownership marker'
Assert-Contains $uninstaller '-not \(Test-Path -LiteralPath \$shortcutOwnershipFile\)' 'Uninstall verification requires the ownership marker to be absent'
Assert-Contains $uninstaller 'Desktop shortcut is not a regular file; preserving it' 'Uninstaller preserves shortcut reparse points and directories'
Assert-Contains $installer 'DllOriginalSha256\s*=\s*if \(Test-Path' 'Installer snapshots the original installed DLL hash before any replacement'
Assert-Contains $installer "\$rollbackStepIds = @\('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState'\)" 'Installer persists the fixed three-step rollback journal order'
Assert-Contains $installer 'Invoke-MBInstallFullRollback' 'Installer startup recovery and failure handling use the full durable rollback executor'
Assert-Contains $installer 'pendingRollbackJournals.Count -eq 1' 'Installer replays only one unambiguous pending transaction'
Assert-Contains $installer 'Multiple interrupted MicBridge rollback transactions were found' 'Installer refuses automatic replay when transaction order is ambiguous'
Assert-Contains $installer 'Interrupted MicBridge rollback did not complete' 'Installer blocks a new install if rollback replay does not finish'
Assert-NotContains $installer 'Recovery replay is not yet automated' 'Installer no longer leaves validated pending transactions permanently blocked'
Assert-Contains $fullExecutor 'Restore-MBEndpointRegistrySnapshot' 'Full executor restores the endpoint FX snapshot'
Assert-Contains $fullExecutor 'Restore-MBRegistryAclSddl' 'Full executor restores capture endpoint ACLs'
Assert-Contains $fullExecutor 'Restore-MBComRegistrySnapshot' 'Full executor restores both COM registrations'
Assert-Contains $fullExecutor 'Restore-MBDllSnapshot' 'Full executor restores the previous DLL by hash'
Assert-Contains $fullExecutor 'Restore-MBInstallSupportFiles' 'Full executor restores the four fixed support files'
Assert-Contains $fullExecutor 'Restore-MBInstallMetadataSnapshot' 'Full executor restores configuration, shortcut and ProgramData ACL metadata'
Assert-Contains $installer 'ولا توجد بيانات كافية لإثبات قيمتها الأصلية' 'Installer refuses to guess legacy backup association values'
Assert-NotContains $installer 'existingAssociation = [(]Get-ItemProperty' 'Installer does not infer historical association from current registry state'

Assert-Contains $installer 'PKEY_CompositeFX_EndpointEffectClsid' 'Installer uses the Windows 10 composite endpoint-effect property'
Assert-Contains $installer '\$fxCompositeValue\s*=\s*''\{d04e05a6-594b-4fb6-a80d-01af5eed7d1d\},15''' 'Installer targets the composite EFX property key'
Assert-Contains $installer '\$dataDir\s*=\s*Join-Path \$env:ProgramData\s+''MicBridgeAPO''[\s\S]*?\$compositeBackupFile\s*=\s*Join-Path \$dataDir' 'Installer initializes ProgramData path before deriving backup paths'
Assert-Contains $installer 'Build the live EFX chain from the endpoint''s CURRENT driver state' 'Composite EFX defaults are derived from live endpoint state'
Assert-NotContains $installer 'elseif \(\$backup\.PrevEndpointEffect' 'Installer never builds active EFX chain from historical backup values'
Assert-Contains $installer '\$efxList \+= \$clsid' 'Installer adds MicBridge to the composite chain'
Assert-Contains $installer 'composite-efx-backup.json' 'Installer stores composite EFX state outside the original backup'
Assert-Contains $installer 'Type MultiString' 'Installer writes the composite EFX chain as REG_MULTI_SZ'
Assert-Contains $installer 'Current composite EFX value has unexpected type' 'Installer refuses to overwrite a malformed composite EFX value'
Assert-Contains $uninstaller 'Current composite EFX value is not REG_MULTI_SZ' 'Uninstaller refuses to mutate a malformed composite EFX value'
Assert-NotContains $installer 'Name \$fxValue -Value \$clsid' 'Installer does not overwrite the legacy single-APO EFX property'
Assert-Contains $uninstaller 'Remove only MicBridge from the live composite list' 'Uninstaller preserves vendor EFX entries added after installation'
Assert-Contains $uninstaller '\$currentLegacy' 'Uninstaller does not overwrite a vendor-updated legacy EFX value'
Assert-Contains $uninstaller '\$expectedAssociation' 'Uninstaller restores association only when it still matches MicBridge state'
Assert-Contains $uninstaller 'RegistryValueKind]::MultiString' 'Uninstaller restores the composite property with REG_MULTI_SZ type'
Assert-Contains $uninstaller 'Remove-Item -LiteralPath \$apoRegistrationPath -Recurse -Force -ErrorAction Stop' 'Uninstaller stops if AudioEngine registration removal fails'
Assert-Contains $uninstaller 'Remove-Item -LiteralPath \$comRegistrationPath -Recurse -Force -ErrorAction Stop' 'Uninstaller stops if COM registration removal fails'

$uiSource = Get-Content -LiteralPath (Join-Path $root 'MicBridgeUI.ps1') -Raw
$uiLauncher = Get-Content -LiteralPath (Join-Path $root 'MicBridgeUI.bat') -Raw
Assert-Contains $uiSource '\$env:ProgramData' 'UI uses the shared ProgramData environment path'
Assert-Contains $uiSource "'control.ini'" 'UI writes the runtime control file'
Assert-Contains $uiSource "'status.txt'" 'UI reads the runtime status file'
Assert-Contains $uiSource 'function Set-Enabled' 'UI exposes a control-file writer'
Assert-Contains $uiSource 'Add_Click' 'UI toggle button has a click handler'
Assert-Contains $uiSource 'ShowDialog' 'UI creates and displays a WinForms window'
Assert-Contains $uiLauncher 'ExecutionPolicy Bypass' 'UI launcher permits the packaged PowerShell script'
Assert-Contains $uiLauncher 'MicBridgeUI.ps1' 'UI launcher targets the adjacent UI script'

$apoSource = Get-Content -LiteralPath (Join-Path $root 'src/MicBridgeAPO.cpp') -Raw
Assert-Contains $apoSource 'm_blender\.Process\(outb, frames, ch, m_recvRing, true, tmp\)' 'APOProcess uses the tested crossfade blender'
Assert-Contains $apoSource 'm_resampler\.Process\(in, frames, step, m_rs\.data\(\), m_rs\.size\(\)\)' 'UDP receive uses the tested stateful resampler'
Assert-Contains $apoSource 'm_latencyHns\.store' 'APO reports its configured jitter-buffer latency'
Assert-Contains $apoSource 'm_resetProcessRequested' 'APO Reset defers process state changes to the processing thread'
Assert-Contains $apoSource 'SO_REUSEADDR' 'APO can share the fixed ReaStream broadcast port'
Assert-Contains $apoSource 'IsLocalIPv4' 'APO accepts only packets sourced from local interfaces'
Assert-Contains $apoSource 'ReadRegMultiStringContains' 'APO startup diagnostics inspect the composite EFX registration list'
Assert-Contains $apoSource 'CompositeEFXMatch' 'APO startup diagnostics report composite EFX endpoint matches'
Assert-Contains $apoSource 'control.ini' 'APO reads the UI runtime control file'
Assert-Contains $apoSource 'GetPrivateProfileIntW\(L"Control", L"Enabled"' 'APO polls the UI Enabled switch'
Assert-Contains $apoSource 'm_userEnabled\.load' 'APO bypasses processing when the UI disables the bridge'
Assert-Contains $apoSource 'void WriteStatus\(\)' 'APO publishes runtime status for the UI'
Assert-Contains $apoSource 'status\.txt' 'APO writes the UI status file'
Assert-Contains $apoSource 'GetSystemTimeAsFileTime' 'APO status timestamp uses Windows FILETIME'
Assert-Contains $apoSource 'Invalid bridge configuration' 'APO rejects invalid UDP ports and identical stream identifiers'
Assert-Contains $apoSource 'm_sendRingDrops.fetch_add' 'APO counts samples dropped by the transmit ring'
Assert-Contains $apoSource 'm_recvRingDrops.fetch_add' 'APO counts samples dropped by the receive ring'
Assert-Contains (Get-Content -LiteralPath (Join-Path $root 'tools/Test-ApoRuntime.ps1') -Raw) 'NoRingOverflowDrops' 'Runtime probe reports ring overflow status'
Assert-Contains (Get-Content -LiteralPath (Join-Path $root 'tools/Test-ApoRuntime.ps1') -Raw) 'SharedUdpPortOwnedByCantabileAndAudioDG' 'Runtime probe confirms both processes own UDP/58710'
Assert-Contains (Get-Content -LiteralPath (Join-Path $root 'tools/Test-ApoRuntime.ps1') -Raw) 'UdpReceiveBindFailed' 'Runtime probe reports UDP bind failure'
Assert-Contains $uninstaller 'matchesBaseline' 'Uninstaller restores original composite-property absence when vendor state is unchanged'
Assert-Contains $uninstaller 'backup.json is missing' 'Uninstaller fails closed when the recovery backup is missing'
Assert-Contains $uninstaller 'preflightIds' 'Uninstaller validates all capture endpoint value types before registry changes'
Assert-Contains $uninstaller 'cleanupIds' 'Uninstaller scans all capture endpoints for stale MicBridge references'
Assert-Contains $installer 'Windows AudioDG protection setting left unchanged' 'Installer leaves Windows AudioDG protection unchanged'
Assert-NotContains $installer 'Set-ItemProperty[^\r\n]*DisableProtectedAudioDG' 'Installer never changes DisableProtectedAudioDG'
Assert-NotContains $installer 'PrevDisableProtectedAudioDG' 'New backups never record the legacy AudioDG value'
Assert-NotContains $uninstaller 'Set-ItemProperty[^\r\n]*DisableProtectedAudioDG' 'Uninstaller never writes a legacy AudioDG value'
Assert-NotContains $uninstaller 'Remove-ItemProperty[^\r\n]*DisableProtectedAudioDG' 'Uninstaller never deletes the Windows AudioDG setting'
Assert-Contains $uninstaller 'legacy backup data is not a trustworthy snapshot' 'Uninstaller explicitly ignores the untrusted legacy AudioDG backup'

Assert-Contains (Get-Content -LiteralPath (Join-Path $root 'tools/Inspect-ApoEndpoint.ps1') -Raw) 'PKEY_CompositeFX_EndpointEffectClsid' 'Endpoint inspector reports composite EFX registration'
$cmake = Get-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Raw
Assert-Contains $cmake 'micbridge_udp_broadcast_share_smoke' 'Windows CI runs the UDP broadcast fan-out test'
Assert-Contains $cmake 'iphlpapi' 'APO links IP Helper for local sender validation'


Assert-NotContains $installer 'Set-Content -LiteralPath \$backupFile' 'Installer never rewrites the original backup.json during legacy migration'
Assert-Contains $installer 'added in memory only' 'Legacy backup migration is non-destructive'
Assert-Contains $installer 'Snapshot the currently installed state for transaction rollback' 'Installer captures the pre-attempt state'

Assert-Contains $installer 'function Write-JsonAtomic' 'Installer writes recovery JSON through an atomic replacement helper'
Assert-Contains $installer '\[IO\.File\]::Replace' 'Atomic JSON helper replaces an existing snapshot atomically'
Assert-Contains $installer '\$publishBackup\s*=\s*Join-Path\s+\$installDir' 'DLL publication keeps a same-directory copy of the previous image'
Assert-Contains $installer '\[IO\.File\]::Replace\(\$stagedDll,\$installedDll,\$publishBackup,\$false\)' 'DLL publication never uses a null replacement backup'
Assert-Contains $installer 'Remove-Item -LiteralPath \$publishBackup' 'DLL publication removes its temporary previous-image copy only after hash verification'
Assert-Contains $installer '\$replacementBackup\s*=\s*Join-Path\s+\$directory' 'Atomic JSON replacement uses a same-directory backup file'
Assert-Contains $installer '\[IO\.File\]::Replace\(\$temp,\s*\$Path,\s*\$replacementBackup,\s*\$true\)' 'Atomic JSON replacement never passes an empty backup path'
Assert-Contains $installer 'Remove-Item -LiteralPath \$replacementBackup' 'Atomic JSON replacement cleans up its temporary backup'
Assert-Contains $installer 'ComRegistrationSnapshotVersion = 1' 'Permanent backup records the COM snapshot schema version'
Assert-Contains $installer 'com-registration-backup' 'Permanent COM recovery files live outside temporary transaction folders'
Assert-Contains $installer 'previous-clsid.reg' 'Permanent backup names the original COM CLSID export'
Assert-Contains $installer 'previous-audioengine-apo.reg' 'Permanent backup names the original AudioEngine APO export'
Assert-Contains $installer 'existing backup predates persistent COM recovery data' 'Installer refuses unsafe upgrades with legacy backups'
Assert-Contains $uninstaller 'ComRegistrationSnapshotVersion' 'Uninstaller requires a persistent COM recovery snapshot before mutation'
Assert-Contains $uninstaller 'Composite EFX recovery record is missing; uninstall stopped before changing' 'Uninstaller fails closed when the original composite EFX snapshot is missing'
Assert-Contains $uninstaller 'PSObject\.Properties\.Name -notcontains ''Exists''' 'Uninstaller requires the composite snapshot Exists field'
Assert-Contains $uninstaller '\$preflightComposite\.Exists -isnot \[bool\]' 'Uninstaller rejects a non-Boolean composite Exists field'
Assert-Contains $uninstaller 'PSObject\.Properties\.Name -notcontains ''Kind''' 'Uninstaller requires the composite snapshot Kind field'
Assert-Contains $uninstaller 'preflightComposite\.Kind -ne ''MultiString''' 'Uninstaller accepts only the MultiString recovery kind'
Assert-Contains $uninstaller 'PSObject\.Properties\.Name -notcontains ''Value''' 'Uninstaller requires the composite snapshot Value field'
Assert-Contains $uninstaller '\$preflightComposite\.Value -isnot \[array\]' 'Uninstaller requires the composite recovery value to be a list'
Assert-Contains $uninstaller 'TryParse\(\$effectId' 'Uninstaller validates every saved composite CLSID'
Assert-Contains $uninstaller 'expectedComFiles' 'Uninstaller validates both COM recovery file identities before mutation'
Assert-Contains $uninstaller 'GetFullPath' 'Uninstaller canonicalizes recorded COM recovery paths'
Assert-Contains $uninstaller 'OrdinalIgnoreCase' 'Uninstaller rejects COM recovery paths outside the installer-owned location'
Assert-Contains $uninstaller 'does not contain its expected registry root' 'Uninstaller validates the exported COM registry root'
Assert-Contains $uninstaller 'contains an unexpected registry tree' 'Uninstaller rejects unrelated registry trees in COM recovery exports'
Assert-Contains $uninstaller 'Windows Registry Editor Version 5\.00' 'Uninstaller validates the original COM registry export header'
Assert-Contains $uninstaller 'if \(\$preflightBackup\.PrevClsidRegistrationExists\)' 'Uninstaller validates the saved CLSID export when it existed'
Assert-Contains $uninstaller 'if \(\$preflightBackup\.PrevApoRegistrationExists\)' 'Uninstaller validates the saved AudioEngine export when it existed'
Assert-Contains $uninstaller 'PrevClsidRegistrationExists' 'Uninstaller restores the pre-install COM CLSID when it existed'
Assert-Contains $uninstaller 'PrevApoRegistrationExists' 'Uninstaller restores the pre-install AudioEngine APO registration when it existed'
Assert-Contains $uninstaller 'reg.exe import' 'Uninstaller imports persistent pre-install COM registrations'
Assert-Contains $uninstaller 'uninstall-cleanup-recovery.json' 'Uninstaller keeps file/service cleanup in a separate durable journal'
Assert-Contains $uninstaller "@\('RemoveDesktopShortcut','RestartAudioService','RemoveInstallDirectory'\)" 'Uninstaller declares independent shortcut, service, and directory cleanup steps'
Assert-Contains $uninstaller "StepId 'RemoveDesktopShortcut'" 'Uninstaller journals desktop shortcut removal'
Assert-Contains $uninstaller "StepId 'RestartAudioService'" 'Uninstaller journals audio service restart'
Assert-Contains $uninstaller "StepId 'RemoveInstallDirectory'" 'Uninstaller journals install directory removal'
Assert-Contains $uninstaller 'serviceRestartMarker' 'Uninstaller persists evidence that the audio service restart completed'
Assert-Contains $uninstaller 'Get-Service -Name Audiosrv' 'Uninstaller verifies the audio service is running after restart'
Assert-Contains $uninstaller 'preserveInstallDirectory' 'Uninstaller preserves files when original COM registrations may reference the installed DLL'
Assert-Contains $uninstaller 'Do not run a broad cleanup over every endpoint' 'Uninstaller avoids deleting pre-existing CLSID references on unrelated endpoints'
Assert-Contains $uninstaller 'remainingReferences' 'Uninstaller blocks binary removal if dangling endpoint references cannot be made safe'
Assert-Contains $installer 'Write-JsonAtomic\s+-Value\s+\$transactionState\s+-Path\s+\$transactionStateFile' 'Transaction snapshot uses atomic JSON persistence'
Assert-Contains $installer 'Write-JsonAtomic\s+-Value\s+\(\[pscustomobject\]@\{' 'Composite EFX snapshot uses atomic JSON persistence'

Assert-Contains $installer 'reg.exe export' 'Installer snapshots existing COM registrations before changing them'
Assert-Contains $fullExecutor 'Restore-MBComRegistrySnapshot -Target CLSID' 'Full rollback executor restores the prior CLSID registration after a failed attempt'
Assert-Contains $installer 'Restore-RegistryValueSnapshot' 'Installer restores endpoint and audio registry values on failure'
Assert-Contains $installer 'MicBridge.InstallRollbackValidation.psm1' 'Installer loads the rollback snapshot validator before recovery mutations'
Assert-Contains $installer 'Test-MBInstallRollbackTransaction' 'Installer validates the durable transaction journal and snapshot before replay'
Assert-Contains $fullExecutor 'no recovery actions attempted' 'Full executor fails closed before any recovery mutation when preflight fails'
Assert-Contains $installer 'ClsidRegBackup' 'Transaction snapshot records the previous CLSID export path'
Assert-Contains $installer 'ClsidRegSha256' 'Transaction snapshot records the previous CLSID export hash'
Assert-Contains $installer 'ApoRegBackup' 'Transaction snapshot records the previous AudioEngine export path'
Assert-Contains $installer 'ApoRegSha256' 'Transaction snapshot records the previous AudioEngine export hash'
Assert-Contains $installer 'Test-MBRegistryExportSnapshot' 'Rollback verifies restored COM registry contents against the saved export hashes'
Assert-Contains $installer 'DataDirSddl' 'Installer snapshots and restores ProgramData ACLs'
Assert-Contains $installer 'InstallFiles' 'Installer snapshots overwritten support files'
Assert-Contains $uninstaller 'Legacy backup proves FxProperties did not exist' 'Uninstaller safely restores legacy association state'

# Exercise the exact REG_MULTI_SZ write/read contract in an isolated HKCU key.
$registryProbePath = "HKCU:\Software\MicBridgeAPO-CI-$PID"
try {
    New-Item -Path $registryProbePath -Force | Out-Null
    $expectedEffects = [string[]]@('{11111111-1111-1111-1111-111111111111}','{22222222-2222-2222-2222-222222222222}')
    Set-ItemProperty -LiteralPath $registryProbePath -Name 'CompositeEffects' -Value $expectedEffects -Type MultiString
    $probeKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\MicBridgeAPO-CI-$PID")
    if (-not $probeKey) { throw 'Could not reopen HKCU composite EFX probe key.' }
    try {
        if ($probeKey.GetValueKind('CompositeEffects') -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
            throw 'Set-ItemProperty did not create REG_MULTI_SZ.'
        }
        $actualEffects = [string[]]@($probeKey.GetValue('CompositeEffects'))
        if ($actualEffects.Count -ne 2 -or $actualEffects[0] -ne $expectedEffects[0] -or $actualEffects[1] -ne $expectedEffects[1]) {
            throw 'REG_MULTI_SZ values did not round-trip in order.'
        }
    } finally { $probeKey.Close() }
    Write-Host 'PASS: REG_MULTI_SZ registry write/read round-trip'
} finally {
    Remove-Item -LiteralPath $registryProbePath -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($scriptName in @('install.ps1','uninstall.ps1','MicBridgeUI.ps1','tools/Test-ApoRuntime.ps1','tools/Inspect-ApoEndpoint.ps1','tools/Test-ApoInstallerRegistration.ps1','tools/MicBridge.InstallRollbackValidation.psm1','tools/Test-MBInstallRollbackValidation.ps1','tools/MicBridge.RegistryAclRollback.psm1','tools/Test-MBRegistryAclRollback.ps1','tools/MicBridge.LegacyInstallAudit.psm1','tools/Test-MBLegacyInstallationAudit.ps1','tools/MicBridge.ComRegistrationRollback.psm1','tools/MicBridge.ComRegistrationExecutor.psm1','tools/Test-MBComRegistrationRollback.ps1','tools/MicBridge.RollbackExecutor.psm1','tools/Test-MBRollbackExecutor.ps1','tools/MicBridge.InstallFileRollback.psm1','tools/MicBridge.InstallFileExecutor.psm1','tools/Test-MBInstallFileRollback.ps1','tools/MicBridge.InstallMetadataRollback.psm1','tools/MicBridge.MetadataExecutor.psm1','tools/Test-MBInstallMetadataRollback.ps1','tools/MicBridge.FullInstallRollbackExecutor.psm1')) {
    $scriptPath = Join-Path $root $scriptName
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            Write-Host ("PowerShell parse error in {0} at line {1}, column {2}: {3}" -f $scriptName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
            Write-Host ("Offending text: {0}" -f $parseError.Extent.Text)
        }
        throw "PowerShell syntax validation failed for $scriptName"
    }
    Write-Host "PASS: PowerShell syntax $scriptName"
}


Assert-Contains $uninstaller 'Read-only global preflight: every capture endpoint value must have its documented registry type' 'Uninstaller performs the global endpoint type preflight'
Assert-Contains $uninstaller 'OpenSubKey\("\$capSub\\\$endpointId\\FxProperties"' 'Uninstaller uses normalized single-separator registry paths'
if ([regex]::Matches($uninstaller, [regex]::Escape('Read-only global preflight: every capture endpoint value must have its documented registry type')).Count -ne 1) { throw 'FAIL: Uninstaller must contain exactly one global preflight block' }
Write-Host 'PASS: Uninstaller contains exactly one global preflight block'
$completionLine = 'Write-Host "تمت الإزالة. الإعدادات والسجل ما زالت في $dataDir، احذفه يدويًا إن أردت."'
$completionIndex = $uninstaller.LastIndexOf($completionLine)
if ($completionIndex -lt 0 -or $uninstaller.Substring($completionIndex + $completionLine.Length).Trim().Length -ne 0) { throw 'FAIL: Uninstaller has executable content after its completion message' }
Write-Host 'PASS: No executable content follows the uninstall completion message'

Write-Host 'All installer registration static checks passed.'

Assert-Contains $installer 'Test-MBInstallRollbackTransaction -JournalPath \$candidateJournal -StatePath \$candidateSnapshotPath' 'Installer rejects interrupted journals paired with an invalid or mismatched transaction snapshot through strict preflight'
Assert-Contains $rollbackValidationModule '\$stateTransactionId -ne \$journalTransactionId' 'Snapshot validator rejects a journal from a different transaction'
$rollbackCatchStart = $installer.IndexOf('    $failure = $_')
$rollbackFinallyStart = $installer.IndexOf('} finally {', $rollbackCatchStart)
if ($rollbackCatchStart -lt 0 -or $rollbackFinallyStart -le $rollbackCatchStart) { throw 'FAIL: Could not isolate installer rollback catch block for service-control safety check' }
$rollbackCatch = $installer.Substring($rollbackCatchStart, $rollbackFinallyStart - $rollbackCatchStart)
if ($rollbackCatch -match '(?im)Restart-Service\s+-Name\s+Audiosrv') { throw 'FAIL: Install rollback must not restart or otherwise control Audiosrv' }
Write-Host 'PASS: Install rollback does not restart or control Audiosrv'

Assert-Contains $installer 'MicBridge.LegacyInstallAudit.psm1' 'Installer loads the read-only legacy installation audit'
Assert-Contains $installer 'Test-MBLegacyInstallationState' 'Installer audits legacy backup, COM registration, and file provenance before upgrade'
Assert-Contains $installer "Outcome -eq 'ReviewRequired'" 'Installer blocks ambiguous legacy state without automatic cleanup'
Assert-Contains $installer 'Original Windows baseline is not claimed as proven' 'Installer does not overstate the trustworthiness of a historical backup'
$auditPosition = $installer.IndexOf('Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
$checkpointPosition = $installer.IndexOf('Checkpoint-Computer',[StringComparison]::Ordinal)
if ($auditPosition -lt 0 -or $checkpointPosition -lt 0 -or $auditPosition -gt $checkpointPosition) {
    throw 'FAIL: legacy audit must run before the restore point and all installation mutations'
}
$repoRoot = $root
while (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.github/workflows/build.yml') -PathType Leaf)) {
    $parent = Split-Path -Parent $repoRoot
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $repoRoot) { throw 'FAIL: could not locate repository .github/workflows/build.yml' }
    $repoRoot = $parent
}
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/build.yml') -Raw
Assert-Contains $workflow 'MicBridge.LegacyInstallAudit.psm1' 'Build package stages the legacy audit module beside the installer'

Assert-Contains $uninstaller 'MicBridge.LegacyInstallAudit.psm1' 'Uninstaller loads the read-only legacy installation audit'
Assert-Contains $uninstaller 'Test-MBLegacyInstallationState' 'Uninstaller validates permanent backup provenance before restoring Windows state'
Assert-Contains $uninstaller 'Legacy installation audit requires manual review' 'Uninstaller preserves ambiguous legacy state without deleting files or registrations'
$uninstallAuditPosition = $uninstaller.IndexOf('Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
$uninstallJournalPosition = $uninstaller.IndexOf('New-MBRecoveryJournal',[StringComparison]::Ordinal)
if ($uninstallAuditPosition -lt 0 -or $uninstallJournalPosition -lt 0 -or $uninstallAuditPosition -gt $uninstallJournalPosition) {
    throw 'FAIL: uninstall legacy audit must run before recovery journal creation and all mutations'
}

Assert-Contains $installer 'InstalledSha256' 'Installer records the exact package support-file hashes for safe rollback ownership checks'
Assert-Contains $workflow 'MicBridge.InstallFileRollback.psm1' 'Build package stages the support-file rollback action module'
Assert-Contains $workflow 'MicBridge.InstallFileExecutor.psm1' 'Build package stages the durable support-file recovery executor'

Assert-Contains $installer 'IniOriginalSha256' 'Installer records original config-file hashes before changing ProgramData'
Assert-Contains $installer 'ShortcutNewSha256' 'Installer persists the shortcut ownership hash before publishing the shortcut'
Assert-Contains $workflow 'MicBridge.InstallMetadataRollback.psm1' 'Build package stages metadata rollback actions'
Assert-Contains $workflow 'MicBridge.MetadataExecutor.psm1' 'Build package stages durable metadata recovery executor'
Assert-Contains $workflow 'MicBridge.FullInstallRollbackExecutor.psm1' 'Build package stages the full transaction recovery executor'
Assert-Contains $workflow 'MicBridge.ComRegistrationRollback.psm1' 'Build package stages the COM rollback dependency required by the full executor'

Assert-Contains $fullExecutor 'RestoreEndpointFxValues' 'Full rollback executor preserves the fixed main transaction step order'
Assert-Contains $fullExecutor 'RestorePreviousInstallState' 'Full rollback executor reconstructs the grouped step from durable state'
Assert-Contains $fullExecutor 'Invoke-MBRecoveryStep' 'Full rollback executor uses durable journal step replay and verification'
Assert-Contains $fullExecutor 'Test-MBInstallRollbackTransaction' 'Full executor binds its snapshot to the durable main journal'
