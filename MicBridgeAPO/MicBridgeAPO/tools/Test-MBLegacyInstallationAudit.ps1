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

    $clsidKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$registrySub\CLSID\$clsid")
    $inproc = $clsidKey.CreateSubKey('InprocServer32')
    try { $inproc.SetValue('', $dll, [Microsoft.Win32.RegistryValueKind]::String) } finally { $inproc.Dispose() }
    $apoKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$registrySub\AudioEngine\AudioProcessingObjects\$clsid")
    $apoKey.SetValue('FriendlyName','MicBridge test',[Microsoft.Win32.RegistryValueKind]::String)
    $clsidKey.Dispose(); $clsidKey=$null
    $apoKey.Dispose(); $apoKey=$null

    $beforeDll = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $beforeLog = (Get-FileHash -LiteralPath (Join-Path $data 'Install.log') -Algorithm SHA256).Hash
    $beforeClsid = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\CLSID\$clsid")
    $beforeApo = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\AudioEngine\AudioProcessingObjects\$clsid")
    try {
        if (-not $beforeClsid -or -not $beforeApo) { throw 'FAIL: HKCU audit fixture was not created' }
        $beforeFriendly = [string]$beforeApo.GetValue('FriendlyName')
        $beforeServer = [string]$beforeClsid.OpenSubKey('InprocServer32').GetValue('')
    } finally { if ($beforeClsid) {$beforeClsid.Dispose()}; if ($beforeApo) {$beforeApo.Dispose()} }

    $result = Test-MBLegacyInstallationState -InstallDirectory $install -DataDirectory $data -RegistryRoot ('HKCU:\' + $registrySub + '\')
    if (-not $result.IsReadOnly -or $result.CleanupAllowed -or $result.OriginalWindowsBaselineProven) {
        throw 'FAIL: audit claimed mutation permission or a proven original Windows baseline'
    }
    if ($result.Outcome -eq 'NoLegacyResidueDetected') { throw 'FAIL: product-owned test candidates were not inventoried' }
    if (-not ($result.Findings | Where-Object { $_.Classification -eq 'MicBridgeCandidate' })) {
        throw 'FAIL: MicBridge-owned CLSID candidate was not identified'
    }
    if (-not ($result.Findings | Where-Object { $_.Classification -eq 'MicBridgeBinaryCandidate' })) {
        throw 'FAIL: MicBridge DLL candidate was not inventoried'
    }

    $afterDll = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $afterLog = (Get-FileHash -LiteralPath (Join-Path $data 'Install.log') -Algorithm SHA256).Hash
    $afterClsid = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\CLSID\$clsid")
    $afterApo = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$registrySub\AudioEngine\AudioProcessingObjects\$clsid")
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
