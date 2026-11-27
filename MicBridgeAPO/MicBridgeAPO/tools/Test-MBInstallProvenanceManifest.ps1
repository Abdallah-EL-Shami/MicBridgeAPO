$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
} catch {
    # Windows PowerShell 5.1 runs on .NET Framework, where SignedCms is
    # provided by System.Security.dll rather than the modern Pkcs assembly name.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    } else {
        throw
    }
}
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
    # On PowerShell 7/.NET, this fixture is expected to fail strict chain validation.
    # .NET Framework may treat an ephemeral self-signed CI certificate as a trust anchor
    # through the host chain engine, so this specific negative assertion is not portable.
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $untrustedChainRejected=$false
    try {
        $strictChainArgs=$args.Clone()
        $strictChainArgs.RequireCertificateChain=$true
        Test-MBInstallProvenanceManifest @strictChainArgs | Out-Null
    } catch { $untrustedChainRejected=$_.Exception.Message -match 'certificate chain is not trusted' }
    if(-not $untrustedChainRejected) { throw 'FAIL: self-signed CI signer passed strict certificate-chain validation.' }
    }
    if((Get-Command Test-MBInstallProvenanceManifest).Parameters.ContainsKey('RequireCertificateRevocation')) {
        throw 'FAIL: online certificate revocation option must not be exposed by the offline verifier.'
    }
    $pinArgs=$args.Clone();$pinArgs.PinFiles=$true
    $ok=Test-MBInstallProvenanceManifest @pinArgs
    if(-not $ok.ManifestVerified -or -not $ok.FileProvenanceVerified -or $ok.OwnershipProven -or
       $ok.ComOwnershipProven -or $ok.IsExecutionAuthorized -or $ok.VerifiedFiles.Count -ne 1 -or
       $ok.CertificateChainValidated -or $ok.CertificateDownloadsDisabled -or $ok.RevocationChecked -or $ok.CertificateRevocationMode -ne 'NotCheckedOffline' -or $ok.IsReleaseTrustEstablished -or
       $ok.VerificationConsistency -ne 'ExclusiveHandlePinned' -or -not $ok.PackageFilesPinnedForUse -or $ok.RaceSafeForExecution -or $ok.BootstrapTrustEstablished -or
       $ok.CallerRevocationDenylistChecked -or $ok.SignerRevocationStatus -ne 'NotCheckedOffline' -or
       -not $ok.VerifiedFiles[0].LeaseResult.FinalHandleValidationPassed -or -not $ok.VerifiedFiles[0].LeaseResult.Lease.IsOpen) {
        throw ('FAIL: manifest verification returned unsafe or incomplete capability flags: ' + (ConvertTo-Json -InputObject ([pscustomobject]@{Count=$ok.VerifiedFiles.Count;Consistency=$ok.VerificationConsistency;FilesPinned=$ok.PackageFilesPinnedForUse;RaceSafe=$ok.RaceSafeForExecution;BootstrapTrust=$ok.BootstrapTrustEstablished;LeaseResult=$ok.VerifiedFiles[0].LeaseResult.FinalHandleValidationPassed;LeaseOpen=$ok.VerifiedFiles[0].LeaseResult.Lease.IsOpen;Sha=$ok.VerifiedFiles[0].LeaseResult.Sha256;Expected=$hash}) -Compress))
    }
    $writeBlocked=$false
    try {
        $probe=[IO.File]::Open($bin,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        $probe.Dispose()
    } catch [IO.IOException] { $writeBlocked=$true }
    if(-not $writeBlocked) { throw 'FAIL: verified package payload remained writable while its provenance lease was held.' }
    $readProbe=[IO.File]::Open($bin,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { if($readProbe.ReadByte() -ne 1) { throw 'FAIL: read access to a pinned package payload was not preserved.' } }
    finally { $readProbe.Dispose() }
    $deleteBlocked=$false
    try { [IO.File]::Delete($bin) } catch [IO.IOException] { $deleteBlocked=$true }
    if(-not $deleteBlocked -or -not (Test-Path -LiteralPath $bin -PathType Leaf)) {
        throw 'FAIL: pinned package payload could be deleted or renamed during its protected use window.'
    }
    Close-MBInstallProvenanceLeases -Verification $ok
    $writeAfterRelease=[IO.File]::Open($bin,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $writeAfterRelease.Dispose()

    # A nested directory must remain non-renamable while a descendant payload lease is held.
    $nestedDir=Join-Path $root 'nested-payload'
    New-Item -ItemType Directory -Path $nestedDir -ErrorAction Stop | Out-Null
    $nestedFile=Join-Path $nestedDir 'nested.bin'
    [IO.File]::WriteAllBytes($nestedFile,[byte[]](9,8,7,6))
    $nestedHash=(Get-FileHash -LiteralPath $nestedFile -Algorithm SHA256).Hash
    $nestedLease=Open-MBInstallPackageFileLease -CandidatePath $nestedFile -InstallRoot $root -ExpectedSha256 $nestedHash
    $directoryRenameBlocked=$false
    try { [IO.Directory]::Move($nestedDir,(Join-Path $root 'nested-payload-moved')) }
    catch [IO.IOException] { $directoryRenameBlocked=$true }
    catch [UnauthorizedAccessException] { $directoryRenameBlocked=$true }
    if(-not $directoryRenameBlocked -or -not (Test-Path -LiteralPath $nestedFile -PathType Leaf)) {
        Close-MBInstallPackageFileLease -LeaseResult $nestedLease
        throw 'FAIL: a parent package directory could be renamed while a descendant payload lease was held.'
    }
    Close-MBInstallPackageFileLease -LeaseResult $nestedLease
    $movedNestedDir=Join-Path $root 'nested-payload-moved'
    [IO.Directory]::Move($nestedDir,$movedNestedDir)
    Remove-Item -LiteralPath $movedNestedDir -Recurse -Force

    # A signed manifest must bind the complete package file set, not only
    # the subset it happens to list. Unlisted payloads are rejected.
    $unlistedPath=Join-Path $root 'unlisted-payload.bin'
    [IO.File]::WriteAllBytes($unlistedPath,[byte[]](1,2,3,4))
    $unlistedRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null }
    catch { $unlistedRejected=$_.Exception.Message -match 'file set differs|unlisted file' }
    finally { Remove-Item -LiteralPath $unlistedPath -Force -ErrorAction SilentlyContinue }
    if(-not $unlistedRejected) { throw 'FAIL: package accepted a file not covered by the signed manifest.' }

    $malformedTrustRejected=$false
    try { $badTrust=$args.Clone();$badTrust.TrustedSignerThumbprints=@('NOT-A-THUMBPRINT');Test-MBInstallProvenanceManifest @badTrust | Out-Null } catch { $malformedTrustRejected=$_.Exception.Message -match 'exactly 40 hexadecimal characters' }
    if(-not $malformedTrustRejected) { throw 'FAIL: malformed trust anchor was not rejected explicitly.' }

    $duplicateTrustRejected=$false
    try {
        $duplicateTrustArgs=$args.Clone()
        $duplicateTrustArgs.TrustedSignerThumbprints=@($cert.Thumbprint,$cert.Thumbprint)
        Test-MBInstallProvenanceManifest @duplicateTrustArgs | Out-Null
    } catch { $duplicateTrustRejected=$_.Exception.Message -match 'must not contain duplicates' }
    if(-not $duplicateTrustRejected) { throw 'FAIL: duplicate trusted signer thumbprints were accepted.' }

    # A thumbprint-pinned certificate without the Code Signing EKU is not an acceptable signer.
    $baselineManifestBytes=[IO.File]::ReadAllBytes($manifestPath)
    $noEkuRsa=[Security.Cryptography.RSA]::Create(2048)
    $noEkuCert=$null
    try {
        $noEkuRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new(
            [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge CI Signer Without Code Signing EKU'),
            $noEkuRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $noEkuRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $noEkuRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
        $noEkuCert=$noEkuRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))
        $noEkuCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
        $noEkuSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
            [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$noEkuCert)
        $noEkuSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $noEkuCms.ComputeSignature($noEkuSigner)
        [IO.File]::WriteAllBytes($signaturePath,$noEkuCms.Encode())
        $noEkuRejected=$false
        try {
            $noEkuArgs=$args.Clone()
            $noEkuArgs.TrustedSignerThumbprints=@($noEkuCert.Thumbprint)
            Test-MBInstallProvenanceManifest @noEkuArgs | Out-Null
        } catch { $noEkuRejected=$_.Exception.Message -match 'Code Signing EKU' }
        if(-not $noEkuRejected) { throw 'FAIL: signer certificate without Code Signing EKU was accepted.' }
    } finally {
        if($noEkuCert) { $noEkuCert.Dispose() }
        $noEkuRsa.Dispose()
    }
    # Restore the original valid signature for subsequent negative cases.
    $restoreCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
    $restoreSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $restoreSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $restoreCms.ComputeSignature($restoreSigner)
    [IO.File]::WriteAllBytes($signaturePath,$restoreCms.Encode())

    # A thumbprint-pinned signer must also carry the DigitalSignature key-usage bit.
    $badUsageRsa=[Security.Cryptography.RSA]::Create(2048)
    $badUsageCert=$null
    try {
        $badUsageRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new(
            [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge CI Signer With Encryption-Only Key Usage'),
            $badUsageRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $badUsageRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $badUsageRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true))
        $badUsageOids=[Security.Cryptography.OidCollection]::new()
        [void]$badUsageOids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $badUsageRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($badUsageOids,$true))
        $badUsageCert=$badUsageRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))
        $badUsageCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
        $badUsageSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
            [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$badUsageCert)
        $badUsageSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $badUsageCms.ComputeSignature($badUsageSigner)
        [IO.File]::WriteAllBytes($signaturePath,$badUsageCms.Encode())
        $badUsageRejected=$false
        try {
            $badUsageArgs=$args.Clone()
            $badUsageArgs.TrustedSignerThumbprints=@($badUsageCert.Thumbprint)
            Test-MBInstallProvenanceManifest @badUsageArgs | Out-Null
        } catch { $badUsageRejected=$_.Exception.Message -match 'permit digital signatures' }
        if(-not $badUsageRejected) { throw 'FAIL: signer certificate without DigitalSignature key usage was accepted.' }
    } finally {
        if($badUsageCert) { $badUsageCert.Dispose() }
        $badUsageRsa.Dispose()
    }
    $restoreUsageCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
    $restoreUsageSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $restoreUsageSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $restoreUsageCms.ComputeSignature($restoreUsageSigner)
    [IO.File]::WriteAllBytes($signaturePath,$restoreUsageCms.Encode())

    # A correctly pinned and purpose-constrained signer is still rejected after expiry.
    $expiredRsa=[Security.Cryptography.RSA]::Create(2048)
    $expiredCert=$null
    try {
        $expiredRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new(
            [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge Expired CI Signer'),
            $expiredRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $expiredRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $expiredRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
        $expiredOids=[Security.Cryptography.OidCollection]::new()
        [void]$expiredOids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $expiredRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($expiredOids,$true))
        $expiredCert=$expiredRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-2),[DateTimeOffset]::UtcNow.AddHours(-1))
        $expiredCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
        $expiredSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
            [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$expiredCert)
        $expiredSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $expiredCms.ComputeSignature($expiredSigner)
        [IO.File]::WriteAllBytes($signaturePath,$expiredCms.Encode())
        $expiredRejected=$false
        try {
            $expiredArgs=$args.Clone()
            $expiredArgs.TrustedSignerThumbprints=@($expiredCert.Thumbprint)
            Test-MBInstallProvenanceManifest @expiredArgs | Out-Null
        } catch { $expiredRejected=$_.Exception.Message -match 'outside its validity period' }
        if(-not $expiredRejected) { throw 'FAIL: expired manifest signing certificate was accepted.' }
    } finally {
        if($expiredCert) { $expiredCert.Dispose() }
        $expiredRsa.Dispose()
    }
    $restoreExpiredCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($baselineManifestBytes),$false)
    $restoreExpiredSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $restoreExpiredSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $restoreExpiredCms.ComputeSignature($restoreExpiredSigner)
    [IO.File]::WriteAllBytes($signaturePath,$restoreExpiredCms.Encode())

    $wrongTrust=$false
    try { $bad=$args.Clone();$bad.TrustedSignerThumbprints=@('0000000000000000000000000000000000000000');Test-MBInstallProvenanceManifest @bad | Out-Null } catch { $wrongTrust=$true }
    if(-not $wrongTrust) { throw 'FAIL: untrusted manifest signer was accepted.' }
    $revokedSignerRejected=$false
    try {
        $revokedArgs=$args.Clone()
        $revokedArgs.RevokedSignerThumbprints=@($cert.Thumbprint)
        Test-MBInstallProvenanceManifest @revokedArgs | Out-Null
    } catch { $revokedSignerRejected=$_.Exception.Message -match 'explicitly revoked' }
    if(-not $revokedSignerRejected) { throw 'FAIL: explicitly revoked manifest signer was accepted.' }

    $malformedRevocationRejected=$false
    try {
        $badRevocationArgs=$args.Clone()
        $badRevocationArgs.RevokedSignerThumbprints=@('INVALID')
        Test-MBInstallProvenanceManifest @badRevocationArgs | Out-Null
    } catch { $malformedRevocationRejected=$_.Exception.Message -match 'Revoked signer thumbprints must be exactly 40 hexadecimal characters' }
    if(-not $malformedRevocationRejected) { throw 'FAIL: malformed signer revocation denylist entry was accepted.' }

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
        if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath,$false) }
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
    } finally { if (Test-Path -LiteralPath $rootAlias) { [IO.Directory]::Delete($rootAlias,$false) } }

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

    # Schema v1 must not let signed-but-unmodeled COM metadata masquerade as ownership evidence.
    $comClaimManifest=[ordered]@{
        SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
        InstallTransactionId=[guid]::NewGuid().ToString()
        Files=@(@{RelativePath='MicBridgeAPO.dll';Sha256=$hash})
        ComRegistrations=@(@{Clsid='{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}';Owner='MicBridgeAPO'})
    }
    $comClaimBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$comClaimManifest) -Compress -Depth 8))
    [IO.File]::WriteAllBytes($manifestPath,$comClaimBytes)
    $comClaimCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($comClaimBytes),$false)
    $comClaimSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $comClaimSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $comClaimCms.ComputeSignature($comClaimSigner)
    [IO.File]::WriteAllBytes($signaturePath,$comClaimCms.Encode())
    $comClaimRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null }
    catch { $comClaimRejected=$_.Exception.Message -match 'COM registration claims are unsupported' }
    if(-not $comClaimRejected) { throw 'FAIL: schema v1 accepted COM metadata that has no authenticated ownership semantics.' }

    # Exercise the empty-directory rule against a real signed fixture, not source text alone.
    $validManifest=[ordered]@{
        SchemaVersion=1; ProductId='MicBridgeAPO'; ProductVersion='0.0.0-ci'
        InstallTransactionId=[guid]::NewGuid().ToString()
        Files=@(@{RelativePath='MicBridgeAPO.dll';Sha256=$hash})
        ComRegistrations=@()
    }
    $validBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$validManifest) -Compress -Depth 8))
    [IO.File]::WriteAllBytes($manifestPath,$validBytes)
    $validCms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($validBytes),$false)
    $validSigner=[Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$cert)
    $validSigner.IncludeOption=[Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $validCms.ComputeSignature($validSigner)
    [IO.File]::WriteAllBytes($signaturePath,$validCms.Encode())
    $emptyDir=Join-Path $root 'empty-package-directory'
    New-Item -ItemType Directory -Path $emptyDir -ErrorAction Stop | Out-Null
    $emptyDirectoryRejected=$false
    try { Test-MBInstallProvenanceManifest @args | Out-Null }
    catch { $emptyDirectoryRejected=$_.Exception.Message -match 'empty directory that cannot be covered by a payload lease' }
    finally { Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue }
    if(-not $emptyDirectoryRejected) { throw 'FAIL: signed package containing an empty directory was accepted.' }

    # Guard the race between the initial package enumeration and acquisition of all file leases.
    $verifierSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MicBridge.InstallProvenanceManifest.psm1') -Raw
    $pinLoopIndex=$verifierSource.IndexOf('foreach($record in $verified)',[StringComparison]::Ordinal)
    $postPinEnumerationIndex=$verifierSource.IndexOf('$pinnedActualFiles=',[StringComparison]::Ordinal)
    $leaseReturnMatch=[regex]::Match($verifierSource,'(?m)^\s*\[pscustomobject\]@\{\s*IsReadOnly=')
    $leaseReturnIndex=if($leaseReturnMatch.Success){$leaseReturnMatch.Index}else{-1}
    if($pinLoopIndex -lt 0 -or $postPinEnumerationIndex -le $pinLoopIndex -or $leaseReturnIndex -le $postPinEnumerationIndex) {
        throw 'FAIL: verifier must re-enumerate and compare the exact package file set after all mutation-resistant file leases are held.'
    }
    $postPinRegion=$verifierSource.Substring($postPinEnumerationIndex,$leaseReturnIndex-$postPinEnumerationIndex)
    foreach($requiredPostPinCheck in @('Get-ChildItem -LiteralPath $root -Force -Recurse','FileAttributes]::ReparsePoint','$pinnedActualFiles.Count -ne $seen.Count','Install tree contains a file outside the signed manifest after pinning','gained or retained an empty directory during pinning')) {
        if($postPinRegion -notmatch [regex]::Escape($requiredPostPinCheck)) {
            throw "FAIL: post-pin package revalidation is missing invariant: $requiredPostPinCheck"
        }
    }
    $initialEnumerationIndex=$verifierSource.IndexOf('$actualFiles=',[StringComparison]::Ordinal)
    if($initialEnumerationIndex -lt 0 -or $initialEnumerationIndex -ge $pinLoopIndex) {
        throw 'FAIL: verifier must perform an initial exact package enumeration before acquiring leases.'
    }
    $initialRegion=$verifierSource.Substring($initialEnumerationIndex,$pinLoopIndex-$initialEnumerationIndex)
    if($initialRegion -notmatch [regex]::Escape('Install tree contains an empty directory that cannot be covered by a payload lease')) {
        throw 'FAIL: initial package enumeration must reject empty directories.'
    }
    if($postPinRegion -notmatch [regex]::Escape('Install tree gained or retained an empty directory during pinning')) {
        throw 'FAIL: post-pin package enumeration must reject empty directories.'
    }

    Write-Host 'PASS: signed manifest trust, signer purpose, transaction identity and file hashes verified; COM ownership and execution remain unproven.'
} finally {
    if($cert){$cert.Dispose()}
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
