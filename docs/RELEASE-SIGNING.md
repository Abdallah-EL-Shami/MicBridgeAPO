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

## Current status

Certificate-generation tooling is staged for review only. No certificate has been generated for the project yet, no private key exists in CI, no certificate has been trusted on a user device, no release is signed, and install/uninstall are not yet gated by this verifier. Do not install artifacts from this validation branch.
