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
        [switch]$RequireCertificateChain
    )
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
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
    if($RequireCertificateChain) {
        $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
            [void]$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
            $chainValidated=$chain.Build($signer)
            if(-not $chainValidated) {
                $status=(@($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ', ')
                throw "Manifest signer certificate chain is not trusted for Code Signing: $status"
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
    [pscustomobject]@{
        IsReadOnly=$true
        SignatureVerified=$true
        ManifestVerified=$true
        FileProvenanceVerified=$true
        VerificationConsistency='PathBasedNonAtomic'
        RaceSafeForExecution=$false
        CertificateChainValidated=$chainValidated
        RevocationChecked=$false
        CallerRevocationDenylistChecked=($revoked.Count -gt 0)
        SignerRevocationStatus=$(if($revoked.Count -gt 0){'NotListedInCallerDenylist'}else{'NotChecked'})
        IsReleaseTrustEstablished=$false
        OwnershipProven=$false
        ComOwnershipProven=$false
        IsExecutionAuthorized=$false
        SignerThumbprint=$signer.Thumbprint
        ProductVersion=[string]$manifest.ProductVersion
        InstallTransactionId=$transaction.ToString()
        VerifiedFiles=@($verified)
        Note='Signed manifest and listed file hashes verified. This is provenance evidence only; it does not prove shared COM ownership or authorize deletion.'
    }
}

Export-ModuleMember -Function Test-MBInstallProvenanceManifest
