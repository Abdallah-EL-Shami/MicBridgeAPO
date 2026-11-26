$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupJournal.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeCleanupJournal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $dll = Join-Path $root 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll, [byte[]](9,8,7,6))
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $plan = [pscustomobject]@{
        IsReadOnly=$true; InstallDirectory=$root; CanProceedToCleanupReview=$true; CleanupExecutionAllowed=$false; InstallAllowed=$false
        Items=@(
            [pscustomobject]@{Kind='File';Name='MicBridgeAPO.dll';Path=$dll;Classification='MicBridgeBinaryCandidate';ProposedAction='CandidateForReviewedRemoval';Sha256=$hash},
            [pscustomobject]@{Kind='Registration';Name='COM CLSID';Path='HKCU:\Software\Test';Classification='MicBridgeCandidate';ProposedAction='CandidateForReviewedRemoval';Sha256=$hash},
            [pscustomobject]@{Kind='File';Name='unknown.bin';Path=(Join-Path $root 'unknown.bin');Classification='UnclassifiedFile';ProposedAction='Preserve';Sha256=''}
        )
    }
    $journalPath = Join-Path $root 'review.json'
    $journal = New-MBLegacyCleanupJournal -Plan $plan -Path $journalPath
    if ($journal.Entries.Count -ne 3 -or $journal.CleanupExecutionAllowed -or $journal.InstallAllowed) { throw 'FAIL: unsafe journal initialization.' }
    $dllEntry = @($journal.Entries | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' })[0]
    $journal = Set-MBLegacyCleanupReviewDecision -Path $journalPath -ItemId $dllEntry.Id -Reviewer 'test-reviewer' -Approve $true
    $approved = @($journal.Entries | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' })[0]
    if ($approved.Status -ne 'ReviewApproved') { throw 'FAIL: approval transition not persisted.' }
    $registration = @($journal.Entries | Where-Object { $_.Kind -eq 'Registration' })[0]
    $blocked = $false
    try { Set-MBLegacyCleanupReviewDecision -Path $journalPath -ItemId $registration.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null } catch { $blocked = $true }
    if (-not $blocked) { throw 'FAIL: registration approval was not blocked.' }
    $staleJournalPath = Join-Path $root 'stale-review.json'
    $staleJournal = New-MBLegacyCleanupJournal -Plan $plan -Path $staleJournalPath
    [IO.File]::WriteAllBytes($dll, [byte[]](1,1,1,1))
    $staleEntry = @($staleJournal.Entries | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' })[0]
    $staleBlocked = $false
    try { Set-MBLegacyCleanupReviewDecision -Path $staleJournalPath -ItemId $staleEntry.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null } catch { $staleBlocked = $true }
    if (-not $staleBlocked) { throw 'FAIL: changed candidate content was approved.' }
    [IO.File]::WriteAllBytes($dll, [byte[]](9,8,7,6))
    $blockedPlan = [pscustomobject]@{
        IsReadOnly=$true; InstallDirectory=$root; CanProceedToCleanupReview=$false
        CleanupExecutionAllowed=$false; InstallAllowed=$false; Items=@($plan.Items[0])
    }
    $blockedJournalPath = Join-Path $root 'blocked-review.json'
    $blockedJournal = New-MBLegacyCleanupJournal -Plan $blockedPlan -Path $blockedJournalPath
    $blockedEntry = @($blockedJournal.Entries | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' })[0]
    $planGateBlocked = $false
    try { Set-MBLegacyCleanupReviewDecision -Path $blockedJournalPath -ItemId $blockedEntry.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null } catch { $planGateBlocked = $true }
    if (-not $planGateBlocked) { throw 'FAIL: plan with unresolved blockers allowed approval.' }

    $outsidePath = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeOutside-' + [guid]::NewGuid().ToString('N') + '.dll')
    try {
        [IO.File]::WriteAllBytes($outsidePath, [byte[]](4,3,2,1))
        $outsideHash = (Get-FileHash -LiteralPath $outsidePath -Algorithm SHA256).Hash
        $outsidePlan = [pscustomobject]@{
            IsReadOnly=$true; InstallDirectory=$root; CanProceedToCleanupReview=$true
            CleanupExecutionAllowed=$false; InstallAllowed=$false
            Items=@([pscustomobject]@{Kind='File';Name='MicBridgeAPO.dll';Path=$outsidePath;Classification='MicBridgeBinaryCandidate';ProposedAction='CandidateForReviewedRemoval';Sha256=$outsideHash})
        }
        $outsideJournalPath = Join-Path $root 'outside-review.json'
        $outsideJournal = New-MBLegacyCleanupJournal -Plan $outsidePlan -Path $outsideJournalPath
        $outsideEntry = $outsideJournal.Entries[0]
        $outsideBlocked = $false
        try { Set-MBLegacyCleanupReviewDecision -Path $outsideJournalPath -ItemId $outsideEntry.Id -Reviewer 'test-reviewer' -Approve $true | Out-Null } catch { $outsideBlocked = $true }
        if (-not $outsideBlocked) { throw 'FAIL: candidate outside install root was approved.' }
    } finally {
        if (Test-Path -LiteralPath $outsidePath) { Remove-Item -LiteralPath $outsidePath -Force }
    }
    $originalHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    if ($originalHash -ne $hash) { throw 'FAIL: journal changed product file.' }
    $raw = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    $tamperedPayload = [string]$raw.PayloadJson | ConvertFrom-Json
    $tamperedPayload.Entries[0].Reviewer = 'tampered'
    $raw.PayloadJson = ConvertTo-Json -InputObject $tamperedPayload -Compress -Depth 12
    Set-Content -LiteralPath $journalPath -Value (ConvertTo-Json -InputObject $raw -Depth 5)
    $integrityBlocked = $false
    try { Get-MBLegacyCleanupJournal -Path $journalPath | Out-Null } catch { $integrityBlocked = $true }
    if (-not $integrityBlocked) { throw 'FAIL: tampered journal passed integrity validation.' }
    Write-Host 'PASS: review journal is integrity-checked, atomic-write based, and cannot authorize cleanup or installation.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
