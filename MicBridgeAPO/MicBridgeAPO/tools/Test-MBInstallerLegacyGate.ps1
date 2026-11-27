$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'install.ps1'
$workflowPath = Join-Path (Split-Path -Parent (Split-Path -Parent $repoRoot)) '.github\workflows\build.yml'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "Installer source missing: $installerPath" }
if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { throw "Build workflow missing: $workflowPath" }

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ("FAIL: install.ps1 parser errors: " + (@($parseErrors | ForEach-Object Message) -join '; ')) }

$source = [IO.File]::ReadAllText($installerPath)
$workflow = [IO.File]::ReadAllText($workflowPath)
$marker = '# Read-only legacy audit gate: never install over unidentified or legacy MicBridge state.'
$start = $source.IndexOf($marker,[StringComparison]::Ordinal)
$end = $source.IndexOf('$compositeBackupFile = Join-Path $dataDir',$start,[StringComparison]::Ordinal)
if ($start -lt 0 -or $end -le $start) { throw 'FAIL: clean-install legacy audit gate is missing or misplaced.' }
$gate = $source.Substring($start,$end-$start)

foreach ($required in @(
    'Import-Module -Name $legacyAuditModule',
    'Test-MBLegacyInstallationState',
    '-IgnoreLegacyRecoveryBackups',
    '$blockingLegacyClasses',
    "'MicBridgeCandidate'",
    "'MicBridgeBinaryCandidate'",
    "'MicBridgeSupportFileCandidate'",
    "'ForeignOrSharedServer'",
    "'UnclassifiedFile'",
    "'ReparsePointPreserved'",
    'Old recovery files were not restored or changed.',
    'No installation was attempted.'
)) {
    if (-not $gate.Contains($required)) { throw "FAIL: clean-install gate is missing required invariant: $required" }
}
if ($gate.Contains("'MicBridgeRecoveryEvidence'")) { throw 'FAIL: legacy recovery evidence must not be included in the clean-install blocking classifications.' }
if ($gate -match '(?i)\b(Remove-Item|Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|reg\.exe\s+(delete|add))\b') {
    throw 'FAIL: clean-install audit gate must remain read-only.'
}
if (-not $gate.Contains('$legacyAudit.OwnershipProven -ne $false') -or
    -not $gate.Contains("$legacyAudit.OwnershipEvidenceStatus -ne 'NotEstablished'")) {
    throw 'FAIL: audit gate must not claim ownership or original Windows baseline proof.'
}

foreach ($required in @(
    '$backupFile = Join-Path $dataDir ''install-baseline-v2.json''',
    '$compositeBackupFile = Join-Path $dataDir ''install-composite-baseline-v2.json''',
    'install-com-registration-baseline-v2',
    'Test-MBInstallTransactionReceipt -ReceiptPath $activeReceipt.FullName -VerifyInstalledFiles',
    'No current-installer receipt exists',
    'BaselineEvidenceSha256',
    "-Filter 'transactions-v2-*'",
    'transactions-v2-'
)) {
    if (-not $source.Contains($required)) { throw "FAIL: installer is missing clean-install/managed-upgrade invariant: $required" }
}
if ($source -notmatch '(?s)Test-MBLegacyInstallationState[^\r\n]*-ExpectedDeviceId[^\r\n]*-IgnoreLegacyRecoveryBackups') {
    throw 'FAIL: managed upgrade audit must ignore legacy backup content while checking current live state.'
}

$auditCalls = @([regex]::Matches($source,'\$legacyAudit\s*=\s*Test-MBLegacyInstallationState')).Count
$checkpoint = $source.IndexOf("Checkpoint-Computer -Description 'قبل MicBridge APO'",[StringComparison]::Ordinal)
$lastAudit = $source.LastIndexOf('$legacyAudit = Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
if ($auditCalls -lt 2 -or $lastAudit -lt 0 -or $checkpoint -le $lastAudit) {
    throw 'FAIL: clean-install and managed-upgrade audit gates must both run before restore-point/snapshot mutations.'
}

$cleanupOnly = @('MicBridge.LegacyCleanupPlan.psm1','MicBridge.LegacyCleanupJournal.psm1','MicBridge.LegacyCleanupPreflight.psm1','MicBridge.LegacyApprovalSignature.psm1','MicBridge.LegacyFileHandleLease.psm1')
foreach ($name in $cleanupOnly) {
    if ($source.Contains($name) -or $workflow.Contains($name)) { throw "FAIL: unapproved legacy cleanup prototype is connected: $name" }
}
$modules = @('MicBridge.RecoveryJournal.psm1','MicBridge.InstallRollbackValidation.psm1','MicBridge.FullInstallRollbackExecutor.psm1','MicBridge.LegacyInstallAudit.psm1','MicBridge.RegistryAclRollback.psm1','MicBridge.InstallTransactionReceipt.psm1','MicBridge.InstallPackageFileLease.psm1')
foreach ($name in $modules) {
    if (-not $source.Contains($name) -or -not $workflow.Contains($name)) { throw "FAIL: installer dependency is missing from source or package staging: $name" }
}
if (-not $workflow.Contains('Test-MBInstallerLegacyGate.ps1') -or -not $workflow.Contains("Copy-Item 'build/Release/MicBridgeAPO.dll'")) {
    throw 'FAIL: CI must run this gate test and stage the built APO DLL.'
}
Write-Host 'PASS: clean install preserves and ignores legacy recovery files; live/ambiguous state blocks; upgrades require a receipt-backed v2 baseline; legacy transaction folders are not replayed.'
