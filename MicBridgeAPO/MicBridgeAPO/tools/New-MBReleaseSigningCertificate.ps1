[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Documents\MicBridgeAPO-Signing'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { throw 'This certificate bootstrap must run on Windows.' }
if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) { throw 'New-SelfSignedCertificate is unavailable. Run this script on Windows.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    if (@(Get-ChildItem -LiteralPath $output -Force -ErrorAction Stop).Count -gt 0) { throw "Output directory is not empty; refusing to overwrite signing material: $output" }
} else { New-Item -ItemType Directory -Path $output -Force | Out-Null }
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $output /inheritance:r /grant:r "*\${currentSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict permissions on the signing output directory.' }
$subject = 'CN=MicBridgeAPO Release Signing'
$cert = $null
try {
    $newCert = @{
        Type = 'CodeSigningCert'
        Subject = $subject
        CertStoreLocation = 'Cert:\CurrentUser\My'
        KeyAlgorithm = 'RSA'
        KeyLength = 3072
        HashAlgorithm = 'SHA256'
        KeyUsage = 'DigitalSignature'
        KeyExportPolicy = 'Exportable'
        NotAfter = (Get-Date).AddYears(5)
        TextExtension = @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
    }
    $cert = New-SelfSignedCertificate @newCert
    if (-not $cert.HasPrivateKey) { throw 'Generated certificate does not have a private key.' }
    if ($cert.Subject -ne $subject) { throw 'Generated certificate subject did not match the expected project identity.' }
    $cerPath = Join-Path $output 'MicBridgeAPO-Release-Signing.cer'
    $pfxPath = Join-Path $output 'MicBridgeAPO-Release-Signing.pfx'
    Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
    $pfxPassword = Read-Host 'Choose a strong, unique password for the private PFX file' -AsSecureString
    if ($null -eq $pfxPassword -or $pfxPassword.Length -lt 14) { throw 'PFX password must contain at least 14 characters.' }
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword -ChainOption EndEntityCertOnly | Out-Null
    $publicCert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath)
    try {
        $thumbprint = $publicCert.Thumbprint.ToUpperInvariant()
        $sha256 = (Get-FileHash -LiteralPath $cerPath -Algorithm SHA256).Hash
        $summary = [ordered]@{
            Product = 'MicBridgeAPO'
            Subject = $publicCert.Subject
            ThumbprintSha1 = $thumbprint
            CertificateFileSha256 = $sha256
            NotBeforeUtc = $publicCert.NotBefore.ToUniversalTime().ToString('o')
            NotAfterUtc = $publicCert.NotAfter.ToUniversalTime().ToString('o')
            PrivateKeyExported = $true
            PrivateKeyLocation = 'PFX file; keep it outside the repository'
            TrustInstalled = $false
            ReleaseSigningEnabled = $false
        }
        $summaryPath = Join-Path $output 'MicBridgeAPO-Release-Certificate-Info.json'
        $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
        Write-Host ''
        Write-Host 'CERTIFICATE CREATED. No trust was installed and no release was signed.' -ForegroundColor Green
        Write-Host "Public certificate: $cerPath"
        Write-Host "Private PFX:        $pfxPath"
        Write-Host "Certificate info:   $summaryPath"
        Write-Host "SHA-1 thumbprint:   $thumbprint"
        Write-Host "Certificate SHA256: $sha256"
        Write-Host ''
        Write-Warning 'Never commit, email, or paste the PFX file or its password. Do not install trust until the public certificate fingerprint is independently reviewed.'
    } finally { $publicCert.Dispose() }
} catch {
    if (Test-Path -LiteralPath (Join-Path $output 'MicBridgeAPO-Release-Signing.pfx')) { Remove-Item -LiteralPath (Join-Path $output 'MicBridgeAPO-Release-Signing.pfx') -Force -ErrorAction SilentlyContinue }
    throw
}
