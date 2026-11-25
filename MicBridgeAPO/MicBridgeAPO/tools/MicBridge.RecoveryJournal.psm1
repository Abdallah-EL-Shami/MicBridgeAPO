Set-StrictMode -Version Latest

function Write-MBRecoveryJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temp = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $Path) {
            $backup = "$Path.previous"
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
            [IO.File]::Replace($temp,$Path,$backup,$true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        } else {
            [IO.File]::Move($temp,$Path)
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
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
    $journal = [pscustomobject]@{
        SchemaVersion=1
        TransactionId=[guid]::NewGuid().ToString('D')
        Operation=$Operation
        DeviceId=$DeviceId.ToString('D')
        CreatedUtc=[DateTime]::UtcNow.ToString('o')
        UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        Steps=$steps
    }
    Write-MBRecoveryJsonAtomic -Path $Path -Value $journal
    return $journal
}

function Read-MBRecoveryJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Recovery journal is missing: $Path" }
    try { $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Recovery journal is unreadable: $($_.Exception.Message)" }
    $parsedDeviceId = [guid]::Empty
    if ($j.SchemaVersion -ne 1 -or $j.Operation -notin @('InstallRollback','Uninstall') -or
        -not [guid]::TryParse([string]$j.DeviceId,[ref]$parsedDeviceId)) {
        throw 'Recovery journal schema or identity is invalid; refusing recovery.'
    }
    if (-not $j.Steps -or @($j.Steps | Where-Object { $_.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}
        throw 'Recovery journal contains invalid step data; refusing recovery.'
    }
    return $j
}

function Invoke-MBRecoveryStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Verify
    )
    $j = Read-MBRecoveryJournal -Path $Path
    $step = @($j.Steps | Where-Object { $_.Id -eq $StepId })
    if ($step.Count -ne 1) { throw "Recovery step '$StepId' is not uniquely defined in the journal." }
    $step = $step[0]
    if ($step.State -eq 'Completed') {
        if (-not (& $Verify)) { throw "Completed recovery step '$StepId' no longer satisfies its postcondition." }
        return
    }
    # A Running step is deliberately replayable. Callers must supply idempotent actions.
    if (& $Verify) {
        $step.State='Completed'
        $step.LastError=$null
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        Write-MBRecoveryJsonAtomic -Path $Path -Value $j
        return
    }
    $step.State='Running'
    $step.Attempts=[int]$step.Attempts + 1
    $step.LastError=$null
    $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    Write-MBRecoveryJsonAtomic -Path $Path -Value $j
    try {
        & $Action
        if (-not (& $Verify)) { throw "Postcondition failed for recovery step '$StepId'." }
        $step.State='Completed'
        $step.LastError=$null
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        Write-MBRecoveryJsonAtomic -Path $Path -Value $j
    } catch {
        $step.LastError=$_.Exception.Message
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        try { Write-MBRecoveryJsonAtomic -Path $Path -Value $j } catch { }
        throw
    }
}

Export-ModuleMember -Function New-MBRecoveryJournal,Read-MBRecoveryJournal,Invoke-MBRecoveryStep -or $_.State -notin @('Pending','Running','Completed') }).Count -gt 0 -or
        @($j.Steps | Select-Object -ExpandProperty Id -Unique).Count -ne @($j.Steps).Count) {
        throw 'Recovery journal contains invalid step data; refusing recovery.'
    }
    return $j
}

function Invoke-MBRecoveryStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Verify
    )
    $j = Read-MBRecoveryJournal -Path $Path
    $step = @($j.Steps | Where-Object { $_.Id -eq $StepId })
    if ($step.Count -ne 1) { throw "Recovery step '$StepId' is not uniquely defined in the journal." }
    $step = $step[0]
    if ($step.State -eq 'Completed') {
        if (-not (& $Verify)) { throw "Completed recovery step '$StepId' no longer satisfies its postcondition." }
        return
    }
    # A Running step is deliberately replayable. Callers must supply idempotent actions.
    if (& $Verify) {
        $step.State='Completed'
        $step.LastError=$null
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        Write-MBRecoveryJsonAtomic -Path $Path -Value $j
        return
    }
    $step.State='Running'
    $step.Attempts=[int]$step.Attempts + 1
    $step.LastError=$null
    $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    Write-MBRecoveryJsonAtomic -Path $Path -Value $j
    try {
        & $Action
        if (-not (& $Verify)) { throw "Postcondition failed for recovery step '$StepId'." }
        $step.State='Completed'
        $step.LastError=$null
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        Write-MBRecoveryJsonAtomic -Path $Path -Value $j
    } catch {
        $step.LastError=$_.Exception.Message
        $j.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
        try { Write-MBRecoveryJsonAtomic -Path $Path -Value $j } catch { }
        throw
    }
}

Export-ModuleMember -Function New-MBRecoveryJournal,Read-MBRecoveryJournal,Invoke-MBRecoveryStep