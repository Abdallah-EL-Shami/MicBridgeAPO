Set-StrictMode -Version Latest

function Test-MBRegularNonReparseFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Label must be a regular non-reparse-point file."
    }
    return [IO.Path]::GetFullPath($Path)
}

function Test-MBInstallProvenanceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string[]]$TrustedSignerThumbprints,
        [string[]]$RevokedSignerThumbprints=@(),
        [switch]$RequireCertificateChain,
        [switch]$PinFiles
    )
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
    $manifestFull=Test-MBRegularNonReparseFile -Path $ManifestPath -Label 'Manifest'
    $signatureFull=Test-MBRegularNonReparseFile -Path $SignaturePath -Label 'Manifest signature'
    $rootItem=Get-Item -LiteralPath $InstallDirectory -Force -ErrorAction Stop
    if(-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Install directory must be a real directory, not a reparse point.'
    }
    $root=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if([string]::IsNullOrWhiteSpace($root)) { throw 'Install directory resolved to an invalid root.' }

    $manifestBytes=[IO.File]::ReadAllBytes($manifestFull)
    $cms=[Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([IO.File]::ReadAllBytes($signatureFull))
    if($cms.SignerInfos.Count -ne 1) { throw 'Exactly one manifest signer is required.' }
    $cms.CheckSignature($true)
    $signer=$cms.SignerInfos[0].Certificate
    if($null -eq $signer) { throw 'Manifest signer certificate is missing.' }
    if($null -eq $TrustedSignerThumbprints -or @($TrustedSignerThumbprints).Count -lt 1) {
        throw 'At least one externally configured trusted signer thumbprint is required.'
    }
    $trusted=[Collections.Generic.List[string]]::new()
    foreach($thumbprint in @($TrustedSignerThumbprints)) {
        $normalized=([string]$thumbprint -replace '\s','').ToUpperInvariant()
        if($normalized -notmatch '^[A-F0-9]{40}$') {
            throw 'Trusted signer thumbprints must be exactly 40 hexadecimal characters.'
        }
        if($trusted.Contains($normalized)) { throw 'Trusted signer thumbprints must not contain duplicates.' }
        $trusted.Add($normalized)
    }
    if($trusted -notcontains $signer.Thumbprint.ToUpperInvariant()) {
        throw 'Manifest signer is not anchored to an explicitly trusted thumbprint.'
    }
    $revoked=[Collections.Generic.List[string]]::new()
    foreach($thumbprint in @($RevokedSignerThumbprints)) {
        $normalized=([string]$thumbprint -replace '\s','').ToUpperInvariant()
        if($normalized -notmatch '^[A-F0-9]{40}$') {
            throw 'Revoked signer thumbprints must be exactly 40 hexadecimal characters.'
        }
        if($revoked.Contains($normalized)) { throw 'Revoked signer thumbprints must not contain duplicates.' }
        $revoked.Add($normalized)
    }
    if($revoked.Contains($signer.Thumbprint.ToUpperInvariant())) {
        throw 'Manifest signer is explicitly revoked by the caller-supplied denylist.'
    }
    $now=[DateTime]::UtcNow
    if($signer.NotBefore.ToUniversalTime() -gt $now -or $signer.NotAfter.ToUniversalTime() -le $now) {
        throw 'Manifest signer certificate is outside its validity period.'
    }
    $keyUsage=$signer.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.15' } | Select-Object -First 1
    if($null -eq $keyUsage -or -not ([Security.Cryptography.X509Certificates.X509KeyUsageExtension]$keyUsage).KeyUsages.HasFlag([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature)) {
        throw 'Manifest signer certificate must permit digital signatures.'
    }
    $eku=$signer.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
    if($null -eq $eku -or -not (([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$eku).EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' })) {
        throw 'Manifest signer certificate must contain the Code Signing EKU.'
    }
    $chainValidated=$false
    $certificateDownloadsDisabled=$false
    $revocationChecked=$false
    if($RequireCertificateChain) {
        $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            # Offline-only chain validation: use certificates already present in
            # the Windows certificate stores. Never fetch intermediates or CRLs.
            $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chain.ChainPolicy.RevocationFlag=[Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
            $chain.ChainPolicy.DisableCertificateDownloads=$true
            $certificateDownloadsDisabled=$true
            $chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
            [void]$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
            $chainValidated=$chain.Build($signer)
            if(-not $chainValidated) {
                $status=(@($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ', ')
                throw "Manifest signer certificate chain is not trusted using locally available certificates: $status"
            }
        } finally { $chain.Dispose() }
    }
    if(-not ([Convert]::ToBase64String([byte[]]$cms.ContentInfo.Content) -ceq [Convert]::ToBase64String([byte[]]$manifestBytes))) {
        throw 'Manifest bytes differ from the signed CMS content.'
    }
    $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
    if($manifest.SchemaVersion -ne 1 -or $manifest.ProductId -ne 'MicBridgeAPO' -or
       [string]::IsNullOrWhiteSpace([string]$manifest.ProductVersion)) {
        throw 'Manifest schema, product identity, or version is invalid.'
    }
    # Schema v1 does not define an authenticated COM-registration ownership model.
    # Refuse non-empty claims rather than silently treating signed metadata as proof.
    if($null -ne $manifest.ComRegistrations -and @($manifest.ComRegistrations).Count -gt 0) {
        throw 'Manifest COM registration claims are unsupported by schema v1 and cannot establish COM ownership.'
    }
    $transaction=[guid]::Empty
    if(-not [guid]::TryParse([string]$manifest.InstallTransactionId,[ref]$transaction) -or $transaction -eq [guid]::Empty) {
        throw 'Manifest installation transaction ID must be a non-empty GUID.'
    }
    if($null -eq $manifest.Files -or @($manifest.Files).Count -lt 1) { throw 'Manifest must contain at least one file record.' }
    $verified=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($record in @($manifest.Files)) {
        $relative=[string]$record.RelativePath
        $expected=[string]$record.Sha256
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
           $relative -match '(^|[\\/])\.\.?([\\/]|$)' -or $relative.Contains(':') -or
           $expected -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Manifest contains an unsafe relative path or invalid SHA-256.'
        }
        $candidate=[IO.Path]::GetFullPath((Join-Path $root $relative))
        if(-not $candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Manifest path escapes the installation root.'
        }
        if(-not $seen.Add($candidate)) { throw 'Manifest contains a duplicate file path.' }
        $cursor=$root
        $parts=$relative -split '[\\/]'
        for($i=0;$i -lt $parts.Count;$i++) {
            $cursor=Join-Path $cursor $parts[$i]
            $entry=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Manifest path traverses a reparse point: $relative"
            }
            if($i -lt ($parts.Count-1) -and -not $entry.PSIsContainer) { throw "Manifest parent is not a directory: $relative" }
            if($i -eq ($parts.Count-1) -and $entry.PSIsContainer) { throw "Manifest file record resolves to a directory: $relative" }
        }
        $actual=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash
        if(-not $actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { throw "Manifest file hash mismatch: $relative" }
        $verified.Add([pscustomobject]@{RelativePath=$relative;Path=$candidate;Sha256=$actual})
    }
    # Require an exact package file set. A valid signature over known files must
    # not silently bless a directory containing additional unlisted payloads.
    $actualFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
        if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install tree contains a reparse point: $($entry.FullName)"
        }
        if($entry.PSIsContainer) { continue }
        $full=[IO.Path]::GetFullPath($entry.FullName)
        if([string]::Equals($full,$manifestFull,[StringComparison]::OrdinalIgnoreCase) -or
           [string]::Equals($full,$signatureFull,[StringComparison]::OrdinalIgnoreCase)) { continue }
        $relativeActual=$full.Substring($root.Length + 1).Replace('\','/')
        if(-not $actualFiles.Add($relativeActual)) { throw "Install tree contains a duplicate normalized file path: $relativeActual" }
    }
    if($actualFiles.Count -ne $seen.Count) {
        throw "Install tree file set differs from the signed manifest: signed=$($seen.Count), actual=$($actualFiles.Count)."
    }
    foreach($actualPath in $actualFiles) {
        $candidate=[IO.Path]::GetFullPath((Join-Path $root $actualPath))
        if(-not $seen.Contains($candidate)) {
            throw "Install tree contains an unlisted file not covered by the signed manifest: $actualPath"
        }
    }

    $leaseResults=[Collections.Generic.List[object]]::new()
    if($PinFiles) {
        # Optionally retain mutation-resistant handles for the caller's complete use window.
        # The lease re-hashes the opened handle, validates its final path and file ID,
        # pins every parent directory, rejects hard links/reparse points, and blocks
        # write/delete sharing while still permitting the installer to read/copy it.
        $leaseResults=[Collections.Generic.List[object]]::new()
        try {
            $leaseModule=Join-Path $PSScriptRoot 'MicBridge.InstallPackageFileLease.psm1'
            if(-not (Test-Path -LiteralPath $leaseModule -PathType Leaf)) {
                throw 'Mutation-resistant package file lease module is missing.'
            }
            Import-Module -Name $leaseModule -Force -ErrorAction Stop
            foreach($record in $verified) {
                $leaseResult=Open-MBInstallPackageFileLease -CandidatePath $record.Path -InstallRoot $root -ExpectedSha256 $record.Sha256
                if(-not $leaseResult.FinalHandleValidationPassed -or -not $leaseResult.Lease.IsOpen) {
                    throw "Package file could not be pinned to its verified handle: $($record.RelativePath)"
                }
                $record | Add-Member -NotePropertyName LeaseResult -NotePropertyValue $leaseResult -Force
                $leaseResults.Add($leaseResult)
            }
        } catch {
            foreach($leaseResult in $leaseResults) {
                try { Close-MBInstallPackageFileLease -LeaseResult $leaseResult } catch {}
            }
            throw
        }
    
    }

    [pscustomobject]@{
        IsReadOnly=$true
        SignatureVerified=$true
        ManifestVerified=$true
        FileProvenanceVerified=$true
        VerificationConsistency=$(if($PinFiles){'ExclusiveHandlePinned'}else{'PathBasedNonAtomic'})
        PackageFilesPinnedForUse=[bool]$PinFiles
        RaceSafeForExecution=$false
        BootstrapTrustEstablished=$false
        CertificateChainValidated=$chainValidated
        CertificateDownloadsDisabled=$certificateDownloadsDisabled
        RevocationChecked=$false
        CallerRevocationDenylistChecked=($revoked.Count -gt 0)
        CertificateRevocationMode='NotCheckedOffline'
        SignerRevocationStatus=$(if($revoked.Count -gt 0){'NotListedInCallerDenylist'}else{'NotCheckedOffline'})
        IsReleaseTrustEstablished=$false
        OwnershipProven=$false
        ComOwnershipProven=$false
        IsExecutionAuthorized=$false
        SignerThumbprint=$signer.Thumbprint
        ProductVersion=[string]$manifest.ProductVersion
        InstallTransactionId=$transaction.ToString()
        VerifiedFiles=@($verified)
        Note=$(if($PinFiles){'Signed manifest and listed file hashes verified, then every payload was re-opened and re-hashed through a mutation-resistant handle with parent directories pinned. Handles remain open in VerifiedFiles.LeaseResult until Close-MBInstallProvenanceLeases is called or the process exits.'}else{'Signed manifest and listed file hashes verified by path. This mode is read-only provenance evidence and is not race-safe for execution.'}) + ' Certificate-chain building is offline-only; revocation is not checked online. This does not prove shared COM ownership or authorize deletion.'
    }
}

function Close-MBInstallProvenanceLeases {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Verification)
    foreach($record in @($Verification.VerifiedFiles)) {
        if($null -ne $record.LeaseResult) {
            Close-MBInstallPackageFileLease -LeaseResult $record.LeaseResult
        }
    }
}

Export-ModuleMember -Function Test-MBInstallProvenanceManifest,Close-MBInstallProvenanceLeases
