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

foreach ($required in @($installerPath,$batchPath,$manifestVerifierPath,$buildWorkflowPath,$releaseWorkflowPath,$readinessPath)) {
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

if ($batch -notmatch '(?im)^\s*powershell(?:\.exe)?\s+-NoProfile\s+-ExecutionPolicy\s+AllSigned\s+-File\s+"%~dp0install\.ps1"\s*$') {
    throw 'FAIL: install.bat must launch install.ps1 with AllSigned and a script path anchored to the package directory.'
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
if ($readiness -notmatch '(?im)Bootstrap trust boundary \(not yet closed\)' -or
    $readiness -notmatch '(?im)Execution policy is not a security boundary') {
    throw 'FAIL: security readiness document must explicitly retain the unresolved bootstrap trust limitation.'
}

Write-Host 'PASS: AllSigned launcher, pre-elevation/pre-log/pre-lock package gate, pinned-file request, non-authorization flags, release script-signing order, and documented unresolved bootstrap boundary are contract-checked.'
Write-Host 'LIMIT: this is a static source contract; it does not prove Windows trust-store state or resist an operator deliberately bypassing PowerShell execution policy.'
