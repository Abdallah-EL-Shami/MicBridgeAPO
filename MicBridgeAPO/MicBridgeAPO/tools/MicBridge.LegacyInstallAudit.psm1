Set-StrictMode -Version Latest

function Test-MBLegacyInstallationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$RegistryRoot = 'HKLM:\'
    )

    # Read-only inventory only. This function must never repair, delete, import,
    # create, or modify Registry keys, files, ACLs, or services.
    if ($RegistryRoot -notmatch '^(HKLM:|HKCU:)\\[^\r\n]*
    $dataFull = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
    $registryTargets = @(
        [pscustomobject]@{ Name='COM CLSID'; Path=($RegistryRoot + 'SOFTWARE\Classes\CLSID\' + $clsid) },
        [pscustomobject]@{ Name='AudioEngine APO'; Path=($RegistryRoot + 'SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\' + $clsid) }
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($target in $registryTargets) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Absent'; Path=$target.Path; ServerPath=$null; Sha256=$null })
            continue
        }

        $serverPath = $null
        $inproc = Join-Path $target.Path 'InprocServer32'
        if (Test-Path -LiteralPath $inproc) {
            try {
                $serverPath = [string](Get-Item -LiteralPath $inproc -ErrorAction Stop).GetValue('')
            } catch {
                $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Unreadable'; Path=$target.Path; ServerPath=$null; Sha256=$null })
                continue
            }
        }

        $classification = 'Ambiguous'
        $serverHash = $null
        if (-not [string]::IsNullOrWhiteSpace($serverPath)) {
            try {
                $expanded = [Environment]::ExpandEnvironmentVariables($serverPath.Trim('"'))
                $serverFull = [IO.Path]::GetFullPath($expanded)
                $insideInstall = $serverFull.StartsWith($installFull + '\',[StringComparison]::OrdinalIgnoreCase)
                if ($insideInstall -and [IO.Path]::GetFileName($serverFull) -ieq 'MicBridgeAPO.dll' -and
                    (Test-Path -LiteralPath $serverFull -PathType Leaf)) {
                    $classification = 'MicBridgeCandidate'
                    $serverHash = (Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } elseif (Test-Path -LiteralPath $serverFull -PathType Leaf) {
                    $classification = 'ForeignOrSharedServer'
                    $serverHash = (Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } else {
                    $classification = 'MissingOrUnresolvedServer'
                }
            } catch {
                $classification = 'InvalidServerPath'
            }
        }
        $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification=$classification; Path=$target.Path; ServerPath=$serverPath; Sha256=$serverHash })
    }

    foreach ($directory in @(
        [pscustomobject]@{ Name='InstallDirectory'; Path=$installFull },
        [pscustomobject]@{ Name='DataDirectory'; Path=$dataFull }
    )) {
        if (-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            $findings.Add([pscustomobject]@{ Kind='Directory'; Name=$directory.Name; Classification='Absent'; Path=$directory.Path; ServerPath=$null; Sha256=$null })
            continue
        }
        $items = @(Get-ChildItem -LiteralPath $directory.Path -Force -Recurse -ErrorAction Stop)
        foreach ($item in $items) {
            if ($item.PSIsContainer) { continue }
            $classification = 'UnclassifiedFile'
            if ($directory.Name -eq 'InstallDirectory' -and $item.Name -ieq 'MicBridgeAPO.dll') {
                $classification = 'MicBridgeBinaryCandidate'
            } elseif ($directory.Name -eq 'DataDirectory' -and $item.Name -in @('backup.json','composite-efx-backup.json','Install.log','control.ini','MicBridge.ini')) {
                $classification = 'MicBridgeRecoveryEvidence'
            }
            $hash = $null
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } else {
                $classification = 'ReparsePointPreserved'
            }
            $findings.Add([pscustomobject]@{ Kind='File'; Name=$item.Name; Classification=$classification; Path=$item.FullName; ServerPath=$null; Sha256=$hash })
        }
    }

    $ambiguous = @($findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved') })
    $candidate = @($findings | Where-Object { $_.Classification -in @('MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeRecoveryEvidence') })
    $outcome = if ($ambiguous.Count -gt 0) { 'ReviewRequired' } elseif ($candidate.Count -gt 0) { 'InventoryOnly' } else { 'NoLegacyResidueDetected' }

    [pscustomobject]@{
        IsReadOnly = $true
        Outcome = $outcome
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Findings = @($findings)
        Warnings = @('A matching product path or SHA-256 proves neither historical ownership nor that the captured state was the original Windows state.')
    }
}

Export-ModuleMember -Function Test-MBLegacyInstallationState
) { throw 'RegistryRoot must be an explicit HKLM: or HKCU: test/product root.' }
    $RegistryRoot = $RegistryRoot.TrimEnd('\')
    $installFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $dataFull = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
    $registryTargets = @(
        [pscustomobject]@{ Name='COM CLSID'; Path=($RegistryRoot + 'SOFTWARE\Classes\CLSID\' + $clsid) },
        [pscustomobject]@{ Name='AudioEngine APO'; Path=($RegistryRoot + 'SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\' + $clsid) }
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($target in $registryTargets) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Absent'; Path=$target.Path; ServerPath=$null; Sha256=$null })
            continue
        }

        $serverPath = $null
        $inproc = Join-Path $target.Path 'InprocServer32'
        if (Test-Path -LiteralPath $inproc) {
            try {
                $serverPath = [string](Get-Item -LiteralPath $inproc -ErrorAction Stop).GetValue('')
            } catch {
                $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Unreadable'; Path=$target.Path; ServerPath=$null; Sha256=$null })
                continue
            }
        }

        $classification = 'Ambiguous'
        $serverHash = $null
        if (-not [string]::IsNullOrWhiteSpace($serverPath)) {
            try {
                $expanded = [Environment]::ExpandEnvironmentVariables($serverPath.Trim('"'))
                $serverFull = [IO.Path]::GetFullPath($expanded)
                $insideInstall = $serverFull.StartsWith($installFull + '\',[StringComparison]::OrdinalIgnoreCase)
                if ($insideInstall -and [IO.Path]::GetFileName($serverFull) -ieq 'MicBridgeAPO.dll' -and
                    (Test-Path -LiteralPath $serverFull -PathType Leaf)) {
                    $classification = 'MicBridgeCandidate'
                    $serverHash = (Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } elseif (Test-Path -LiteralPath $serverFull -PathType Leaf) {
                    $classification = 'ForeignOrSharedServer'
                    $serverHash = (Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } else {
                    $classification = 'MissingOrUnresolvedServer'
                }
            } catch {
                $classification = 'InvalidServerPath'
            }
        }
        $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification=$classification; Path=$target.Path; ServerPath=$serverPath; Sha256=$serverHash })
    }

    foreach ($directory in @(
        [pscustomobject]@{ Name='InstallDirectory'; Path=$installFull },
        [pscustomobject]@{ Name='DataDirectory'; Path=$dataFull }
    )) {
        if (-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            $findings.Add([pscustomobject]@{ Kind='Directory'; Name=$directory.Name; Classification='Absent'; Path=$directory.Path; ServerPath=$null; Sha256=$null })
            continue
        }
        $items = @(Get-ChildItem -LiteralPath $directory.Path -Force -Recurse -ErrorAction Stop)
        foreach ($item in $items) {
            if ($item.PSIsContainer) { continue }
            $classification = 'UnclassifiedFile'
            if ($directory.Name -eq 'InstallDirectory' -and $item.Name -ieq 'MicBridgeAPO.dll') {
                $classification = 'MicBridgeBinaryCandidate'
            } elseif ($directory.Name -eq 'DataDirectory' -and $item.Name -in @('backup.json','composite-efx-backup.json','Install.log','control.ini','MicBridge.ini')) {
                $classification = 'MicBridgeRecoveryEvidence'
            }
            $hash = $null
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } else {
                $classification = 'ReparsePointPreserved'
            }
            $findings.Add([pscustomobject]@{ Kind='File'; Name=$item.Name; Classification=$classification; Path=$item.FullName; ServerPath=$null; Sha256=$hash })
        }
    }

    $ambiguous = @($findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved') })
    $candidate = @($findings | Where-Object { $_.Classification -in @('MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeRecoveryEvidence') })
    $outcome = if ($ambiguous.Count -gt 0) { 'ReviewRequired' } elseif ($candidate.Count -gt 0) { 'InventoryOnly' } else { 'NoLegacyResidueDetected' }

    [pscustomobject]@{
        IsReadOnly = $true
        Outcome = $outcome
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        Findings = @($findings)
        Warnings = @('A matching product path or SHA-256 proves neither historical ownership nor that the captured state was the original Windows state.')
    }
}

Export-ModuleMember -Function Test-MBLegacyInstallationState
