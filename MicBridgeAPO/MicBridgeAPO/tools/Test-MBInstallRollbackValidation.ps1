$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeRollbackValidation-' + [guid]::NewGuid().ToString('N'))
$tx = Join-Path $root 'transactions-test'
$data = Join-Path $root 'data'
$files = Join-Path $tx 'install-files'
$dlls = Join-Path $data 'dll-backups'
$registryProviderPath = $null
$restoreProviderPath = $null
New-Item -ItemType Directory -Force -Path $files,$dlls | Out-Null
try {
    $device = [guid]::NewGuid()
    $fileEntries = @()
    foreach ($name in @('MicBridgeUI.ps1','MicBridgeUI.bat','uninstall.ps1','uninstall.bat')) {
        $path = Join-Path $files $name
        [IO.File]::WriteAllText($path,"snapshot:$name")
        $fileEntries += [pscustomobject]@{ Name=$name; Existed=$true; Backup=$path; Sha256=(Get-FileHash $path -Algorithm SHA256).Hash }
    }
    $shortcut = Join-Path $tx 'MicBridge.lnk'
    [IO.File]::WriteAllText($shortcut,'shortcut')
    $state = [pscustomobject]@{
        DeviceId=$device.ToString('D')
        TransactionId=([guid]::NewGuid().ToString('D'))
        FxEffect=[pscustomobject]@{KeyExists=$true;Exists=$false;Kind='String';Value=$null}
        FxAssociation=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='String';Value='{00000000-0000-0000-0000-000000000000}'}
        FxComposite=[pscustomobject]@{KeyExists=$true;Exists=$true;Kind='MultiString';Value=@('{11111111-1111-1111-1111-111111111111}')}
        DevSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        FxKeyExisted=$true
        ClsidRegExisted=$false
        ClsidRegBackup=$null
        ClsidRegSha256=$null
        ApoRegExisted=$false
        ApoRegBackup=$null
        ApoRegSha256=$null
        DllExisted=$false
        DllOriginalSha256=$null
        DllNewSha256=('A' * 64)
        DllReplacementStarted=$false
        IniExisted=$false
        ControlExisted=$false
        DataDirSddl='O:SYG:SYD:PAI(A;;FA;;;SY)'
        ControlSddl=$null
        InstallFiles=$fileEntries
        ShortcutExisted=$true
        ShortcutBackup=$shortcut
        ShortcutBackupSha256=(Get-FileHash $shortcut -Algorithm SHA256).Hash
        InstallDirExisted=$false
    }

    $valid = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if (-not $valid.IsValid -or -not $valid.ReplaySafe) { throw "FAIL: valid fixture rejected: $($valid.Errors -join '; ')" }

    # A reparse point at the transaction root must be rejected even if no
    # snapshot entry currently requires an individual backup file.
    $rootTarget = Join-Path $root 'transaction-root-target'
    $rootLink = Join-Path $root 'transaction-root-link'
    New-Item -ItemType Directory -Force -Path $rootTarget | Out-Null
    $rootJunctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $rootLink -Target $rootTarget -ErrorAction Stop | Out-Null
        $rootJunctionCreated = $true
    } catch {
        Write-Host 'INFO: Transaction-root junction test skipped; junction creation unavailable.'
    }
    if ($rootJunctionCreated) {
        $rootRejected = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $rootLink -DataDirectory $data -ExpectedDeviceId $device
        if ($rootRejected.IsValid -or -not ($rootRejected.Errors -match 'Transaction directory')) {
            throw 'FAIL: rollback validator accepted a reparse-point transaction root'
        }
        Remove-Item -LiteralPath $rootLink -Force
    }

    $missingNewDllHash = $state.PSObject.Copy()
    $missingNewDllHash.DllNewSha256 = 'bad-hash'
    $invalidNewDllHash = Test-MBInstallRollbackSnapshot -State $missingNewDllHash -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($invalidNewDllHash.IsValid -or -not ($invalidNewDllHash.Errors -match 'package DLL SHA-256')) { throw 'FAIL: malformed new DLL hash accepted' }

    $wrongDevice = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId ([guid]::NewGuid())
    if ($wrongDevice.IsValid) { throw 'FAIL: wrong device identity accepted' }

    $wrongTransaction = $state.PSObject.Copy()
    $wrongTransaction.TransactionId = 'not-a-guid'
    $invalidTransaction = Test-MBInstallRollbackSnapshot -State $wrongTransaction -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($invalidTransaction.IsValid -or -not ($invalidTransaction.Errors -match 'transaction identity')) { throw 'FAIL: invalid transaction identity accepted' }

    $originalBackup = $state.InstallFiles[0].Backup
    $state.InstallFiles[0].Backup = Join-Path $root 'outside.ps1'
    $pathEscape = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($pathEscape.IsValid -or -not ($pathEscape.Errors -match 'escapes')) { throw 'FAIL: path escape accepted' }
    $state.InstallFiles[0].Backup = $originalBackup

    # A lexically in-root backup can still escape through a junction/reparse parent.
    # Exercise the production validator when the Windows runner permits junction creation.
    $junctionTarget = Join-Path $root 'junction-target'
    $junctionPath = Join-Path $files 'redirected'
    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    $junctionFile = Join-Path $junctionTarget 'backup.ps1'
    [IO.File]::WriteAllText($junctionFile,'junction-escape')
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Host 'INFO: Junction creation unavailable; reparse-parent test skipped.'
    }
    if ($junctionCreated) {
        $state.InstallFiles[0].Backup = Join-Path $junctionPath 'backup.ps1'
        $state.InstallFiles[0].Sha256 = (Get-FileHash $junctionFile -Algorithm SHA256).Hash
        $junctionRejected = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
        if ($junctionRejected.IsValid -or -not ($junctionRejected.Errors -match 'reparse point')) {
            throw 'FAIL: rollback validator accepted a backup path redirected by a junction'
        }
        $state.InstallFiles[0].Backup = $originalBackup
        $state.InstallFiles[0].Sha256 = (Get-FileHash $originalBackup -Algorithm SHA256).Hash
        Remove-Item -LiteralPath $junctionPath -Force
    }

    [IO.File]::AppendAllText($originalBackup,'tampered')
    $hashMismatch = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($hashMismatch.IsValid -or -not ($hashMismatch.Errors -match 'hash')) { throw 'FAIL: modified backup accepted' }
    [IO.File]::WriteAllText($originalBackup,'snapshot:MicBridgeUI.ps1')
    $state.InstallFiles[0].Sha256 = (Get-FileHash $originalBackup -Algorithm SHA256).Hash

    $clsidExport = Join-Path $tx 'clsid.reg'
    [IO.File]::WriteAllText($clsidExport,'Windows Registry Editor Version 5.00')
    $state.ClsidRegExisted = $true
    $state.ClsidRegBackup = $clsidExport
    $state.ClsidRegSha256 = (Get-FileHash $clsidExport -Algorithm SHA256).Hash
    $wrongComPath = $state.ClsidRegBackup
    $state.ClsidRegBackup = Join-Path $tx 'other.reg'
    $wrongPath = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($wrongPath.IsValid -or -not ($wrongPath.Errors -match 'fixed transaction-owned filename')) { throw 'FAIL: alternate COM export path accepted' }
    $state.ClsidRegBackup = $wrongComPath
    $comValid = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if (-not $comValid.IsValid) { throw "FAIL: valid transaction-bound COM export rejected: $($comValid.Errors -join '; ')" }

    $exportAction = {
        param($registryPath,$outputPath)
        Copy-Item -LiteralPath $clsidExport -Destination $outputPath -Force
        return $true
    }.GetNewClosure()
    $registryMatchesSnapshot = Test-MBRegistryExportSnapshot -RegistryPath 'HKLM\SOFTWARE\Classes\CLSID\Example' -ExpectedSha256 $state.ClsidRegSha256 -TemporaryDirectory $tx -ExportAction $exportAction
    if (-not $registryMatchesSnapshot) { throw 'FAIL: matching restored COM registry export was rejected' }

    [IO.File]::AppendAllText($clsidExport,'tampered')
    $comTampered = Test-MBInstallRollbackSnapshot -State $state -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device
    if ($comTampered.IsValid -or -not ($comTampered.Errors -match 'COM export snapshot hash')) { throw 'FAIL: modified COM export accepted' }
    $registryTampered = Test-MBRegistryExportSnapshot -RegistryPath 'HKLM\SOFTWARE\Classes\CLSID\Example' -ExpectedSha256 $state.ClsidRegSha256 -TemporaryDirectory $tx -ExportAction $exportAction
    if ($registryTampered) { throw 'FAIL: modified restored COM registry contents accepted' }

    # Exercise the production reg.exe export path against an isolated HKCU test key.
    $registryLeaf = 'MicBridgeRollbackValidation-' + [guid]::NewGuid().ToString('N')
    $registryProviderPath = "Registry::HKEY_CURRENT_USER\Software\$registryLeaf"
    $registryPath = "HKCU\Software\$registryLeaf"
    New-Item -Path $registryProviderPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $registryProviderPath -Name 'SnapshotValue' -Value 'before' -Type String
    $realExport = Join-Path $tx 'real-registry-export.reg'
    & reg.exe export $registryPath $realExport /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $realExport -PathType Leaf)) { throw 'FAIL: could not export isolated HKCU registry fixture' }
    $realExportHash = (Get-FileHash -LiteralPath $realExport -Algorithm SHA256).Hash
    $realRegistryMatches = Test-MBRegistryExportSnapshot -RegistryPath $registryPath -ExpectedSha256 $realExportHash -TemporaryDirectory $tx
    if (-not $realRegistryMatches) { throw 'FAIL: real reg.exe export did not match its saved snapshot' }
    Set-ItemProperty -LiteralPath $registryProviderPath -Name 'SnapshotValue' -Value 'after' -Type String
    $realRegistryTampered = Test-MBRegistryExportSnapshot -RegistryPath $registryPath -ExpectedSha256 $realExportHash -TemporaryDirectory $tx
    if ($realRegistryTampered) { throw 'FAIL: real reg.exe export accepted modified registry contents' }


    # Exercise the production restore primitive against an isolated HKCU key.
    $restoreLeaf = 'MicBridgeRollbackRestore-' + [guid]::NewGuid().ToString('N')
    $restoreProviderPath = "Registry::HKEY_CURRENT_USER\Software\$restoreLeaf"
    $restoreRegistryPath = "HKCU\Software\$restoreLeaf"
    $restoreSnapshot = Join-Path $tx 'restore-fixture.reg'
    New-Item -Path $restoreProviderPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $restoreProviderPath -Name 'OriginalValue' -Value 'before' -Type String
    & reg.exe export $restoreRegistryPath $restoreSnapshot /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'FAIL: could not export isolated HKCU restore fixture' }
    $restoreHash = (Get-FileHash -LiteralPath $restoreSnapshot -Algorithm SHA256).Hash
    Set-ItemProperty -LiteralPath $restoreProviderPath -Name 'OriginalValue' -Value 'after' -Type String
    Restore-MBRegistryExportSnapshot -RegistryPath $restoreRegistryPath -SnapshotPath $restoreSnapshot -ExpectedSha256 $restoreHash -TemporaryDirectory $tx | Out-Null
    $restoredValue = (Get-ItemProperty -LiteralPath $restoreProviderPath -Name 'OriginalValue').OriginalValue
    if ($restoredValue -ne 'before') { throw 'FAIL: registry restore primitive did not restore the original HKCU value' }
    try {
        Restore-MBRegistryExportSnapshot -RegistryPath 'HKLM\\SOFTWARE\\Classes\\CLSID\\MustNotTouch' -SnapshotPath $restoreSnapshot -ExpectedSha256 ('0' * 64) -TemporaryDirectory $tx
        throw 'FAIL: registry restore primitive accepted a mismatched snapshot hash'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: registry restore primitive accepted a mismatched snapshot hash') { throw }
    }
    Remove-Item -LiteralPath $restoreProviderPath -Recurse -Force -ErrorAction SilentlyContinue

    # Kill a separate PowerShell process after importing a COM-style registry
    # snapshot but before the recovery journal can persist Completed.
    $recoveryModule = Join-Path $PSScriptRoot 'MicBridge.RecoveryJournal.psm1'
    Import-Module $recoveryModule -Force
    $crashLeaf = 'MicBridgeRollbackCrash-' + [guid]::NewGuid().ToString('N')
    $crashProviderPath = "Registry::HKEY_CURRENT_USER\Software\$crashLeaf"
    $crashRegistryPath = "HKCU\Software\$crashLeaf"
    $crashSnapshot = Join-Path $tx 'crash-registry.reg'
    New-Item -Path $crashProviderPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $crashProviderPath -Name 'OriginalValue' -Value 'before' -Type String
    & reg.exe export $crashRegistryPath $crashSnapshot /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'FAIL: could not export crash-recovery registry fixture' }
    $crashHash = (Get-FileHash -LiteralPath $crashSnapshot -Algorithm SHA256).Hash
    Set-ItemProperty -LiteralPath $crashProviderPath -Name 'OriginalValue' -Value 'after' -Type String
    $crashJournal = Join-Path $tx 'registry-crash-resume.json'
    $crashDevice = [guid]::NewGuid()
    New-MBRecoveryJournal -Path $crashJournal -Operation InstallRollback -DeviceId $crashDevice -StepIds @('RestoreCom') | Out-Null
    $childScript = Join-Path $tx 'registry-crash-child.ps1'
    $childSource = @'
