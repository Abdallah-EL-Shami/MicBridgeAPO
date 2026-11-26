Set-StrictMode -Version Latest

function Write-MBRecoveryJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temp = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    # Never delete the last known-good journal before the replacement is durable.
    $backup = "$Path.previous"
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = $null
    $writeLock = $null
    try {
        # Serialize every journal replacement, including initial creation and fallback repair.
        # The OS releases this handle automatically if the process terminates.
        $writeLock = New-Object IO.FileStream("$Path.write.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        # WriteThrough reduces exposure to OS cache loss; Flush(true) requests a durable file flush.
        $stream = New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temp,$Path,$backup,$true)
        } else {
            [IO.File]::Move($temp,$Path)
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($writeLock) { $writeLock.Dispose() }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        # A backup left by a crash is intentionally retained for forensic/manual recovery.
    }
}

function New-MBRecoveryJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('InstallRollback','Uninstall')][string]$Operation,
        [Parameter(Mandatory)][guid]$DeviceId,
        [Parameter(Mandatory)][string[]]$StepIds
    )
    if (Test-Path -LiteralPath $Path) { throw "Recovery journal already exists: $Path" }
    if (-not $StepIds -or @($StepIds | Select-Object -Unique).Count -ne $StepIds.Count) {
        throw 'Recovery journal step IDs must be non-empty and unique.'
    }
    $steps = @()
    foreach ($id in $StepIds) {
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw "Invalid recovery step ID: $id" }
        $steps += [pscustomobject]@{ Id=$id; State='Pending'; Attempts=0; LastError=$null }
    }
    $now = [DateTime]::UtcNow.ToString('o')
    $journal = [pscustomobject]@{
        SchemaVersion=1
        TransactionId=[guid]::NewGuid().ToString('D')
        Operation=$Operation
        DeviceId=$DeviceId.ToString('D')
        CreatedUtc=$now
        UpdatedUtc=$now
        Steps=$steps
    }
    Write-MBRecoveryJsonAtomic -Path $Path -Value $journal
    return $journal
}

function Restore-MBRecoveryPreviousJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedOperation,
        [guid]$ExpectedDeviceId,
        [string[]]$ExpectedStepIds
    )
    $writeLock = $null
    $temp = $null
    try {
        # Recovery must serialize with normal writers and re-check the primary
        # only after acquiring the same lock used by Write-MBRecoveryJsonAtomic.
        $writeLock = New-Object IO.FileStream("$Path.write.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $primaryArgs = @{ Path=$Path; NoPreviousFallback=$true }
        if ($ExpectedOperation) { $primaryArgs.ExpectedOperation=$ExpectedOperation }
        if ($ExpectedDeviceId -ne [guid]::Empty) { $primaryArgs.ExpectedDeviceId=$ExpectedDeviceId }
        if (@($ExpectedStepIds).Count -gt 0) { $primaryArgs.ExpectedStepIds=$ExpectedStepIds }
        try {
            # A writer may have repaired/replaced the primary while we waited.
            # Prefer that newer valid primary over an older .previous snapshot.
            return Read-MBRecoveryJournal @primaryArgs
        } catch {
            # Continue only when the primary is still missing or invalid.
        }
        $previousPath = "$Path.previous"
        if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
            throw "Recovery journal and its fallback are invalid or unreadable: $Path"
        }
        $fallbackArgs = @{ Path=$previousPath; NoPreviousFallback=$true }
        if ($ExpectedOperation) { $fallbackArgs.ExpectedOperation=$ExpectedOperation }
        if ($ExpectedDeviceId -ne [guid]::Empty) { $fallbackArgs.ExpectedDeviceId=$ExpectedDeviceId }
        if (@($ExpectedStepIds).Count -gt 0) { $fallbackArgs.ExpectedStepIds=$ExpectedStepIds }
        $fallback = Read-MBRecoveryJournal @fallbackArgs
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $temp = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.restore.tmp')
        $bytes = [IO.File]::ReadAllBytes($previousPath)
        $corrupt = "$Path.corrupt.$([guid]::NewGuid().ToString('N'))"
        $restore = $null
        try {
            $restore = New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            $restore.Write($bytes,0,$bytes.Length)
            $restore.Flush($true)
            $restore.Dispose()
            $restore = $null
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                [IO.File]::Replace($temp,$Path,$corrupt,$true)
            } else {
                [IO.File]::Move($temp,$Path)
            }
        } finally {
            if ($restore) { $restore.Dispose() }
            if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        return $fallback
    } finally {
        if ($writeLock) { $writeLock.Dispose() }
    }
}

