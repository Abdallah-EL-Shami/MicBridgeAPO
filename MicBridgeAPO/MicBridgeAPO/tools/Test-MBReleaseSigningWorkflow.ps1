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
    'version tag trigger' = "(?m)^\s*-\s*'v\*'\s*$"
    'manual dispatch trigger' = '(?m)^\s*workflow_dispatch:\s*$'
    'tag-only job guard' = "github\.ref_type\s*==\s*'tag'.*startsWith\(github\.ref,\s*'refs/tags/v'\)"
    'protected signing environment' = '(?m)^\s*environment:\s*$[\r\n]+\s*name:\s*release-signing\s*$'
    'PFX Base64 environment secret' = 'MB_RELEASE_SIGNING_PFX_BASE64:\s*\$\{\{\s*secrets\.MB_RELEASE_SIGNING_PFX_BASE64\s*\}\}'
    'PFX password environment secret' = 'MB_RELEASE_SIGNING_PFX_PASSWORD:\s*\$\{\{\s*secrets\.MB_RELEASE_SIGNING_PFX_PASSWORD\s*\}\}'
    'pinned SHA-1 certificate thumbprint' = '29BAC42BFC53F2586559A9B95D1FEEB658E8891A'
    'pinned SHA-256 certificate fingerprint' = 'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369'
    'ephemeral private key storage' = 'EphemeralKeySet'
    'detached CMS signature' = 'SignedCms'
    'post-signature verification' = 'Test-MBInstallProvenanceManifest'
    'Authenticode script signing' = 'Set-AuthenticodeSignature'
    'Authenticode signature verification' = 'Get-AuthenticodeSignature'
    'public certificate artifact' = 'MicBridgeAPO-Release[.]cer'
    'AllSigned launcher enforcement' = 'AllSigned'
    'temporary PFX cleanup' = 'Remove-Item\s+-LiteralPath\s+\$pfxPath\s+-Force'
    'secret environment cleanup' = 'Remove-Item\s+Env:MB_RELEASE_SIGNING_PFX_PASSWORD'
    'signed release artifact' = 'MicBridgeAPO-Signed-Release'
}
foreach ($entry in $requiredReleasePatterns.GetEnumerator()) {
    if ($release -notmatch $entry.Value) { throw "Release signing workflow is missing invariant: $($entry.Key)" }
}
if ($release -match '(?im)^\s*pull_request\s*:') { throw 'Release signing workflow must never subscribe to pull_request.' }
if ($release -match '(?i)upload-artifact[\s\S]{0,500}\.pfx') { throw 'Private PFX material must never be uploaded as an artifact.' }
if ($release -notmatch 'MicBridge\.InstallTransactionReceipt\.psm1') { throw 'Signed release package must stage the machine-bound transaction receipt module.' }
if ($release -notmatch 'TrustedPublisher' -or $release -notmatch 'StoreName]::Root') { throw 'Release workflow must validate Authenticode signatures using temporary runner trust and remove that trust afterward.' }
if ($release -notmatch 'MicBridge\.InstallPackageFileLease\.psm1') { throw 'Signed release package must stage the mutation-resistant install package lease module.' }
foreach ($testName in @('Test-MBInstallTransactionReceipt[.]ps1','Test-MBInstallerProvenanceGate[.]ps1')) {
    if ($release -notmatch [regex]::Escape($testName.Replace('[.]','.'))) {
        throw "Signed release workflow must run the provenance integration test: $testName"
    }
}
if ($build -notmatch 'Test-MBInstallTransactionReceipt\.ps1') { throw 'Ordinary CI must execute transaction receipt security tests.' }
foreach ($workflowName in @('build','release')) {
    $workflowContent = if ($workflowName -eq 'build') { $build } else { $release }
    if ($workflowContent -notmatch 'powershell[.]exe -NoProfile -ExecutionPolicy Bypass -File ./MicBridgeAPO/MicBridgeAPO/tools/Test-MBInstallProvenanceManifest[.]ps1' -or
        $workflowContent -notmatch 'powershell[.]exe -NoProfile -ExecutionPolicy Bypass -File ./MicBridgeAPO/MicBridgeAPO/tools/Test-MBInstallTransactionReceipt[.]ps1') {
        throw "$workflowName workflow must exercise manifest and receipt modules under Windows PowerShell 5.1."
    }
}
if ($build -match 'MB_RELEASE_SIGNING_PFX_(BASE64|PASSWORD)') { throw 'Ordinary build workflow must never reference release signing secrets.' }
if ($build -match '(?im)^\s*environment:\s*release-signing\s*$') { throw 'Ordinary build workflow must never enter the protected signing environment.' }

Write-Host 'PASS: release signing workflow has tag-only gating, protected environment, pinned certificate, detached CMS verification, and private-key cleanup.'
Write-Host 'PASS: ordinary build workflow has no release signing secrets or protected signing environment.'
