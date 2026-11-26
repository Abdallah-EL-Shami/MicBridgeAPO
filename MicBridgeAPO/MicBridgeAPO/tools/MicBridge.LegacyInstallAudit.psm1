Set-StrictMode -Version Latest

function Test-MBLegacyRegExport {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedRoot)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $lines=[IO.File]::ReadAllLines($Path)
        $header=@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if($header.Count -ne 1) { return $false }
        $headerText=$header[0].TrimStart([char]0xFEFF)
        if($headerText -notin @('Windows Registry Editor Version 5.00','REGEDIT4')) { return $false }
        $keys=@()
        foreach($line in $lines) {
            $v=$line.Trim()
            if($v.StartsWith('[HKEY_',[StringComparison]::OrdinalIgnoreCase) -and $v.EndsWith(']')) {
                $keys += $v.Substring(1,$v.Length-2)
            }
        }
        if($keys.Count -eq 0 -or -not ($keys | Where-Object { $_.Equals($ExpectedRoot,[StringComparison]::OrdinalIgnoreCase) })) { return $false }
        foreach($key in $keys) {
            if(-not $key.Equals($ExpectedRoot,[StringComparison]::OrdinalIgnoreCase) -and
                -not $key.StartsWith($ExpectedRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-MBLegacyInstallationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$RegistryRoot = 'HKLM:\',
        [guid]$ExpectedDeviceId = [guid]::Empty
    )

    # Read-only audit. No Registry, file, ACL, service, or shortcut mutations.
    if($RegistryRoot -notmatch '^(HKLM:|HKCU:)\\.*$') { throw 'RegistryRoot must be an explicit HKLM: or HKCU: root.' }
    $RegistryRoot=$RegistryRoot.TrimEnd('\')
    $installFull=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $dataFull=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    $clsid='{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'
    $registryHiveName=if($RegistryRoot.StartsWith('HKLM:',[StringComparison]::OrdinalIgnoreCase)) {'HKEY_LOCAL_MACHINE'} else {'HKEY_CURRENT_USER'}
    $registrySubRoot=$RegistryRoot.Substring(5).Trim('\')
    $registryTargets=@(
        [pscustomobject]@{Name='COM CLSID';Path=($RegistryRoot+'\SOFTWARE\Classes\CLSID\'+$clsid)},
        [pscustomobject]@{Name='AudioEngine APO';Path=($RegistryRoot+'\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\'+$clsid)}
    )
    $findings=[Collections.Generic.List[object]]::new()
    $baselineAssessment='NotPresent'
    $backupJson=Join-Path $dataFull 'backup.json'

    # Validate the immutable first-install backup as evidence, never as proof of
    # the true Windows baseline. Hashes establish integrity only against the
    # manifest; they cannot prove that the captured values were historically correct.
    if(Test-Path -LiteralPath $backupJson) {
        try {
            $backupItem=Get-Item -LiteralPath $backupJson -Force -ErrorAction Stop
            if(($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'backup.json is a reparse point.' }
            $backup=Get-Content -LiteralPath $backupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $required=@('DeviceId','ComRegistrationSnapshotVersion','PrevClsidRegistrationExists','PrevApoRegistrationExists','PrevClsidRegistrationFile','PrevApoRegistrationFile','PrevClsidRegistrationSha256','PrevApoRegistrationSha256')
            $missing=@($required | Where-Object { $backup.PSObject.Properties.Name -notcontains $_ })
            if($missing.Count -gt 0) { throw ('Permanent backup is missing fields: '+($missing -join ', ')) }
            if([int]$backup.ComRegistrationSnapshotVersion -ne 1) { throw 'Permanent backup COM snapshot schema is not version 1.' }
            $backupDevice=[guid]::Empty
            if(-not [guid]::TryParse([string]$backup.DeviceId,[ref]$backupDevice)) { throw 'Permanent backup endpoint identity is invalid.' }
            if($ExpectedDeviceId -ne [guid]::Empty -and $backupDevice -ne $ExpectedDeviceId) { throw 'Permanent backup belongs to a different capture endpoint.' }

            $comBackupRoot=Join-Path $dataFull 'com-registration-backup'
            $comEntries=@(
                [pscustomobject]@{Name='CLSID';ExistsField='PrevClsidRegistrationExists';Path=[string]$backup.PrevClsidRegistrationFile;Hash=[string]$backup.PrevClsidRegistrationSha256;File='previous-clsid.reg';Key='SOFTWARE\Classes\CLSID\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'},
                [pscustomobject]@{Name='AudioEngine APO';ExistsField='PrevApoRegistrationExists';Path=[string]$backup.PrevApoRegistrationFile;Hash=[string]$backup.PrevApoRegistrationSha256;File='previous-audioengine-apo.reg';Key='SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}'}
            )
            foreach($entry in $comEntries) {
                $existsValue=$backup.($entry.ExistsField)
                if($existsValue -isnot [bool]) { throw "$($entry.Name) existence flag is not Boolean." }
                $expectedPath=[IO.Path]::GetFullPath((Join-Path $comBackupRoot $entry.File))
                if([string]::IsNullOrWhiteSpace($entry.Path)) { throw "$($entry.Name) backup path is missing." }
                $recordedPath=[IO.Path]::GetFullPath($entry.Path)
                if(-not $recordedPath.Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)) { throw "$($entry.Name) backup path does not match its fixed ProgramData location." }

                if(-not $existsValue) {
                    if(-not [string]::IsNullOrWhiteSpace($entry.Hash)) { throw "$($entry.Name) has a hash although its original key was absent." }
                    if(Test-Path -LiteralPath $expectedPath) { throw "$($entry.Name) backup file exists although its original key was recorded absent." }
                    continue
                }

                if($entry.Hash -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) { throw "$($entry.Name) backup file or SHA-256 is missing." }
                $fileItem=Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
                if(($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$($entry.Name) backup is a reparse point." }
                $actual=(Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256 -ErrorAction Stop).Hash
                if(-not $actual.Equals($entry.Hash,[StringComparison]::OrdinalIgnoreCase)) { throw "$($entry.Name) backup hash mismatch." }
                $expectedRoot=if([string]::IsNullOrWhiteSpace($registrySubRoot)) {
                    "$registryHiveName\$($entry.Key)"
                } else {
                    "$registryHiveName\$registrySubRoot\$($entry.Key)"
                }
                if(-not (Test-MBLegacyRegExport -Path $expectedPath -ExpectedRoot $expectedRoot)) { throw "$($entry.Name) backup contains an invalid or foreign Registry root." }
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
            foreach($field in @('DeviceId','Exists','Kind','Value')) {
                if($composite.PSObject.Properties.Name -notcontains $field) { throw "Composite EFX backup is missing '$field'." }
            }
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

    $clsidProductCandidate=$false
    foreach($target in $registryTargets) {
        if(-not (Test-Path -LiteralPath $target.Path)) {
            $findings.Add([pscustomobject]@{Kind='Registration';Name=$target.Name;Classification='Absent';Path=$target.Path;ServerPath=$null;Sha256=$null})
            continue
        }
        $serverPath=$null
        $inproc=Join-Path $target.Path 'InprocServer32'
        if(Test-Path -LiteralPath $inproc) {
            try {
                $key=Get-Item -LiteralPath $inproc -ErrorAction Stop
                try { $serverPath=[string]$key.GetValue('') } finally { $key.Close() }
            } catch {
                $findings.Add([pscustomobject]@{Kind='Registration';Name=$target.Name;Classification='Unreadable';Path=$target.Path;ServerPath=$null;Sha256=$null})
                continue
            }
        }
        $classification='Ambiguous'; $serverHash=$null
        if([string]::IsNullOrWhiteSpace($serverPath) -and $target.Name -eq 'AudioEngine APO' -and $clsidProductCandidate) {
            $classification='MicBridgeCandidate'
        }
        if(-not [string]::IsNullOrWhiteSpace($serverPath)) {
            try {
                $serverFull=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($serverPath.Trim('"')))
                if($serverFull.StartsWith($installFull+'\',[StringComparison]::OrdinalIgnoreCase) -and
                    [IO.Path]::GetFileName($serverFull) -ieq 'MicBridgeAPO.dll' -and
                    (Test-Path -LiteralPath $serverFull -PathType Leaf)) {
                    $classification='MicBridgeCandidate'
                    $serverHash=(Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } elseif(Test-Path -LiteralPath $serverFull -PathType Leaf) {
                    $classification='ForeignOrSharedServer'
                    $serverHash=(Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                } else { $classification='MissingOrUnresolvedServer' }
            } catch { $classification='InvalidServerPath' }
        }
        if($target.Name -eq 'COM CLSID' -and $classification -eq 'MicBridgeCandidate') { $clsidProductCandidate=$true }
        $findings.Add([pscustomobject]@{Kind='Registration';Name=$target.Name;Classification=$classification;Path=$target.Path;ServerPath=$serverPath;Sha256=$serverHash})
    }

    foreach($directory in @(
        [pscustomobject]@{Name='InstallDirectory';Path=$installFull},
        [pscustomobject]@{Name='DataDirectory';Path=$dataFull}
    )) {
        if(-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            $findings.Add([pscustomobject]@{Kind='Directory';Name=$directory.Name;Classification='Absent';Path=$directory.Path;ServerPath=$null;Sha256=$null})
            continue
        }
        $pending=[Collections.Generic.Stack[string]]::new()
        $pending.Push($directory.Path)
        while($pending.Count -gt 0) {
            $currentDirectory=$pending.Pop()
            foreach($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop)) {
                if($item.PSIsContainer) {
                    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $findings.Add([pscustomobject]@{Kind='Directory';Name=$item.Name;Classification='ReparsePointPreserved';Path=$item.FullName;ServerPath=$null;Sha256=$null})
                    } else { $pending.Push($item.FullName) }
                    continue
                }
                $classification='UnclassifiedFile'
                if($directory.Name -eq 'InstallDirectory' -and $item.Name -ieq 'MicBridgeAPO.dll') {
                    $classification='MicBridgeBinaryCandidate'
                } elseif($directory.Name -eq 'InstallDirectory' -and $item.Name -in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
                    $classification='MicBridgeSupportFileCandidate'
                } elseif($directory.Name -eq 'DataDirectory' -and $item.Name -in @('backup.json','composite-efx-backup.json','control.ini','MicBridge.ini','MicBridge.log','desktop-shortcut.sha256','previous-clsid.reg','previous-audioengine-apo.reg')) {
                    $classification='MicBridgeRecoveryEvidence'
                } elseif($directory.Name -eq 'DataDirectory' -and $item.FullName -match '\\com-registration-backup\\|\\dll-backups\\|\\transactions-[^\\]+\\') {
                    $classification='MicBridgeRecoveryEvidence'
                } elseif($directory.Name -eq 'DataDirectory') {
                    $classification='PreserveDataFile'
                }
                $hash=$null
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                } else { $classification='ReparsePointPreserved' }
                $findings.Add([pscustomobject]@{Kind='File';Name=$item.Name;Classification=$classification;Path=$item.FullName;ServerPath=$null;Sha256=$hash})
            }
        }
    }

    $legacyArtifacts=@($findings | Where-Object { $_.Classification -in @('MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeSupportFileCandidate','MicBridgeRecoveryEvidence') })
    if($baselineAssessment -eq 'NotPresent' -and $legacyArtifacts.Count -gt 0) {
        $baselineAssessment='Missing'
        $findings.Add([pscustomobject]@{Kind='PermanentBackup';Name='backup.json';Classification='MissingPermanentBackup';Path=$backupJson;ServerPath=$null;Sha256=$null})
    }
    $ambiguous=@($findings | Where-Object { $_.Classification -in @('Ambiguous','Unreadable','MissingOrUnresolvedServer','InvalidServerPath','ForeignOrSharedServer','UnclassifiedFile','ReparsePointPreserved','InvalidOrInsufficient','MissingPermanentBackup') })
    $candidate=@($findings | Where-Object { $_.Classification -in @('MicBridgeCandidate','MicBridgeBinaryCandidate','MicBridgeSupportFileCandidate','MicBridgeRecoveryEvidence','StructurallyValidCandidate') })
    $outcome=if($ambiguous.Count -gt 0) {'ReviewRequired'} elseif($candidate.Count -gt 0) {'InventoryOnly'} else {'NoLegacyResidueDetected'}

    [pscustomobject]@{
        IsReadOnly=$true
        Outcome=$outcome
        CleanupAllowed=$false
        OriginalWindowsBaselineProven=$false
        BaselineAssessment=$baselineAssessment
        Findings=@($findings)
        Warnings=@('A matching product path or SHA-256 proves neither historical ownership nor that the captured values were the original Windows state.')
    }
}
Export-ModuleMember -Function Test-MBLegacyInstallationState