function Read-MBRecoveryJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('InstallRollback','Uninstall')][string]$ExpectedOperation,
        [guid]$ExpectedDeviceId,
        [string[]]$ExpectedStepIds,
        [switch]$NoPreviousFallback
    )
    $sourcePath = $Path
    $usedPrevious = $false
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        if (-not $NoPreviousFallback -and (Test-Path -LiteralPath "$Path.previous" -PathType Leaf)) {
            $sourcePath = "$Path.previous"
            $usedPrevious = $true
        } else {
            throw "Recovery journal is missing: $Path"
        }
    }
    try {
        $j = Get-Content -LiteralPath $sourcePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $parsedDeviceId = [guid]::Empty
        $parsedTransactionId = [guid]::Empty
        $created = [DateTime]::MinValue
        $updated = [DateTime]::MinValue
        if ($j.SchemaVersion -ne 1 -or $j.Operation -notin @('InstallRollback','Uninstall') -or
            -not [guid]::TryParse([string]$j.DeviceId,[ref]$parsedDeviceId) -or
            -not [guid]::TryParse([string]$j.TransactionId,[ref]$parsedTransactionId) -or
            -not [DateTime]::TryParse([string]$j.CreatedUtc,[ref]$created) -or
            -not [DateTime]::TryParse([string]$j.UpdatedUtc,[ref]$updated) -or
            $null -eq $j.Steps -or @($j.Steps).Count -eq 0) {
            throw 'Recovery journal schema, timestamps, or identity are invalid.'
        }
        foreach ($entry in @($j.Steps)) {
            if ($entry.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or
                $entry.State -notin @('Pending','Running','Completed') -or [int]$entry.Attempts -lt 0) {
                throw 'Recovery journal contains invalid step data.'
            }
        }
        $ids = @($j.Steps | ForEach-Object { [string]$_.Id })
        if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
            throw 'Recovery journal contains duplicate step IDs.'
        }
    } catch {
        if ($NoPreviousFallback -or $usedPrevious -or -not (Test-Path -LiteralPath "$Path.previous" -PathType Leaf)) {
            throw "Recovery journal and its fallback are invalid or unreadable: $($_.Exception.Message)"
        }
        $restoreArgs = @{ Path=$Path }
        if ($PSBoundParameters.ContainsKey('ExpectedOperation')) { $restoreArgs.ExpectedOperation=$ExpectedOperation }
        if ($PSBoundParameters.ContainsKey('ExpectedDeviceId')) { $restoreArgs.ExpectedDeviceId=$ExpectedDeviceId }
        if ($PSBoundParameters.ContainsKey('ExpectedStepIds')) { $restoreArgs.ExpectedStepIds=$ExpectedStepIds }
        return Restore-MBRecoveryPreviousJournal @restoreArgs
    }
    if ($ExpectedOperation -and $j.Operation -ne $ExpectedOperation) {
        throw 'Recovery journal operation does not match the requested operation; refusing recovery.'
    }
    if ($PSBoundParameters.ContainsKey('ExpectedDeviceId') -and $parsedDeviceId -ne $ExpectedDeviceId) {
        throw 'Recovery journal endpoint identity does not match the requested device; refusing recovery.'
    }
    if ($PSBoundParameters.ContainsKey('ExpectedStepIds')) {
        if (@($ExpectedStepIds).Count -ne $ids.Count) { throw 'Recovery journal step plan does not match the caller; refusing recovery.' }
        for ($i=0; $i -lt $ids.Count; $i++) {
            if ([string]$ExpectedStepIds[$i] -ne $ids[$i]) { throw 'Recovery journal step plan does not match the caller; refusing recovery.' }
        }
    }
    if ($usedPrevious) {
        $restoreArgs = @{ Path=$Path }
        if ($PSBoundParameters.ContainsKey('ExpectedOperation')) { $restoreArgs.ExpectedOperation=$ExpectedOperation }
        if ($PSBoundParameters.ContainsKey('ExpectedDeviceId')) { $restoreArgs.ExpectedDeviceId=$ExpectedDeviceId }
        if ($PSBoundParameters.ContainsKey('ExpectedStepIds')) { $restoreArgs.ExpectedStepIds=$ExpectedStepIds }
        return Restore-MBRecoveryPreviousJournal @restoreArgs
    }
    return $j
}

