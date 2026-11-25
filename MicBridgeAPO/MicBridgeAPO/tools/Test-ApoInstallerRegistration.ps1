$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
$uninstaller = Get-Content -LiteralPath (Join-Path $root 'uninstall.ps1') -Raw

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
Assert-Contains $installer 'Previous DLL restored' 'Installer attempts DLL restoration after failure'
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
Assert-Contains $uninstaller 'PrevDisableProtectedAudioDG' 'Uninstaller restores the Windows audio security setting only from a recorded snapshot'
Assert-Contains $uninstaller 'leaving the current Windows audio security setting unchanged' 'Uninstaller does not guess a missing legacy audio security snapshot'
Assert-Contains (Get-Content -LiteralPath (Join-Path $root 'tools/Inspect-ApoEndpoint.ps1') -Raw) 'PKEY_CompositeFX_EndpointEffectClsid' 'Endpoint inspector reports composite EFX registration'
$cmake = Get-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Raw
Assert-Contains $cmake 'micbridge_udp_broadcast_share_smoke' 'Windows CI runs the UDP broadcast fan-out test'
Assert-Contains $cmake 'iphlpapi' 'APO links IP Helper for local sender validation'


Assert-NotContains $installer 'Set-Content -LiteralPath \$backupFile' 'Installer never rewrites the original backup.json during legacy migration'
Assert-Contains $installer 'added in memory only' 'Legacy backup migration is non-destructive'
Assert-Contains $installer 'Snapshot the currently installed state for transaction rollback' 'Installer captures the pre-attempt state'

Assert-Contains $installer 'function Write-JsonAtomic' 'Installer writes recovery JSON through an atomic replacement helper'
Assert-Contains $installer '\[IO\.File\]::Replace' 'Atomic JSON helper replaces an existing snapshot atomically'
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
Assert-Contains $uninstaller 'Windows Registry Editor Version 5\.00' 'Uninstaller validates the original COM registry export header'
Assert-Contains $uninstaller 'if \(\$preflightBackup\.PrevClsidRegistrationExists\)' 'Uninstaller validates the saved CLSID export when it existed'
Assert-Contains $uninstaller 'if \(\$preflightBackup\.PrevApoRegistrationExists\)' 'Uninstaller validates the saved AudioEngine export when it existed'
Assert-Contains $uninstaller 'PrevClsidRegistrationExists' 'Uninstaller restores the pre-install COM CLSID when it existed'
Assert-Contains $uninstaller 'PrevApoRegistrationExists' 'Uninstaller restores the pre-install AudioEngine APO registration when it existed'
Assert-Contains $uninstaller 'reg.exe import' 'Uninstaller imports persistent pre-install COM registrations'
Assert-Contains $uninstaller 'Do not run a broad cleanup over every endpoint' 'Uninstaller avoids deleting pre-existing CLSID references on unrelated endpoints'
Assert-Contains $uninstaller 'remainingReferences' 'Uninstaller blocks binary removal if dangling endpoint references cannot be made safe'
Assert-Contains $installer 'Write-JsonAtomic\s+-Value\s+\$transactionState\s+-Path\s+\$transactionStateFile' 'Transaction snapshot uses atomic JSON persistence'
Assert-Contains $installer 'Write-JsonAtomic\s+-Value\s+\(\[pscustomobject\]@\{' 'Composite EFX snapshot uses atomic JSON persistence'

Assert-Contains $installer 'reg.exe export' 'Installer snapshots existing COM registrations before changing them'
Assert-Contains $installer 'reg.exe import' 'Installer restores prior COM registrations after a failed attempt'
Assert-Contains $installer 'Restore-RegistryValueSnapshot' 'Installer restores endpoint and audio registry values on failure'
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

foreach ($scriptName in @('install.ps1','uninstall.ps1','MicBridgeUI.ps1','tools/Test-ApoRuntime.ps1','tools/Inspect-ApoEndpoint.ps1','tools/Test-ApoInstallerRegistration.ps1')) {
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
