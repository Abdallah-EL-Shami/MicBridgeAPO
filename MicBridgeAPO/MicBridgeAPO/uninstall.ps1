#Requires -RunAsAdministrator
# إزالة MicBridge APO وإرجاع القيم التي غيّرها التثبيت.
$ErrorActionPreference = 'Continue'
$clsid      = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
$fxValue    = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$installDir = Join-Path $env:ProgramFiles 'MicBridgeAPO'
$dataDir    = Join-Path $env:ProgramData  'MicBridgeAPO'
$backupFile = Join-Path $dataDir 'backup.json'
$audioKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Audio'
$capRoot    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'

if (Test-Path $backupFile) {
    $b = Get-Content $backupFile -Raw | ConvertFrom-Json
    $fxPath = "$capRoot\$($b.DeviceId)\FxProperties"
    if (Test-Path $fxPath) {
        if ($b.PrevEndpointEffect) { Set-ItemProperty -LiteralPath $fxPath -Name $fxValue -Value $b.PrevEndpointEffect -Type String }
        else { Remove-ItemProperty -LiteralPath $fxPath -Name $fxValue -ErrorAction SilentlyContinue }
    }
    if ($null -ne $b.PrevDisableProtectedAudioDG) { Set-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -Value $b.PrevDisableProtectedAudioDG -Type DWord }
    else { Remove-ItemProperty -LiteralPath $audioKey -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue }
} else { Write-Warning 'لم أجد backup.json، سأزيل التسجيل فقط.' }

Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -ErrorAction SilentlyContinue

Restart-Service -Name Audiosrv -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Write-Host "تمت الإزالة. ملفاتك في $dataDir (الإعدادات والسجل) لم تُحذف، احذفها يدويًا إن أردت."
Write-Host "ملاحظة: ملكية مفتاح المايك في السجل بقيت للمسؤولين، وهذا لا يؤثر على عمل الجهاز."
