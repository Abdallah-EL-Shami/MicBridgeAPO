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

## Protected tag-only release signing workflow

The workflow `.github/workflows/signed-release.yml` is separate from the ordinary `build-dll` CI workflow.

- It is triggered by version tags beginning with `v` (for example, `v1.2.3`) or by manual dispatch while a version tag is selected. Its job-level condition refuses to run from a branch or pull-request ref.
- It requests only `contents: read` and uses the protected `release-signing` environment. Configure that environment to allow only reviewed release tags and require approval where available.
- It rebuilds and runs the existing Windows validation suite, stages the install package, and imports the PFX with an ephemeral key-storage flag.
- Before signing, it checks the PFX certificate's SHA-1 thumbprint and SHA-256 certificate fingerprint against the independently verified public CER, its validity period, DigitalSignature key usage, and Code Signing EKU.
- It creates a UTF-8 JSON manifest listing each staged package file and SHA-256 hash, signs the manifest as an **attached CMS SignedData** object (the CMS contains the signed content), then runs the project's provenance verifier against the staged package using the pinned signer thumbprint.
- The artifact contains the package, `install-manifest.json`, and CMS signature file `install-manifest.p7s`. The `.p7s` file is not a detached CMS object in the current implementation. This is a signed-manifest/hash provenance mechanism; it is not an Authenticode signature embedded in the DLL.
- The job removes the temporary PFX file and clears the secret environment variables in a `finally` block. GitHub-hosted runners are ephemeral; the private key is not uploaded as an artifact or committed.

The workflow is present on the development branch and has not yet been exercised with a version tag, so real PFX import, CMS signing, post-sign verification, and artifact creation remain unproven. The ordinary `build-dll` CI run does not execute this protected signing job. Do not create a production version tag merely to test it; use a deliberately designated validation tag only after reviewing tag protection and confirming the environment approval policy.

The current installer and uninstaller are **not yet gated** by this manifest verifier. Do not treat a signed artifact as an approved installation until independent trust provisioning and fail-closed integration into install/uninstall have been completed and tested. Manifest provenance also does not prove ownership of shared COM registrations or authorize cleanup/deletion.

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

## Provenance, ownership, and cleanup limits

### What the signed manifest proves

The release workflow signs a manifest containing the relative path and SHA-256 digest of every staged regular file. The verifier checks the CMS signature against an explicitly supplied signer-thumbprint pin, validates the signer validity period and Code Signing EKU, rejects path traversal and reparse points, and hashes each listed file from the target directory. It also rejects any additional unlisted file in the package tree (the manifest and its CMS signature are the two expected metadata files excluded from the payload set).

This proves that the enumerated payload bytes match the signed release manifest at verification time. It does not prove who owns a pre-existing Windows file, registry key, COM class, endpoint property, shortcut, or shared resource. It does not authorize execution, replacement, restoration, or deletion. The verifier currently reports path-based non-atomic verification and explicitly sets `RaceSafeForExecution=false`; a caller must not treat it as a race-free execution lease.

### Ownership classification and preservation policy

- A signed package manifest is provenance evidence for files shipped in that release, not proof that an identically named pre-existing file on a machine was installed by MicBridgeAPO.
- A file can be considered a MicBridge-created installed file only when its installation transaction has an independently protected record binding the canonical destination path, release identity, file digest, and transaction identity, and the current file still matches that record. A mutable `backup.json`, filename, directory name, registry server path, or hash observed during a later audit is not sufficient on its own.
- Shared COM registrations, Windows audio endpoint properties, vendor APO registrations, Realtek components, and any registry values that may predate MicBridgeAPO are not eligible for automatic deletion based solely on CLSID, path, or matching hash. Their ownership is unproven unless a reliable pre-install snapshot and transaction-bound evidence establish exactly what MicBridge changed and what must be restored.
- Files outside the canonical MicBridge install directory, files with unknown provenance, files whose hash differs, reparse points, user data, recovery journals, and ambiguous/shared components must be classified as `Preserve`/`ReviewRequired`. The cleanup planner must block rather than infer ownership.
- A successful provenance check must never be translated into `OwnershipProven`, `ComOwnershipProven`, or `IsExecutionAuthorized`.

### Installer and uninstaller integration status

The current `install.ps1` and `uninstall.ps1` do not yet invoke `Test-MBInstallProvenanceManifest`. The build package stages the verifier module, but staging is not runtime enforcement. This remains an explicit release blocker. In addition, `uninstall.ps1` now fails closed before creating its uninstall journal or changing Registry/COM/ACL/files unless the read-only audit reports `OwnershipProven=true` and `OwnershipEvidenceStatus=Proven`. The current audit deliberately reports ownership as unestablished, so existing installs will be refused by this uninstaller until independently protected transaction-bound ownership evidence is implemented. This restriction is intentional: it prevents unproven cleanup rather than guessing.

The package manifest covers the release package, whereas the installer copies only a subset of package files into the installed directory. A safe integration therefore needs two separately defined checks: (1) verify the complete downloaded package before the installer performs any system mutation; and (2) persist transaction-bound installed-file evidence and verify each installed file before uninstall changes anything. The installed-file evidence must not be self-asserted by a mutable backup file, and the uninstaller bootstrap itself must be authenticated before it is trusted to enforce the check. Do not paper over this boundary by merely adding the manifest thumbprint to an otherwise unauthenticated script.

Until that design and its tests are implemented, do not treat the current signed artifact as installable/approved, and do not connect the cleanup executor to the installer or uninstaller. Unknown or unproven files and registrations must be preserved; if the current uninstaller cannot safely distinguish them, it must stop before mutation rather than guess.

### Offline revocation and trust limitations

The verifier deliberately disables certificate downloads and sets revocation mode to `NoCheck`. Consequently `RevocationChecked=false` and `CertificateRevocationMode=NotCheckedOffline` are expected, not evidence that the certificate is unrevoked. A locally available certificate chain and a pinned thumbprint do not provide fresh revocation status. A caller-supplied denylist can reject a known-revoked thumbprint, but cannot discover a newly revoked certificate without updated trusted information.

The self-signed release certificate is trusted only when its SHA-256 fingerprint has been independently compared and provisioned through a trusted channel. A fingerprint embedded only in the same untrusted package is not an independent trust anchor. No certificate-store modification is performed by the installer. No online revocation lookup occurs during installation, uninstall, or runtime operation.

## Current status

Certificate-generation tooling and the tag-only signing workflow are present on the development branch. The public CER fingerprint was verified against the maintainer-reported certificate details. The maintainer reports that the PFX and password are configured as environment secrets; the private PFX remains outside the repository. The ordinary CI check for commit `1493cf8d04feaefd037eceecd6abd2c2b882f331` completed successfully, but it did not execute the signing job. No real version-tag signing run has yet verified the secrets or produced a signed release artifact. No certificate has been trusted on a target device, and install/uninstall are not yet gated by this verifier. Do not install artifacts from this validation branch.
