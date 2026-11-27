$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path ([IO.Path]::GetTempPath()) ('MicBridgeAuthenticode-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(2048)
$cert = $null
$rootStore = $null
$publisherStore = $null
try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=MicBridge CI Authenticode Signer'),
        $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
    $oids = [Security.Cryptography.OidCollection]::new()
    [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))

    $rootStore = New-Object Security.Cryptography.X509Certificates.X509Store([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $publisherStore = New-Object Security.Cryptography.X509Certificates.X509Store([Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $rootStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $publisherStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $rootStore.Add($cert)
    $publisherStore.Add($cert)

    $scriptPath = Join-Path $root 'SignedProbe.ps1'
    [IO.File]::WriteAllText($scriptPath,"Write-Output 'AUTHENTICODE_PROBE_OK'"+[Environment]::NewLine,[Text.UTF8Encoding]::new($true))
    $signed = Set-AuthenticodeSignature -LiteralPath $scriptPath -Certificate $cert -HashAlgorithm SHA256
    $verified = Get-AuthenticodeSignature -LiteralPath $scriptPath
    if ($signed.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $verified.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $verified.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        throw "FAIL: signed PowerShell bootstrap did not verify as Valid. Set=$($signed.Status); Verify=$($verified.Status)"
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy AllSigned -File `"$scriptPath`""
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "FAIL: AllSigned rejected the trusted signed script. ExitCode=$($process.ExitCode)" }

    Add-Content -LiteralPath $scriptPath -Value '# tampered'
    $tampered = Get-AuthenticodeSignature -LiteralPath $scriptPath
    if ($tampered.Status -ne [Management.Automation.SignatureStatus]::HashMismatch) {
        throw "FAIL: modified signed script was not classified as HashMismatch. Status=$($tampered.Status)"
    }
    $tamperedProcess = Start-Process -FilePath $powershell -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($tamperedProcess.ExitCode -eq 0) { throw 'FAIL: AllSigned executed a modified signed script.' }

    Write-Host 'PASS: Authenticode signature validates for the pinned trusted publisher.'
    Write-Host 'PASS: Windows PowerShell AllSigned executes a valid signed script.'
    Write-Host 'PASS: Windows PowerShell AllSigned rejects a modified signed script.'
} finally {
    if ($publisherStore) {
        try { if ($null -ne $cert) { $publisherStore.Remove($cert) } } catch {}
        $publisherStore.Close()
    }
    if ($rootStore) {
        try { if ($null -ne $cert) { $rootStore.Remove($cert) } } catch {}
        $rootStore.Close()
    }
    if ($cert) { $cert.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
