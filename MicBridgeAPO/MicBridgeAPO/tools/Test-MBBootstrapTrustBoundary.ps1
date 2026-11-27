$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $projectRoot)
$installerPath = Join-Path $projectRoot 'install.ps1'
$batchPath = Join-Path $projectRoot 'install.bat'
$manifestVerifierPath = Join-Path $projectRoot 'tools\MicBridge.InstallProvenanceManifest.psm1'
$buildWorkflowPath = Join-Path $repositoryRoot '.github\workflows\build.yml'
$releaseWorkflowPath = Join-Path $repositoryRoot '.github\workflows\signed-release.yml'
$readinessPath = Join-Path $projectRoot 'SECURITY-READINESS-AND-RELEASE-GATES.md'
$manualBootstrapGuidePath = Join-Path $projectRoot 'INSTALL-TRUST-AR.md'
$launcherDesignPath = Join-Path $repositoryRoot 'docs\BOOTSTRAP-LAUNCHER-SECURITY-DESIGN.md'
$cmakePath = Join-Path $projectRoot 'CMakeLists.txt'
$launcherSourcePath = Join-Path $projectRoot 'src\MicBridgeBootstrap.cpp'
$trustSourcePath = Join-Path $projectRoot 'src\MicBridgeBootstrapTrust.cpp'
$trustHeaderPath = Join-Path $projectRoot 'src\MicBridgeBootstrapTrust.h'
$signatureTestPath = Join-Path $projectRoot 'tests\bootstrap_signature_rejects_unsigned.cpp'
$launcherTestPath = Join-Path $projectRoot 'tests\bootstrap_fail_closed.cpp'

