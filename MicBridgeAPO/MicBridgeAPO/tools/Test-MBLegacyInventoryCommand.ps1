$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot 'Inspect-MBLegacyInstallation.ps1'
$modulePath = Join-Path $PSScriptRoot 'MicBridge.LegacyInstallAudit.psm1'
$trustDocPath = Join-Path $repoRoot 'INSTALL-TRUST-AR.md'
$buildWorkflowPath = Join-Path $repoRoot '..\..\.github\workflows\build.yml'
$releaseWorkflowPath = Join-Path $repoRoot '..\..\.github\workflows\signed-release.yml'
foreach($path in @($scriptPath,$modulePath,$trustDocPath,$buildWorkflowPath,$releaseWorkflowPath)) {
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required inventory component is missing: $path" }
}
$tokens=$null; $errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0) { throw ("FAIL: inventory script parser errors: "+(@($errors|ForEach-Object Message)-join '; ')) }
$source=[IO.File]::ReadAllText($scriptPath)
$module=[IO.File]::ReadAllText($modulePath)
$trustDoc=[IO.File]::ReadAllText($trustDocPath)
$buildWorkflow=[IO.File]::ReadAllText($buildWorkflowPath)
$releaseWorkflow=[IO.File]::ReadAllText($releaseWorkflowPath)
foreach($workflow in @($buildWorkflow,$releaseWorkflow)) {
    if(-not $workflow.Contains("Inspect-MBLegacyInstallation.ps1")) { throw 'FAIL: inventory command is not staged in both unsigned CI and signed release packages.' }
}
$entrySignature=$source.IndexOf('Get-AuthenticodeSignature -FilePath $PSCommandPath',[StringComparison]::Ordinal)
$moduleSignature=$source.IndexOf('Get-AuthenticodeSignature -FilePath $modulePath',[StringComparison]::Ordinal)
$import=$source.IndexOf('Import-Module -Name $modulePath',[StringComparison]::Ordinal)
$audit=$source.IndexOf('Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
$json=$source.IndexOf('ConvertTo-Json -Depth 8',[StringComparison]::Ordinal)
if($entrySignature -lt 0 -or $moduleSignature -le $entrySignature -or $import -le $moduleSignature -or $audit -le $import -or $json -le $audit) {
    throw 'FAIL: entrypoint and module signatures must be pinned and verified before import, audit and report.'
}
if($source.Contains('PublisherSignatureVerified')) { throw 'FAIL: inventory command must not rely on a caller-supplied trust bypass switch.' }
foreach($required in @('29BAC42BFC53F2586559A9B95D1FEEB658E8891A','CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369','CleanupAllowed = $false','OwnershipProven = $false','OriginalWindowsBaselineProven = $false','-ExpectedDeviceId $ExpectedDeviceId')) {
    if(-not $source.Contains($required)) { throw "FAIL: inventory trust/report contract missing: $required" }
}
if($source -match '(?i)\b(Remove-Item|Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|reg\.exe\s+(delete|add)|Start-Process|Checkpoint-Computer)\b') {
    throw 'FAIL: read-only inventory command contains a mutation or elevation operation.'
}
if($module -notmatch 'IsReadOnly=\$true' -or $module -notmatch 'CleanupAllowed=\$false' -or $module -notmatch 'OwnershipProven=\$false') {
    throw 'FAIL: underlying audit module does not preserve read-only/no-ownership invariants.'
}
$documentedCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Inspect-MBLegacyInstallation.ps1 | Tee-Object -FilePath .\legacy-inventory.json'
if(-not $trustDoc.Contains($documentedCommand) -or $trustDoc.Contains('Inspect-MBLegacyInstallation.ps1 -PublisherSignatureVerified')) {
    throw 'FAIL: documented inventory command must invoke the self-verifying read-only entrypoint without a removed bypass switch and write legacy-inventory.json.'
}
Write-Host 'PASS: legacy inventory is publisher-pinned, verifies entrypoint and module signatures before import, read-only, and emits a structured report.'
Write-Host 'PASS: documentation invokes the exact self-verifying inventory command.'
