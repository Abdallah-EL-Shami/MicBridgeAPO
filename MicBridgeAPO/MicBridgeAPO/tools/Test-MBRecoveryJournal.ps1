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

    Write-Host 'PASS: durable journal creation, hard process interruption/resume, retry, and identity binding, exclusive locking, and fail-closed validation'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
