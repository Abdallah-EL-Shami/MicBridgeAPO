$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
$uninstaller = Get-Content -LiteralPath (Join-Path $root 'uninstall.ps1') -Raw

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

Assert-Contains $installer '\$fxAssociationValue\s*=\s*''\{d04e05a6-594b-4fb6-a80d-01af5eed7d1d\},0''' 'Installer declares PKEY_FX_Association'
Assert-Contains $installer '\$ksNodeTypeAny\s*=\s*''\{00000000-0000-0000-0000-000000000000\}''' 'Installer uses the documented KSNODETYPE_ANY GUID'
Assert-Contains $installer 'PrevFxAssociation\s*=' 'Fresh backup records the previous association value'
Assert-Contains $installer 'PSObject\.Properties\.Name\s+-notcontains\s+''PrevFxAssociation''' 'Installer migrates legacy backup.json files'
Assert-Contains $installer 'Name\s+\$fxAssociationValue\s+-Value\s+\$ksNodeTypeAny' 'Installer writes the association property'
Assert-Contains $uninstaller 'PSObject\.Properties\.Name\s+-contains\s+''PrevFxAssociation''' 'Uninstaller distinguishes legacy backups'
Assert-Contains $uninstaller 'Name\s+\$fxAssociationValue\s+-Value\s+\$b\.PrevFxAssociation' 'Uninstaller restores a prior association value'
Assert-Contains $uninstaller 'Remove-ItemProperty\s+-LiteralPath\s+\$fxPath\s+-Name\s+\$fxAssociationValue' 'Uninstaller removes only its association value when no prior value existed'
Assert-Contains $uninstaller 'GetValueNames\(\)\.Count\s+-eq\s+0' 'Uninstaller checks that a created FxProperties key is empty before deleting it'
Assert-NotContains $uninstaller 'Remove-Item\s+-LiteralPath\s+\$fxPath\s+-Recurse' 'Uninstaller never recursively deletes FxProperties and unrelated driver values'

Assert-Contains $installer 'DllSource\s+`"\$DllSource`"' 'Elevated installer relaunch preserves the selected DLL source path'
Assert-Contains $installer 'Refuse to reuse a backup created for a different capture endpoint' 'Installer documents the backup/device identity guard'
Assert-Contains $installer '\[string\]\$existingBackup\.DeviceId\s+-ne\s+\[string\]\$dev\.Id' 'Installer refuses a backup belonging to another endpoint'
Assert-Contains $installer 'قد تكون بعض خطوات التثبيت قد نُفذت' 'Installer warns that a failed run may have made partial changes'
Assert-NotContains $installer 'شغّل uninstall\.bat للتراجع' 'Installer does not recommend broad uninstall as automatic partial rollback'


Assert-Contains $installer 'function Write-InstallLog' 'Installer defines diagnostic logging'
Assert-Contains $installer 'Installation failed:' 'Installer logs detailed failure exceptions'
Assert-Contains $installer 'dll-backups' 'Installer preserves the previous DLL before replacement'
Assert-Contains $installer 'Previous DLL restored' 'Installer attempts DLL restoration after failure'
Assert-Contains $installer 'ولا توجد بيانات كافية لإثبات قيمتها الأصلية' 'Installer refuses to guess legacy backup association values'
Assert-NotContains $installer 'existingAssociation = (Get-ItemProperty' 'Installer does not infer historical association from current registry state'

Write-Host 'All installer registration static checks passed.'
