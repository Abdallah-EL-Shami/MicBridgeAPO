$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot 'Inspect-MBLegacyInstallation.ps1'
$modulePath = Join-Path $PSScriptRoot 'MicBridge.LegacyInstallAudit.psm1'
foreach($path in @($scriptPath,$modulePath)) {
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required inventory component is missing: $path" }
}
$tokens=$null; $errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0) { throw ("FAIL: inventory script parser errors: "+(@($errors|ForEach-Object Message)-join '; ')) }
$source=[IO.File]::ReadAllText($scriptPath)
$module=[IO.File]::ReadAllText($modulePath)
$trust=$source.IndexOf('if (-not $PublisherSignatureVerified)',[StringComparison]::Ordinal)
$signature=$source.IndexOf('Get-AuthenticodeSignature -FilePath $modulePath',[StringComparison]::Ordinal)
$import=$source.IndexOf('Import-Module -Name $modulePath',[StringComparison]::Ordinal)
$audit=$source.IndexOf('Test-MBLegacyInstallationState',[StringComparison]::Ordinal)
$json=$source.IndexOf('ConvertTo-Json -Depth 8',[StringComparison]::Ordinal)
if($trust -lt 0 -or $signature -le $trust -or $import -le $signature -or $audit -le $import -or $json -le $audit) {
    throw 'FAIL: manual trust, pinned module signature, import, read-only audit and report ordering is invalid.'
}
foreach($required in @('29BAC42BFC53F2586559A9B95D1FEEB658E8891A','CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369','CleanupAllowed = $false','OwnershipProven = $false','OriginalWindowsBaselineProven = $false','-ExpectedDeviceId $ExpectedDeviceId')) {
    if(-not $source.Contains($required)) { throw "FAIL: inventory trust/report contract missing: $required" }
}
if($source -match '(?i)\b(Remove-Item|Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|reg\.exe\s+(delete|add)|Start-Process|Checkpoint-Computer)\b') {
    throw 'FAIL: read-only inventory command contains a mutation or elevation operation.'
}
if($module -notmatch 'IsReadOnly=\$true' -or $module -notmatch 'CleanupAllowed=\$false' -or $module -notmatch 'OwnershipProven=\$false') {
    throw 'FAIL: underlying audit module does not preserve read-only/no-ownership invariants.'
}
Write-Host 'PASS: legacy inventory is signed-publisher gated, verifies module signature before import, read-only, and emits a structured report.'
