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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [void]$Errors.Add("$Label snapshot file is missing.")
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

function Test-MBInstallRollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TransactionDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][guid]$ExpectedDeviceId
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $required = @(
        'DeviceId','FxEffect','FxAssociation','FxComposite','DevSddl','FxSddl',
        'FxKeyExisted','ClsidRegExisted','ApoRegExisted','DllExisted',
        'DllOriginalSha256','ClsidRegExisted','ClsidRegBackup','ClsidRegSha256','ApoRegExisted','ApoRegBackup','ApoRegSha256','IniExisted','ControlExisted','DataDirSddl',
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

    if ($State.PSObject.Properties.Name -contains 'DllReplacementStarted' -and $State.DllReplacementStarted) {
        if ($State.DllExisted) {
            if ($State.PSObject.Properties.Name -notcontains 'DllBackupPath' -or $State.PSObject.Properties.Name -notcontains 'DllBackupSha256') {
                [void]$errors.Add('DLL replacement started but durable backup provenance is incomplete.')
            } else {
                Test-MBFileSnapshot -Path ([string]$State.DllBackupPath) -Sha256 ([string]$State.DllBackupSha256) -Root (Join-Path $DataDirectory 'dll-backups') -Label 'Previous DLL' -Errors $errors
            }
        }
    }

    foreach ($com in @(
        [pscustomobject]@{ Name='CLSID'; Existed=[bool]$State.ClsidRegExisted; Path=[string]$State.ClsidRegBackup; Hash=[string]$State.ClsidRegSha256 },
        [pscustomobject]@{ Name='AudioEngine APO'; Existed=[bool]$State.ApoRegExisted; Path=[string]$State.ApoRegBackup; Hash=[string]$State.ApoRegSha256 }
    )) {
        if ($com.Existed) {
            Test-MBFileSnapshot -Path $com.Path -Sha256 $com.Hash -Root $TransactionDirectory -Label "$($com.Name) COM export" -Errors $errors
        }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = @($errors)
        ReplaySafe = ($errors.Count -eq 0)
    }
}

Export-ModuleMember -Function Test-MBInstallRollbackSnapshot
