$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallProvenanceManifest.psm1') -Force

$root=Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeProvenance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$rsa=[Security.Cryptography.RSA]::Create(2048)
$cert=$null
try {
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new(
        [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge Manifest CI Signer'),
        $rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
    $oids=[Security.Cryptography.OidCollection]::new()
    [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
    $cert=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))
    $pfx=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,'ci-only')
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx,'ci-only',
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)

    $bin=Join-Path $root 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($bin,[byte[]](1,3,5,7,9))
    $hash=(Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash
    $manifest=[ordered]@{
        SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
        InstallTransactionId=[guid]::NewGuid().ToString()
        Files=@(@{RelativePath='MicBridgeAPO.dll';Sha256=$hash})
        ComRegistrations=@()
    }
    $manifestPath=Join-Path $root 'install-manifest.json'
    $signaturePath=Join-Path $root 'install-manifest.p7s'
    $json=ConvertTo-Json -InputObject ([pscustomobject]$manifest) -Compress -Depth 8
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    [IO.File]::WriteAllBytes($manifestPath,$bytes)
    $cms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($bytes),$false)
    $signer=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $signer.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $cms.ComputeSignature($signer)
    [IO.File]::WriteAllBytes($signaturePath,$cms.Encode())

    $args=@{ManifestPath=$manifestPath;SignaturePath=$signaturePath;InstallDirectory=$root;TrustedSignerThumbprints=@($cert.Thumbprint)}
    $ok=Test-MBInstallProvenanceManifest @args
    if(-not $ok.ManifestVerified -or -not $ok.FileProvenanceVerified -or $ok.OwnershipProven -or
       $ok.ComOwnershipProven -or $ok.IsExecutionAuthorized -or $ok.VerifiedFiles.Count -ne 1) {
        throw 'FAIL: manifest verification returned unsafe or incomplete capability flags.'
    }

    $wrongTrust=$false
    try { $bad=$args.Clone();$bad.TrustedSignerThumbprints=@('0000000000000000000000000000000000000000');Test-MBInstallProvenanceManifest @bad | Out-Null } catch { $wrongTrust=$true }
    if(-not $wrongTrust) { throw 'FAIL: untrusted manifest signer was accepted.' }

    [IO.File]::WriteAllBytes($bin,[byte[]](2,4,6,8,10))
    $hashMismatch=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null } catch { $hashMismatch=$_.Exception.Message -match 'Manifest file hash mismatch' }
    if(-not $hashMismatch) { throw 'FAIL: modified installed file passed manifest verification.' }

    Write-Host 'PASS: signed manifest trust, signer purpose, transaction identity and file hashes verified; COM ownership and execution remain unproven.'
} finally {
    if($cert){$cert.Dispose()}
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
