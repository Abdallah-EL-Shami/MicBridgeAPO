Set-StrictMode -Version Latest

function Test-MBPathWithinDirectory {
    param([string]$Candidate,[string]$Root)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $candidateFull = [IO.Path]::GetFullPath($Candidate)
        return $candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-MBNoReparsePath {
    param([string]$Path,[string]$StopAt)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($StopAt)) { return $false }
    try {
        $pathFull = [IO.Path]::GetFullPath($Path)
        $stopFull = [IO.Path]::GetFullPath($StopAt).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        if (-not [string]::Equals($pathFull,$stopFull,[StringComparison]::OrdinalIgnoreCase) -and
            -not $pathFull.StartsWith($stopFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return $false }

        # Check the file, every parent, and the transaction root. Checking only
        # the leaf misses junctions/symlinks that redirect a backup outside its root.
        $current = $pathFull
        $volumeRoot = [IO.Path]::GetPathRoot($pathFull)
        while ($true) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            if ([string]::Equals($current.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),
                $volumeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = [IO.Directory]::GetParent($current)
            if (-not $parent) { return $false }
            $current = $parent.FullName
        }
        return $true
    } catch { return $false }
}

function Test-MBFileSnapshot {
    param(
        [string]$Path,
        [string]$Sha256,
        [string]$Root,
        [string]$Label,
        [System.Collections.Generic.List[string]]$Errors
    )
    if (-not (Test-MBPathWithinDirectory -Candidate $Path -Root $Root)) {
        [void]$Errors.Add("$Label path is missing or escapes its transaction-owned directory.")
        return
    }
    if ($Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [void]$Errors.Add("$Label SHA-256 is missing or malformed.")
        return
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or
        -not (Test-MBNoReparsePath -Path $Path -StopAt $Root)) {
        [void]$Errors.Add("$Label snapshot path traverses a reparse point or an unsafe transaction directory.")
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [void]$Errors.Add("$Label snapshot file is missing.")
        return
    }
    $snapshotItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($snapshotItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [void]$Errors.Add("$Label snapshot file must not be a reparse point.")
        return
    }
    try {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($actual,$Sha256,[StringComparison]::OrdinalIgnoreCase)) {
            [void]$Errors.Add("$Label snapshot hash does not match its durable manifest.")
        }
    } catch {
        [void]$Errors.Add("$Label snapshot could not be hashed: $($_.Exception.Message)")
    }
}


