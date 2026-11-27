$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uninstaller = Join-Path $repoRoot 'uninstall.ps1'
if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw "Uninstaller source missing: $uninstaller" }

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($uninstaller,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw ("FAIL: uninstall.ps1 has PowerShell parse errors: " + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}

$source = [IO.File]::ReadAllText($uninstaller)
$auditCall = $source.IndexOf('$legacyAudit = Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
$gate = $source.IndexOf('if ($legacyAudit.Outcome -eq ''ReviewRequired'' -or',$auditCall,[StringComparison]::Ordinal)
$journal = $source.IndexOf('New-MBRecoveryJournal -Path $uninstallJournal',$gate,[StringComparison]::Ordinal)
$firstRegistryMutation = $source.IndexOf('Invoke-MBRecoveryStep -Path $uninstallJournal -StepId ''RestoreEndpointValues''',$gate,[StringComparison]::Ordinal)
if ($auditCall -lt 0 -or $gate -le $auditCall -or $journal -le $gate -or $firstRegistryMutation -le $gate) {
    throw 'FAIL: uninstaller ownership gate is missing or is not before recovery journal/mutation work.'
}
$gateEnd = $source.IndexOf('}', $gate, [StringComparison]::Ordinal)
$gateText = $source.Substring($gate,[Math]::Max(0,$journal-$gate))
foreach ($required in @('$legacyAudit.OwnershipProven -ne $true','$legacyAudit.OwnershipEvidenceStatus -ne ''Proven''')) {
    if (-not $gateText.Contains($required)) { throw "FAIL: uninstaller does not require independent ownership proof: $required" }
}
if (-not $gateText.Contains('No Registry, COM, ACL, or file changes were made.')) {
    throw 'FAIL: ownership refusal does not guarantee a pre-mutation stop message.'
}
if (-not $source.Contains('Remove-Item -LiteralPath $apoRegistrationPath') -or -not $source.Contains('Remove-Item -LiteralPath $comRegistrationPath')) {
    throw 'FAIL: expected COM cleanup actions changed; review the uninstaller contract test.'
}

Write-Host 'PASS: uninstaller parses and refuses to proceed before journal or system mutation unless independent ownership evidence is explicitly Proven.'
