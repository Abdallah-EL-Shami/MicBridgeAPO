# Read-only target-machine integration probe for MicBridgeAPO.
[CmdletBinding()]
param(
    [string]$EndpointId = '{cf9ccd95-754b-4c27-a433-54265883928a}',
    [ValidateRange(15,300)][int]$DurationSeconds = 60
)
$ErrorActionPreference = 'Stop'
$clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$dataDir = Join-Path $env:ProgramData 'MicBridgeAPO'
$logPath = Join-Path $dataDir 'MicBridge.log'
$outPath = Join-Path $dataDir ("RuntimeTest-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$capSub = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$EndpointId"
$fxSub = "$capSub\FxProperties"

function Read-RegValue([string]$sub, [string]$name) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub)
    if (-not $key) { return '<key missing>' }
    try {
        if ($key.GetValueNames() -notcontains $name) { return '<value absent>' }
        $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($value -is [array]) { return ($value -join '; ') }
        return [string]$value
    } finally { $key.Close() }
}
function Get-ApoModules {
    $found = @()
    foreach ($p in @(Get-Process -Name audiodg -ErrorAction SilentlyContinue)) {
        try {
            foreach ($m in $p.Modules) {
                if ($m.ModuleName -ieq 'MicBridgeAPO.dll') {
                    $found += [pscustomobject]@{ Pid=$p.Id; Path=$m.FileName }
                }
            }
        } catch {}
    }
    return $found
}
function Write-Report([string]$Path, [string[]]$Lines) {
    $Lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("MicBridgeAPO read-only runtime probe")
$lines.Add("Started: $(Get-Date -Format o)")
$os = Get-CimInstance Win32_OperatingSystem
$lines.Add("OS: $($os.Caption) $($os.Version)")
$lines.Add("EndpointId: $EndpointId")
$lines.Add("DeviceState: $(Read-RegValue $capSub 'DeviceState')")
$lines.Add("Legacy EFX CLSID: $(Read-RegValue $fxSub '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},7')")
$lines.Add("Composite EFX CLSIDs: $(Read-RegValue $fxSub '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},15')")
$lines.Add("FX Association: $(Read-RegValue $fxSub '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},0')")
$lines.Add("COM DLL: $(Read-RegValue "SOFTWARE\Classes\CLSID\$clsid\InprocServer32" '')")
$lines.Add("AudioEngine FriendlyName: $(Read-RegValue "SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" 'FriendlyName')")
$lines.Add("Initial audiodg modules: $(@(Get-ApoModules).Count)")
$before = if (Test-Path -LiteralPath $logPath) { (Get-Content -LiteralPath $logPath -Tail 400) } else { @() }
$lines.Add("Log file present before test: $(Test-Path -LiteralPath $logPath)")
Write-Report $outPath $lines.ToArray()

Write-Host "سجل الاختبار: $outPath"
Write-Host "بعد الضغط على Enter ابدأ تسجيلًا فعليًا من AT2040USB في التطبيق الذي تستخدمه، ثم أوقف التسجيل قبل انتهاء المدة."
[void](Read-Host 'اضغط Enter عندما تكون مستعدًا')
$moduleSamples = New-Object System.Collections.Generic.List[string]
$deadline = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $deadline) {
    foreach ($m in @(Get-ApoModules)) { $moduleSamples.Add("PID=$($m.Pid) PATH=$($m.Path)") }
    Start-Sleep -Seconds 1
}
$after = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath -Tail 800) } else { @() }
$newLog = @()
if ($after.Count -gt 0) {
    $beforeSet = @{}
    foreach ($line in $before) { $beforeSet[$line] = $true }
    foreach ($line in $after) { if (-not $beforeSet.ContainsKey($line)) { $newLog += $line } }
}
$checks = [ordered]@{
    DllGetClassObject = [bool]($newLog -match 'DllGetClassObject entry')
    FactoryCreateInstance = [bool]($newLog -match 'ClassFactory::CreateInstance requested')
    Initialize = [bool]($newLog -match 'Initialize succeeded')
    FormatAccepted = [bool]($newLog -match 'Is(Input|Output)FormatSupported accepted')
    LockForProcess = [bool]($newLog -match 'LockForProcess entered')
    UdpBridgeStarted = [bool]($newLog -match 'Started: rate=')
    ApoProcessSummary = [bool]($newLog -match 'APOProcess summary:')
    DllObservedInAudiodg = ($moduleSamples.Count -gt 0)
}
$report = New-Object System.Collections.Generic.List[string]
$report.Add('')
$report.Add("Finished: $(Get-Date -Format o)")
$report.Add("DurationSeconds: $DurationSeconds")
$report.Add('--- Runtime checkpoints ---')
foreach ($entry in $checks.GetEnumerator()) { $report.Add(("{0}: {1}" -f $entry.Key, $entry.Value)) }
$report.Add('--- Observed audiodg module samples ---')
foreach ($line in ($moduleSamples | Select-Object -Unique)) { $report.Add($line) }
$report.Add('--- New MicBridge log lines ---')
foreach ($line in $newLog) { $report.Add($line) }
$report | Add-Content -LiteralPath $outPath -Encoding UTF8
$checks.GetEnumerator() | ForEach-Object { Write-Host ("{0,-26} {1}" -f $_.Key, $_.Value) }
Write-Host "انتهى الاختبار. التقرير: $outPath"
Write-Host 'هذا الاختبار لا يغيّر Registry أو إعدادات الصوت؛ غياب module enumeration وحده ليس دليلًا قاطعًا على عدم التحميل.'
