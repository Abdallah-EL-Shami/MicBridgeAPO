$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

trap {
    Write-Host ("RECOVERY TEST ERROR: " + $_.Exception.Message)
    Write-Host ("RECOVERY TEST STACK: " + $_.ScriptStackTrace)
    throw
}

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

    # Crash-injection coverage for the three non-registry uninstall cleanup operations.
    # Each child dies after its external effect but before the journal can mark Completed.
    $cleanupChildPath = Join-Path $tempRoot 'cleanup-crash-child.ps1'
    $cleanupChildSource = @'
param([string]$ModulePath,[string]$JournalPath,[string]$StatePath,[string]$StepId,[string]$Mode,[string]$DeviceId)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force
$action = {
    switch ($Mode) {
        'RemoveDesktopShortcut' { Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop }
        'RestartAudioService' { [IO.File]::WriteAllText($StatePath,'restarted') }
        'RemoveInstallDirectory' { Remove-Item -LiteralPath $StatePath -Recurse -Force -ErrorAction Stop }
    }
    [Environment]::FailFast("Injected uninstall cleanup interruption: $Mode")
}
$verify = {
    switch ($Mode) {
        'RemoveDesktopShortcut' { -not (Test-Path -LiteralPath $StatePath) }
        'RestartAudioService' { (Test-Path -LiteralPath $StatePath -PathType Leaf) -and ([IO.File]::ReadAllText($StatePath) -eq 'restarted') }
        'RemoveInstallDirectory' { -not (Test-Path -LiteralPath $StatePath) }
    }
}
Invoke-MBRecoveryStep -Path $JournalPath -StepId $StepId -ExpectedOperation Uninstall -ExpectedDeviceId ([guid]$DeviceId) -ExpectedStepIds @($StepId) -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($cleanupChildPath,$cleanupChildSource,(New-Object Text.UTF8Encoding($false)))
    foreach ($cleanupMode in @('RemoveDesktopShortcut','RestartAudioService','RemoveInstallDirectory')) {
        $cleanupStatePath = Join-Path $tempRoot ($cleanupMode + '.state')
        if ($cleanupMode -eq 'RemoveInstallDirectory') {
            New-Item -ItemType Directory -Path $cleanupStatePath | Out-Null
            [IO.File]::WriteAllText((Join-Path $cleanupStatePath 'payload.txt'),'owned')
        } else {
            [IO.File]::WriteAllText($cleanupStatePath,'original')
        }
        $cleanupJournalPath = Join-Path $tempRoot ($cleanupMode + '.json')
        New-MBRecoveryJournal -Path $cleanupJournalPath -Operation Uninstall -DeviceId $device -StepIds @($cleanupMode) | Out-Null
        $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$cleanupChildPath,$modulePath,$cleanupJournalPath,$cleanupStatePath,$cleanupMode,$cleanupMode,$device.ToString()) -Wait -PassThru
        if ($child.ExitCode -eq 0) { throw "FAIL: $cleanupMode crash child exited successfully" }
        $crashedJournal = Read-MBRecoveryJournal -Path $cleanupJournalPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @($cleanupMode)
        if ($crashedJournal.Steps[0].State -ne 'Running') { throw "FAIL: $cleanupMode interruption did not persist Running state" }
        $resumeAction = { throw "Action must not repeat after $cleanupMode effect was observed" }
        $resumeVerify = switch ($cleanupMode) {
            'RemoveDesktopShortcut' { { -not (Test-Path -LiteralPath $cleanupStatePath) } }
            'RestartAudioService' { { (Test-Path -LiteralPath $cleanupStatePath -PathType Leaf) -and ([IO.File]::ReadAllText($cleanupStatePath) -eq 'restarted') } }
            'RemoveInstallDirectory' { { -not (Test-Path -LiteralPath $cleanupStatePath) } }
        }
        Invoke-MBRecoveryStep -Path $cleanupJournalPath -StepId $cleanupMode -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @($cleanupMode) -Action $resumeAction -Verify $resumeVerify
        $resumedJournal = Read-MBRecoveryJournal -Path $cleanupJournalPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @($cleanupMode)
        if ($resumedJournal.Steps[0].State -ne 'Completed' -or $resumedJournal.Steps[0].Attempts -ne 1) {
            throw "FAIL: $cleanupMode was not resumed without repeating its completed external effect"
        }
        Write-Host "PASS: hard interruption/resume after $cleanupMode external effect"
    }

    # Declared prerequisites suppress dependent mutations after a prerequisite fails.
    $dependencyPath = Join-Path $tempRoot 'dependency-plan.json'
    $dependencySteps = @('RestoreRegistry','RestoreAcl','VerifyState')
    New-MBRecoveryJournal -Path $dependencyPath -Operation Uninstall -DeviceId $device -StepIds $dependencySteps | Out-Null
    $dependencyState = Join-Path $tempRoot 'dependency-state'
    New-Item -ItemType Directory -Path $dependencyState | Out-Null
    $dependencyActions = @{
        RestoreRegistry = { throw 'injected registry restore failure' }
        RestoreAcl = { [IO.File]::WriteAllText((Join-Path $dependencyState 'acl'),'changed') }
        VerifyState = { [IO.File]::WriteAllText((Join-Path $dependencyState 'verified'),'yes') }
    }
    $dependencyVerifiers = @{
        RestoreRegistry = { Test-Path (Join-Path $dependencyState 'registry') }
        RestoreAcl = { Test-Path (Join-Path $dependencyState 'acl') }
        VerifyState = { Test-Path (Join-Path $dependencyState 'verified') }
    }
    $dependencyFailed = $false
    try {
        Invoke-MBRecoveryPlan -Path $dependencyPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds $dependencySteps -Actions $dependencyActions -Verifiers $dependencyVerifiers -Dependencies @{ RestoreAcl=@('RestoreRegistry'); VerifyState=@('RestoreAcl') }
    } catch { if ($_.Exception.Message -like '*RestoreRegistry*') { $dependencyFailed = $true } else { throw } }
    if (-not $dependencyFailed) { throw 'FAIL: prerequisite failure was not reported' }
    if ((Test-Path (Join-Path $dependencyState 'acl')) -or (Test-Path (Join-Path $dependencyState 'verified'))) {
        throw 'FAIL: dependent recovery action ran after its prerequisite failed'
    }
    $dependencyJournal = Read-MBRecoveryJournal -Path $dependencyPath
    if (@($dependencyJournal.Steps | Where-Object { $_.State -eq 'Completed' }).Count -ne 0) {
        throw 'FAIL: dependent plan incorrectly marked a step completed'
    }

    # The installer may hand its already-held operation lock to the plan.
    # The plan must neither reacquire nor dispose a lock owned by its caller.
    $heldPlanPath = Join-Path $tempRoot 'held-plan.json'
    New-MBRecoveryJournal -Path $heldPlanPath -Operation Uninstall -DeviceId $device -StepIds @('HeldLockStep') | Out-Null
    $callerLock = Enter-MBRecoveryOperationLock -Path $heldPlanPath
    try {
        $heldActionRan = $false
        $heldActions = @{ HeldLockStep = { $script:heldActionRan=$true } }
        $heldVerifiers = @{ HeldLockStep = { $script:heldActionRan } }
        Invoke-MBRecoveryPlan -Path $heldPlanPath -ExpectedOperation Uninstall -ExpectedDeviceId $device -ExpectedStepIds @('HeldLockStep') -Actions $heldActions -Verifiers $heldVerifiers -OperationLock $callerLock | Out-Null
        if (-not $heldActionRan) { throw 'FAIL: plan did not execute under caller-held operation lock' }
        $stillExclusive = $false
        try { Enter-MBRecoveryOperationLock -Path $heldPlanPath | Out-Null }
        catch { if ($_.Exception.Message -like '*Another MicBridge*') { $stillExclusive = $true } else { throw } }
        if (-not $stillExclusive) { throw 'FAIL: plan disposed an operation lock owned by its caller' }
    } finally { $callerLock.Dispose() }

    Write-Host 'PASS: durable journal creation, hard process interruption/resume, retry, and identity binding, exclusive locking, and fail-closed validation'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
