Set-StrictMode -Version Latest

function Get-MBLegacyJournalHash {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Write-MBLegacyJournalAtomic {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Journal parent directory must already exist.' }
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Journal parent cannot be a reparse point.' }
    if (Test-Path -LiteralPath $full) {
        $existing = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Journal cannot be a reparse point.' }
        if ($existing.PSIsContainer) { throw 'Journal path is a directory.' }
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $full) { [IO.File]::Replace($temp, $full, $null) }
        else { [IO.File]::Move($temp, $full) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MBLegacyCleanupJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Journal does not exist.' }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Journal is a reparse point.' }
    $envelope = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($envelope.Payload.SchemaVersion -ne 1 -or $envelope.Payload.Purpose -ne 'ReviewOnly' -or
        $envelope.Payload.CleanupExecutionAllowed -ne $false -or $envelope.Payload.InstallAllowed -ne $false) {
        throw 'Journal schema or safety flags are invalid.'
    }
    $actual = Get-MBLegacyJournalHash -Text (ConvertTo-Json -InputObject $envelope.Payload -Compress -Depth 12)
    if (-not $actual.Equals([string]$envelope.PayloadSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'Journal integrity check failed.' }
    $ids = @($envelope.Payload.Entries | ForEach-Object { [string]$_.Id })
    if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Journal contains duplicate item identities.' }
    return $envelope.Payload
}

function Write-MBLegacyCleanupJournalPayload {
    param([Parameter(Mandatory)][psobject]$Payload,[Parameter(Mandatory)][string]$Path)
    $hash = Get-MBLegacyJournalHash -Text (ConvertTo-Json -InputObject $Payload -Compress -Depth 12)
    $envelope = [ordered]@{ Payload=$Payload; PayloadSha256=$hash }
    Write-MBLegacyJournalAtomic -Path $Path -Content (ConvertTo-Json -InputObject $envelope -Depth 14)
}

function New-MBLegacyCleanupJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Plan,[Parameter(Mandatory)][string]$Path)
    if ($Plan.IsReadOnly -ne $true -or $Plan.CleanupExecutionAllowed -ne $false -or $Plan.InstallAllowed -ne $false) {
        throw 'Only a read-only, non-authorizing cleanup plan can be journaled.'
    }
    if (Test-Path -LiteralPath $Path) { throw 'Refusing to overwrite an existing journal.' }
    $entries = @()
    foreach ($item in @($Plan.Items)) {
        $identityFields = [ordered]@{ Kind=[string]$item.Kind; Name=[string]$item.Name; Path=[string]$item.Path
            Classification=[string]$item.Classification; ProposedAction=[string]$item.ProposedAction; Sha256=[string]$item.Sha256 }
        $id = Get-MBLegacyJournalHash -Text (ConvertTo-Json -InputObject $identityFields -Compress -Depth 8)
        if (@($entries | Where-Object { $_.Id -eq $id }).Count -gt 0) { throw 'Duplicate item identity in plan.' }
        $entries += [pscustomobject]@{ Id=$id; Kind=$identityFields.Kind; Name=$identityFields.Name; Path=$identityFields.Path
            Classification=$identityFields.Classification; ProposedAction=$identityFields.ProposedAction; Sha256=$identityFields.Sha256
            Status='Planned'; Reviewer=$null; DecisionUtc=$null }
    }
    $payload = [pscustomobject][ordered]@{ SchemaVersion=1; Purpose='ReviewOnly'; CreatedUtc=[DateTime]::UtcNow.ToString('o')
        CleanupExecutionAllowed=$false; InstallAllowed=$false; Entries=@($entries) }
    Write-MBLegacyCleanupJournalPayload -Payload $payload -Path $Path
    Get-MBLegacyCleanupJournal -Path $Path
}

function Set-MBLegacyCleanupReviewDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Reviewer,[Parameter(Mandatory)][bool]$Approve)
    if ([string]::IsNullOrWhiteSpace($Reviewer)) { throw 'Reviewer identity is required.' }
    $payload = Get-MBLegacyCleanupJournal -Path $Path
    $matches = @($payload.Entries | Where-Object { $_.Id -eq $ItemId })
    if ($matches.Count -ne 1) { throw 'Item identity is missing or ambiguous.' }
    $entry = $matches[0]
    if ($entry.Status -ne 'Planned') { throw 'Only Planned entries can receive a review decision.' }
    if ($Approve -and ($entry.ProposedAction -ne 'CandidateForReviewedRemoval' -or
        $entry.Kind -ne 'File' -or $entry.Classification -ne 'MicBridgeBinaryCandidate' -or
        [string]$entry.Path -notmatch '(^|\\)MicBridgeAPO\.dll$' -or [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$')) {
        throw 'Approval is restricted to a hash-verified product DLL candidate; registrations and unknown files remain blocked.'
    }
    $entry.Status = if ($Approve) { 'ReviewApproved' } else { 'Blocked' }
    $entry.Reviewer = $Reviewer.Trim()
    $entry.DecisionUtc = [DateTime]::UtcNow.ToString('o')
    Write-MBLegacyCleanupJournalPayload -Payload $payload -Path $Path
    Get-MBLegacyCleanupJournal -Path $Path
}

Export-ModuleMember -Function New-MBLegacyCleanupJournal,Get-MBLegacyCleanupJournal,Set-MBLegacyCleanupReviewDecision
