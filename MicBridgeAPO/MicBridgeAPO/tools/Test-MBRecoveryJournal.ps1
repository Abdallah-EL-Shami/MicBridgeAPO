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

    $state = Join-Path $tempRoot 'effect.txt'
    $actionCount = 0
    $action = {
        $script:actionCount++
        [IO.File]::WriteAllText($state,'applied')
        throw 'Injected interruption after side effect'
    }.GetNewClosure()
    $verify = { Test-Path -LiteralPath $state }.GetNewClosure()

    try {
        Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointValues' -Action $action -Verify $verify
        throw 'FAIL: injected interruption was not propagated'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: injected interruption was not propagated') { throw }
        if ($_.Exception.Message -notlike '*Injected interruption*') { throw }
    }

    $afterFailure = Read-MBRecoveryJournal -Path $journalPath
    $step = @($afterFailure.Steps | Where-Object Id -eq 'RestoreEndpointValues')[0]
    if ($step.State -ne 'Running' -or $step.Attempts -ne 1) { throw 'FAIL: interrupted step was not durably marked Running' }

    # Simulate process death after the side effect but before completion was persisted.
    Invoke-MBRecoveryStep -Path $journalPath -StepId 'RestoreEndpointValues' -Action { throw 'Action must not repeat when postcondition already holds' } -Verify $verify
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

    Write-Host 'PASS: durable journal creation, interrupted-step resume, retry, and fail-closed validation'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