function Invoke-MBRecoveryStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Verify,
        [ValidateSet('InstallRollback','Uninstall')][string]$ExpectedOperation,
        [guid]$ExpectedDeviceId,
        [string[]]$ExpectedStepIds,
        [int]$LockTimeoutSeconds = 0
    )
    $lockPath = "$Path.lock"
    $lock = $null
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0,$LockTimeoutSeconds))
    do {
        try {
            $lock = New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Another MicBridge recovery operation holds the journal lock; refusing concurrent recovery.' }
            Start-Sleep -Milliseconds 100
        }
    } while (-not $lock)
    try {
        $readArgs = @{ Path=$Path }
        if ($ExpectedOperation) { $readArgs.ExpectedOperation=$ExpectedOperation }
        if ($PSBoundParameters.ContainsKey('ExpectedDeviceId')) { $readArgs.ExpectedDeviceId=$ExpectedDeviceId }
        if ($PSBoundParameters.ContainsKey('ExpectedStepIds')) { $readArgs.ExpectedStepIds=$ExpectedStepIds }
        $j = Read-MBRecoveryJournal @readArgs
        $stepMatches = @($j.Steps | Where-Object { $_.Id -eq $StepId })
        if ($stepMatches.Count -ne 1) {
            throw "Recovery step '$StepId' is not uniquely defined in the journal."
        }
        $step = $stepMatches[0]
        if ($step.State -eq 'Completed') {
            if (-not (& $Verify)) {
                throw "Completed recovery step '$StepId' no longer satisfies its postcondition."
            }
            return
        }
        # A Running step may only be replayed when the caller's action is idempotent
        # and Verify reliably detects whether its external side effect already occurred.
        if (& $Verify) {
            $step.State = 'Completed'
            $step.LastError = $null
            $j.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-MBRecoveryJsonAtomic -Path $Path -Value $j
            return
        }
        $step.State = 'Running'
        $step.Attempts = [int]$step.Attempts + 1
        $step.LastError = $null
        $j.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Write-MBRecoveryJsonAtomic -Path $Path -Value $j
        try {
            & $Action
            if (-not (& $Verify)) {
                throw "Postcondition failed for recovery step '$StepId'."
            }
            $step.State = 'Completed'
            $step.LastError = $null
            $j.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-MBRecoveryJsonAtomic -Path $Path -Value $j
        } catch {
            $step.LastError = $_.Exception.Message
            $j.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            try { Write-MBRecoveryJsonAtomic -Path $Path -Value $j } catch { }
            throw
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

function Enter-MBRecoveryOperationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 0
    )
    # This lock is deliberately separate from the short journal-write lock.
    # The caller holds it across the ENTIRE install rollback or uninstall plan.
    $lockPath = "$Path.operation.lock"
    $directory = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0,$TimeoutSeconds))
    do {
        try {
            $stream = New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $metadata = (New-Object Text.UTF8Encoding($false)).GetBytes(("PID={0};UTC={1}" -f $PID,[DateTime]::UtcNow.ToString('o')))
            $stream.SetLength(0)
            $stream.Write($metadata,0,$metadata.Length)
            $stream.Flush($true)
            return $stream
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Another MicBridge install/recovery/uninstall operation is active; refusing to interleave registry, ACL, COM, or file changes.'
            }
            Start-Sleep -Milliseconds 150
        }
    } while ($true)
}

function Invoke-MBRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('InstallRollback','Uninstall')][string]$ExpectedOperation,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [Parameter(Mandatory)][string[]]$ExpectedStepIds,
        [Parameter(Mandatory)][hashtable]$Actions,
        [Parameter(Mandatory)][hashtable]$Verifiers,
        [int]$LockTimeoutSeconds = 0
    )
    if (-not $ExpectedStepIds -or @($ExpectedStepIds | Select-Object -Unique).Count -ne $ExpectedStepIds.Count) {
        throw 'Recovery plan requires a non-empty, unique, ordered step list.'
    }
    foreach ($id in $ExpectedStepIds) {
        if (-not $Actions.ContainsKey($id) -or $Actions[$id] -isnot [scriptblock] -or
            -not $Verifiers.ContainsKey($id) -or $Verifiers[$id] -isnot [scriptblock]) {
            throw "Recovery plan is incomplete: action and verifier are required for '$id'."
        }
    }
    $operationLock = Enter-MBRecoveryOperationLock -Path $Path -TimeoutSeconds $LockTimeoutSeconds
    $failures = @()
    try {
        $journal = Read-MBRecoveryJournal -Path $Path -ExpectedOperation $ExpectedOperation -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $ExpectedStepIds
        foreach ($id in $ExpectedStepIds) {
            try {
                Invoke-MBRecoveryStep -Path $Path -StepId $id -ExpectedOperation $ExpectedOperation -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $ExpectedStepIds -Action $Actions[$id] -Verify $Verifiers[$id]
            } catch {
                # A failed step is recorded and does not suppress independent later
                # restorations. The caller receives every failure after all steps run.
                $failures += [pscustomobject]@{ StepId=$id; Error=$_.Exception.Message }
            }
        }
    } finally {
        if ($operationLock) { $operationLock.Dispose() }
    }
    if ($failures.Count -gt 0) {
        $summary = ($failures | ForEach-Object { "$($_.StepId): $($_.Error)" }) -join ' | '
        throw "Recovery plan incomplete; completed independent steps were retained and failed steps remain retryable. $summary"
    }
    return Read-MBRecoveryJournal -Path $Path -ExpectedOperation $ExpectedOperation -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $ExpectedStepIds
}

function Protect-MBRecoveryDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($env:OS -ne 'Windows_NT') {
        throw 'Recovery directory ACL hardening is supported only on Windows.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRuleAll($_) }
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($sid in @($admins,$system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    $check = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $check.AreAccessRulesProtected -or $check.Owner -notmatch 'S-1-5-32-544|Administrators') {
        throw 'Recovery directory ACL verification failed; refusing to continue.'
    }
    return $check.Sddl
}

Export-ModuleMember -Function New-MBRecoveryJournal,Read-MBRecoveryJournal,Invoke-MBRecoveryStep,Enter-MBRecoveryOperationLock,Invoke-MBRecoveryPlan,Protect-MBRecoveryDirectory
