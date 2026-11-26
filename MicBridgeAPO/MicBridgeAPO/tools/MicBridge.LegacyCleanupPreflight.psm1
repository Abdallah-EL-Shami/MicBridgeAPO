Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupJournal.psm1') -ErrorAction Stop

function Test-MBLegacyCleanupPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalPath)

    # This function is deliberately read-only. It does not delete, move, rename,
    # alter registry, change ACLs, or authorize installation.
    $journal = Get-MBLegacyCleanupJournal -Path $JournalPath
    $approved = @($journal.Entries | Where-Object { $_.Status -eq 'ReviewApproved' })
    $skipped = @($journal.Entries | Where-Object { $_.Status -ne 'ReviewApproved' })
    $verified = @()
    $blockers = @()

    if ($journal.CleanupExecutionAllowed -ne $false -or $journal.InstallAllowed -ne $false) {
        $blockers += 'Journal contains an unsafe authorization flag.'
    }
    if ($journal.CanProceedToCleanupReview -ne $true) {
        $blockers += 'Original audit contains unresolved blockers.'
    }
    if ($approved.Count -eq 0) {
        $blockers += 'No entries have an explicit review approval.'
    }

    $root = [IO.Path]::GetFullPath([string]$journal.InstallDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $blockers += 'Audited installation directory no longer exists.'
    } else {
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $blockers += 'Audited installation directory is a reparse point.'
        }
    }

    foreach ($entry in $approved) {
        if ($entry.Kind -ne 'File' -or $entry.Classification -ne 'MicBridgeBinaryCandidate' -or
            $entry.ProposedAction -ne 'CandidateForReviewedRemoval' -or
            [IO.Path]::GetFileName([string]$entry.Path) -ine 'MicBridgeAPO.dll' -or
            [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            $blockers += "Approved entry is outside the permitted product-DLL scope: $($entry.Id)"
            continue
        }
        try {
            $candidatePath = [IO.Path]::GetFullPath([string]$entry.Path)
            $prefix = $root + [IO.Path]::DirectorySeparatorChar
            if (-not $candidatePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Candidate is outside the audited installation directory.'
            }
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw 'Candidate file is missing.' }
            $file = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate file is a reparse point.' }
            $walk = Split-Path -Parent $candidatePath
            while ($walk -and $walk.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {
                $dir = Get-Item -LiteralPath $walk -Force -ErrorAction Stop
                if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate path contains a reparse-point directory.' }
                if ($walk.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { break }
                $walk = Split-Path -Parent $walk
            }
            if (-not $walk -or -not $walk.Equals($root,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Candidate path could not be resolved beneath the audited installation directory.'
            }
            $actual = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not $actual.Equals([string]$entry.Sha256,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Candidate hash changed after review approval.'
            }
            $verified += [pscustomobject]@{
                ItemId=[string]$entry.Id
                Name=[string]$entry.Name
                Path=$candidatePath
                Sha256=$actual
                Status='RevalidatedForManualReview'
            }
        } catch {
            $blockers += "Entry $($entry.Id) failed revalidation: $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        SchemaVersion=1
        IsReadOnly=$true
        JournalPath=[IO.Path]::GetFullPath($JournalPath)
        AuditedInstallDirectory=$root
        VerifiedEntries=@($verified)
        SkippedEntries=@($skipped | ForEach-Object { [pscustomobject]@{ItemId=[string]$_.Id;Status=[string]$_.Status;Kind=[string]$_.Kind;Name=[string]$_.Name} })
        Blockers=@($blockers)
        CanProceedToManualReview=($blockers.Count -eq 0 -and $verified.Count -gt 0)
        CleanupExecutionAllowed=$false
        InstallAllowed=$false
        Warnings=@(
            'Revalidation is not proof of ownership and is not deletion authorization.',
            'Shared COM/APO registrations and unapproved entries remain untouched.',
            'A separate reviewed executor and explicit user confirmation are still required.'
        )
    }
}

Export-ModuleMember -Function Test-MBLegacyCleanupPreflight