function Test-MBRegistryExportSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$TemporaryDirectory,
        [scriptblock]$ExportAction
    )
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') { return $false }
    if (-not (Test-Path -LiteralPath $TemporaryDirectory -PathType Container)) { return $false }
    if ($RegistryPath -notmatch '^(HKLM|HKCU)\\') { return $false }

    $temporaryExport = Join-Path $TemporaryDirectory ('verify-' + [guid]::NewGuid().ToString('N') + '.reg')
    try {
        if ($ExportAction) {
            $exportSucceeded = [bool](& $ExportAction $RegistryPath $temporaryExport)
        } else {
            & reg.exe export $RegistryPath $temporaryExport /y | Out-Null
            $exportSucceeded = ($LASTEXITCODE -eq 0)
        }
        if (-not $exportSucceeded -or -not (Test-Path -LiteralPath $temporaryExport -PathType Leaf)) { return $false }
        $actualHash = (Get-FileHash -LiteralPath $temporaryExport -Algorithm SHA256 -ErrorAction Stop).Hash
        return [string]::Equals($actualHash,$ExpectedSha256,[StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $temporaryExport -Force -ErrorAction SilentlyContinue
    }
}


function Test-MBRegistryExportBounds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$ExpectedRegistryRoot
    )
    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($SnapshotPath)
        $lines = @($text -split '\r?\n')
        $header = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($header.Count -ne 1) { return $false }
        $headerText = $header[0].TrimStart([char]0xFEFF)
        if ($headerText -ne 'Windows Registry Editor Version 5.00' -and $headerText -ne 'REGEDIT4') { return $false }

        $keys = @()
        foreach ($line in $lines) {
            $candidate = $line.Trim()
            if ($candidate.StartsWith('[HKEY_', [StringComparison]::OrdinalIgnoreCase) -and $candidate.EndsWith(']')) {
                $keys += $candidate.Substring(1,$candidate.Length - 2)
            }
        }
        if ($keys.Count -eq 0 -or -not ($keys -contains $ExpectedRegistryRoot)) { return $false }
        foreach ($key in $keys) {
            if (-not $key.Equals($ExpectedRegistryRoot,[StringComparison]::OrdinalIgnoreCase) -and
                -not $key.StartsWith($ExpectedRegistryRoot + '\',[StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

function Test-MBInstallRollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive = 'HKLM'
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'
    # Validate the transaction/data roots themselves even when this snapshot
    # contains no existing files (and therefore no individual backup paths).
    foreach ($rootSpec in @(
        [pscustomobject]@{ Path=$TransactionDirectory; Label='Transaction directory' },
        [pscustomobject]@{ Path=$DataDirectory; Label='ProgramData directory' }
    )) {
        if (-not (Test-Path -LiteralPath $rootSpec.Path -PathType Container) -or
            -not (Test-MBNoReparsePath -Path $rootSpec.Path -StopAt $rootSpec.Path)) {
            [void]$errors.Add("$($rootSpec.Label) is missing or traverses a reparse point.")
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid=$false; Errors=@($errors); ReplaySafe=$false }
    }
    $required = @(
        'DeviceId','TransactionId','FxEffect','FxAssociation','FxComposite','DevSddl','FxSddl',
        'FxKeyExisted','ClsidRegExisted','ApoRegExisted','DllExisted',
        'DllOriginalSha256','DllNewSha256','DllReplacementStarted','ClsidRegExisted','ClsidRegBackup','ClsidRegSha256','ApoRegExisted','ApoRegBackup','ApoRegSha256','IniExisted','ControlExisted','DataDirSddl',
        'ControlSddl','InstallFiles','ShortcutExisted','ShortcutBackup',
        'ShortcutBackupSha256','InstallDirExisted'
    )
    foreach ($name in $required) {
        if ($State.PSObject.Properties.Name -notcontains $name) {
            [void]$errors.Add("Required snapshot field '$name' is missing.")
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid=$false; Errors=@($errors); ReplaySafe=$false }
    }

    $parsedDevice = [guid]::Empty
    if (-not [guid]::TryParse([string]$State.DeviceId,[ref]$parsedDevice) -or $parsedDevice -ne $ExpectedDeviceId) {
        [void]$errors.Add('Snapshot device identity does not match the journal device identity.')
    }
    $parsedTransaction = [guid]::Empty
    if (-not [guid]::TryParse([string]$State.TransactionId,[ref]$parsedTransaction)) {
        [void]$errors.Add('Snapshot transaction identity is missing or invalid.')
    }
    foreach ($name in @('FxKeyExisted','ClsidRegExisted','ApoRegExisted','DllExisted','IniExisted','ControlExisted','ShortcutExisted','InstallDirExisted')) {
        if ($State.$name -isnot [bool]) { [void]$errors.Add("Snapshot field '$name' must be Boolean.") }
    }
    foreach ($name in @('DevSddl','DataDirSddl')) {
        if ([string]::IsNullOrWhiteSpace([string]$State.$name)) { [void]$errors.Add("Snapshot field '$name' is missing.") }
    }
    if ($State.FxKeyExisted -and [string]::IsNullOrWhiteSpace([string]$State.FxSddl)) {
        [void]$errors.Add('FxSddl is required when the endpoint FxProperties key existed.')
    }

    foreach ($name in @('FxEffect','FxAssociation','FxComposite')) {
        $snapshot = $State.$name
        if ($null -eq $snapshot) {
            [void]$errors.Add("Registry snapshot '$name' is missing.")
            continue
        }
        $requiredSnapshotFields = @('KeyExists','Exists','Kind','Value')
        $missingSnapshotFields = @($requiredSnapshotFields | Where-Object { $snapshot.PSObject.Properties.Name -notcontains $_ })
        if ($missingSnapshotFields.Count -gt 0) {
            [void]$errors.Add("Registry snapshot '$name' is incomplete.")
            continue
        }
        if ($snapshot.KeyExists -isnot [bool] -or $snapshot.Exists -isnot [bool]) {
            [void]$errors.Add("Registry snapshot '$name' has invalid existence flags.")
        }
        if ($snapshot.Exists -and [string]::IsNullOrWhiteSpace([string]$snapshot.Kind)) {
            [void]$errors.Add("Registry snapshot '$name' has no value kind.")
        }
    }
    if ($State.FxComposite.Exists -and [string]$State.FxComposite.Kind -ne 'MultiString') {
        [void]$errors.Add('Composite EFX snapshot is not REG_MULTI_SZ.')
    }

    $expectedNames = @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')
    $fileEntries = @($State.InstallFiles)
    if ($fileEntries.Count -ne $expectedNames.Count) {
        [void]$errors.Add('Installer support-file snapshot does not contain exactly the expected four entries.')
    }
    foreach ($name in $expectedNames) {
        $matches = @($fileEntries | Where-Object { [string]$_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            [void]$errors.Add("Installer support-file snapshot '$name' is missing or duplicated.")
            continue
        }
        $entry = $matches[0]
        if ($entry.Existed -isnot [bool]) {
            [void]$errors.Add("Installer support-file snapshot '$name' has an invalid Existed flag.")
        } elseif ($entry.Existed) {
            Test-MBFileSnapshot -Path ([string]$entry.Backup) -Sha256 ([string]$entry.Sha256) -Root (Join-Path $TransactionDirectory 'install-files') -Label "Support file $name" -Errors $errors
        }
    }

    if ($State.ShortcutExisted) {
        Test-MBFileSnapshot -Path ([string]$State.ShortcutBackup) -Sha256 ([string]$State.ShortcutBackupSha256) -Root $TransactionDirectory -Label 'Desktop shortcut' -Errors $errors
    }

    if ($State.DllReplacementStarted -isnot [bool]) {
        [void]$errors.Add('DLL replacement state must be Boolean.')
    }
    if ([string]$State.DllNewSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [void]$errors.Add('Verified package DLL SHA-256 is missing or malformed.')
    }
    if ($State.DllExisted) {
        if ([string]$State.DllOriginalSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            [void]$errors.Add('Original installed DLL SHA-256 is missing or malformed.')
        }
    } elseif ($null -ne $State.DllOriginalSha256 -and -not [string]::IsNullOrWhiteSpace([string]$State.DllOriginalSha256)) {
        [void]$errors.Add('Original DLL SHA-256 must be empty when no installed DLL existed.')
    }
    if ($State.DllReplacementStarted -and $State.DllExisted) {
        if ($State.PSObject.Properties.Name -notcontains 'DllBackupPath' -or $State.PSObject.Properties.Name -notcontains 'DllBackupSha256') {
            [void]$errors.Add('DLL replacement started but durable backup provenance is incomplete.')
        } else {
            Test-MBFileSnapshot -Path ([string]$State.DllBackupPath) -Sha256 ([string]$State.DllBackupSha256) -Root (Join-Path $DataDirectory 'dll-backups') -Label 'Previous DLL' -Errors $errors
            if (-not [string]::Equals([string]$State.DllBackupSha256,[string]$State.DllOriginalSha256,[StringComparison]::OrdinalIgnoreCase)) {
                [void]$errors.Add('DLL backup hash differs from the original installed DLL snapshot.')
            }
        }
    }

    foreach ($com in @(
        [pscustomobject]@{ Name='CLSID'; Existed=[bool]$State.ClsidRegExisted; Path=[string]$State.ClsidRegBackup; Hash=[string]$State.ClsidRegSha256; ExpectedName='clsid.reg' },
        [pscustomobject]@{ Name='AudioEngine APO'; Existed=[bool]$State.ApoRegExisted; Path=[string]$State.ApoRegBackup; Hash=[string]$State.ApoRegSha256; ExpectedName='audioengine-apo.reg' }
    )) {
        if ($com.Existed) {
            $expectedPath = [IO.Path]::GetFullPath((Join-Path $TransactionDirectory $com.ExpectedName))
            $recordedPath = ''
            try { $recordedPath = [IO.Path]::GetFullPath($com.Path) } catch {}
            if (-not [string]::Equals($recordedPath,$expectedPath,[StringComparison]::OrdinalIgnoreCase)) {
                [void]$errors.Add("$($com.Name) COM export path does not match its fixed transaction-owned filename.")
                continue
            }
            Test-MBFileSnapshot -Path $com.Path -Sha256 $com.Hash -Root $TransactionDirectory -Label "$($com.Name) COM export" -Errors $errors
            $registryHiveName = if ($RegistryHive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
            $expectedRegistryRoot = if ($com.Name -eq 'CLSID') {
                "$registryHiveName\SOFTWARE\Classes\CLSID\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}"
            } else {
                "$registryHiveName\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}"
            }
            if (-not (Test-MBRegistryExportBounds -SnapshotPath $com.Path -ExpectedRegistryRoot $expectedRegistryRoot)) {
                [void]$errors.Add("$($com.Name) COM export has an invalid header, missing fixed root, or keys outside the MicBridge registration.")
            }
            if (Test-Path -LiteralPath $com.Path -PathType Leaf) {
                $item = Get-Item -LiteralPath $com.Path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [void]$errors.Add("$($com.Name) COM export must not be a reparse point.")
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = @($errors)
        ReplaySafe = ($errors.Count -eq 0)
    }
}

function Restore-MBRegistryExportSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$TemporaryDirectory
    )
    if ($RegistryPath -notmatch '^(HKLM|HKCU)\\') {
        throw 'Registry restore path must be an explicit HKLM or HKCU key.'
    }
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Registry snapshot SHA-256 is missing or malformed.'
    }
    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
        throw 'Registry snapshot file is missing.'
    }
    if (-not (Test-Path -LiteralPath $TemporaryDirectory -PathType Container)) {
        throw 'Registry verification directory is missing.'
    }
    $snapshotItem = Get-Item -LiteralPath $SnapshotPath -Force -ErrorAction Stop
    if (($snapshotItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Registry snapshot must not be a reparse point.'
    }
    $actualSnapshotHash = (Get-FileHash -LiteralPath $SnapshotPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualSnapshotHash,$ExpectedSha256,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Registry snapshot hash mismatch; refusing to import untrusted recovery data.'
    }

    $registryHive = if ($RegistryPath.StartsWith('HKLM\',[StringComparison]::OrdinalIgnoreCase)) { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
    $registrySubKey = $RegistryPath.Substring(5)
    $expectedRoot = "$registryHive\$registrySubKey"
    $snapshotText = [IO.File]::ReadAllText($SnapshotPath)
    $snapshotKeys = @($snapshotText -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match "^\[HKEY_.+\]$" } | ForEach-Object { $_.Substring(1, $_.Length - 2) })
    if ($snapshotKeys.Count -eq 0 -or -not ($snapshotKeys -contains $expectedRoot)) {
        throw 'Registry snapshot does not contain the exact requested root key.'
    }
    foreach ($snapshotKey in $snapshotKeys) {
        if (-not ($snapshotKey.Equals($expectedRoot,[StringComparison]::OrdinalIgnoreCase) -or $snapshotKey.StartsWith($expectedRoot + '\',[StringComparison]::OrdinalIgnoreCase))) {
            throw 'Registry snapshot contains a key outside the requested recovery root.'
        }
    }

    & reg.exe import $SnapshotPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe import failed for the fixed recovery target '$RegistryPath' (exit $LASTEXITCODE)."
    }
    if (-not (Test-MBRegistryExportSnapshot -RegistryPath $RegistryPath -ExpectedSha256 $ExpectedSha256 -TemporaryDirectory $TemporaryDirectory)) {
        throw "Registry restore verification failed for '$RegistryPath'."
    }
    return $true
}

function Test-MBInstallRollbackTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId,
        [Parameter(Mandatory)][string[]]$ExpectedStepIds,
        [ValidateSet('HKLM','HKCU')][string]$RegistryHive = 'HKLM'
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $journalModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
    try {
        if (-not (Test-Path -LiteralPath $journalModule -PathType Leaf)) {
            throw 'Recovery journal module is missing.'
        }
        Import-Module -Name $journalModule -Force -Global -ErrorAction Stop

        $expectedJournal = [IO.Path]::GetFullPath((Join-Path $TransactionDirectory 'rollback-recovery.json'))
        $expectedState = [IO.Path]::GetFullPath((Join-Path $TransactionDirectory 'state.json'))
        if (-not [string]::Equals([IO.Path]::GetFullPath($JournalPath),$expectedJournal,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Journal path does not match the fixed transaction-owned filename.'
        }
        if (-not [string]::Equals([IO.Path]::GetFullPath($StatePath),$expectedState,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Snapshot path does not match the fixed transaction-owned filename.'
        }
        foreach ($file in @($JournalPath,$StatePath)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                -not (Test-MBNoReparsePath -Path $file -StopAt $TransactionDirectory)) {
                throw "Transaction metadata is missing or traverses a reparse point: $file"
            }
        }

        $journal = Read-MBRecoveryJournal -Path $JournalPath -ExpectedOperation InstallRollback -ExpectedDeviceId $ExpectedDeviceId -ExpectedStepIds $ExpectedStepIds -ErrorAction Stop
        $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $snapshot = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $TransactionDirectory -DataDirectory $DataDirectory -ExpectedDeviceId $ExpectedDeviceId -RegistryHive $RegistryHive
        if (-not $snapshot.IsValid -or -not $snapshot.ReplaySafe) {
            foreach ($errorText in @($snapshot.Errors)) { [void]$errors.Add([string]$errorText) }
        }
        $stateTransactionId = [guid]::Empty
        $journalTransactionId = [guid]::Empty
        if (-not [guid]::TryParse([string]$state.TransactionId,[ref]$stateTransactionId) -or
            -not [guid]::TryParse([string]$journal.TransactionId,[ref]$journalTransactionId) -or
            $stateTransactionId -ne $journalTransactionId) {
            [void]$errors.Add('Journal and snapshot transaction identities do not match.')
        }
        return [pscustomobject]@{
            IsValid = ($errors.Count -eq 0)
            ReplaySafe = ($errors.Count -eq 0)
            Errors = @($errors)
            Journal = $journal
            State = $state
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
        return [pscustomobject]@{
            IsValid = $false
            ReplaySafe = $false
            Errors = @($errors)
            Journal = $null
            State = $null
        }
    }
}


Export-ModuleMember -Function Test-MBInstallRollbackSnapshot, Test-MBRegistryExportSnapshot, Restore-MBRegistryExportSnapshot, Test-MBInstallRollbackTransaction
