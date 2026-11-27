Set-StrictMode -Version Latest

function Get-MBReceiptCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Get-MBReceiptEntropy {
    param([Parameter(Mandatory)][string]$ReceiptPath)
    $canonical = Get-MBReceiptCanonicalPath -Path $ReceiptPath
    $bytes = [Text.Encoding]::UTF8.GetBytes("MicBridgeAPO.InstallReceipt.v1|$canonical")
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ,$sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Test-MBReceiptRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Label must be a regular non-reparse-point file."
    }
    return [IO.Path]::GetFullPath($Path)
}

function Set-MBReceiptRestrictedAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($sid in @($system,$admins,$current)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-MBInstallTransactionReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProductVersion,
        [Parameter(Mandatory)][string]$ReleaseManifestSha256,
        [Parameter(Mandatory)][string]$SignerThumbprint,
        [Parameter(Mandatory)][object[]]$InstalledFiles,
        [Parameter(Mandatory)][guid]$ReleaseManifestTransactionId,
        [guid]$TransactionId = [guid]::Empty,
        [string]$BaselineEvidenceSha256
    )
    Add-Type -AssemblyName System.Security
    $receiptFull = Get-MBReceiptCanonicalPath -Path $ReceiptPath
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Install root must be a real directory, not a reparse point.'
    }
    $root = Get-MBReceiptCanonicalPath -Path $InstallRoot
    if ([IO.Path]::GetPathRoot($receiptFull) -ne [IO.Path]::GetPathRoot($root)) {
        # Receipt and install files may reside on different volumes; this is informational only.
    }
    if ($ReleaseManifestSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Release manifest SHA-256 is invalid.' }
    if ($SignerThumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Signer thumbprint is invalid.' }
    if ([string]::IsNullOrWhiteSpace($ProductVersion)) { throw 'Product version is required.' }
    if ($InstalledFiles.Count -lt 1) { throw 'At least one installed file is required.' }
    if ($BaselineEvidenceSha256 -and $BaselineEvidenceSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Baseline evidence SHA-256 is invalid.' }

    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $InstalledFiles) {
        $relative = [string]$record.RelativePath
        $expected = [string]$record.Sha256
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.\.?([\\/]|$)' -or $relative.Contains(':') -or
            $expected -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Installed-file receipt contains an unsafe path or invalid SHA-256.' }
        $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Installed-file receipt path escapes the install root.'
        }
        if (-not $seen.Add($full)) { throw 'Installed-file receipt contains a duplicate path.' }
        $cursor = $root
        $parts = $relative -split '[\\/]'
        for ($i=0; $i -lt $parts.Count; $i++) {
            $cursor = Join-Path $cursor $parts[$i]
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installed-file receipt path traverses a reparse point: $relative" }
            if ($i -lt ($parts.Count-1) -and -not $entry.PSIsContainer) { throw "Installed-file parent is not a directory: $relative" }
            if ($i -eq ($parts.Count-1) -and $entry.PSIsContainer) { throw "Installed-file record resolves to a directory: $relative" }
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not $actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { throw "Installed-file hash does not match receipt input: $relative" }
        $records.Add([pscustomobject]@{RelativePath=$relative.Replace('\','/');Sha256=$actual})
    }

    $parent = Split-Path -Parent $receiptFull
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Receipt parent directory must already exist.' }
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Receipt parent directory cannot be a reparse point.' }
    if (Test-Path -LiteralPath $receiptFull) { throw 'An install transaction receipt already exists; refusing to overwrite history.' }

    if ($ReleaseManifestTransactionId -eq [guid]::Empty) { throw 'Signed release manifest transaction ID is required.' }
    if ($TransactionId -eq [guid]::Empty) { $TransactionId = [guid]::NewGuid() }
    $payload = [ordered]@{
        SchemaVersion=1
        ProductId='MicBridgeAPO'
        TransactionId=$TransactionId.ToString()
        ReleaseManifestTransactionId=$ReleaseManifestTransactionId.ToString()
        ProductVersion=$ProductVersion
        ReleaseManifestSha256=$ReleaseManifestSha256.ToUpperInvariant()
        SignerThumbprint=$SignerThumbprint.ToUpperInvariant()
        InstallRoot=$root
        CreatedUtc=[DateTime]::UtcNow.ToString('o')
        BaselineEvidenceSha256=$(if ($BaselineEvidenceSha256) { $BaselineEvidenceSha256.ToUpperInvariant() } else { $null })
        InstalledFiles=@($records.ToArray())
    }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$payload) -Depth 8 -Compress
    $plain = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $entropy = Get-MBReceiptEntropy -ReceiptPath $receiptFull
    $protected = $null
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($receiptFull) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $stream = New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($protected,0,$protected.Length);$stream.Flush($true) } finally { $stream.Dispose() }
        Set-MBReceiptRestrictedAcl -Path $temp
        [IO.File]::Move($temp,$receiptFull)
        Set-MBReceiptRestrictedAcl -Path $receiptFull
    } finally {
        [Array]::Clear($plain,0,$plain.Length)
        if ($entropy) { [Array]::Clear($entropy,0,$entropy.Length) }
        if ($protected) { [Array]::Clear($protected,0,$protected.Length) }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Created=$true
        TransactionId=$payload.TransactionId
        ReleaseManifestTransactionId=$payload.ReleaseManifestTransactionId
        ReceiptPath=$receiptFull
        ReceiptProtection='DPAPI-LocalMachine'
        InstalledFileCount=$records.Count
        OwnershipProven=$false
        ComOwnershipProven=$false
        IsExecutionAuthorized=$false
        Note='Machine-bound tamper-evident installation record. It is not a release signature, does not prove pre-install baseline ownership, and does not authorize cleanup.'
    }
}

function Test-MBInstallTransactionReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReceiptPath,[switch]$VerifyInstalledFiles)
    Add-Type -AssemblyName System.Security
    $receiptFull = Test-MBReceiptRegularFile -Path $ReceiptPath -Label 'Install transaction receipt'
    $bytes = [IO.File]::ReadAllBytes($receiptFull)
    $entropy = Get-MBReceiptEntropy -ReceiptPath $receiptFull
    $plain = $null
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $payload = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -ErrorAction Stop
        $transaction = [guid]::Empty
        $releaseManifestTransaction = [guid]::Empty
        if ($payload.SchemaVersion -ne 1 -or $payload.ProductId -ne 'MicBridgeAPO' -or
            -not [guid]::TryParse([string]$payload.TransactionId,[ref]$transaction) -or $transaction -eq [guid]::Empty -or
            -not [guid]::TryParse([string]$payload.ReleaseManifestTransactionId,[ref]$releaseManifestTransaction) -or $releaseManifestTransaction -eq [guid]::Empty -or
            [string]$payload.ReleaseManifestSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$payload.SignerThumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Install transaction receipt schema or identity is invalid.' }
        $rootItem = Get-Item -LiteralPath ([string]$payload.InstallRoot) -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Receipt install root is missing or is a reparse point.' }
        $root = Get-MBReceiptCanonicalPath -Path ([string]$payload.InstallRoot)
        if (-not [string]::Equals($root,[string]$payload.InstallRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Receipt install root is not canonical.' }
        $verified = [Collections.Generic.List[object]]::new()
        foreach ($record in @($payload.InstalledFiles)) {
            $relative = [string]$record.RelativePath
            $expected = [string]$record.Sha256
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
                $relative -match '(^|[\\/])\.\.?([\\/]|$)' -or $relative.Contains(':') -or
                $expected -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Receipt contains an unsafe installed-file path or digest.' }
            $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Receipt installed-file path escapes install root.' }
            if ($VerifyInstalledFiles) {
                $cursor=$root
                foreach ($part in ($relative -split '[\\/]')) {
                    $cursor=Join-Path $cursor $part
                    $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Receipt file path traverses a reparse point: $relative" }
                }
                $actual=(Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash
                if (-not $actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { throw "Installed file no longer matches its transaction receipt: $relative" }
            }
            $verified.Add([pscustomobject]@{RelativePath=$relative;Sha256=$expected})
        }
        [pscustomobject]@{
            IsReadOnly=$true
            ReceiptIntegrityVerified=$true
            MachineBound=$true
            InstalledFilesVerified=[bool]$VerifyInstalledFiles
            TransactionId=$transaction.ToString()
            ReleaseManifestTransactionId=$releaseManifestTransaction.ToString()
            ProductVersion=[string]$payload.ProductVersion
            ReleaseManifestSha256=[string]$payload.ReleaseManifestSha256
            SignerThumbprint=[string]$payload.SignerThumbprint
            InstallRoot=$root
            InstalledFiles=@($verified.ToArray())
            OwnershipProven=$false
            ComOwnershipProven=$false
            IsExecutionAuthorized=$false
            Note='DPAPI integrity and machine binding verified. This receipt is not a release signature, not proof of the historical Windows baseline, and not authorization to mutate shared resources.'
        }
    } finally {
        [Array]::Clear($bytes,0,$bytes.Length)
        if ($entropy) { [Array]::Clear($entropy,0,$entropy.Length) }
        if ($plain) { [Array]::Clear($plain,0,$plain.Length) }
    }
}

Export-ModuleMember -Function New-MBInstallTransactionReceipt,Test-MBInstallTransactionReceipt
