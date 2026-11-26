$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
Import-Module $modulePath -Force

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeRecoveryTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $journalPath = Join-Path $tempRoot 'recovery.json'
    $device = [guid]::NewGuid()
    $journal = New-MBRecoveryJournal -Path $journalPath -Operation Uninstall -DeviceId $device -StepIds @('RestoreEndpointValues','RestoreEndpointAcl','RestoreCom')
    if ($journal.SchemaVersion -ne 1 -or $journal.Steps.Count -ne 3) { throw 'FAIL: journal creation/schema' }

    # Exercise a real abrupt process death after the side effect, before the journal
    # can persist Completed. FailFast bypasses PowerShell catch/finally handlers.
    $state = Join-Path $tempRoot 'effect.txt'
    $childPath = Join-Path $tempRoot 'crash-child.ps1'
    $childSource = @'
param([string]$ModulePath,[string]$JournalPath,[string]$StatePath)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force
$state = $StatePath
Invoke-MBRecoveryStep -Path $JournalPath -StepId 'RestoreEndpointValues' -Action {
    [IO.File]::WriteAllText($state,'applied')
    [Environment]::FailFast('Injected hard process termination after side effect')
} -Verify { Test-Path -LiteralPath $state }
'@
    [IO.File]::WriteAllText($childPath,$childSource,(New-Object Text.UTF8Encoding($false)))
    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { $powershell = (Get-Command pwsh.exe -ErrorAction Stop).Source }
    $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childPath,$modulePath,$journalPath,$state) -Wait -PassThru
    if ($child.ExitCode -eq 0) { throw 'FAIL: crash child unexpectedly exited successfully' }
    if (-not (Test-Path -LiteralPath $state)) { throw 'FAIL: child did not persist the simulated external side effect' }

    $afterCrash = Read-MBRecoveryJournal -Path $journalPath
    $step = @($afterCrash.Steps | Where-Object Id -eq 'RestoreEndpointValues')[0]
    if ($step.State -ne 'Running' -or $step.Attempts -ne 1) { throw 'FAIL: abrupt process death did not leave a durable Running state' }

    # A fresh parent process context resumes by observing the postcondition;
    # the action must not run a second time.
    Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointValues' -Action { throw 'Action must not repeat when postcondition already holds' } -Verify { Test-Path -LiteralPath $state }
    $afterResume = Read-MBRecoveryJournal -Path $journalPath
    $step = @($afterResume.Steps | Where-Object Id -eq 'RestoreEndpointValues')[0]
    if ($step.State -ne 'Completed' -or $step.Attempts -ne 1) { throw 'FAIL: recovery did not recognize the already-applied effect' }

    # Each atomic replacement keeps a deterministic last-known-good journal.
    $stablePrevious = "$journalPath.previous"
    if (-not (Test-Path -LiteralPath $stablePrevious -PathType Leaf)) {
        throw 'FAIL: atomic journal replacement did not retain a stable .previous file'
    }
    $previousState = Get-Content -LiteralPath $stablePrevious -Raw | ConvertFrom-Json
    if ($previousState.SchemaVersion -ne 1 -or $previousState.TransactionId -ne $journal.TransactionId) {
        throw 'FAIL: stable .previous file is not a valid snapshot of this transaction'
    }

    # Corrupt the active journal and verify that the independently validated
    # last-known-good snapshot is restored without losing transaction identity.
    $fallbackPath = Join-Path $tempRoot 'fallback.json'
    $fallbackJournal = New-MBRecoveryJournal -Path $fallbackPath -Operation Uninstall -DeviceId $device -StepIds @('RestoreOne') 
    Invoke-MBRecoveryStep -Path $fallbackPath -StepId 'RestoreOne' -Action { [IO.File]::WriteAllText((Join-Path $tempRoot 'fallback-effect'),'ok') } -Verify { Test-Path (Join-Path $tempRoot 'fallback-effect') }
    [IO.File]::WriteAllText($fallbackPath,'{corrupted')
    $recovered = Read-MBRecoveryJournal -Path $fallbackPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @('RestoreOne')
    if ($recovered.TransactionId -ne $fallbackJournal.TransactionId) { throw 'FAIL: fallback journal identity was not preserved' }
    $restoredPrimary = Get-Content -LiteralPath $fallbackPath -Raw | ConvertFrom-Json
    if ($restoredPrimary.TransactionId -ne $fallbackJournal.TransactionId) { throw 'FAIL: validated fallback was not restored to the primary journal path' }
    if (-not (Get-ChildItem -LiteralPath $tempRoot -Filter 'fallback.json.corrupt.*' -File)) { throw 'FAIL: corrupt primary journal was not preserved for diagnosis' }

    # Missing primary with a valid .previous must recreate the primary durably.
    $missingPath = Join-Path $tempRoot 'missing-primary.json'
    $missingJournal = New-MBRecoveryJournal -Path $missingPath -Operation Uninstall -DeviceId $device -StepIds @('RestoreMissing')
    Invoke-MBRecoveryStep -Path $missingPath -StepId 'RestoreMissing' -Action { [IO.File]::WriteAllText((Join-Path $tempRoot 'missing-effect'),'ok') } -Verify { Test-Path (Join-Path $tempRoot 'missing-effect') }
    if (-not (Test-Path -LiteralPath "$missingPath.previous" -PathType Leaf)) { throw 'FAIL: missing-primary scenario has no previous snapshot' }
    Remove-Item -LiteralPath $missingPath -Force
    $fromMissing = Read-MBRecoveryJournal -Path $missingPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @('RestoreMissing')
    if ($fromMissing.TransactionId -ne $missingJournal.TransactionId) { throw 'FAIL: missing primary fallback changed transaction identity' }
    if (-not (Test-Path -LiteralPath $missingPath -PathType Leaf)) { throw 'FAIL: missing primary was not recreated from the previous snapshot' }
    $recreated = Get-Content -LiteralPath $missingPath -Raw | ConvertFrom-Json
    if ($recreated.TransactionId -ne $missingJournal.TransactionId) { throw 'FAIL: recreated primary content is invalid' }

    # Idempotent retry after an action failed before its effect.
    $retryPath = Join-Path $tempRoot 'retry.json'
    New-MBRecoveryJournal -Path $retryPath -Operation InstallRollback -DeviceId $device -StepIds @('RestoreFiles') | Out-Null
    $flag = Join-Path $tempRoot 'retry.flag'
    try {
        Invoke-MBRecoveryStep -Path $retryPath -StepId 'RestoreFiles' -Action { throw 'first attempt failure' } -Verify { Test-Path -LiteralPath $flag }
    } catch { if ($_.Exception.Message -notlike '*first attempt failure*') { throw } }
    Invoke-MBRecoveryStep -Path $retryPath -StepId 'RestoreFiles' -Action { [IO.File]::WriteAllText($flag,'ok') } -Verify { Test-Path -LiteralPath $flag }
    $retryJournal = Read-MBRecoveryJournal -Path $retryPath
    $retryStep = @($retryJournal.Steps | Where-Object Id -eq 'RestoreFiles')[0]
    if ($retryStep.State -ne 'Completed' -or $retryStep.Attempts -ne 2) { throw 'FAIL: retry did not complete correctly' }

    # If the journal cannot be read/written (e.g. storage handle contention),
    # the external action must not begin before its Running state is durable.
    $blockedWritePath = Join-Path $tempRoot 'blocked-write.json'
    New-MBRecoveryJournal -Path $blockedWritePath -Operation Uninstall -DeviceId $device -StepIds @('RestoreBeforeMutation') | Out-Null
    $blockedWriteRan = $false
    $exclusiveJournalHandle = New-Object IO.FileStream($blockedWritePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $writeBlocked = $false
        try {
            Invoke-MBRecoveryStep -Path $blockedWritePath -StepId 'RestoreBeforeMutation' -Action { $script:blockedWriteRan=$true } -Verify { $false }
        } catch { $writeBlocked = $true }
        if (-not $writeBlocked) { throw 'FAIL: recovery proceeded despite an unavailable journal file' }
        if ($blockedWriteRan) { throw 'FAIL: external mutation ran before its Running journal state could be persisted' }
    } finally { $exclusiveJournalHandle.Dispose() }
    $stillValid = Read-MBRecoveryJournal -Path $blockedWritePath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @('RestoreBeforeMutation')
    if ($stillValid.Steps[0].State -ne 'Pending') { throw 'FAIL: failed journal update damaged the last durable state' }

    # The dedicated writer lock must also fail closed independently of the
    # per-step lock, leaving the durable journal state unchanged.
    $writerLockPath = Join-Path $tempRoot 'writer-lock.json'
    New-MBRecoveryJournal -Path $writerLockPath -Operation Uninstall -DeviceId $device -StepIds @('WriterLockStep') | Out-Null
    $writerLockHandle = New-Object IO.FileStream("$writerLockPath.write.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $writerActionRan = $false
    try {
        $writerBlocked = $false
        try {
            Invoke-MBRecoveryStep -Path $writerLockPath -StepId 'WriterLockStep' -Action { $script:writerActionRan=$true } -Verify { $false }
        } catch { $writerBlocked = $true }
        if (-not $writerBlocked) { throw 'FAIL: journal writer lock did not block a competing writer' }
        if ($writerActionRan) { throw 'FAIL: action ran without a durable Running journal update' }
    } finally { $writerLockHandle.Dispose() }
    $writerLockState = Read-MBRecoveryJournal -Path $writerLockPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @('WriterLockStep')
    if ($writerLockState.Steps[0].State -ne 'Pending') { throw 'FAIL: writer-lock contention changed the durable step state' }

    # Fallback restoration must honor the same writer lock as normal journal writes.
    $lockedFallbackPath = Join-Path $tempRoot 'locked-fallback.json'
    New-MBRecoveryJournal -Path $lockedFallbackPath -Operation Uninstall -DeviceId $device -StepIds @('RestoreLocked') | Out-Null
    Invoke-MBRecoveryStep -Path $lockedFallbackPath -StepId 'RestoreLocked' -Action { } -Verify { $true }
    [IO.File]::WriteAllText($lockedFallbackPath,'{corrupted')
    $corruptBytesBefore = [IO.File]::ReadAllBytes($lockedFallbackPath)
    $fallbackWriteLock = New-Object IO.FileStream("$lockedFallbackPath.write.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $restoreBlocked = $false
        try { Read-MBRecoveryJournal -Path $lockedFallbackPath | Out-Null }
        catch { $restoreBlocked = $true }
        if (-not $restoreBlocked) { throw 'FAIL: corrupt-primary fallback restoration ignored the writer lock' }
        $corruptBytesAfter = [IO.File]::ReadAllBytes($lockedFallbackPath)
        if ([Convert]::ToBase64String($corruptBytesBefore) -ne [Convert]::ToBase64String($corruptBytesAfter)) {
            throw 'FAIL: blocked fallback restoration changed the corrupt primary'
        }
    } finally { $fallbackWriteLock.Dispose() }
    $lockedRecovered = Read-MBRecoveryJournal -Path $lockedFallbackPath
    if ($lockedRecovered.Steps.Count -ne 1) { throw 'FAIL: corrupt-primary fallback did not recover after lock release' }

    $lockedMissingPath = Join-Path $tempRoot 'locked-missing.json'
    New-MBRecoveryJournal -Path $lockedMissingPath -Operation Uninstall -DeviceId $device -StepIds @('RestoreMissingLocked') | Out-Null
    Invoke-MBRecoveryStep -Path $lockedMissingPath -StepId 'RestoreMissingLocked' -Action { } -Verify { $true }
    Remove-Item -LiteralPath $lockedMissingPath -Force
    $missingWriteLock = New-Object IO.FileStream("$lockedMissingPath.write.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $missingRestoreBlocked = $false
        try { Read-MBRecoveryJournal -Path $lockedMissingPath | Out-Null }
        catch { $missingRestoreBlocked = $true }
        if (-not $missingRestoreBlocked) { throw 'FAIL: missing-primary fallback restoration ignored the writer lock' }
        if (Test-Path -LiteralPath $lockedMissingPath) { throw 'FAIL: blocked missing-primary restoration created a primary file' }
    } finally { $missingWriteLock.Dispose() }
    $missingLockedRecovered = Read-MBRecoveryJournal -Path $lockedMissingPath
    if ($missingLockedRecovered.Steps.Count -ne 1) { throw 'FAIL: missing-primary fallback did not recover after lock release' }

    # Persistent recovery artifacts are bound to their SHA-256 content.
    $manifestFile = Join-Path $tempRoot 'com-snapshot.reg'
    [IO.File]::WriteAllText($manifestFile,"Windows Registry Editor Version 5.00`r`n")
    $manifestHash = (Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash
    if ($manifestHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'FAIL: SHA-256 manifest format' }
    [IO.File]::AppendAllText($manifestFile,';tampered')
    $tamperedHash = (Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash
    if ([string]::Equals($manifestHash,$tamperedHash,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'FAIL: modified recovery artifact retained its original hash'
    }

    # Corrupt identity/schema must fail closed.
    $badPath = Join-Path $tempRoot 'bad.json'
    [IO.File]::WriteAllText($badPath,'{"SchemaVersion":99,"Operation":"Uninstall","DeviceId":"bad","Steps":[]}')
    try { Read-MBRecoveryJournal -Path $badPath | Out-Null; throw 'FAIL: corrupt journal accepted' }
    catch { if ($_.Exception.Message -eq 'FAIL: corrupt journal accepted') { throw } }

    # Caller identity and exact step-plan binding must fail closed.
    try {
        Read-MBRecoveryJournal -Path $journalPath -ExpectedOperation InstallRollback | Out-Null
        throw 'FAIL: operation mismatch accepted'
    } catch { if ($_.Exception.Message -eq 'FAIL: operation mismatch accepted') { throw } }
    try {
        Read-MBRecoveryJournal -Path $journalPath -ExpectedDeviceId ([guid]::NewGuid()) | Out-Null
        throw 'FAIL: endpoint mismatch accepted'
    } catch { if ($_.Exception.Message -eq 'FAIL: endpoint mismatch accepted') { throw } }
    try {
        Read-MBRecoveryJournal -Path $journalPath -ExpectedStepIds @('RestoreCom','RestoreEndpointAcl','RestoreEndpointValues') | Out-Null
        throw 'FAIL: altered step plan accepted'
    } catch { if ($_.Exception.Message -eq 'FAIL: altered step plan accepted') { throw } }

    # An exclusive lock prevents two recovery processes from executing concurrently.
    $lockPath = "$journalPath.lock"
    $heldLock = New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $ranWhileLocked = $false
    try {
        try {
            Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointAcl' -Action { $script:ranWhileLocked=$true } -Verify { $false }
            throw 'FAIL: recovery proceeded while lock was held'
        } catch { if ($_.Exception.Message -eq 'FAIL: recovery proceeded while lock was held') { throw } }
    } finally { $heldLock.Dispose() }
    if ($ranWhileLocked) { throw 'FAIL: action ran despite a held recovery lock' }


    # Operation-wide lock is distinct from the per-step journal lock and must
    # prevent a second transaction from entering while the first plan is active.
    $operationLock = Enter-MBRecoveryOperationLock -Path $journalPath
    try {
        $blocked = $false
        try { Enter-MBRecoveryOperationLock -Path $journalPath | Out-Null }
        catch { if ($_.Exception.Message -like '*Another MicBridge*') { $blocked = $true } else { throw } }
        if (-not $blocked) { throw 'FAIL: operation-wide lock allowed a concurrent transaction' }
    } finally { $operationLock.Dispose() }

    # A plan must continue independent restoration steps after one action fails,
    # retain successful progress, and report the failed step for a later retry.
    $planPath = Join-Path $tempRoot 'plan.json'
    $planSteps = @('RestoreValues','RestoreAcl','RestoreCom')
    New-MBRecoveryJournal -Path $planPath -Operation Uninstall -DeviceId $device -StepIds $planSteps | Out-Null
    $planState = Join-Path $tempRoot 'plan-state'
    New-Item -ItemType Directory -Path $planState | Out-Null
    $actions = @{
        RestoreValues = { [IO.File]::WriteAllText((Join-Path $planState 'values'),'ok') }
        RestoreAcl = { throw 'injected ACL restore failure' }
        RestoreCom = { [IO.File]::WriteAllText((Join-Path $planState 'com'),'ok') }
    }
    $verifiers = @{
        RestoreValues = { Test-Path (Join-Path $planState 'values') }
        RestoreAcl = { Test-Path (Join-Path $planState 'acl') }
        RestoreCom = { Test-Path (Join-Path $planState 'com') }
    }
    $planFailed = $false
    try {
        Invoke-MBRecoveryPlan -Path $planPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds $planSteps -Actions $actions -Verifiers $verifiers
    } catch { if ($_.Exception.Message -like '*RestoreAcl*') { $planFailed = $true } else { throw } }
    if (-not $planFailed) { throw 'FAIL: incomplete plan did not report its failed step' }
    if (-not (Test-Path (Join-Path $planState 'values')) -or -not (Test-Path (Join-Path $planState 'com'))) {
        throw 'FAIL: independent steps were not attempted after the ACL failure'
    }
    $partial = Read-MBRecoveryJournal -Path $planPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds $planSteps
    if ((@($partial.Steps | Where-Object { $_.State -eq 'Completed' })).Count -ne 2) {
        throw 'FAIL: successful independent plan steps were not durably recorded'
    }
    $actions.RestoreAcl = { [IO.File]::WriteAllText((Join-Path $planState 'acl'),'ok') }
    Invoke-MBRecoveryPlan -Path $planPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds $planSteps -Actions $actions -Verifiers $verifiers | Out-Null
    $finished = Read-MBRecoveryJournal -Path $planPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds $planSteps
    if (@($finished.Steps | Where-Object { $_.State -ne 'Completed' }).Count -ne 0) {
        throw 'FAIL: resumed plan did not complete every step'
    }

    Write-Host 'PASS: durable journal creation, hard process interruption/resume, retry, and identity binding, exclusive locking, and fail-closed validation'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
