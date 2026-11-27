$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$installerPath = Join-Path $repoRoot 'MicBridgeAPO/MicBridgeAPO/install.ps1'
$buildWorkflowPath = Join-Path $repoRoot '.github/workflows/build.yml'
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/signed-release.yml'
foreach ($path in @($installerPath,$buildWorkflowPath,$releaseWorkflowPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required provenance integration file is missing: $path" }
}
$installer = Get-Content -LiteralPath $installerPath -Raw
$build = Get-Content -LiteralPath $buildWorkflowPath -Raw
$release = Get-Content -LiteralPath $releaseWorkflowPath -Raw

$verifyIndex = $installer.IndexOf('Test-MBInstallProvenanceManifest', [StringComparison]::Ordinal)
$elevationIndex = $installer.IndexOf('Start-Process powershell -Verb RunAs', [StringComparison]::Ordinal)
$diagnosticsIndex = $installer.IndexOf('# Establish operation-specific diagnostics', [StringComparison]::Ordinal)
if ($verifyIndex -lt 0 -or $elevationIndex -lt 0 -or $diagnosticsIndex -lt 0 -or
    -not ($verifyIndex -lt $elevationIndex -and $verifyIndex -lt $diagnosticsIndex)) {
    throw 'FAIL: signed package verification must execute before elevation, logging, locks, or installer preflight.'
}
foreach ($pattern in @(
    'install-manifest[.]json',
    'install-manifest[.]p7s',
    'MicBridge[.]InstallProvenanceManifest[.]psm1',
    '29BAC42BFC53F2586559A9B95D1FEEB658E8891A',
    'SignatureVerified',
    'ManifestVerified',
    'FileProvenanceVerified'
)) {
    if ($installer -notmatch $pattern) { throw "FAIL: installer signed-package gate is missing invariant: $pattern" }
}
if ($installer -notmatch 'A signed MicBridge release package is required' -or
    $installer -notmatch 'no elevation or installation was attempted') {
    throw 'FAIL: missing manifest/signature/verifier must fail closed before elevation.'
}

$serviceIndex = $installer.IndexOf("Restart-Service -Name Audiosrv -Force", [StringComparison]::Ordinal)
$receiptCreateIndex = $installer.IndexOf('New-MBInstallTransactionReceipt', [StringComparison]::Ordinal)
$receiptVerifyIndex = $installer.IndexOf('Test-MBInstallTransactionReceipt -ReceiptPath $receiptPath -VerifyInstalledFiles', [StringComparison]::Ordinal)
$successIndex = $installer.IndexOf("Write-InstallLog 'INFO' 'Installation completed successfully.'", [StringComparison]::Ordinal)
$transactionCleanupIndex = $installer.IndexOf("Remove-Item -LiteralPath $transactionDir -Recurse -Force -ErrorAction Stop", [StringComparison]::Ordinal)
if ($serviceIndex -lt 0 -or $receiptCreateIndex -le $serviceIndex -or
    $receiptVerifyIndex -le $receiptCreateIndex -or $successIndex -le $receiptVerifyIndex -or
    $transactionCleanupIndex -le $successIndex) {
    throw 'FAIL: receipt must be created and verified after successful system setup and before transaction cleanup/completion.'
}
foreach ($pattern in @(
    'MicBridgeAPO[.]dll',
    'MicBridgeUI[.]ps1',
    'MicBridgeUI[.]bat',
    'uninstall[.]ps1',
    'uninstall[.]bat',
    'OwnershipProven',
    'ComOwnershipProven',
    'IsExecutionAuthorized'
)) {
    if ($installer -notmatch $pattern) { throw "FAIL: receipt integration is missing expected evidence/safety invariant: $pattern" }
}
if ($installer -notmatch 'ReceiptIntegrityVerified' -or $installer -notmatch 'InstalledFilesVerified') {
    throw 'FAIL: installer does not independently verify the persisted receipt and installed file hashes.'
}
if ($build -notmatch 'MicBridge[.]InstallTransactionReceipt[.]psm1' -or
    $build -notmatch 'Test-MBInstallerProvenanceGate[.]ps1') {
    throw 'FAIL: ordinary CI package staging or installer provenance integration test is missing.'
}
if ($release -notmatch 'MicBridge[.]InstallTransactionReceipt[.]psm1' -or
    $release -notmatch 'Test-MBInstallProvenanceManifest') {
    throw 'FAIL: signed release workflow must stage receipt support and verify the release manifest after signing.'
}

Write-Host 'PASS: signed package verification precedes elevation and every installer mutation/preflight.'
Write-Host 'PASS: installer fails closed when signed manifest, signature, verifier, or trust checks are unavailable.'
Write-Host 'PASS: successful install writes and independently verifies a machine-bound transaction receipt before declaring completion.'
Write-Host 'PASS: CI and signed release package staging include the receipt module and provenance verifier.'
