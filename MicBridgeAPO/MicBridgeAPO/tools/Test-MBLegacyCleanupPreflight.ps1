$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupJournal.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupPreflight.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeCleanupPreflight-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $dll = Join-Path $root 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll, [byte[]](11,22,33,44,55))
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $plan = [pscustomobject]@{
        IsReadOnly=$true; InstallDirectory=$root; CanProceedToCleanupReview=$true
        CleanupExecutionAllowed=$false; InstallAllowed=$false
        Items=@([pscustomobject]@{
            Kind='File'; Name='MicBridgeAPO.dll'; Path=$dll
            Classification='MicBridgeBinaryCandidate'; ProposedAction='CandidateForReviewedRemoval'; Sha256=$hash
        })
    }
    $journalPath = Join-Path $root 'approved.json'
    $journal = New-MBLegacyCleanupJournal -Plan $plan -Path $journalPath
    $entry = $journal.Entries[0]
    Set-MBLegacyCleanupReviewDecision -Path $journalPath -ItemId $entry.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null

    $before = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $result = Test-MBLegacyCleanupPreflight -JournalPath $journalPath
    if (-not $result.IsReadOnly -or $result.CleanupExecutionAllowed -or $result.InstallAllowed) {
        throw 'FAIL: preflight returned unsafe capability flags.'
    }
    if (-not $result.CanProceedToManualReview -or $result.VerifiedEntries.Count -ne 1 -or $result.Blockers.Count -ne 0) {
        throw 'FAIL: valid reviewed candidate did not pass read-only revalidation.'
    }
    $after = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    if ($before -ne $after) { throw 'FAIL: preflight changed the product DLL.' }

    $stalePath = Join-Path $root 'stale.json'
    $staleJournal = New-MBLegacyCleanupJournal -Plan $plan -Path $stalePath
    $staleEntry = $staleJournal.Entries[0]
    Set-MBLegacyCleanupReviewDecision -Path $stalePath -ItemId $staleEntry.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null
    [IO.File]::WriteAllBytes($dll, [byte[]](99,98,97))
    $stale = Test-MBLegacyCleanupPreflight -JournalPath $stalePath
    if ($stale.CanProceedToManualReview -or $stale.Blockers.Count -eq 0 -or $stale.VerifiedEntries.Count -ne 0) {
        throw 'FAIL: changed candidate passed preflight.'
    }

    $unreviewedPath = Join-Path $root 'unreviewed.json'
    $unreviewedJournal = New-MBLegacyCleanupJournal -Plan $plan -Path $unreviewedPath
    $unreviewed = Test-MBLegacyCleanupPreflight -JournalPath $unreviewedPath
    if ($unreviewed.CanProceedToManualReview -or $unreviewed.Blockers.Count -eq 0) {
        throw 'FAIL: unapproved candidate passed preflight.'
    }

    Write-Host 'PASS: preflight revalidates reviewed candidates, rejects stale/unapproved items, and performs no mutation.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
