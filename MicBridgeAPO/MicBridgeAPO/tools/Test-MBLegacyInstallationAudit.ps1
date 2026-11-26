$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyInstallAudit.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeLegacyAudit-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $root 'ProgramFiles\MicBridgeAPO'
$data = Join-Path $root 'ProgramData\MicBridgeAPO'
$registrySub = 'Software\MicBridgeLegacyAudit-' + [guid]::NewGuid().ToString('N')
$clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$clsidKey = $null
$apoKey = $null
New-Item -ItemType Directory -Force -Path $install,$data | Out-Null
try {
    $dll = Join-Path $install 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll,[byte[]](1,2,3,4,5))
    [IO.File]::WriteAllText((Join-Path $data 'Install.log'),'legacy test evidence')

    $clsidKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$registrySub\SOFTWARE\Classes\CLSID\$clsid")
    $inproc = $clsidKey.CreateSubKey('InprocServer32')
    try { $inproc.SetValue('', $dll, [Microsoft.Win32.RegistryValueKind]::String) } finally { $inproc.Dispose() }
    $apoKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$registrySub\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid")
    $apoKey.SetValue('FriendlyName','MicBridge test',[Microsoft.Win32.RegistryValueKind]::String)
    $clsidKey.Dispose(); $clsidKey=$null
    $apoKey.Dispose(); $apoKey=$null

    $beforeDll = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $beforeLog = (Get-FileHash -LiteralPath (Join-Path $data 'Install.log') -Algorithm SHA256).Hash
    $beforeClsid = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\SOFTWARE\Classes\CLSID\$clsid")
    $beforeApo = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid")
    try {
        if (-not $beforeClsid -or -not $beforeApo) { throw 'FAIL: HKCU audit fixture was not created' }
        $beforeFriendly = [string]$beforeApo.GetValue('FriendlyName')
        $beforeServer = [string]$beforeClsid.OpenSubKey('InprocServer32').GetValue('')
    } finally { if ($beforeClsid) {$beforeClsid.Dispose()}; if ($beforeApo) {$beforeApo.Dispose()} }

    $expectedDevice=[guid]::NewGuid()
    $registryRoot='HKCU:\'+$registrySub
    $missingBaseline=Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot $registryRoot -ExpectedDeviceId $expectedDevice
    if($missingBaseline.Outcome -ne 'ReviewRequired' -or $missingBaseline.BaselineAssessment -ne 'Missing') {
        throw 'FAIL: an existing MicBridge installation without a permanent backup was not marked for review'
    }

    $comBackupDir=Join-Path $data 'com-registration-backup'
    New-Item -ItemType Directory -Force -Path $comBackupDir | Out-Null
    $clsidExport=Join-Path $comBackupDir 'previous-clsid.reg'
    $apoExport=Join-Path $comBackupDir 'previous-audioengine-apo.reg'
    $regExe=Join-Path $env:SystemRoot 'System32\reg.exe'
    & $regExe export "HKCU\$registrySub\SOFTWARE\Classes\CLSID\$clsid" $clsidExport /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export isolated permanent CLSID backup' }
    & $regExe export "HKCU\$registrySub\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" $apoExport /y | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'FAIL: could not export isolated permanent APO backup' }
    $permanentBackup=[pscustomobject]@{
        ComRegistrationSnapshotVersion=1
        DeviceId=$expectedDevice.ToString('D')
        PrevClsidRegistrationExists=$true
        PrevApoRegistrationExists=$true
        PrevClsidRegistrationFile=$clsidExport
        PrevApoRegistrationFile=$apoExport
        PrevClsidRegistrationSha256=(Get-FileHash $clsidExport -Algorithm SHA256).Hash
        PrevApoRegistrationSha256=(Get-FileHash $apoExport -Algorithm SHA256).Hash
    }
    $backupJson=Join-Path $data 'backup.json'
    [IO.File]::WriteAllText($backupJson,(ConvertTo-Json -InputObject $permanentBackup -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $backupHashBefore=(Get-FileHash $backupJson -Algorithm SHA256).Hash
    $result = Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot $registryRoot -ExpectedDeviceId $expectedDevice
    if($result.BaselineAssessment -ne 'StructurallyValidCandidate' -or $result.Outcome -ne 'InventoryOnly') {
        throw 'FAIL: structurally valid permanent backup candidate was not distinguished from an unproven Windows baseline'
    }
    if((Get-FileHash $backupJson -Algorithm SHA256).Hash -ne $backupHashBefore) { throw 'FAIL: read-only audit modified permanent backup.json' }
    if (-not $result.IsReadOnly -or $result.CleanupAllowed -or $result.OriginalWindowsBaselineProven) {
        throw 'FAIL: audit claimed mutation permission or a proven original Windows baseline'
    }
    if ($result.Outcome -eq 'NoLegacyResidueDetected') { throw 'FAIL: product-owned test candidates were not inventoried' }

    # Tampering or endpoint mismatch invalidates the baseline candidate without changing the live state.
    [IO.File]::AppendAllText($clsidExport,'tampered')
    $tampered=Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot $registryRoot -ExpectedDeviceId $expectedDevice
    if($tampered.Outcome -ne 'ReviewRequired' -or $tampered.BaselineAssessment -ne 'InvalidOrInsufficient') { throw 'FAIL: tampered permanent COM backup was accepted' }
    [IO.File]::WriteAllText($backupJson,(ConvertTo-Json -InputObject ($permanentBackup | Select-Object * ) -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $permanentBackup.DeviceId=[guid]::NewGuid().ToString('D')
    [IO.File]::WriteAllText($backupJson,(ConvertTo-Json -InputObject $permanentBackup -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $mismatch=Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot $registryRoot -ExpectedDeviceId $expectedDevice
    if($mismatch.Outcome -ne 'ReviewRequired') { throw 'FAIL: mismatched endpoint backup was accepted' }
    [IO.File]::WriteAllText($backupJson,(ConvertTo-Json -InputObject $permanentBackup -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $permanentBackup.DeviceId=$expectedDevice.ToString('D')
    [IO.File]::WriteAllText($backupJson,(ConvertTo-Json -InputObject $permanentBackup -Depth 8),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'foreign.dll'),'unknown legacy file')
    $unknownFile=Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot $registryRoot -ExpectedDeviceId $expectedDevice
    if($unknownFile.Outcome -ne 'ReviewRequired') { throw 'FAIL: unknown file in install directory was not preserved for review' }
    if (-not ($result.Findings | Where-Object { $_.Classification -eq 'MicBridgeCandidate' })) {
        throw 'FAIL: MicBridge-owned CLSID candidate was not identified'
    }
    if (-not ($result.Findings | Where-Object { $_.Classification -eq 'MicBridgeBinaryCandidate' })) {
        throw 'FAIL: MicBridge DLL candidate was not inventoried'
    }

    $afterDll = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $afterLog = (Get-FileHash -LiteralPath (Join-Path $data 'Install.log') -Algorithm SHA256).Hash
    $afterClsid = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\SOFTWARE\Classes\CLSID\$clsid")
    $afterApo = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid")
    try {
        if (-not $afterClsid -or -not $afterApo) { throw 'FAIL: audit removed a registry key' }
        $afterFriendly = [string]$afterApo.GetValue('FriendlyName')
        $afterServer = [string]$afterClsid.OpenSubKey('InprocServer32').GetValue('')
    } finally { if ($afterClsid) {$afterClsid.Dispose()}; if ($afterApo) {$afterApo.Dispose()} }
    if ($beforeDll -ne $afterDll -or $beforeLog -ne $afterLog -or $beforeFriendly -ne $afterFriendly -or $beforeServer -ne $afterServer) {
        throw 'FAIL: read-only audit changed Registry or file state'
    }

    Write-Host 'PASS: legacy audit inventories MicBridge candidates, makes no cleanup/baseline claim, and leaves HKCU/files unchanged'
} finally {
    if ($clsidKey) { $clsidKey.Dispose() }
    if ($apoKey) { $apoKey.Dispose() }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registrySub,$false)
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
