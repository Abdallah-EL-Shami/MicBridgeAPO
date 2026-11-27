[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:ProgramFiles 'MicBridgeAPO'),
    [string]$DataDirectory = (Join-Path $env:ProgramData 'MicBridgeAPO'),
    [ValidatePattern('^(HKLM:|HKCU:)\\.*$')]
    [string]$RegistryRoot = 'HKLM:\',
    [guid]$ExpectedDeviceId = [guid]::Empty,
    [Parameter(Mandatory)]
    [switch]$PublisherSignatureVerified
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PublisherSignatureVerified) {
    throw 'Verify this script signature and compare the publisher SHA-256/SHA-1 pins in INSTALL-TRUST-AR.md before rerunning with -PublisherSignatureVerified. No system changes were attempted.'
}

$trustedReleaseThumbprint = '29BAC42BFC53F2586559A9B95D1FEEB658E8891A'
$trustedReleaseCertificateSha256 = 'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369'
$modulePath = Join-Path $PSScriptRoot 'MicBridge.LegacyInstallAudit.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Read-only audit module is missing: $modulePath"
}

$moduleSignature = Get-AuthenticodeSignature -FilePath $modulePath
if ($moduleSignature.Status -notin @([System.Management.Automation.SignatureStatus]::Valid,[System.Management.Automation.SignatureStatus]::NotTrusted) -or
    $null -eq $moduleSignature.SignerCertificate -or
    -not $moduleSignature.SignerCertificate.Thumbprint.Equals($trustedReleaseThumbprint,[StringComparison]::OrdinalIgnoreCase) -or
    -not $moduleSignature.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).Equals($trustedReleaseCertificateSha256,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Read-only audit module signature or pinned publisher identity is invalid. No system changes were attempted.'
}

Import-Module -Name $modulePath -Force -ErrorAction Stop
$audit = Test-MBLegacyInstallationState -InstallDirectory $InstallDirectory -DataDirectory $DataDirectory -RegistryRoot $RegistryRoot -ExpectedDeviceId $ExpectedDeviceId
if (-not $audit.IsReadOnly -or $audit.CleanupAllowed -ne $false -or $audit.OwnershipProven -ne $false -or $audit.OriginalWindowsBaselineProven -ne $false) {
    throw 'Audit module returned an unsafe or inconsistent result. No system changes were attempted.'
}

$report = [pscustomobject]@{
    SchemaVersion = 1
    Product = 'MicBridgeAPO'
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    RegistryRoot = $RegistryRoot
    InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
    DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
    IsReadOnly = $true
    CleanupAllowed = $false
    OwnershipProven = $false
    OriginalWindowsBaselineProven = $false
    Outcome = $audit.Outcome
    BaselineAssessment = $audit.BaselineAssessment
    Findings = @($audit.Findings)
    Warnings = @($audit.Warnings)
}
$report | ConvertTo-Json -Depth 8
