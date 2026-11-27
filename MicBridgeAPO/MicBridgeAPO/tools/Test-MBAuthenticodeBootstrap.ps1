$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeAuthenticode-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(2048)
$cert = $null
$rootStore = $null
$publisherStore = $null
try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge CI Authenticode Signer'),
        $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
    $oids = [Security.Cryptography.OidCollection]::new()
    [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))

    # Do not mutate Windows trust stores in CI: test cryptographic signing and
    # tamper detection without installing a trust anchor or invoking trust UI.

    $scriptPath = Join-Path $root 'SignedProbe.ps1'
    [IO.File]::WriteAllText($scriptPath,"Write-Output 'AUTHENTICODE_PROBE_OK'"+[Environment]::NewLine,[Text.UTF8Encoding]::new($true))
    Write-Host 'AUTHENTICODE TEST: signing fixture'
    $signed = Set-AuthenticodeSignature -FilePath $scriptPath -Certificate $cert -HashAlgorithm SHA256
    Write-Host "AUTHENTICODE TEST: Set-AuthenticodeSignature status=$($signed.Status)"
    $verified = Get-AuthenticodeSignature -FilePath $scriptPath
    Write-Host "AUTHENTICODE TEST: Get-AuthenticodeSignature status=$($verified.Status)"
    if ($signed.Status -eq [Management.Automation.SignatureStatus]::NotSigned -or
        $signed.Status -eq [Management.Automation.SignatureStatus]::HashMismatch -or
        $verified.Status -eq [Management.Automation.SignatureStatus]::NotSigned -or
        $verified.Status -eq [Management.Automation.SignatureStatus]::HashMismatch -or
        $null -eq $verified.SignerCertificate -or
        $verified.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        throw "FAIL: Authenticode signature is absent, damaged, or has a different signer. Set=$($signed.Status); Verify=$($verified.Status)"
    }

    Add-Content -FilePath $scriptPath -Value '# tampered'
    $tampered = Get-AuthenticodeSignature -FilePath $scriptPath
    if ($tampered.Status -ne [Management.Automation.SignatureStatus]::HashMismatch) {
        throw "FAIL: modified signed script was not classified as HashMismatch. Status=$($tampered.Status)"
    }
    Write-Host 'AUTHENTICODE TEST: tampered script correctly reports HashMismatch'

    Write-Host 'PASS: Authenticode signature is present and matches the generated signer certificate.'
} finally {
    if ($cert) { $cert.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
