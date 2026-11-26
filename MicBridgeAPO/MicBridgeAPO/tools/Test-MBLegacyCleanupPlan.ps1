$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyCleanupPlan.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeCleanupPlan-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $root 'ProgramFiles\MicBridgeAPO'
New-Item -ItemType Directory -Force -Path $install | Out-Null
try {
    $dll = Join-Path $install 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll, [byte[]](1,2,3,4))
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash

    $audit = [pscustomobject]@{
        IsReadOnly = $true
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Outcome = 'ReviewRequired'
        Findings = @(
            [pscustomobject]@{Kind='Registration';Name='COM CLSID';Classification='MicBridgeCandidate';Path='HKCU:\Software\Test\CLSID';ServerPath=$dll;Sha256=$hash},
            [pscustomobject]@{Kind='File';Name='MicBridgeAPO.dll';Classification='MicBridgeBinaryCandidate';Path=$dll;ServerPath=$null;Sha256=$hash},
            [pscustomobject]@{Kind='File';Name='user.ini';Classification='PreserveDataFile';Path=(Join-Path $root 'user.ini');ServerPath=$null;Sha256=$null},
            [pscustomobject]@{Kind='File';Name='foreign.dll';Classification='UnclassifiedFile';Path=(Join-Path $root 'foreign.dll');ServerPath=$null;Sha256=$null}
        )
    }
    $before = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $plan = New-MBLegacyCleanupPlan -Audit $audit -InstallDirectory $install

    if (-not $plan.IsReadOnly -or $plan.CleanupExecutionAllowed -or $plan.InstallAllowed) {
        throw 'FAIL: planner enabled mutation or installation.'
    }
    if ($plan.CanProceedToCleanupReview) { throw 'FAIL: ambiguous audit did not block cleanup review.' }
    if (-not ($plan.Items | Where-Object { $_.Name -eq 'foreign.dll' -and $_.ProposedAction -eq 'Preserve' })) {
        throw 'FAIL: unknown file was not preserved.'
    }
    if (-not ($plan.Items | Where-Object { $_.Name -eq 'user.ini' -and $_.ProposedAction -eq 'Preserve' })) {
        throw 'FAIL: data file was not preserved.'
    }
    if (-not ($plan.Items | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' -and $_.ProposedAction -eq 'CandidateForReviewedRemoval' })) {
        throw 'FAIL: verified product DLL was not limited to reviewed-removal candidate.'
    }
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $before) {
        throw 'FAIL: planning modified a file.'
    }

    # A stale or forged inventory hash must never produce a review candidate.
    $tamperedAudit = [pscustomobject]@{
        IsReadOnly = $true
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Outcome = 'InventoryOnly'
        Findings = @([pscustomobject]@{
            Kind='File'; Name='MicBridgeAPO.dll'; Classification='MicBridgeBinaryCandidate'
            Path=$dll; ServerPath=$null; Sha256=('0' * 64)
        })
    }
    $tamperedPlan = New-MBLegacyCleanupPlan -Audit $tamperedAudit -InstallDirectory $install
    if (-not ($tamperedPlan.Items | Where-Object { $_.Name -eq 'MicBridgeAPO.dll' -and $_.ProposedAction -eq 'Preserve' })) {
        throw 'FAIL: DLL with a stale/mismatched hash was not preserved.'
    }
    if ($tamperedPlan.CanProceedToCleanupReview) {
        throw 'FAIL: mismatched DLL hash did not block cleanup review.'
    }
    if ($tamperedPlan.CleanupExecutionAllowed -or $tamperedPlan.InstallAllowed) {
        throw 'FAIL: tampered inventory enabled cleanup or installation.'
    }

    # A COM registration must also be rejected when its server DLL hash is stale.
    $tamperedRegistrationAudit = [pscustomobject]@{
        IsReadOnly = $true
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Outcome = 'InventoryOnly'
        Findings = @([pscustomobject]@{
            Kind='Registration'; Name='COM CLSID'; Classification='MicBridgeCandidate'
            Path='HKCU:\Software\Test\CLSID'; ServerPath=$dll; Sha256=('0' * 64)
        })
    }
    $tamperedRegistrationPlan = New-MBLegacyCleanupPlan -Audit $tamperedRegistrationAudit -InstallDirectory $install
    if (-not ($tamperedRegistrationPlan.Items | Where-Object { $_.Name -eq 'COM CLSID' -and $_.ProposedAction -eq 'Preserve' })) {
        throw 'FAIL: COM registration with a stale server hash was not preserved.'
    }
    if ($tamperedRegistrationPlan.CanProceedToCleanupReview) {
        throw 'FAIL: stale COM server hash did not block cleanup review.'
    }
    if ($tamperedRegistrationPlan.CleanupExecutionAllowed -or $tamperedRegistrationPlan.InstallAllowed) {
        throw 'FAIL: stale COM server hash enabled cleanup or installation.'
    }

    $cleanAudit = [pscustomobject]@{
        IsReadOnly = $true
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Outcome = 'InventoryOnly'
        Findings = @([pscustomobject]@{Kind='Registration';Name='COM CLSID';Classification='Absent';Path='HKCU:\Software\Test\CLSID';ServerPath=$null;Sha256=$null})
    }
    $cleanPlan = New-MBLegacyCleanupPlan -Audit $cleanAudit -InstallDirectory $install
    if (-not $cleanPlan.CanProceedToCleanupReview -or $cleanPlan.InstallAllowed -or $cleanPlan.CleanupExecutionAllowed) {
        throw 'FAIL: clean read-only plan has incorrect gate semantics.'
    }

    Write-Host 'PASS: cleanup planner is read-only, preserves unknown/data items, and never authorizes execution or install.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
