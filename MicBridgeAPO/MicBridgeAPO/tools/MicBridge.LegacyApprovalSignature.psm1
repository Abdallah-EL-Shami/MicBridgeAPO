Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupJournal.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupPreflight.psm1') -ErrorAction Stop

function Get-MBLegacyApprovalJournalDigest {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Approval journal must be a regular, non-reparse-point file.'
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Get-MBLegacyApprovalIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) { throw 'Current Windows identity has no SID; approval cannot be bound.' }
    [pscustomobject]@{ Sid=$identity.User.Value; Machine=[Environment]::MachineName }
}

function Write-MBLegacyApprovalBytes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Approval output directory must already exist.' }
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Approval output directory cannot be a reparse point.' }
    if (Test-Path -LiteralPath $full) { throw 'Refusing to overwrite an existing approval signature.' }
    $temp = Join-Path $parent ('.approval-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp,$Bytes)
        [IO.File]::Move($temp,$full)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function New-MBLegacyApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Reviewer,
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(1,15)][int]$ValidForMinutes=10
    )
    if ([string]::IsNullOrWhiteSpace($Reviewer)) { throw 'Reviewer display name is required.' }
    if (-not $Certificate.HasPrivateKey) { throw 'Signing certificate must include its private key.' }
    if ($Certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or $Certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
        throw 'Signing certificate is not currently valid.'
    }
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
    $journal = Get-MBLegacyCleanupJournal -Path $JournalPath
    $preflight = Test-MBLegacyCleanupPreflight -JournalPath $JournalPath
    if (-not $preflight.CanProceedToManualReview) { throw 'Preflight blocked; no signed authorization can be issued.' }
    $matches = @($preflight.VerifiedEntries | Where-Object { $_.ItemId -eq $ItemId })
    if ($matches.Count -ne 1) { throw 'Item is not uniquely revalidated by preflight.' }
    $entry = $matches[0]
    $journalEntry = @($journal.Entries | Where-Object { $_.Id -eq $ItemId -and $_.Status -eq 'ReviewApproved' })
    if ($journalEntry.Count -ne 1) { throw 'A matching human review approval is required before signing.' }
    $identity = Get-MBLegacyApprovalIdentity
    $now = [DateTime]::UtcNow
    $payload = [ordered]@{
        SchemaVersion=1
        Purpose='MicBridgeLegacyCleanupAuthorization'
        ItemId=$ItemId
        JournalSha256=(Get-MBLegacyApprovalJournalDigest -Path $JournalPath)
        CandidatePath=[IO.Path]::GetFullPath([string]$entry.Path)
        CandidateSha256=[string]$entry.Sha256
        Reviewer=$Reviewer.Trim()
        ReviewerSid=$identity.Sid
        Machine=$identity.Machine
        IssuedUtc=$now.ToString('o')
        ExpiresUtc=$now.AddMinutes($ValidForMinutes).ToString('o')
        Nonce=[guid]::NewGuid().ToString('N')
        Action='AuthorizeSingleFileRemovalAfterFinalHandleValidation'
    }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$payload) -Compress -Depth 6
    $content = [Text.Encoding]::UTF8.GetBytes($json)
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($content),$false)
    $signer = [Security.Cryptography.Pkcs.CmsSigner]::new([Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber,$Certificate)
    $signer.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $signer.DigestAlgorithm = [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
    $cms.ComputeSignature($signer)
    Write-MBLegacyApprovalBytes -Path $OutputPath -Bytes $cms.Encode()
    [pscustomobject]@{
        IsSigned=$true; IsExecutionAuthorized=$false
        ItemId=$ItemId; CertificateThumbprint=$Certificate.Thumbprint
        ExpiresUtc=$payload.ExpiresUtc; OutputPath=[IO.Path]::GetFullPath($OutputPath)
        Note='Signed approval evidence only. No file or registry mutation was performed.'
    }
}

function Test-MBLegacyApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string[]]$TrustedSignerThumbprints,
        [Parameter(Mandatory)][string]$ItemId
    )
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
    $sigFile = Get-Item -LiteralPath $SignaturePath -Force -ErrorAction Stop
    if ($sigFile.PSIsContainer -or (($sigFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Signature must be a regular file.' }
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SignaturePath)))
    if ($cms.SignerInfos.Count -ne 1) { throw 'Exactly one trusted signer is required.' }
    $cms.CheckSignature($true)
    $signerCert = $cms.SignerInfos[0].Certificate
    if ($null -eq $signerCert) { throw 'Embedded signer certificate is missing.' }
    $trusted = @($TrustedSignerThumbprints | ForEach-Object { ($_ -replace '\s','').ToUpperInvariant() })
    if ($trusted -notcontains $signerCert.Thumbprint.ToUpperInvariant()) { throw 'Signer certificate thumbprint is not explicitly trusted.' }
    $now = [DateTime]::UtcNow
    if ($signerCert.NotBefore.ToUniversalTime() -gt $now -or $signerCert.NotAfter.ToUniversalTime() -le $now) { throw 'Signer certificate is outside its validity period.' }
    $payload = [Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json -ErrorAction Stop
    if ($payload.SchemaVersion -ne 1 -or $payload.Purpose -ne 'MicBridgeLegacyCleanupAuthorization' -or
        $payload.Action -ne 'AuthorizeSingleFileRemovalAfterFinalHandleValidation' -or $payload.ItemId -ne $ItemId) {
        throw 'Signed approval purpose, schema, action, or item identity is invalid.'
    }
    $identity = Get-MBLegacyApprovalIdentity
    if ($payload.ReviewerSid -ne $identity.Sid -or $payload.Machine -ne $identity.Machine) {
        throw 'Approval is bound to a different Windows identity or machine.'
    }
    $expires = [DateTime]::Parse([string]$payload.ExpiresUtc).ToUniversalTime()
    $issued = [DateTime]::Parse([string]$payload.IssuedUtc).ToUniversalTime()
    if ($issued -gt $now.AddMinutes(1) -or $expires -le $now -or $expires -gt $issued.AddMinutes(15)) {
        throw 'Approval is expired or has an invalid time window.'
    }
    $journal = Get-MBLegacyCleanupJournal -Path $JournalPath
    $digest = Get-MBLegacyApprovalJournalDigest -Path $JournalPath
    if (-not $digest.Equals([string]$payload.JournalSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'Journal changed after approval was signed.' }
    $preflight = Test-MBLegacyCleanupPreflight -JournalPath $JournalPath
    if (-not $preflight.CanProceedToManualReview) { throw 'Current preflight blocks the signed approval.' }
    $entry = @($preflight.VerifiedEntries | Where-Object { $_.ItemId -eq $ItemId })
    if ($entry.Count -ne 1 -or
        -not ([string]$entry[0].Sha256).Equals([string]$payload.CandidateSha256,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$entry[0].Path).Equals([string]$payload.CandidatePath,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Current candidate identity or hash differs from signed approval.'
    }
    [pscustomobject]@{
        IsValid=$true
        SignatureVerified=$true
        SignerThumbprint=$signerCert.Thumbprint
        ItemId=$ItemId
        CandidateSha256=[string]$payload.CandidateSha256
        ExpiresUtc=$expires.ToString('o')
        IsExecutionAuthorized=$false
        FinalHandleValidationRequired=$true
        Note='Signature verified; this function is non-destructive and does not authorize or perform deletion.'
    }
}

Export-ModuleMember -Function New-MBLegacyApprovalSignature,Test-MBLegacyApprovalSignature
