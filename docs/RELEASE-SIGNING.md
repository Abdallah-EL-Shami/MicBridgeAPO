# MicBridgeAPO release signing bootstrap

## Purpose and security boundary

This procedure creates a project-specific, self-signed Code Signing certificate on the maintainer's Windows machine. It does **not** install trust, sign a release, change the installer, or authorize cleanup. The private key must never enter the repository or a release artifact.

A self-signed certificate is not publicly trusted by Windows. Each target machine must deliberately trust the exact public certificate after its SHA-256 fingerprint has been checked through an independent trusted channel. Trusting it means trusting whoever controls the corresponding private key to sign MicBridgeAPO code.

## Create the certificate locally

On the Windows machine that will own the release key:

1. Check out the reviewed development branch.
2. Open Windows PowerShell (or PowerShell on Windows) in the repository.
3. Run:

   ```powershell
   .\MicBridgeAPO\MicBridgeAPO\tools\New-MBReleaseSigningCertificate.ps1
   ```

4. Choose a unique PFX password of at least 14 characters when prompted.
5. The script refuses to overwrite a non-empty output directory. It creates:
   - `MicBridgeAPO-Release-Signing.cer`: public certificate only.
   - `MicBridgeAPO-Release-Signing.pfx`: private key protected by the password you chose.
   - `MicBridgeAPO-Release-Certificate-Info.json`: public certificate details and fingerprints.

The default output directory is `%USERPROFILE%\Documents\MicBridgeAPO-Signing`. The script restricts its ACL to the current user, SYSTEM, and local Administrators. Review that ACL and keep an offline backup of the PFX in an encrypted location. Never commit, upload as an artifact, paste, or send the PFX or its password in chat.

## Trust installation is a separate, deliberate step

Do not install the certificate automatically from the installer or from the same package that contains it. First compare the certificate's SHA-256 fingerprint with the value obtained through a separately trusted channel. Then, and only then, manually add the exact public certificate to the appropriate Windows trust stores on each target machine (Trusted Root Certification Authorities and Trusted Publishers, after security review).

The script deliberately reports `TrustInstalled=false` and `ReleaseSigningEnabled=false`. It does not modify any certificate store.

## CI signing is not enabled yet

The current verifier requires an explicitly trusted signer thumbprint and can build a certificate chain using locally available Windows certificates with certificate downloads disabled. It does not check online revocation. A thumbprint passed as a command-line argument is not, by itself, an independent trust anchor.

Before enabling release signing, the project still needs all of the following:

- Agree on the independently provisioned trust anchor and how its fingerprint is pinned by the verifier and installer.
- Add a protected GitHub Actions environment and store the PFX (base64-encoded) and its password as separately named secrets, for example `MB_RELEASE_SIGNING_PFX_BASE64` and `MB_RELEASE_SIGNING_PFX_PASSWORD`. Do not put either value in repository files, workflow logs, artifacts, or chat.
- Implement a release-only signing job with least-privilege permissions, protected environment approval, no signing on pull requests, and cleanup of temporary key material.
- Sign the canonical manifest and all required release binaries, then verify the produced signatures and file hashes in a separate CI step.
- Integrate fail-closed verification into both install and uninstall before any mutation; keep provenance verification distinct from ownership proof and deletion authorization.
- Add tests for wrong signer, altered manifest, altered payload, expired certificate, missing trust, and offline behavior.


## Prepare the protected GitHub Actions signing environment

The release key is kept in a GitHub Actions **environment**, not in repository files and not in ordinary repository-wide secrets.

1. In the repository, open **Settings → Environments → New environment**.
2. Name it exactly `release-signing`, then configure it.
3. If the account/repository plan exposes deployment protection rules, require approval before jobs enter this environment. Restrict deployment branches/tags to the intended release tags or release branch. Do not allow pull-request refs.
4. Inside the `release-signing` environment, add these two **Environment secrets**:
   - `MB_RELEASE_SIGNING_PFX_BASE64`: the Base64 text of the PFX file.
   - `MB_RELEASE_SIGNING_PFX_PASSWORD`: the password chosen when exporting the PFX.
5. Do not create these as ordinary repository secrets if the protected environment is available. Environment secrets are only supplied to a job after it enters that environment.

To prepare the Base64 value on the Windows maintainer machine, run this in PowerShell. It reads the PFX locally and puts only its Base64 representation on the clipboard; it does not print the value to the terminal:

```powershell
$pfxPath = Join-Path $env:USERPROFILE 'Documents\MicBridgeAPO-Signing\MicBridgeAPO-Release-Signing.pfx'
if (-not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) { throw "PFX not found: $pfxPath" }
$bytes = [IO.File]::ReadAllBytes($pfxPath)
$b64 = [Convert]::ToBase64String($bytes)
if ([Text.Encoding]::UTF8.GetByteCount($b64) -gt 49152) { throw 'Base64 PFX exceeds GitHub Actions 48 KB secret limit.' }
Set-Clipboard -Value $b64
[Array]::Clear($bytes,0,$bytes.Length)
$b64 = $null
Write-Host 'PFX Base64 copied to clipboard. Paste it directly into the GitHub environment secret value.'
```

Paste the clipboard into the value field for `MB_RELEASE_SIGNING_PFX_BASE64`. Then add `MB_RELEASE_SIGNING_PFX_PASSWORD` by typing the original PFX password directly into GitHub's secret field. Do not put the password in PowerShell command history, a text file, chat, or the repository. Clear the clipboard after saving (for example, run `Set-Clipboard -Value ''`).

GitHub limits each secret to 48 KB. See the official [GitHub secrets reference](https://docs.github.com/en/actions/reference/security/secrets) and [environment secret setup instructions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).

**Important:** Adding these secrets does not itself sign anything. The current `build-dll` workflow is a validation/build workflow; it does not consume these secrets or produce a signed release. Do not trigger a test run expecting signing. A separate release-only workflow must first be implemented and reviewed to consume these secrets, sign the canonical manifest and payload, verify the output, and delete temporary key material. Pull-request builds must never receive the signing environment.

## Current status

Certificate-generation tooling is staged for review. The maintainer has generated a self-signed release certificate and supplied its public CER for inspection; its public fingerprint was verified against the reported certificate details. The private PFX remains outside the repository and has not been provisioned to GitHub Actions. No certificate has been trusted on a target device, no release is signed, and install/uninstall are not yet gated by this verifier. Do not install artifacts from this validation branch.
