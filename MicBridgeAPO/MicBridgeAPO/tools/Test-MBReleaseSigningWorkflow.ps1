$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$releasePath = Join-Path $repoRoot '.github/workflows/signed-release.yml'
$buildPath = Join-Path $repoRoot '.github/workflows/build.yml'
foreach ($path in @($releasePath,$buildPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required workflow file is missing: $path" }
}
$release = Get-Content -LiteralPath $releasePath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw

$requiredReleasePatterns = [ordered]@{
    'version-tag push trigger' = 'push:\s*tags:\s*-\s*''v\*'''
    'manual dispatch trigger' = '(?m)^\s*workflow_dispatch:\s*$'
    'tag-only job guard' = "github\.ref_type\s*==\s*'tag'.*startsWith\(github\.ref,\s*'refs/tags/v'\)"
    'protected signing environment' = '(?m)^\s*environment:\s*$[\r\n]+\s*name:\s*release-signing\s*$'
    'PFX Base64 environment secret' = 'MB_RELEASE_SIGNING_PFX_BASE64:\s*\$\{\{\s*secrets\.MB_RELEASE_SIGNING_PFX_BASE64\s*\}\}'
    'PFX password environment secret' = 'MB_RELEASE_SIGNING_PFX_PASSWORD:\s*\$\{\{\s*secrets\.MB_RELEASE_SIGNING_PFX_PASSWORD\s*\}\}'
    'pinned SHA-1 certificate thumbprint' = '29BAC42BFC53F2586559A9B95D1FEEB658E8891A'
    'pinned SHA-256 certificate fingerprint' = 'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369'
    'persistent private-key container import' = 'Import-PfxCertificate'
    'attached CMS SignedData signature' = 'SignedCms'
    'post-signature verification' = 'Test-MBInstallProvenanceManifest'
    'UI UTF-16LE BOM normalization before signing' = 'UnicodeEncoding\]::new\(\$false,\$true,\$true\)'
    'UI encoding round-trip verification' = 'normalizedText\s*-cne\s*\$uiScript'
    'temporary PFX cleanup' = 'Remove-Item\s+-LiteralPath\s+\$pfxPath\s+-Force'
    'secret environment cleanup' = 'Remove-Item\s+Env:MB_RELEASE_SIGNING_PFX_PASSWORD'
    'signed release artifact' = 'MicBridgeAPO-Signed-Release'
}
foreach ($entry in $requiredReleasePatterns.GetEnumerator()) {
    if ($release -notmatch $entry.Value) { throw "Release signing workflow is missing invariant: $($entry.Key)" }
}
if ($release -match '(?im)^\s*push\s*:\s*\r?\n\s*branches\s*:') { throw 'Release signing workflow must never trigger on branch pushes.' }
if ($release -match '(?im)^\s*pull_request\s*:') { throw 'Release signing workflow must never subscribe to pull_request.' }
if ($release -match '(?i)upload-artifact[\s\S]{0,500}\.pfx') { throw 'Private PFX material must never be uploaded as an artifact.' }
if ($release -match '(?i)Cert:\\\\CurrentUser\\\\Root|Import-Certificate|rootCertAdded|rootStorePath') {
    throw 'Release signing workflow must not promote the self-signed leaf certificate into a trusted Root store.'
}
if ($release -notmatch 'terminated in a root certificate which is not trusted by the trust provider' -or
    $release -notmatch 'SignatureStatus]::UnknownError' -or
    $release -notmatch 'SignatureStatus]::Valid' -or
    $release -notmatch 'Authenticode digest or pinned signer verification failed') {
    throw 'Release signing workflow must accept only Valid or the exact untrusted-root status for the pinned signer, while rejecting digest mismatches.'
}
if ($release -notmatch 'AUTHENTICODE NEGATIVE CONTROL PASSED' -or
    $release -notmatch 'ReadAllBytes\(\$uiScript[.]FullName\)' -or
    $release -notmatch 'SignatureStatus]::HashMismatch') {
    throw 'Release signing workflow must prove MicBridgeUI.ps1 content tampering is rejected.'
}
if ($release -notmatch 'WINDOWS POWERSHELL 5[.]1 UI SIGNATURE DIGEST AND PINNED SIGNER VERIFIED' -or
    $release -notmatch 'WindowsPowerShell/v1[.]0/powershell[.]exe' -or
    $release -notmatch '\$scriptFile[.]Name -eq ''MicBridgeUI[.]ps1''' -or
    $release -notmatch '\$signature[.]SignerCertificate[.]Thumbprint -ne \$Thumbprint' -or
    $release -notmatch '& \$isAcceptable \$signResult' -or
    $release -notmatch '& \$isAcceptable \$verifyResult' -or
    $release -notmatch 'MicBridgeUI[.]ps1') {
    throw 'MicBridgeUI.ps1 must be signed and digest-verified by Windows PowerShell 5.1 with the pinned signer.'
}
if ($release -notmatch 'MicBridge\.InstallTransactionReceipt\.psm1') { throw 'Signed release package must stage the machine-bound transaction receipt module.' }
foreach ($testName in @('Test-MBInstallTransactionReceipt[.]ps1','Test-MBInstallerProvenanceGate[.]ps1')) {
    if ($release -notmatch [regex]::Escape($testName.Replace('[.]','.'))) {
        throw "Signed release workflow must run the provenance integration test: $testName"
    }
}
if ($build -notmatch 'Test-MBInstallTransactionReceipt\.ps1') { throw 'Ordinary CI must execute transaction receipt security tests.' }
if ($build -notmatch 'Test-MBUIEncoding\.ps1') { throw 'Ordinary CI must execute the MicBridgeUI UTF-16LE and Windows PowerShell 5.1 parser regression test.' }
foreach ($workflowName in @('build','release')) {
    $workflowContent = if ($workflowName -eq 'build') { $build } else { $release }
    if ($workflowContent -notmatch 'powershell[.]exe -NoProfile -ExecutionPolicy Bypass -File ./MicBridgeAPO/MicBridgeAPO/tools/Test-MBInstallProvenanceManifest[.]ps1' -or
        $workflowContent -notmatch 'powershell[.]exe -NoProfile -ExecutionPolicy Bypass -File ./MicBridgeAPO/MicBridgeAPO/tools/Test-MBInstallTransactionReceipt[.]ps1') {
        throw "$workflowName workflow must exercise manifest and receipt modules under Windows PowerShell 5.1."
    }
}
if ($build -match 'MB_RELEASE_SIGNING_PFX_(BASE64|PASSWORD)') { throw 'Ordinary build workflow must never reference release signing secrets.' }
if ($build -match '(?im)^\s*environment:\s*release-signing\s*$') { throw 'Ordinary build workflow must never enter the protected signing environment.' }

Write-Host 'PASS: release signing workflow has tag-only gating, protected environment, pinned certificate, attached CMS SignedData verification, and private-key cleanup.'
Write-Host 'PASS: ordinary build workflow has no release signing secrets or protected signing environment.'
