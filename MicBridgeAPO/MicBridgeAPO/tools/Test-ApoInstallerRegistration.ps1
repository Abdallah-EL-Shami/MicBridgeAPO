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
Assert-Contains $installer 'elseif \(\$backup\.PrevFxAssociation\)' 'Installer falls back to the original KS node association for legacy installs'
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


Assert-Contains $installer 'function Write-InstallLog' 'Installer defines diagnostic logging'
Assert-Contains $installer 'Installation failed:' 'Installer logs detailed failure exceptions'
Assert-Contains $installer 'dll-backups' 'Installer preserves the previous DLL before replacement'
Assert-Contains $installer 'Previous DLL restored' 'Installer attempts DLL restoration after failure'
Assert-Contains $installer 'ولا توجد بيانات كافية لإثبات قيمتها الأصلية' 'Installer refuses to guess legacy backup association values'
Assert-NotContains $installer 'existingAssociation = [(]Get-ItemProperty' 'Installer does not infer historical association from current registry state'

Assert-Contains $installer 'PKEY_CompositeFX_EndpointEffectClsid' 'Installer uses the Windows 10 composite endpoint-effect property'
Assert-Contains $installer '\$fxCompositeValue\s*=\s*''\{d04e05a6-594b-4fb6-a80d-01af5eed7d1d\},15''' 'Installer targets the composite EFX property key'
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

$apoSource = Get-Content -LiteralPath (Join-Path $root 'src/MicBridgeAPO.cpp') -Raw
Assert-Contains $apoSource 'm_blender\.Process\(outb, frames, ch, m_recvRing, true, tmp\)' 'APOProcess uses the tested crossfade blender'
Assert-Contains $apoSource 'm_resampler\.Process\(in, frames, step, m_rs\.data\(\), m_rs\.size\(\)\)' 'UDP receive uses the tested stateful resampler'
Assert-Contains $apoSource 'm_latencyHns\.store' 'APO reports its configured jitter-buffer latency'
Assert-Contains $apoSource 'm_resetProcessRequested' 'APO Reset defers process state changes to the processing thread'
Assert-Contains $apoSource 'SO_REUSEADDR' 'APO can share the fixed ReaStream broadcast port'
Assert-Contains $apoSource 'IsLocalIPv4' 'APO accepts only packets sourced from local interfaces'
$cmake = Get-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Raw
Assert-Contains $cmake 'micbridge_udp_broadcast_share_smoke' 'Windows CI runs the UDP broadcast fan-out test'
Assert-Contains $cmake 'iphlpapi' 'APO links IP Helper for local sender validation'


Assert-NotContains $installer 'Set-Content -LiteralPath \$backupFile' 'Installer never rewrites the original backup.json during legacy migration'
Assert-Contains $installer 'added in memory only' 'Legacy backup migration is non-destructive'
Assert-Contains $installer 'Snapshot the currently installed state for transaction rollback' 'Installer captures the pre-attempt state'
Assert-Contains $installer 'reg.exe export' 'Installer snapshots existing COM registrations before changing them'
Assert-Contains $installer 'reg.exe import' 'Installer restores prior COM registrations after a failed attempt'
Assert-Contains $installer 'Restore-RegistryValueSnapshot' 'Installer restores endpoint and audio registry values on failure'
Assert-Contains $installer 'DataDirSddl' 'Installer snapshots and restores ProgramData ACLs'
Assert-Contains $installer 'InstallFiles' 'Installer snapshots overwritten support files'
Assert-Contains $uninstaller 'Legacy backup proves FxProperties did not exist' 'Uninstaller safely restores legacy association state'

foreach ($scriptName in @('install.ps1','uninstall.ps1','tools/Test-ApoRuntime.ps1','tools/Test-ApoInstallerRegistration.ps1')) {
    $scriptPath = Join-Path $root $scriptName
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $parseErrors | ForEach-Object { Write-Error ("PowerShell parse error in {0}: {1}" -f $scriptName, $_.Message) }
        throw "PowerShell syntax validation failed for $scriptName"
    }
    Write-Host "PASS: PowerShell syntax $scriptName"
}

Write-Host 'All installer registration static checks passed.'