foreach ($required in @($installerPath,$batchPath,$manifestVerifierPath,$buildWorkflowPath,$releaseWorkflowPath,$readinessPath,$manualBootstrapGuidePath,$launcherDesignPath,$cmakePath,$launcherSourcePath,$trustSourcePath,$trustHeaderPath,$signatureTestPath,$launcherTestPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "FAIL: required bootstrap contract input is missing: $required" }
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw ("FAIL: installer parser errors: " + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}

$installer = [IO.File]::ReadAllText($installerPath)
$batch = [IO.File]::ReadAllText($batchPath)
$verifier = [IO.File]::ReadAllText($manifestVerifierPath)
$buildWorkflow = [IO.File]::ReadAllText($buildWorkflowPath)
$releaseWorkflow = [IO.File]::ReadAllText($releaseWorkflowPath)
$readiness = [IO.File]::ReadAllText($readinessPath)
$manualBootstrapGuide = [IO.File]::ReadAllText($manualBootstrapGuidePath)
$launcherDesign = [IO.File]::ReadAllText($launcherDesignPath)
$cmake = [IO.File]::ReadAllText($cmakePath)
$launcherSource = [IO.File]::ReadAllText($launcherSourcePath)
$trustSource = [IO.File]::ReadAllText($trustSourcePath)
$trustHeader = [IO.File]::ReadAllText($trustHeaderPath)
$revocationDesign = [IO.File]::ReadAllText($launcherDesignPath)
$signatureTest = [IO.File]::ReadAllText($signatureTestPath)
$launcherTest = [IO.File]::ReadAllText($launcherTestPath)

if ($batch -notmatch '(?im)^\s*powershell(?:\.exe)?\s+-NoProfile\s+-ExecutionPolicy\s+AllSigned\s+-File\s+"%~dp0install\.ps1"\s*$') {
    throw 'FAIL: install.bat must launch install.ps1 with AllSigned and a script path anchored to the package directory.'
}

$signatureLoopIndex = $installer.IndexOf('foreach ($scriptFile in $packageScripts)',[StringComparison]::Ordinal)
$signatureCallIndex = $installer.IndexOf('Get-AuthenticodeSignature -FilePath $scriptFile.FullName',[StringComparison]::Ordinal)
$manualTrustIndex = $installer.IndexOf('if (-not $PublisherSignatureVerified)',[StringComparison]::Ordinal)
$scriptSignatureIndex = $installer.IndexOf('Get-AuthenticodeSignature -FilePath $scriptFile.FullName',[StringComparison]::Ordinal)
$verifierImportIndex = $installer.IndexOf('Import-Module -Name $provenanceVerifier',[StringComparison]::Ordinal)
if ($manualTrustIndex -lt 0 -or $scriptSignatureIndex -lt 0 -or $verifierImportIndex -lt 0 -or
    -not ($manualTrustIndex -lt $scriptSignatureIndex -and $scriptSignatureIndex -lt $verifierImportIndex)) {
    throw 'FAIL: manual out-of-band publisher confirmation and all package script signatures must be checked before importing the manifest verifier.'
}
if ($installer -notmatch '(?s)-not\s+\$manualBootstrapTrustEstablished' -or
    $installer -notmatch '(?s)PublisherSignatureVerified' -or
    $installer -notmatch '(?s)SignatureStatus]::NotTrusted' -or
    $installer -notmatch '(?s)SignerCertificate\.Thumbprint -ne \$trustedReleaseThumbprint') {
    throw 'FAIL: installer must require explicit manual bootstrap confirmation and pin every script/module signature to the release signer.'
}
$verifyIndex = $installer.IndexOf('Test-MBInstallProvenanceManifest',[StringComparison]::Ordinal)
$elevationIndex = $installer.IndexOf('Start-Process powershell -Verb RunAs',[StringComparison]::Ordinal)
$diagnosticIndex = $installer.IndexOf('function Resolve-MBLogPath',[StringComparison]::Ordinal)
$lockIndex = $installer.IndexOf('Enter-MBRecoveryOperationLock',[StringComparison]::Ordinal)
if ($verifyIndex -lt 0 -or $elevationIndex -lt 0 -or $diagnosticIndex -lt 0 -or $lockIndex -lt 0 -or
    -not ($verifyIndex -lt $elevationIndex -and $verifyIndex -lt $diagnosticIndex -and $verifyIndex -lt $lockIndex)) {
    throw 'FAIL: signed package verification must precede elevation, log-path creation, and lock acquisition.'
}

$bootstrapPrefix = $installer.Substring(0,$verifyIndex)
if ($bootstrapPrefix -match '(?im)\b(Start-Process|New-Item|Add-Content|Set-ItemProperty|Remove-Item|reg\.exe|Enter-MBRecoveryOperationLock)\b') {
    throw 'FAIL: bootstrap prefix contains a process launch, file/log creation, registry mutation, or lock acquisition before verification.'
}
if ($installer -notmatch '(?s)\$verifiedPackage\s*=\s*Test-MBInstallProvenanceManifest\b[^\r\n]*-PinFiles' -or
    $installer -notmatch '(?s)-not\s+\$manualBootstrapTrustEstablished') {
    throw 'FAIL: installer must pin package files and require the independently confirmed manual bootstrap result.'
}
if ($verifier -notmatch '(?m)^\s*BootstrapTrustEstablished\s*=\s*\$false\s*$' -or
    $verifier -notmatch '(?m)^\s*RaceSafeForExecution\s*=\s*\$false\s*$') {
    throw 'FAIL: package verifier must not claim bootstrap trust or execution race safety.'
}

foreach ($workflow in @(@{Name='build.yml';Text=$buildWorkflow},@{Name='signed-release.yml';Text=$releaseWorkflow})) {
    if (-not $workflow.Text.Contains('Test-MBBootstrapTrustBoundary.ps1')) {
        throw "FAIL: $($workflow.Name) does not execute the bootstrap trust-boundary contract test."
    }
}
if ($releaseWorkflow -notmatch '(?s)\$scriptFiles\s*=.*?Set-AuthenticodeSignature.*?Get-AuthenticodeSignature.*?\$manifestBytes\s*=') {
    throw 'FAIL: release workflow must Authenticode-sign and verify every staged PowerShell script before creating the signed manifest.'
}
$nativeBuildContract = @(
    'add_executable(MicBridgeBootstrap'
    'src/MicBridgeBootstrap.cpp'
    'src/MicBridgeBootstrapTrust.cpp'
    'add_executable(micbridge_bootstrap_signature_test'
    'tests/bootstrap_signature_rejects_unsigned.cpp'
    'add_test(NAME micbridge_bootstrap_rejects_unsigned'
    'add_test(NAME micbridge_bootstrap_fail_closed'
    'wintrust crypt32 bcrypt'
)
foreach ($needle in $nativeBuildContract) {
    if (-not $cmake.Contains($needle)) { throw "FAIL: CMake bootstrap wiring is missing: $needle" }
}
if ($launcherSource -notmatch '(?s)return 78;' -or
    $launcherSource -match '(?i)CreateProcess|ShellExecute|WinVerifyTrust|CryptMsgOpenToDecode' -or
    $trustSource -notmatch '(?s)WinVerifyTrust' -or
    $trustSource -notmatch '(?s)WTHelperGetProvSignerFromChain' -or
    $trustSource -notmatch '(?s)WTHelperGetProvCertFromChain' -or
    $trustSource -notmatch '(?s)CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369' -or
    $trustHeader -notmatch '(?s)VerifyPinnedAuthenticodeSigner' -or
    $signatureTest -notmatch '(?s)VerifyPinnedAuthenticodeSigner' -or
    $signatureTest -notmatch '(?s)unsigned test executable unexpectedly passed' -or
    $launcherTest -notmatch '(?s)CreateProcessW' -or
    $launcherTest -notmatch '(?s)exitCode != 78') {
    throw 'FAIL: native bootstrap scaffold must compile as a CMake target and CTest must prove it exits fail-closed without launching a payload.'
}
if ($trustSource -notmatch '(?s)CertificateEncodingMatchesSha256' -or
    $trustSource -notmatch '(?s)MICBRIDGE_BOOTSTRAP_TESTING' -or
    $trustHeader -notmatch '(?s)TestCertificateEncodingMatchesSha256Pin' -or
    $signatureTest -notmatch '(?s)matching SHA-256 pin was rejected' -or
    $signatureTest -notmatch '(?s)mismatching SHA-256 pin was accepted' -or
    $signatureTest -notmatch '(?s)malformed pin-comparison input was accepted' -or
    $cmake -notmatch '(?s)MICBRIDGE_BOOTSTRAP_TESTING') {
    throw 'FAIL: test-only certificate pin comparator must cover matching, mismatching, malformed inputs and remain excluded from production targets.'
}

if ($launcherDesign -notmatch '(?im)Status: \*\*native fail-closed launcher scaffold plus a separately compiled WinVerifyTrust/pinned-SHA256 signer-verification component and unsigned-file negative test are implemented; the verifier is not yet called by the launcher; manifest/CMS verification, file pinning, authenticated handoff, and production launch are not implemented; production installation remains blocked\.\*\*' -or
    $launcherDesign -notmatch '(?im)Required verification sequence' -or
    $launcherDesign -notmatch '(?im)Required negative and adversarial tests') {
    throw 'FAIL: independent native launcher design and its blocked/not-implemented status must remain present.'
}
if ($trustSource -notmatch '(?s)WTD_REVOKE_NONE' -or
    $trustSource -notmatch '(?s)WTD_REVOCATION_CHECK_NONE' -or
    $trustSource -notmatch '(?s)WTD_CACHE_ONLY_URL_RETRIEVAL' -or
    $trustSource -notmatch '(?s)WTD_STATEACTION_CLOSE' -or
    $revocationDesign -notmatch '(?im)does \*\*not\*\* establish fresh revocation status' -or
    $revocationDesign -notmatch '(?im)Selected project policy: offline-capable pinned-certificate policy' -or
    $revocationDesign -notmatch '(?im)Do not generate a certificate per build' -or
    $revocationDesign -notmatch '(?im)independently authenticated channel') {
    throw 'FAIL: Native verifier flags must match the selected offline pinned-certificate policy, single active signer, and independently authenticated rotation procedure.'
}

if ($readiness -notmatch '(?im)Bootstrap trust boundary \(not yet closed\)' -or
    $readiness -notmatch '(?im)Execution policy is not a security boundary') {
    throw 'FAIL: security readiness document must explicitly retain the unresolved bootstrap trust limitation.'
}

Write-Host 'PASS: Current bootstrap limitation is explicitly detected and not misrepresented as independently trusted. Static ordering, release-signing contracts, native fail-closed scaffold wiring, and the launcher design/status were also checked.'
Write-Host 'LIMIT: this test documents a known unresolved bootstrap flaw. It does not establish trust, validate Windows trust-store state, or authorize production installation.'
