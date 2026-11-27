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
$launcherDesignPath = Join-Path $repositoryRoot 'docs\BOOTSTRAP-LAUNCHER-SECURITY-DESIGN.md'
$cmakePath = Join-Path $projectRoot 'CMakeLists.txt'
$launcherSourcePath = Join-Path $projectRoot 'src\MicBridgeBootstrap.cpp'
$trustSourcePath = Join-Path $projectRoot 'src\MicBridgeBootstrapTrust.cpp'
$trustHeaderPath = Join-Path $projectRoot 'src\MicBridgeBootstrapTrust.h'
$signatureTestPath = Join-Path $projectRoot 'tests\bootstrap_signature_rejects_unsigned.cpp'
$launcherTestPath = Join-Path $projectRoot 'tests\bootstrap_fail_closed.cpp'

foreach ($required in @($installerPath,$batchPath,$manifestVerifierPath,$buildWorkflowPath,$releaseWorkflowPath,$readinessPath,$launcherDesignPath,$cmakePath,$launcherSourcePath,$trustSourcePath,$trustHeaderPath,$signatureTestPath,$launcherTestPath)) {
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
$launcherDesign = [IO.File]::ReadAllText($launcherDesignPath)
$cmake = [IO.File]::ReadAllText($cmakePath)
$launcherSource = [IO.File]::ReadAllText($launcherSourcePath)
$trustSource = [IO.File]::ReadAllText($trustSourcePath)
$trustHeader = [IO.File]::ReadAllText($trustHeaderPath)
$signatureTest = [IO.File]::ReadAllText($signatureTestPath)
$launcherTest = [IO.File]::ReadAllText($launcherTestPath)

if ($batch -notmatch '(?im)^\s*powershell(?:\.exe)?\s+-NoProfile\s+-ExecutionPolicy\s+AllSigned\s+-File\s+"%~dp0install\.ps1"\s*$') {
    throw 'FAIL: install.bat must launch install.ps1 with AllSigned and a script path anchored to the package directory.'
}

$verifierImportIndex = $installer.IndexOf('Import-Module -Name $provenanceVerifier',[StringComparison]::Ordinal)
$verifyCallIndex = $installer.IndexOf('$verifiedPackage = Test-MBInstallProvenanceManifest',[StringComparison]::Ordinal)
if ($verifierImportIndex -lt 0 -or $verifyCallIndex -lt 0 -or $verifierImportIndex -ge $verifyCallIndex) {
    throw 'FAIL: bootstrap audit expected to detect the current verifier-module execution before manifest verification; review and replace this test when an independent bootstrap is implemented.'
}
if ($readiness -notmatch '(?im)code therefore runs before the package authenticates that module') {
    throw 'FAIL: readiness document must explicitly disclose that the package verifier executes before package authentication.'
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
if ($installer -notmatch '(?s)-not\s+\$verifiedPackage\.BootstrapTrustEstablished') {
    throw 'FAIL: installer must refuse installation unless an independent bootstrap trust mechanism explicitly establishes trust.'
}
if ($installer -notmatch '(?s)\$verifiedPackage\s*=\s*Test-MBInstallProvenanceManifest\b[^\r\n]*-PinFiles' -or
    $installer -notmatch '(?s)\$verifiedPackage\.BootstrapTrustEstablished') {
    throw 'FAIL: installer must request pinned package files and explicitly retain the bootstrap-trust boundary result.'
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
if ($cmake -notmatch '(?s)add_executable\(MicBridgeBootstrap\s+src/MicBridgeBootstrap\.cpp\s+src/MicBridgeBootstrapTrust\.cpp\s*\)' -or
    $cmake -notmatch '(?s)add_executable\(micbridge_bootstrap_signature_test\s+tests/bootstrap_signature_rejects_unsigned\.cpp\s+src/MicBridgeBootstrapTrust\.cpp\s*\)' -or
    $cmake -notmatch '(?s)add_test\(NAME micbridge_bootstrap_rejects_unsigned\s+COMMAND micbridge_bootstrap_signature_test \$<TARGET_FILE:micbridge_bootstrap_fail_closed>\)' -or
    $cmake -notmatch '(?s)add_test\(NAME micbridge_bootstrap_fail_closed\s+COMMAND micbridge_bootstrap_fail_closed \$<TARGET_FILE:MicBridgeBootstrap>\)' -or
    $launcherSource -notmatch '(?s)return 78;' -or
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
if ($launcherDesign -notmatch '(?im)Status: \*\*security design documented; fail-closed native CMake scaffold and CTest added; signature/manifest verification, file pinning, authenticated handoff, and production launch are not implemented; production installation remains blocked\.\*\*' -or
    $launcherDesign -notmatch '(?im)Required verification sequence' -or
    $launcherDesign -notmatch '(?im)Required negative and adversarial tests') {
    throw 'FAIL: independent native launcher design and its blocked/not-implemented status must remain present.'
}
if ($readiness -notmatch '(?im)Bootstrap trust boundary \(not yet closed\)' -or
    $readiness -notmatch '(?im)Execution policy is not a security boundary') {
    throw 'FAIL: security readiness document must explicitly retain the unresolved bootstrap trust limitation.'
}

Write-Host 'PASS: Current bootstrap limitation is explicitly detected and not misrepresented as independently trusted. Static ordering, release-signing contracts, native fail-closed scaffold wiring, and the launcher design/status were also checked.'
Write-Host 'LIMIT: this test documents a known unresolved bootstrap flaw. It does not establish trust, validate Windows trust-store state, or authorize production installation.'
