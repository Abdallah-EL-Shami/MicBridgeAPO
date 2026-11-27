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
$launcherPath = Join-Path $repoRoot 'MicBridgeAPO/MicBridgeAPO/install.bat'
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { throw 'Installer launcher is missing.' }
$launcher = Get-Content -LiteralPath $launcherPath -Raw
if ($launcher -match '(?i)PublisherSignatureVerified' -or $launcher -notmatch '(?i)install[.]ps1' -or $launcher -notmatch '(?i)-ExecutionPolicy Bypass') {
    throw 'FAIL: install.bat must remain fail-closed and must not assert manual publisher verification on the operator\'s behalf.'
}
$release = Get-Content -LiteralPath $releaseWorkflowPath -Raw

$manualTrustIndex = $installer.IndexOf('if (-not $PublisherSignatureVerified)',[StringComparison]::Ordinal)
$scriptSignatureIndex = $installer.IndexOf('Get-AuthenticodeSignature -FilePath $scriptFile.FullName',[StringComparison]::Ordinal)
$verifierImportIndex = $installer.IndexOf('Import-Module -Name $provenanceVerifier',[StringComparison]::Ordinal)
$manifestVerifyIndex = $installer.IndexOf('Test-MBInstallProvenanceManifest',[StringComparison]::Ordinal)
$elevationIndex = $installer.IndexOf('Start-Process powershell -Verb RunAs',[StringComparison]::Ordinal)
$diagnosticsIndex = $installer.IndexOf('# Establish operation-specific diagnostics',[StringComparison]::Ordinal)
if ($manualTrustIndex -lt 0 -or $scriptSignatureIndex -le $manualTrustIndex -or
    $verifierImportIndex -le $scriptSignatureIndex -or $manifestVerifyIndex -le $verifierImportIndex -or
    $elevationIndex -le $manifestVerifyIndex -or $diagnosticsIndex -le $manifestVerifyIndex) {
    throw 'FAIL: manual pinned-publisher confirmation, all script signatures, manifest verification, and pre-elevation ordering are not enforced.'
}
foreach ($pattern in @(
    'PublisherSignatureVerified',
    'manualBootstrapTrustEstablished',
    'Get-AuthenticodeSignature',
    '29BAC42BFC53F2586559A9B95D1FEEB658E8891A',
    'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369',
    'SignerCertificate\.Thumbprint',
    'GetCertHashString',
    'trustedReleaseCertificateSha256',
    'SignatureStatus\]::NotTrusted',
    'install-manifest[.]json',
    'install-manifest[.]p7s',
    'SignatureVerified',
    'ManifestVerified',
    'FileProvenanceVerified',
    'PackageFilesPinnedForUse',
    'Close-MBInstallProvenanceLeases'
)) {
    if ($installer -notmatch $pattern) { throw "FAIL: installer bootstrap/provenance invariant is missing: $pattern" }
}
if ($installer -notmatch '(?s)-not\s+\$manualBootstrapTrustEstablished' -or
    $installer -notmatch 'A signed MicBridge release package is required' -or
    $installer -notmatch 'no elevation or installation was attempted') {
    throw 'FAIL: installer must fail closed without manual trust and signed package evidence.'
}

$receiptCreate = $installer.IndexOf('New-MBInstallTransactionReceipt',[StringComparison]::Ordinal)
$receiptVerify = $installer.IndexOf('Test-MBInstallTransactionReceipt -ReceiptPath $receiptPath -VerifyInstalledFiles',[StringComparison]::Ordinal)
$success = $installer.IndexOf("Write-InstallLog 'INFO' 'Installation completed successfully.'",[StringComparison]::Ordinal)
if ($receiptCreate -lt 0 -or $receiptVerify -le $receiptCreate -or $success -le $receiptVerify) {
    throw 'FAIL: transaction receipt must be created and independently verified before installation success.'
}
foreach ($required in @(
    'BaselineEvidenceSha256',
    '$baselineSha256 = (Get-FileHash -LiteralPath $backupFile',
    '-BaselineEvidenceSha256 $baselineSha256',
    '$activeReceiptCheck.BaselineEvidenceSha256',
    'ReceiptIntegrityVerified',
    'InstalledFilesVerified',
    'OwnershipProven',
    'ComOwnershipProven',
    'IsExecutionAuthorized'
)) {
    if (-not $installer.Contains($required)) { throw "FAIL: receipt/baseline evidence invariant is missing: $required" }
}

foreach ($workflow in @(@{Name='build.yml';Text=$build},@{Name='signed-release.yml';Text=$release})) {
    foreach ($required in @('MicBridge.InstallTransactionReceipt.psm1','MicBridge.InstallPackageFileLease.psm1','Test-MBInstallerProvenanceGate.ps1','INSTALL-TRUST-AR.md')) {
        if (-not $workflow.Text.Contains($required)) { throw "FAIL: $($workflow.Name) omits package/test dependency: $required" }
    }
}
if ($release -notmatch '(?s)\$scriptFiles\s*=.*?Set-AuthenticodeSignature.*?Get-AuthenticodeSignature.*?\$manifestBytes\s*=') {
    throw 'FAIL: signed release must sign and verify every PowerShell script before creating the signed manifest.'
}
Write-Host 'PASS: manual pinned publisher bootstrap precedes module import; all PowerShell scripts are pinned by SHA-1/SHA-256; signed manifest and files precede elevation.'
Write-Host 'PASS: machine-bound receipt authenticates the independent v2 baseline and is verified before success.'