param([string]$RecoveryModule,[string]$ValidationModule,[string]$Journal,[string]$RegistryPath,[string]$Snapshot,[string]$Hash,[string]$TemporaryDirectory,[string]$Device)
$ErrorActionPreference = 'Stop'
Import-Module $RecoveryModule -Force
Import-Module $ValidationModule -Force
$action = {
    Restore-MBRegistryExportSnapshot -RegistryPath $RegistryPath -SnapshotPath $Snapshot -ExpectedSha256 $Hash -TemporaryDirectory $TemporaryDirectory | Out-Null
    [Environment]::FailFast('Injected process death after COM registry restore side effect')
}.GetNewClosure()
$verify = { Test-MBRegistryExportSnapshot -RegistryPath $RegistryPath -ExpectedSha256 $Hash -TemporaryDirectory $TemporaryDirectory }.GetNewClosure()
Invoke-MBRecoveryStep -Path $Journal -StepId 'RestoreCom' -ExpectedOperation InstallRollback -ExpectedDeviceId ([guid]$Device) -ExpectedStepIds @('RestoreCom') -Action $action -Verify $verify
'@
    [IO.File]::WriteAllText($childScript,$childSource,(New-Object Text.UTF8Encoding($false)))
    $childProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,
        $recoveryModule,(Join-Path $PSScriptRoot 'MicBridge.InstallRollbackValidation.psm1'),
        $crashJournal,$crashRegistryPath,$crashSnapshot,$crashHash,$tx,$crashDevice.ToString('D')
    ) -Wait -PassThru
    if ($childProcess.ExitCode -eq 0) { throw 'FAIL: COM registry crash-injection child exited successfully' }
    $interruptedRegistry = Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreCom')
    if ($interruptedRegistry.Steps[0].State -ne 'Running' -or
        -not (Test-MBRegistryExportSnapshot -RegistryPath $crashRegistryPath -ExpectedSha256 $crashHash -TemporaryDirectory $tx)) {
        throw 'FAIL: COM registry restore was not durable after process interruption'
    }
    Invoke-MBRecoveryStep -Path $crashJournal -StepId 'RestoreCom' -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreCom') -Action { throw 'COM registry import repeated after fresh-process recovery' } -Verify { Test-MBRegistryExportSnapshot -RegistryPath $crashRegistryPath -ExpectedSha256 $crashHash -TemporaryDirectory $tx }
    $resumedRegistry = Read-MBRecoveryJournal -Path $crashJournal -ExpectedOperation InstallRollback -ExpectedDeviceId $crashDevice -ExpectedStepIds @('RestoreCom')
    if ($resumedRegistry.Steps[0].State -ne 'Completed' -or $resumedRegistry.Steps[0].Attempts -ne 1) {
        throw 'FAIL: fresh-process COM recovery did not complete without repeating registry import'
    }
    Remove-Item -LiteralPath $crashProviderPath -Recurse -Force -ErrorAction SilentlyContinue

    # Validate the durable journal and state as one transaction before any replay.
    $preflightJournalPath = Join-Path $tx 'rollback-recovery.json'
    $preflightSteps = @('RestoreEndpointFxValues','RestoreEndpointAcl','RestorePreviousInstallState')
    $preflightJournal = New-MBRecoveryJournal -Path $preflightJournalPath -Operation InstallRollback -DeviceId $device -StepIds $preflightSteps
    $state.TransactionId = $preflightJournal.TransactionId
    [IO.File]::WriteAllText((Join-Path $tx 'state.json'),(ConvertTo-Json -InputObject $state -Depth 20),(New-Object Text.UTF8Encoding($false)))
    $preflight = Test-MBInstallRollbackTransaction -JournalPath $preflightJournalPath -StatePath (Join-Path $tx 'state.json') -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device -ExpectedStepIds $preflightSteps
    if (-not $preflight.IsValid -or -not $preflight.ReplaySafe) {
        throw "FAIL: valid durable transaction preflight rejected: $($preflight.Errors -join '; ')"
    }
    $state.TransactionId = [guid]::NewGuid().ToString('D')
    [IO.File]::WriteAllText((Join-Path $tx 'state.json'),(ConvertTo-Json -InputObject $state -Depth 20),(New-Object Text.UTF8Encoding($false)))
    $mismatchedPreflight = Test-MBInstallRollbackTransaction -JournalPath $preflightJournalPath -StatePath (Join-Path $tx 'state.json') -TransactionDirectory $tx -DataDirectory $data -ExpectedDeviceId $device -ExpectedStepIds $preflightSteps
    if ($mismatchedPreflight.IsValid -or -not ($mismatchedPreflight.Errors -match 'transaction identities do not match')) {
        throw 'FAIL: preflight accepted a state snapshot from a different transaction'
    }

    Write-Host 'PASS: rollback snapshot identity, path confinement, file hashes, transaction-bound COM exports, mock registry verification, and real HKCU export verification and fresh-process COM crash recovery'
} finally {
    if ($registryProviderPath -and (Test-Path -LiteralPath $registryProviderPath)) { Remove-Item -LiteralPath $registryProviderPath -Recurse -Force -ErrorAction SilentlyContinue }
    if ($restoreProviderPath -and (Test-Path -LiteralPath $restoreProviderPath)) { Remove-Item -LiteralPath $restoreProviderPath -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
