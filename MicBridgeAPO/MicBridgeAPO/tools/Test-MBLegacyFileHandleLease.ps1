$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyFileHandleLease.psm1') -Force

$sandboxParent = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeHandleLease-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $sandboxParent 'install-root'
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $dll = Join-Path $root 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll,[byte[]](1,3,5,7,9,11))
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $leaseResult = Open-MBLegacyExclusiveFileLease -CandidatePath $dll -InstallRoot $root -ExpectedSha256 $hash
    try {
        if (-not $leaseResult.FinalHandleValidationPassed -or $leaseResult.IsExecutionAuthorized) {
            throw 'FAIL: lease returned unsafe capability flags.'
        }
        if (-not $leaseResult.FileIdentity -or $leaseResult.Sha256 -ne $hash) {
            throw 'FAIL: opened-handle identity/hash missing or incorrect.'
        }
        $writeBlocked = $false
        try { [IO.File]::WriteAllBytes($dll,[byte[]](2,4,6)) } catch { $writeBlocked = $true }
        if (-not $writeBlocked) { throw 'FAIL: another writer modified a file while exclusive lease was held.' }
        $renameBlocked = $false
        $movedPath = Join-Path $root 'MicBridgeAPO.renamed.dll'
        try { [IO.File]::Move($dll,$movedPath) } catch { $renameBlocked = $true }
        if (-not $renameBlocked) {
            [IO.File]::Move($movedPath,$dll)
            throw 'FAIL: file was renamed while exclusive lease was held.'
        }
        $renamedRoot = $root + '.renamed'
        $directoryRenameBlocked = $false
        try { [IO.Directory]::Move($root,$renamedRoot) } catch { $directoryRenameBlocked = $true }
        if (-not $directoryRenameBlocked) {
            [IO.Directory]::Move($renamedRoot,$root)
            throw 'FAIL: install-root directory was renamed while directory pins were held.'
        }
        $renamedParent = $sandboxParent + '.renamed'
        $ancestorRenameBlocked = $false
        try { [IO.Directory]::Move($sandboxParent,$renamedParent) } catch { $ancestorRenameBlocked = $true }
        if (-not $ancestorRenameBlocked) {
            [IO.Directory]::Move($renamedParent,$sandboxParent)
            throw 'FAIL: ancestor directory was renamed while directory pins were held.'
        }

        # Pin an intermediate candidate directory too; it must not be renameable during the lease.
        $nested = Join-Path $root 'nested-candidate'
        New-Item -ItemType Directory -Path $nested | Out-Null
        $nestedFile = Join-Path $nested 'nested.dll'
        [IO.File]::WriteAllBytes($nestedFile,[byte[]](4,8,12,16))
        $nestedHash = (Get-FileHash -LiteralPath $nestedFile -Algorithm SHA256).Hash
        $nestedLease = Open-MBLegacyExclusiveFileLease -CandidatePath $nestedFile -InstallRoot $root -ExpectedSha256 $nestedHash
        try {
            $nestedRenameBlocked = $false
            try { [IO.Directory]::Move($nested,(Join-Path $root 'nested-renamed')) } catch { $nestedRenameBlocked = $true }
            if (-not $nestedRenameBlocked) {
                [IO.Directory]::Move((Join-Path $root 'nested-renamed'),$nested)
                throw 'FAIL: intermediate candidate directory was renamed while directory pins were held.'
            }
        } finally {
            Close-MBLegacyExclusiveFileLease -LeaseResult $nestedLease
        }
        $wrongHashRejected = $false
        try {
            Open-MBLegacyExclusiveFileLease -CandidatePath $dll -InstallRoot $root -ExpectedSha256 ('0' * 64) | Out-Null
        } catch { $wrongHashRejected = $true }
        if (-not $wrongHashRejected) { throw 'FAIL: incorrect expected hash was accepted.' }

        $wrongIdentityRejected = $false
        try {
            Open-MBLegacyExclusiveFileLease -CandidatePath $dll -InstallRoot $root -ExpectedSha256 $hash -ExpectedIdentity '00000000:0000000000000000' | Out-Null
        } catch { $wrongIdentityRejected = $_.Exception.Message -match 'identity differs' }
        if (-not $wrongIdentityRejected) { throw 'FAIL: incorrect approved file identity was accepted.' }

        # Failed hash/identity validation must release the exclusive file and directory handles.
        $reopenAfterRejectedApproval = $false
        $probe = $null
        try {
            $probe = [IO.File]::Open($dll,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $reopenAfterRejectedApproval = $true
        } finally { if ($probe) { $probe.Dispose() } }
        if (-not $reopenAfterRejectedApproval) {
            throw 'FAIL: rejected approval validation leaked an exclusive handle.'
        }
    } finally {
        Close-MBLegacyExclusiveFileLease -LeaseResult $leaseResult
    }

    # A second hard link makes path-based cleanup ambiguous even while one handle is exclusive.
    if (-not ('MicBridgeHandleLeaseHardLink.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MicBridgeHandleLeaseHardLink {
    public static class Native {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateHardLink(string newName, string existingName, IntPtr security);
    }
}
'@
    }
    $hardLink = Join-Path $root 'MicBridgeAPO-hardlink.dll'
    $hardLinkCreated = [MicBridgeHandleLeaseHardLink.Native]::CreateHardLink($hardLink,$dll,[IntPtr]::Zero)
    if ($hardLinkCreated) {
        $hardLinkRejected = $false
        try { Open-MBLegacyExclusiveFileLease -CandidatePath $dll -InstallRoot $root -ExpectedSha256 $hash | Out-Null }
        catch { $hardLinkRejected = $_.Exception.Message -match 'multiple hard links' }
        if (-not $hardLinkRejected) { throw 'FAIL: file with multiple hard links was not rejected.' }
        Remove-Item -LiteralPath $hardLink -Force
    } else {
        $win32 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "FAIL: could not create hard-link test fixture (Win32 $win32)."
    }

    # A junction whose target remains inside the install root must still be rejected.
    $targetDir = Join-Path $root 'real-subdir'
    $junctionDir = Join-Path $root 'junction-subdir'
    New-Item -ItemType Directory -Path $targetDir | Out-Null
    $junctionTargetFile = Join-Path $targetDir 'through-junction.dll'
    [IO.File]::WriteAllBytes($junctionTargetFile,[byte[]](9,7,5,3))
    $junctionHash = (Get-FileHash -LiteralPath $junctionTargetFile -Algorithm SHA256).Hash
    $mklinkOutput = & cmd.exe /d /c mklink /J "$junctionDir" "$targetDir" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "FAIL: could not create junction fixture: $mklinkOutput" }
    $junctionRejected = $false
    try {
        Open-MBLegacyExclusiveFileLease -CandidatePath (Join-Path $junctionDir 'through-junction.dll') -InstallRoot $root -ExpectedSha256 $junctionHash | Out-Null
    } catch { $junctionRejected = $_.Exception.Message -match 'reparse point' }
    if (-not $junctionRejected) { throw 'FAIL: candidate reached through an in-root junction was not rejected.' }
    Remove-Item -LiteralPath $junctionDir -Force

    $outside = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeOutside-' + [guid]::NewGuid().ToString('N') + '.dll')
    [IO.File]::WriteAllBytes($outside,[byte[]](8,6,4,2))
    try {
        $outsideHash = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
        $outsideRejected = $false
        try { Open-MBLegacyExclusiveFileLease -CandidatePath $outside -InstallRoot $root -ExpectedSha256 $outsideHash | Out-Null }
        catch { $outsideRejected = $true }
        if (-not $outsideRejected) { throw 'FAIL: candidate outside install root was accepted.' }
    } finally { Remove-Item -LiteralPath $outside -Force }

    Write-Host 'PASS: exclusive file and pinned ancestor/root/intermediate directory handles block writes/renames; hard links, junction traversal, wrong hashes/identities and out-of-root paths are rejected; rejected approvals release all handles. No deletion occurs.'
} finally {
    Remove-Item -LiteralPath $sandboxParent -Recurse -Force -ErrorAction SilentlyContinue
}
