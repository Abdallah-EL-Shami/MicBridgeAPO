[CmdletBinding()]
param(
    [string]$DeviceName = 'AT2040USB',
    [string]$EndpointId = ''
)

$ErrorActionPreference = 'Stop'

$clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$capSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
$capRoot = "HKLM:\$capSub"
$fxSubKey = '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D}'
$epEffectName = "$fxSubKey,7"       # PKEY_FX_EndpointEffectClsid
$compositeEffectName = "$fxSubKey,15" # PKEY_CompositeFX_EndpointEffectClsid
$fxAssociationName = "$fxSubKey,0"  # PKEY_FX_Association
$disableSysFxName = '{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E},5'

function Read-LmValue([string]$SubKey, [string]$Name) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey)
    if (-not $key) { return '<key missing>' }
    try {
        $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '<value absent>' }
        return $value
    } finally {
        $key.Close()
    }
}

Write-Host '=== Windows / Audio Engine ==='
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("OS: {0} | Version: {1} | Build: {2}.{3}" -f $os.Caption, $os.Version, $cv.CurrentBuildNumber, $cv.UBR)
Write-Host ("DisableProtectedAudioDG: {0}" -f (Read-LmValue 'SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' 'DisableProtectedAudioDG'))

if ([string]::IsNullOrWhiteSpace($EndpointId)) {
    $matches = @()
    foreach ($key in Get-ChildItem -LiteralPath $capRoot) {
        $state = (Get-ItemProperty -LiteralPath $key.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState
        if ($state -ne 1) { continue }
        $props = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'Properties') -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $hit = $false
        foreach ($property in $props.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            if ($property.Value -is [string] -and $property.Value -like "*$DeviceName*") { $hit = $true; break }
        }
        if ($hit) { $matches += $key.PSChildName }
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one active Capture endpoint matching '$DeviceName'; found $($matches.Count). Re-run with -EndpointId '<capture endpoint GUID>'."
    }
    $EndpointId = $matches[0]
}

$devSub = "$capSub\$EndpointId"
$fxSub = "$devSub\FxProperties"
Write-Host ''
Write-Host '=== Selected Capture endpoint ==='
Write-Host ("EndpointId: {0}" -f $EndpointId)
Write-Host ("DeviceState: {0}" -f (Read-LmValue $devSub 'DeviceState'))
$compositeEffects = Read-LmValue $fxSub $compositeEffectName
$compositeText = if ($compositeEffects -is [array]) { $compositeEffects -join '; ' } else { [string]$compositeEffects }
$fxKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fxSub)
$compositeKind = if ($fxKey -and ($fxKey.GetValueNames() -contains $compositeEffectName)) { [string]$fxKey.GetValueKind($compositeEffectName) } else { '<absent>' }
if ($fxKey) { $fxKey.Close() }
Write-Host ("PKEY_FX_EndpointEffectClsid ({0}): {1}" -f $epEffectName, (Read-LmValue $fxSub $epEffectName))
Write-Host ("PKEY_CompositeFX_EndpointEffectClsid ({0}) [{1}]: {2}" -f $compositeEffectName, $compositeKind, $compositeText)
Write-Host ("PKEY_FX_Association ({0}): {1}" -f $fxAssociationName, (Read-LmValue $fxSub $fxAssociationName))
Write-Host ("PKEY_AudioEndpoint_Disable_SysFx ({0}): {1}" -f $disableSysFxName, (Read-LmValue $fxSub $disableSysFxName))

Write-Host ''
Write-Host '=== APO COM / AudioEngine registration ==='
$clsidSub = "SOFTWARE\Classes\CLSID\$clsid"
$inprocSub = "$clsidSub\InprocServer32"
$apoSub = "SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid"
$dllPath = Read-LmValue $inprocSub ''
Write-Host ("InprocServer32: {0}" -f $dllPath)
Write-Host ("ThreadingModel: {0}" -f (Read-LmValue $inprocSub 'ThreadingModel'))
Write-Host ("AudioEngine FriendlyName: {0}" -f (Read-LmValue $apoSub 'FriendlyName'))
Write-Host ("AudioEngine Flags: {0}" -f (Read-LmValue $apoSub 'Flags'))
Write-Host ("AudioEngine APOInterface0: {0}" -f (Read-LmValue $apoSub 'APOInterface0'))
if ($dllPath -and $dllPath -ne '<value absent>' -and (Test-Path -LiteralPath $dllPath)) {
    $item = Get-Item -LiteralPath $dllPath
    Write-Host ("DLL exists: True | Length: {0} | LastWrite: {1}" -f $item.Length, $item.LastWriteTime)
    Write-Host ("DLL SHA256: {0}" -f (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash)
} else {
    Write-Host 'DLL exists: False'
}

Write-Host ''
Write-Host '=== audiodg.exe module inspection ==='
$processes = @(Get-Process -Name audiodg -ErrorAction SilentlyContinue)
if ($processes.Count -eq 0) {
    Write-Host 'No audiodg.exe process is currently running.'
} else {
    foreach ($process in $processes) {
        try {
            $loaded = @($process.Modules | Where-Object { $_.ModuleName -ieq 'MicBridgeAPO.dll' })
            Write-Host ("PID {0}: MicBridgeAPO.dll loaded = {1}" -f $process.Id, ($loaded.Count -gt 0))
            foreach ($module in $loaded) { Write-Host ("  Path: {0}" -f $module.FileName) }
        } catch {
            Write-Host ("PID {0}: module list unavailable ({1})" -f $process.Id, $_.Exception.Message)
        }
    }
}

Write-Host ''
Write-Host 'Read-only diagnostic completed. No registry, service, device, or file settings were changed.'
