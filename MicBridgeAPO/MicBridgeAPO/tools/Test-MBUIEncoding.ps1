$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$sourcePath = Join-Path $repoRoot 'MicBridgeAPO/MicBridgeAPO/MicBridgeUI.ps1'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "UI source is missing: $sourcePath" }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MicBridgeUI-Encoding-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $tempUi = Join-Path $tempRoot 'MicBridgeUI.ps1'
    $validator = Join-Path $tempRoot 'Validate-Parse.ps1'

    # Match the signed-release staging transformation exactly.
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    $strictUtf8 = [Text.UTF8Encoding]::new($false,$true)
    $uiScript = $strictUtf8.GetString($sourceBytes)
    if ($uiScript.Length -gt 0 -and $uiScript[0] -eq [char]0xFEFF) { $uiScript = $uiScript.Substring(1) }

    $versionPattern = '(?m)^\$appVersion\s*=\s*''[^'']*''\s*$'
    $versionAssignment = [regex]::Matches($uiScript, $versionPattern)
    if ($versionAssignment.Count -ne 1) { throw 'Expected exactly one UI version assignment.' }
    $uiScript = [regex]::Replace($uiScript, $versionPattern, ('$appVersion = ' + "'" + '0.1.2-encoding-test' + "'"))

    $utf16LeBom = [Text.UnicodeEncoding]::new($false,$true,$true)
    [IO.File]::WriteAllText($tempUi,$uiScript,$utf16LeBom)
    $normalizedBytes = [IO.File]::ReadAllBytes($tempUi)
    if ($normalizedBytes.Length -lt 2 -or $normalizedBytes[0] -ne 0xFF -or $normalizedBytes[1] -ne 0xFE) {
        throw 'UTF-16LE BOM was not written.'
    }
    $normalizedText = [IO.File]::ReadAllText($tempUi,[Text.Encoding]::Unicode)
    if ($normalizedText -cne $uiScript) { throw 'UTF-16LE round-trip changed the UI script text.' }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($tempUi,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "Current PowerShell parser rejected normalized UI script: $($parseErrors[0].Message)" }

    @'
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) { throw "Windows PowerShell 5.1 parser rejected normalized UI script: $($parseErrors[0].Message)" }
'@ | Set-Content -LiteralPath $validator -Encoding UTF8

    $legacyPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not (Test-Path -LiteralPath $legacyPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 executable is unavailable on this runner.' }
    & $legacyPowerShell -NoProfile -ExecutionPolicy Bypass -File $validator -Path $tempUi
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell 5.1 parser exited with code $LASTEXITCODE." }

    Write-Host 'PASS: MicBridgeUI strict UTF-8 decode, UTF-16LE BOM, exact text round-trip, and PowerShell parsing.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}