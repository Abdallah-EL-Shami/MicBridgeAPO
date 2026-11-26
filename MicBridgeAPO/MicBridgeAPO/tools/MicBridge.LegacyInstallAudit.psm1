Set-StrictMode -Version Latest


function Test-MBLegacyRegExport {
    param([string]$Path,[string]$ExpectedRoot)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $lines=[IO.File]::ReadAllLines($Path)
        $header=@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if($header.Count -ne 1 -or $header[0].TrimStart([char]0xFEFF) -notin @('Windows Registry Editor Version 5.00','REGEDIT4')) { return $false }
        $keys=@()
        foreach($line in $lines) {
            $v=$line.Trim()
            if($v.StartsWith('[HKEY_',[StringComparison]::OrdinalIgnoreCase) -and $v.EndsWith(']')) { $keys += $v.Substring(1,$v.Length-2) }
        }
        if($keys.Count -eq 0 -or -not ($keys | Where-Object { $_.Equals($ExpectedRoot,[StringComparison]::OrdinalIgnoreCase) })) { return $false }
        foreach($key in $keys) {
            if(-not $key.Equals($ExpectedRoot,[StringComparison]::OrdinalIgnoreCase) -and -not $key.StartsWith($ExpectedRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Get-MBLegacyExpectedRegistryHiveName {
    param([string]$RegistryRoot)
    if($RegistryRoot.StartsWith('HKLM:',[StringComparison]::OrdinalIgnoreCase)) { return 'HKEY_LOCAL_MACHINE' }
    return 'HKEY_CURRENT_USER'
}

function Test-MBLegacyInstallationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$RegistryRoot = 'HKLM:\',
        [guid]$ExpectedDeviceId = [guid]::Empty
    )

    # Read-only inventory. No Registry, file, ACL, or service mutations.
    if ($RegistryRoot -notmatch '^(HKLM:|HKCU:)\\.*$') {
        throw 'RegistryRoot must be an explicit HKLM: or HKCU: root.'
    }
    $RegistryRoot = $RegistryRoot.TrimEnd('\')
    $installFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $dataFull = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $clsid = '{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
    $registryTargets = @(
        [pscustomobject]@{ Name='COM CLSID'; Path=($RegistryRoot + '\SOFTWARE\Classes\CLSID\' + $clsid) },
        [pscustomobject]@{ Name='AudioEngine APO'; Path=($RegistryRoot + '\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\' + $clsid) }
    )

    $findings = [Collections.Generic.List[object]]::new()
    $baselineAssessment = 'NotPresent'
    $backupJson = Join-Path $dataFull 'backup.json'
    $registryHiveName = Get-MBLegacyExpectedRegistryHiveName -RegistryRoot $RegistryRoot
    if(Test-Path -LiteralPath $backupJson) {
        try {
            $backupItem=Get-Item -LiteralPath $backupJson -Force -ErrorAction Stop
            if(($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'backup.json is a reparse point.' }
            $backup=Get-Content -LiteralPath $backupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $required=@('DeviceId','ComRegistrationSnapshotVersion','PrevClsidRegistrationExists','PrevApoRegistrationExists','PrevClsidRegistrationFile','PrevApoRegistrationFile','PrevClsidRegistrationSha256','PrevApoRegistrationSha256')
            $missing=@($required | Where-Object { $backup.PSObject.Properties.Name -notcontains $_ })
            if($missing.Count -gt 0) { throw ('Permanent backup is missing required fields: '+($missing -join ', ')) }
            if([int]$backup.ComRegistrationSnapshotVersion -ne 1) { throw 'Permanent backup COM snapshot schema is not version 1.' }
            $backupDevice=[guid]::Empty
            if(-not [guid]::TryParse([string]$backup.DeviceId,[ref]$backupDevice)) { throw 'Permanent backup endpoint identity is invalid.' }
            if($ExpectedDeviceId -ne [guid]::Empty -and $backupDevice -ne $ExpectedDeviceId) { throw 'Permanent backup belongs to a different capture endpoint.' }

            $comBackupRoot=Join-Path $dataFull 'com-registration-backup'
            foreach($entry in @(
                [pscustomobject]@{Name='CLSID';Exists=[bool]$backup.PrevClsidRegistrationExists;Path=[string]$backup.PrevClsidRegistrationFile;Hash=[string]$backup.PrevClsidRegistrationSha256;File='previous-clsid.reg';Key='SOFTWARE\Classes\CLSID\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'},
                [pscustomobject]@{Name='AudioEngine APO';Exists=[bool]$backup.PrevApoRegistrationExists;Path=[string]$backup.PrevApoRegistrationFile;Hash=[string]$backup.PrevApoRegistrationSha256;File='previous-audioengine-apo.reg';Key='SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'}
            )) {
                $expectedPath=[IO.Path]::GetFullPath((Join-Path $comBackupRoot $entry.File))
                if(-not $entry.Exists) {
                    if(-not [string]::IsNullOrWhiteSpace($entry.Hash)) { throw "$($entry.Name) backup has a hash although the original key was absent." }
                    if(Test-Path -LiteralPath $expectedPath) { throw "$($entry.Name) backup file exists although the original key was recorded absent." }
                    continue
                }
                $recordedPath=[IO.Path]::GetFullPath($entry.Path)
                if(-not $recordedPath.Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)) { throw "$($entry.Name) backup path does not match its fixed ProgramData location." }
                if($entry.Hash -notmatch '^[A-Fa-f0-9]{64}    foreach ($target in $registryTargets) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Absent'; Path=$target.Path; ServerPath=$null; Sha256=$null })
            continue
        }

        $serverPath = $null
        $inproc = Join-Path $target.Path 'InprocServer32'
        if (Test-Path -LiteralPath $inproc) {
            try {
                $registryKey = Get-Item -LiteralPath $inproc -ErrorAction Stop
                try { $serverPath = [string]$registryKey.GetValue('') } finally { $registryKey.Close() }
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

        # Enumerate manually and never descend through reparse points.
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($directory.Path)
        while ($pending.Count -gt 0) {
            $currentDirectory = $pending.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop)) {
                if ($item.PSIsContainer) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $findings.Add([pscustomobject]@{ Kind='Directory'; Name=$item.Name; Classification='ReparsePointPreserved'; Path=$item.FullName; ServerPath=$null; Sha256=$null })
                    } else {
                        $pending.Push($item.FullName)
                    }
                    continue
                }

                $classification = 'UnclassifiedFile'
                if ($directory.Name -eq 'InstallDirectory' -and $item.Name -ieq 'MicBridgeAPO.dll') {
                    $classification = 'MicBridgeBinaryCandidate'
                } elseif ($directory.Name -eq 'InstallDirectory' -and $item.Name -in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
                    $classification = 'MicBridgeSupportFileCandidate'
                } elseif ($directory.Name -eq 'DataDirectory') {
                    $classification = 'PreserveDataFile'
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
    }

    $ambiguous = @($findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved','InvalidOrInsufficient') })
    $candidate = @($findings | Where-Object { $_.Classification -in @('MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeSupportFileCandidate','MicBridgeRecoveryEvidence','StructurallyValidCandidate') })
    $outcome = if ($ambiguous.Count -gt 0) { 'ReviewRequired' } elseif ($candidate.Count -gt 0) { 'InventoryOnly' } else { 'NoLegacyResidueDetected' }

    [pscustomobject]@{
        IsReadOnly = $true
        Outcome = $outcome
        CleanupAllowed = $false
        OriginalWindowsBaselineProven = $false
        BaselineAssessment = $baselineAssessment
        Findings = @($findings)
        Warnings = @('A matching product path or SHA-256 proves neither historical ownership nor that the captured state was the original Windows state.')
    }
}

Export-ModuleMember -Function Test-MBLegacyInstallationState
 -or -not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) { throw "$($entry.Name) backup file or SHA-256 is missing." }
                $fileItem=Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
                if(($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$($entry.Name) backup is a reparse point." }
                $actual=(Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256 -ErrorAction Stop).Hash
                if(-not $actual.Equals($entry.Hash,[StringComparison]::OrdinalIgnoreCase)) { throw "$($entry.Name) backup hash mismatch." }
                $expectedRoot="$registryHiveName\$($entry.Key)"
                if(-not (Test-MBLegacyRegExport -Path $expectedPath -ExpectedRoot $expectedRoot)) { throw "$($entry.Name) backup contains an invalid or foreign registry root." }
            }
            $baselineAssessment='StructurallyValidCandidate'
            $findings.Add([pscustomobject]@{Kind='PermanentBackup';Name='backup.json';Classification='StructurallyValidCandidate';Path=$backupJson;ServerPath=$null;Sha256=(Get-FileHash -LiteralPath $backupJson -Algorithm SHA256).Hash})
        } catch {
            $baselineAssessment='InvalidOrInsufficient'
            $findings.Add([pscustomobject]@{Kind='PermanentBackup';Name='backup.json';Classification='InvalidOrInsufficient';Path=$backupJson;ServerPath=$null;Sha256=$null;Detail=$_.Exception.Message})
        }
    }

    $compositeJson=Join-Path $dataFull 'composite-efx-backup.json'
    if(Test-Path -LiteralPath $compositeJson) {
        try {
            $compositeItem=Get-Item -LiteralPath $compositeJson -Force -ErrorAction Stop
            if(($compositeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Composite EFX backup is a reparse point.' }
            $composite=Get-Content -LiteralPath $compositeJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if($composite.PSObject.Properties.Name -notcontains 'DeviceId' -or $composite.PSObject.Properties.Name -notcontains 'Exists' -or
                $composite.PSObject.Properties.Name -notcontains 'Kind' -or $composite.PSObject.Properties.Name -notcontains 'Value') { throw 'Composite EFX backup schema is incomplete.' }
            $compositeDevice=[guid]::Empty
            if(-not [guid]::TryParse([string]$composite.DeviceId,[ref]$compositeDevice)) { throw 'Composite EFX backup endpoint identity is invalid.' }
            if($ExpectedDeviceId -ne [guid]::Empty -and $compositeDevice -ne $ExpectedDeviceId) { throw 'Composite EFX backup belongs to a different endpoint.' }
            if($composite.Exists -isnot [bool]) { throw 'Composite EFX Exists field is not Boolean.' }
            if($composite.Exists -and [string]$composite.Kind -ne 'MultiString') { throw 'Composite EFX backup is not REG_MULTI_SZ.' }
            if($composite.Value -isnot [array]) { throw 'Composite EFX backup value is not an array.' }
            $findings.Add([pscustomobject]@{Kind='CompositeBackup';Name='composite-efx-backup.json';Classification='StructurallyValidCandidate';Path=$compositeJson;ServerPath=$null;Sha256=(Get-FileHash -LiteralPath $compositeJson -Algorithm SHA256).Hash})
        } catch {
            $findings.Add([pscustomobject]@{Kind='CompositeBackup';Name='composite-efx-backup.json';Classification='InvalidOrInsufficient';Path=$compositeJson;ServerPath=$null;Sha256=$null;Detail=$_.Exception.Message})
        }
    }
    foreach ($target in $registryTargets) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            $findings.Add([pscustomobject]@{ Kind='Registration'; Name=$target.Name; Classification='Absent'; Path=$target.Path; ServerPath=$null; Sha256=$null })
            continue
        }

        $serverPath = $null
        $inproc = Join-Path $target.Path 'InprocServer32'
        if (Test-Path -LiteralPath $inproc) {
            try {
                $registryKey = Get-Item -LiteralPath $inproc -ErrorAction Stop
                try { $serverPath = [string]$registryKey.GetValue('') } finally { $registryKey.Close() }
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

        # Enumerate manually and never descend through reparse points.
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($directory.Path)
        while ($pending.Count -gt 0) {
            $currentDirectory = $pending.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop)) {
                if ($item.PSIsContainer) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $findings.Add([pscustomobject]@{ Kind='Directory'; Name=$item.Name; Classification='ReparsePointPreserved'; Path=$item.FullName; ServerPath=$null; Sha256=$null })
                    } else {
                        $pending.Push($item.FullName)
                    }
                    continue
                }

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
