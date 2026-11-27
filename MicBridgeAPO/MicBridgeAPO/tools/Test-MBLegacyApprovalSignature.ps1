$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupJournal.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupPreflight.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyApprovalSignature.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeApprovalSignature-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(2048)
$cert = $null
try {
    $subject = [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge CI Test Signer')
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $subject,$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))
    $pfx = $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,'temporary-test-only')
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfx,'temporary-test-only',
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)

    $dll = Join-Path $root 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll,[byte[]](10,20,30,40,50))
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $plan = [pscustomobject]@{
        IsReadOnly=$true; InstallDirectory=$root; CanProceedToCleanupReview=$true
        CleanupExecutionAllowed=$false; InstallAllowed=$false
        Items=@([pscustomobject]@{
            Kind='File'; Name='MicBridgeAPO.dll'; Path=$dll
            Classification='MicBridgeBinaryCandidate'; ProposedAction='CandidateForReviewedRemoval'; Sha256=$hash
        })
    }
    $journalPath = Join-Path $root 'review.json'
    $journal = New-MBLegacyCleanupJournal -Plan $plan -Path $journalPath
    Set-MBLegacyCleanupReviewDecision -Path $journalPath -ItemId $journal.Entries[0].Id -Reviewer 'CI Reviewer' -Approve $true | Out-Null
    $signaturePath = Join-Path $root 'approval.p7s'
    $signArgs = @{
        JournalPath=$journalPath; ItemId=$journal.Entries[0].Id; Reviewer='CI Reviewer'
        Certificate=$cert; OutputPath=$signaturePath; ValidForMinutes=5
    }
    $signed = New-MBLegacyApprovalSignature @signArgs
    if (-not $signed.IsSigned -or $signed.IsExecutionAuthorized) { throw 'FAIL: signature creation exposed execution authorization.' }

    $verifyArgs = @{
        JournalPath=$journalPath; SignaturePath=$signaturePath
        TrustedSignerThumbprints=@($cert.Thumbprint); ItemId=$journal.Entries[0].Id
    }
    $verified = Test-MBLegacyApprovalSignature @verifyArgs
    if (-not $verified.IsValid -or -not $verified.SignatureVerified -or $verified.IsExecutionAuthorized) {
        throw 'FAIL: trusted CMS signature did not verify with safe capability flags.'
    }

    # Retained-lease mode must keep the file and every path component pinned until
    # the caller explicitly closes the lease; a rename/replacement must fail meanwhile.
    $retained = Test-MBLegacyApprovalSignature @verifyArgs -RetainLease
    if (-not $retained.LeaseRetained -or $null -eq $retained.LeaseResult -or
        -not $retained.LeaseResult.Lease.IsOpen) {
        throw 'FAIL: retained approval did not return an open exclusive file lease.'
    }
    $replaceBlocked = $false
    try {
        [IO.File]::Move($dll,(Join-Path $root 'blocked-replacement.dll'))
    } catch { $replaceBlocked = $true }
    if (-not $replaceBlocked) {
        Close-MBLegacyExclusiveFileLease -LeaseResult $retained.LeaseResult
        throw 'FAIL: candidate rename succeeded while the exclusive lease was retained.'
    }
    Close-MBLegacyExclusiveFileLease -LeaseResult $retained.LeaseResult

    $wrongTrustRejected = $false
    try {
        $badTrustArgs = $verifyArgs.Clone()
        $badTrustArgs.TrustedSignerThumbprints = @('0000000000000000000000000000000000000000')
        Test-MBLegacyApprovalSignature @badTrustArgs | Out-Null
    } catch { $wrongTrustRejected = $true }
    if (-not $wrongTrustRejected) { throw 'FAIL: untrusted signer thumbprint was accepted.' }

    $tamperedPath = Join-Path $root 'tampered.p7s'
    $bytes = [IO.File]::ReadAllBytes($signaturePath)
    $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($tamperedPath,$bytes)
    $tamperRejected = $false
    try {
        $tamperArgs = $verifyArgs.Clone()
        $tamperArgs.SignaturePath = $tamperedPath
        Test-MBLegacyApprovalSignature @tamperArgs | Out-Null
    } catch { $tamperRejected = $true }
    if (-not $tamperRejected) { throw 'FAIL: tampered signature was accepted.' }

    [IO.File]::WriteAllBytes($dll,[byte[]](99,98,97))
    $staleRejected = $false
    try { Test-MBLegacyApprovalSignature @verifyArgs | Out-Null } catch { $staleRejected = $true }
    if (-not $staleRejected) { throw 'FAIL: signed approval survived candidate content change.' }

    # Same bytes at the same path but a different NTFS file identity must not inherit approval.
    [IO.File]::WriteAllBytes($dll,[byte[]](10,20,30,40,50))
    $replacement = Join-Path $root 'replacement.dll'
    [IO.File]::WriteAllBytes($replacement,[byte[]](10,20,30,40,50))
    [IO.File]::Delete($dll)
    [IO.File]::Move($replacement,$dll)
    $sameBytesReplacementRejected = $false
    try { Test-MBLegacyApprovalSignature @verifyArgs | Out-Null } catch {
        $sameBytesReplacementRejected = $_.Exception.ToString() -match 'identity|file|approved'
    }
    if (-not $sameBytesReplacementRejected) { throw 'FAIL: approval accepted a replacement file with identical bytes but a different file identity.' }

    # Restore the candidate so this next assertion isolates journal-digest binding.
    [IO.File]::WriteAllBytes($dll,[byte[]](10,20,30,40,50))
    $journalBytes = [IO.File]::ReadAllBytes($journalPath)
    [IO.File]::WriteAllBytes($journalPath,[byte[]]($journalBytes + [byte]0x20))
    $journalTamperRejected = $false
    try { Test-MBLegacyApprovalSignature @verifyArgs | Out-Null } catch {
        $journalTamperRejected = $_.Exception.ToString() -match 'Journal changed after approval was signed'
    }
    if (-not $journalTamperRejected) { throw 'FAIL: signed approval survived journal digest change.' }

    Write-Host 'PASS: CMS approval is bound to an explicitly trusted signer, identity, journal digest and candidate; no execution/deletion occurs.'
} finally {
    if ($cert) { $cert.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
