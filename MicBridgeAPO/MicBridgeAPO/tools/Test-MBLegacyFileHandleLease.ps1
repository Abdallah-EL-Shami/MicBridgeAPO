$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.LegacyFileHandleLease.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeHandleLease-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
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
        $wrongHashRejected = $false
        try {
            Open-MBLegacyExclusiveFileLease -CandidatePath $dll -InstallRoot $root -ExpectedSha256 ('0' * 64) | Out-Null
        } catch { $wrongHashRejected = $true }
        if (-not $wrongHashRejected) { throw 'FAIL: incorrect expected hash was accepted.' }
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

    $outside = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeOutside-' + [guid]::NewGuid().ToString('N') + '.dll')
    [IO.File]::WriteAllBytes($outside,[byte[]](8,6,4,2))
    try {
        $outsideHash = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
        $outsideRejected = $false
        try { Open-MBLegacyExclusiveFileLease -CandidatePath $outside -InstallRoot $root -ExpectedSha256 $outsideHash | Out-Null }
        catch { $outsideRejected = $true }
        if (-not $outsideRejected) { throw 'FAIL: candidate outside install root was accepted.' }
    } finally { Remove-Item -LiteralPath $outside -Force }

    Write-Host 'PASS: exclusive read handle pins file identity and blocks writers; wrong hash and out-of-root paths are rejected. No deletion occurs.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
