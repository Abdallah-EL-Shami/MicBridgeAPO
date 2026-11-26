Set-StrictMode -Version Latest

if (-not ('MicBridge.LegacyFileHandleLease.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;

namespace MicBridge.LegacyFileHandleLease {
    [StructLayout(LayoutKind.Sequential)]
    internal struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    internal static class Native {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        internal static extern SafeFileHandle CreateFile(
            string name, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        internal static extern uint GetFinalPathNameByHandle(
            SafeFileHandle handle, System.Text.StringBuilder path, uint length, uint flags);
    }

    public sealed class Lease : IDisposable {
        private SafeFileHandle handle;
        private FileStream stream;
        public string FinalPath { get; private set; }
        public string Sha256 { get; private set; }
        public string FileIdentity { get; private set; }
        public long Length { get; private set; }
        public bool IsOpen { get { return handle != null && !handle.IsClosed && !handle.IsInvalid; } }

        internal Lease(SafeFileHandle h, string finalPath, BY_HANDLE_FILE_INFORMATION info) {
            handle = h;
            FinalPath = finalPath;
            FileIdentity = info.VolumeSerialNumber.ToString("X8") + ":" +
                info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
            Length = ((long)info.FileSizeHigh << 32) | info.FileSizeLow;
            stream = new FileStream(handle, FileAccess.Read, 4096, false);
            using (SHA256 sha = SHA256.Create()) {
                byte[] digest = sha.ComputeHash(stream);
                Sha256 = BitConverter.ToString(digest).Replace("-", "");
            }
            stream.Position = 0;
        }

        public void Dispose() {
            if (stream != null) { stream.Dispose(); stream = null; }
            if (handle != null) { handle.Dispose(); handle = null; }
        }
    }

    public static class LeaseFactory {
        private const uint GENERIC_READ = 0x80000000;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_SHARE_ALL = 0x00000001 | 0x00000002 | 0x00000004;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;

        private static string FinalPath(SafeFileHandle h) {
            var b = new System.Text.StringBuilder(32768);
            uint n = Native.GetFinalPathNameByHandle(h, b, (uint)b.Capacity, 0);
            if (n == 0 || n >= b.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return b.ToString();
        }

        public static Lease OpenExclusiveRegularFile(string candidatePath, string installRoot,
                                                     string expectedSha256, string expectedIdentity) {
            string fullCandidate = Path.GetFullPath(candidatePath);
            string fullRoot = Path.GetFullPath(installRoot);
            using (SafeFileHandle root = Native.CreateFile(fullRoot, 0x80, FILE_SHARE_ALL, IntPtr.Zero,
                    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero)) {
                if (root.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                BY_HANDLE_FILE_INFORMATION ri;
                if (!Native.GetFileInformationByHandle(root, out ri)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                if ((ri.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (ri.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                    throw new InvalidOperationException("Install root is not a regular directory.");
                string rootFinal = FinalPath(root).TrimEnd('\\');
                SafeFileHandle file = Native.CreateFile(fullCandidate, GENERIC_READ, 0, IntPtr.Zero,
                    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
                if (file.IsInvalid) {
                    int error = Marshal.GetLastWin32Error(); file.Dispose();
                    throw new System.ComponentModel.Win32Exception(error);
                }
                try {
                    BY_HANDLE_FILE_INFORMATION fi;
                    if (!Native.GetFileInformationByHandle(file, out fi)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    if ((fi.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
                        throw new InvalidOperationException("Candidate is a directory or reparse point.");
                    string candidateFinal = FinalPath(file);
                    string prefix = rootFinal + "\\";
                    if (!candidateFinal.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Opened file handle resolves outside the audited installation root.");
                    var lease = new Lease(file, candidateFinal, fi);
                    file = null;
                    try {
                        if (!String.Equals(lease.Sha256, expectedSha256, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Opened file handle hash differs from signed approval.");
                        if (!String.IsNullOrEmpty(expectedIdentity) &&
                            !String.Equals(lease.FileIdentity, expectedIdentity, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Opened file identity differs from the approved identity.");
                        return lease;
                    } catch { lease.Dispose(); throw; }
                } finally { if (file != null) file.Dispose(); }
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Open-MBLegacyExclusiveFileLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [string]$ExpectedFileIdentity
    )
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Exclusive file-handle validation is supported only on Windows.'
    }
    $lease = [MicBridge.LegacyFileHandleLease.LeaseFactory]::OpenExclusiveRegularFile(
        $CandidatePath,$InstallRoot,$ExpectedSha256,$ExpectedFileIdentity)
    [pscustomobject]@{
        IsReadOnly=$true
        IsExecutionAuthorized=$false
        FinalHandleValidationPassed=$true
        FinalPath=$lease.FinalPath
        Sha256=$lease.Sha256
        FileIdentity=$lease.FileIdentity
        Length=$lease.Length
        Lease=$lease
        Note='Exclusive read lease held. No deletion, rename, registry change, or installation was performed.'
    }
}

function Close-MBLegacyExclusiveFileLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$LeaseResult)
    if ($null -eq $LeaseResult.Lease -or
        $LeaseResult.Lease -isnot [MicBridge.LegacyFileHandleLease.Lease]) {
        throw 'A valid MicBridge exclusive file lease result is required.'
    }
    $LeaseResult.Lease.Dispose()
}

Export-ModuleMember -Function Open-MBLegacyExclusiveFileLease,Close-MBLegacyExclusiveFileLease
