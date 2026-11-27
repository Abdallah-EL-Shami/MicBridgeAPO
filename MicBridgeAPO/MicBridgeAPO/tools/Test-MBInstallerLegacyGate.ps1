$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$workflow = Join-Path (Split-Path -Parent (Split-Path -Parent $repoRoot)) '.github\workflows\build.yml'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Installer source missing: $installer" }
if (-not (Test-Path -LiteralPath $workflow -PathType Leaf)) { throw "Build workflow missing: $workflow" }

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw ("FAIL: install.ps1 has PowerShell parse errors: " + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}

$source = [IO.File]::ReadAllText($installer)
$workflowSource = [IO.File]::ReadAllText($workflow)
$gateMarker = '# Read-only legacy audit gate: never install over unidentified or legacy MicBridge state.'
$gateStart = $source.IndexOf($gateMarker,[StringComparison]::Ordinal)
$gateEnd = $source.IndexOf('$compositeBackupFile = Join-Path $dataDir', $gateStart, [StringComparison]::Ordinal)
if ($gateStart -lt 0 -or $gateEnd -le $gateStart) { throw 'FAIL: first-install legacy audit gate is missing or misplaced.' }
$gate = $source.Substring($gateStart,$gateEnd-$gateStart)

if (-not $gate.Contains("Import-Module -Name `$legacyAuditModule -Force -ErrorAction Stop")) { throw 'FAIL: installer does not import the read-only legacy audit module.' }
if (-not $gate.Contains("Test-MBLegacyInstallationState -InstallDirectory `$installDir -DataDirectory `$dataDir -RegistryRoot 'HKLM:\'")) { throw 'FAIL: installer does not audit the intended HKLM root.' }
if (-not $gate.Contains("'MicBridgeCandidate'" ) -or -not $gate.Contains("'MicBridgeBinaryCandidate'" ) -or -not $gate.Contains("'ForeignOrSharedServer'")) { throw 'FAIL: clean-install gate does not block live MicBridge or foreign COM registrations.' }
if (-not $gate.Contains('Old recovery files were not restored or changed.') -or $gate.Contains("'MicBridgeRecoveryEvidence'")) { throw 'FAIL: clean-install gate must preserve and ignore old recovery evidence rather than treating it as a blocking live artifact.' }
if (-not $gate.Contains("`$legacyAudit.OwnershipProven -ne `$false") -or -not $gate.Contains("`$legacyAudit.OwnershipEvidenceStatus -ne 'NotEstablished'")) { throw 'FAIL: installer does not require the audit to report ownership as unproven.' }
if (-not $gate.Contains('No installation was attempted.')) { throw 'FAIL: blocked install does not explain that no installation was attempted.' }
if ($gate -match '(?i)\b(Remove-Item|Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|reg\.exe\s+(delete|add))\b') {
    throw 'FAIL: first-install audit gate contains a Registry or file mutation command.'
}

$auditCall1 = $source.IndexOf('$legacyAudit = Test-MBLegacyInstallationState',$gateStart,[StringComparison]::Ordinal)
$auditCall2 = $source.IndexOf('$legacyAudit = Test-MBLegacyInstallationState',$auditCall1+1,[StringComparison]::Ordinal)
$upgradeCheckpoint = $source.IndexOf("Checkpoint-Computer -Description 'قبل MicBridge APO'",$auditCall2,[StringComparison]::Ordinal)
if ($auditCall1 -lt 0 -or $auditCall2 -le $auditCall1 -or $upgradeCheckpoint -le $auditCall2) {
    throw 'FAIL: both first-install and upgrade paths must audit before the first restore-point/snapshot mutation.'
}
if (-not $source.Contains('$backupFile = Join-Path $dataDir ''install-baseline-v2.json''') -or -not $source.Contains('$compositeBackupFile = Join-Path $dataDir ''install-composite-baseline-v2.json''')) { throw 'FAIL: new installer must use fresh v2 baseline paths and leave legacy backup.json untouched.' }
if (-not $source.Contains('Test-MBInstallTransactionReceipt -ReceiptPath $activeReceipt.FullName -VerifyInstalledFiles') -or -not $source.Contains('No current-installer receipt exists')) { throw 'FAIL: managed upgrade must require a valid current-installer receipt.' }
if ($source -notmatch "-Filter 'transactions-v2-\*'" -or $source -notmatch 'transactions-v2-') { throw 'FAIL: new installer must recover only its own v2 transaction journals and leave legacy transactions-* folders untouched.' }
if (-not $workflowSource.Contains("Copy-Item -LiteralPath `$legacyAuditModule -Destination `$toolsPackage")) {
    throw 'FAIL: package staging does not include the required legacy audit module.'
}

# Legacy cleanup planning, approval and handle-lease prototypes must remain outside
# the installer/package until race-safe path-relative deletion is independently proven.
$cleanupOnlyModules = @(
    'MicBridge.LegacyCleanupPlan.psm1',
    'MicBridge.LegacyCleanupJournal.psm1',
    'MicBridge.LegacyCleanupPreflight.psm1',
    'MicBridge.LegacyApprovalSignature.psm1',
    'MicBridge.LegacyFileHandleLease.psm1'
)
foreach ($moduleName in $cleanupOnlyModules) {
    if ($source.Contains($moduleName)) {
        throw "FAIL: installer references cleanup prototype '$moduleName' before security approval."
    }
    if ($workflowSource.Contains($moduleName)) {
        throw "FAIL: install package stages cleanup prototype '$moduleName' before security approval."
    }
}
if (-not $workflowSource.Contains('Test-MBInstallerLegacyGate.ps1')) {
    throw 'FAIL: CI workflow does not run this installer-gate contract test.'
}

# Verify every module imported from the installer's adjacent tools folder is staged.
$moduleNames = @('MicBridge.RecoveryJournal.psm1','MicBridge.InstallRollbackValidation.psm1','MicBridge.FullInstallRollbackExecutor.psm1','MicBridge.LegacyInstallAudit.psm1','MicBridge.RegistryAclRollback.psm1')
foreach ($moduleName in $moduleNames) {
    if (-not $source.Contains($moduleName)) { throw "FAIL: installer does not reference expected module '$moduleName'." }
    if (-not $workflowSource.Contains($moduleName)) { throw "FAIL: package staging omits installer dependency '$moduleName'." }
}
if (-not $workflowSource.Contains("Copy-Item 'build/Release/MicBridgeAPO.dll' `$package")) {
    throw 'FAIL: staged package does not include the freshly built APO DLL.'
}

Write-Host 'PASS: installer parses; clean install preserves legacy recovery evidence without restoring it; managed upgrade requires receipt-backed files and clean COM state; audit gate is read-only; modules and APO DLL are staged.'
