$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MicBridge.InstallTransactionReceipt.psm1') -Force

$root=Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeReceipt-' + [guid]::NewGuid().ToString('N'))
$install=Join-Path $root 'install'
$data=Join-Path $root 'data'
New-Item -ItemType Directory -Path $install,$data | Out-Null
try {
    $dll=Join-Path $install 'MicBridgeAPO.dll'
    [IO.File]::WriteAllBytes($dll,[byte[]](2,7,1,8,2,8))
    $hash=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $receipt=Join-Path $data 'install-transaction.receipt'
    $manifestTransactionId=[guid]::NewGuid()
    $created=New-MBInstallTransactionReceipt -ReceiptPath $receipt -InstallRoot $install -ProductVersion '0.0.0-ci' -ReleaseManifestSha256 ('A'*64) -SignerThumbprint '29BAC42BFC53F2586559A9B95D1FEEB658E8891A' -TransactionId $manifestTransactionId -InstalledFiles @(@{RelativePath='MicBridgeAPO.dll';Sha256=$hash})
    if (-not $created.Created -or $created.TransactionId -ne $manifestTransactionId.ToString() -or $created.InstalledFileCount -ne 1 -or $created.OwnershipProven -or $created.ComOwnershipProven -or $created.IsExecutionAuthorized) { throw 'FAIL: receipt creation returned invalid or unsafe capability flags.' }
    $verified=Test-MBInstallTransactionReceipt -ReceiptPath $receipt -VerifyInstalledFiles
    if (-not $verified.ReceiptIntegrityVerified -or -not $verified.MachineBound -or -not $verified.InstalledFilesVerified -or $verified.TransactionId -ne $manifestTransactionId.ToString() -or $verified.OwnershipProven -or $verified.ComOwnershipProven -or $verified.IsExecutionAuthorized) { throw 'FAIL: valid receipt did not verify with safe capability flags.' }
    $duplicateRejected=$false
    try { New-MBInstallTransactionReceipt -ReceiptPath $receipt -InstallRoot $install -ProductVersion '0.0.0-ci' -ReleaseManifestSha256 ('A'*64) -SignerThumbprint '29BAC42BFC53F2586559A9B95D1FEEB658E8891A' -InstalledFiles @(@{RelativePath='MicBridgeAPO.dll';Sha256=$hash}) | Out-Null }
    catch { $duplicateRejected=$_.Exception.Message -match 'refusing to overwrite history' }
    if (-not $duplicateRejected) { throw 'FAIL: existing receipt could be overwritten.' }
    [IO.File]::WriteAllBytes($dll,[byte[]](3,1,4,1,5,9))
    $tamperRejected=$false
    try { Test-MBInstallTransactionReceipt -ReceiptPath $receipt -VerifyInstalledFiles | Out-Null }
    catch { $tamperRejected=$_.Exception.Message -match 'no longer matches' }
    if (-not $tamperRejected) { throw 'FAIL: modified installed file passed receipt verification.' }
    $tamperBytes=[IO.File]::ReadAllBytes($receipt)
    $tamperBytes[0]=[byte]($tamperBytes[0] -bxor 0xFF)
    [IO.File]::WriteAllBytes($receipt,$tamperBytes)
    $receiptTamperRejected=$false
    try { Test-MBInstallTransactionReceipt -ReceiptPath $receipt | Out-Null } catch { $receiptTamperRejected=$true }
    if (-not $receiptTamperRejected) { throw 'FAIL: modified receipt bytes passed DPAPI integrity verification.' }
    $traversalRejected=$false
    try { New-MBInstallTransactionReceipt -ReceiptPath (Join-Path $data 'bad.receipt') -InstallRoot $install -ProductVersion '0.0.0-ci' -ReleaseManifestSha256 ('A'*64) -SignerThumbprint '29BAC42BFC53F2586559A9B95D1FEEB658E8891A' -InstalledFiles @(@{RelativePath='../outside.dll';Sha256=$hash}) | Out-Null }
    catch { $traversalRejected=$_.Exception.Message -match 'unsafe path' }
    if (-not $traversalRejected) { throw 'FAIL: receipt accepted path traversal.' }
    Write-Host 'PASS: machine-bound transaction receipt, atomic create/no-overwrite, file tamper detection, receipt tamper detection, and path traversal rejection.'
    Write-Host 'PASS: receipt never asserts historical ownership, COM ownership, or execution authorization.'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
