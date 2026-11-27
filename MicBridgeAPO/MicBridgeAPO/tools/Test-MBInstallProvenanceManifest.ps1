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

    # Altering the detached manifest bytes without re-signing must be rejected.
    $signedManifestBytes=[IO.File]::ReadAllBytes($manifestPath)
    $tamperedBytes=[byte[]]$signedManifestBytes.Clone()
    $tamperedBytes[0]=[byte]([int]$tamperedBytes[0] -bxor 1)
    [IO.File]::WriteAllBytes($manifestPath,$tamperedBytes)
    $tamperedManifestRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null } catch { $tamperedManifestRejected=$_.Exception.Message -match 'Manifest bytes differ' }
    if(-not $tamperedManifestRejected) { throw 'FAIL: manifest content changed after signing was accepted.' }
    [IO.File]::WriteAllBytes($manifestPath,$signedManifestBytes)

    # Even a correctly signed manifest must not permit traversal outside install root.
    $traversalManifest=[ordered]@{
        SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
        InstallTransactionId=[guid]::NewGuid().ToString()
        Files=@(@{RelativePath='../outside.dll';Sha256=$hash})
        ComRegistrations=@()
    }
    $traversalBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$traversalManifest) -Compress -Depth 8))
    [IO.File]::WriteAllBytes($manifestPath,$traversalBytes)
    $traversalCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($traversalBytes),$false)
    $traversalSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $traversalSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $traversalCms.ComputeSignature($traversalSigner)
    [IO.File]::WriteAllBytes($signaturePath,$traversalCms.Encode())
    $traversalRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null } catch { $traversalRejected=$_.Exception.Message -match 'unsafe relative path' }
    if(-not $traversalRejected) { throw 'FAIL: signed manifest path traversal was accepted.' }

    # Restore the valid signed manifest/signature before testing installed-file tampering.
    [IO.File]::WriteAllBytes($manifestPath,$signedManifestBytes)
    $originalCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($signedManifestBytes),$false)
    $originalSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $originalSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $originalCms.ComputeSignature($originalSigner)
    [IO.File]::WriteAllBytes($signaturePath,$originalCms.Encode())

    [IO.File]::WriteAllBytes($bin,[byte[]](2,4,6,8,10))
    $hashMismatch=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null } catch { $hashMismatch=$_.Exception.Message -match 'Manifest file hash mismatch' }
    if(-not $hashMismatch) { throw 'FAIL: modified installed file passed manifest verification.' }


    # A correctly signed manifest must still reject a path traversing a junction.
    $outsideDir=Join-Path $root 'outside-target'
    New-Item -ItemType Directory -Path $outsideDir | Out-Null
    $outsideFile=Join-Path $outsideDir 'outside.dll'
    [IO.File]::WriteAllBytes($outsideFile,[byte[]](31,41,59,26))
    $outsideHash=(Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
    $junctionPath=Join-Path $root 'manifest-junction'
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideDir -ErrorAction Stop | Out-Null
    try {
        $junctionManifest=[ordered]@{
            SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
            InstallTransactionId=[guid]::NewGuid().ToString()
            Files=@(@{RelativePath='manifest-junction\\outside.dll';Sha256=$outsideHash})
            ComRegistrations=@()
        }
        $junctionBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$junctionManifest) -Compress -Depth 8))
        [IO.File]::WriteAllBytes($manifestPath,$junctionBytes)
        $junctionCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($junctionBytes),$false)
        $junctionSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
            [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
        $junctionSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $junctionCms.ComputeSignature($junctionSigner)
        [IO.File]::WriteAllBytes($signaturePath,$junctionCms.Encode())
        $junctionRejected=$false
        try { Test-MBInstallProvenanceManifest @args | Out-Null }
        catch { $junctionRejected=$_.Exception.Message -match 'Manifest path traverses a reparse point' }
        if(-not $junctionRejected) { throw 'FAIL: correctly signed manifest traversing a junction was accepted.' }
    } finally {
        Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outsideDir -Recurse -Force -ErrorAction SilentlyContinue
    }


    # A trusted manifest cannot redirect the verifier by supplying an install-root junction.
    $rootAlias=Join-Path ([IO.Path]::GetDirectoryName($root)) ('MicBridgeProvenanceAlias-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Junction -Path $rootAlias -Target $root -ErrorAction Stop | Out-Null
    try {
        $rootAliasRejected=$false
        try { Test-MBInstallProvenanceManifest -ManifestPath $manifestPath -SignaturePath $signaturePath -InstallDirectory $rootAlias -TrustedSignerThumbprints @($cert.Thumbprint) | Out-Null }
        catch { $rootAliasRejected=$_.Exception.Message -match 'Install directory must be a real directory' }
        if(-not $rootAliasRejected) { throw 'FAIL: install root reached through a junction alias was accepted.' }
    } finally { Remove-Item -LiteralPath $rootAlias -Force -ErrorAction SilentlyContinue }

    # Restore the fixture bytes after the hash-mismatch probe so later tests isolate their intended condition.
    [IO.File]::WriteAllBytes($bin,[byte[]](1,3,5,7,9))
    $restoredHash=(Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash
    if(-not $restoredHash.Equals($hash,[StringComparison]::OrdinalIgnoreCase)) { throw 'FAIL: provenance fixture DLL could not be restored.' }

    # Duplicate paths are rejected case-insensitively before file verification.
    $duplicateManifest=[ordered]@{
        SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
        InstallTransactionId=[guid]::NewGuid().ToString()
        Files=@(
            @{RelativePath='MicBridgeAPO.dll';Sha256=$hash},
            @{RelativePath='micbridgeapo.dll';Sha256=$hash}
        )
        ComRegistrations=@()
    }
    $duplicateBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$duplicateManifest) -Compress -Depth 8))
    [IO.File]::WriteAllBytes($manifestPath,$duplicateBytes)
    $duplicateCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($duplicateBytes),$false)
    $duplicateSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $duplicateSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $duplicateCms.ComputeSignature($duplicateSigner)
    [IO.File]::WriteAllBytes($signaturePath,$duplicateCms.Encode())
    $duplicateRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null }
    catch { $duplicateRejected=$_.Exception.Message -match 'duplicate file path' }
    if(-not $duplicateRejected) { throw 'FAIL: case-insensitive duplicate manifest paths were accepted.' }

    Write-Host 'PASS: signed manifest trust, signer purpose, transaction identity and file hashes verified; COM ownership and execution remain unproven.'
} finally {
    if($cert){$cert.Dispose()}
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
