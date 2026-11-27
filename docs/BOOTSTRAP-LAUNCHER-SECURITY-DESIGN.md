# Independent bootstrap launcher — security design

Status: **native fail-closed launcher scaffold plus a separately compiled WinVerifyTrust/pinned-SHA256 signer-verification component and unsigned-file negative test are implemented; the verifier is not yet called by the launcher; manifest/CMS verification, file pinning, authenticated handoff, and production launch are not implemented; production installation remains blocked.**

## Why the current bootstrap is not trusted

The current installer imports `MicBridge.InstallProvenanceManifest.psm1` before it calls `Test-MBInstallProvenanceManifest`. Importing a PowerShell module executes its code. A later CMS/hash check cannot authenticate code that has already executed.

The installer now fails closed unless `BootstrapTrustEstablished` is true. The current verifier deliberately returns false. Do not change that default merely to make installation proceed.

## Selected architecture

Implement a small, separately Authenticode-signed native Windows launcher named `MicBridgeBootstrap.exe`. It is the only supported entry point for installation. The launcher must be built as a distinct CMake target and included in the release package. It must not load, import, dot-source, or execute any package-controlled PowerShell code before completing every verification below.

The launcher itself is not a trust anchor just because it is in the package. The operator must independently compare the release certificate SHA-256 fingerprint through a trusted out-of-band channel, verify the launcher's Authenticode signature and signer thumbprint, and deliberately provision the public certificate in Windows trust stores. Only then may the operator launch the verified executable. A signature check performed only by the launcher cannot authenticate the launcher itself.

## Required verification sequence

1. Resolve the package root from the launcher's own final path; reject relative/ambiguous paths, reparse points, alternate data streams, and package roots that cannot be canonicalized.
2. Verify the launcher's Authenticode signature using WinVerifyTrust with no UI, no network retrieval, and an explicit pinned signer certificate SHA-256 fingerprint. Fail closed for absent, invalid, expired, or wrong-signer signatures.
3. Read the manifest and CMS signature as data only. Verify attached CMS SignedData using Windows Crypt32 APIs; require exactly one expected signer, the pinned certificate fingerprint, Code Signing EKU, valid signing time/certificate policy, and exact signed-content equality.
4. Parse the supported manifest schema strictly. Reject duplicate JSON properties, duplicate normalized paths, unknown schema versions, path traversal, rooted paths, alternate data streams, case-colliding paths, reparse points, hard links, unexpected directories, and unlisted files.
5. Open every payload with handles that deny write/delete sharing. Hash bytes from the opened handles with BCrypt SHA-256; validate final paths and file identities. Keep all handles and parent-directory pins alive through child-process creation and the complete install session. If any file cannot be pinned, stop.
6. Verify the exact required PowerShell entry script and every imported `.ps1`/`.psm1` is present in the signed manifest and bears a valid Authenticode signature from the same pinned signer. Do not trust ExecutionPolicy as a security boundary.
7. Only after all checks succeed, create the child process with a fixed, fully qualified `powershell.exe` path and fixed arguments: `-NoProfile -NonInteractive -ExecutionPolicy AllSigned -File <verified install.ps1>`. Do not use `cmd.exe`, shell association, PATH lookup, batch wrappers, or user-controlled argument concatenation.
8. Pass a short-lived, unforgeable verification handoff to the installer (for example, an inherited, non-inheritable-by-default handle to a launcher-owned verification record). The installer must validate the handoff and refuse direct invocation without it. The handoff must bind package root, manifest digest, signer fingerprint, process identity, and transaction nonce.
9. Retain package file/directory handles until the installer has completed or exited. On any launch, handoff, or child exit failure, release handles and return a nonzero exit code. No log, lock, elevation request, registry, COM, file, service, or ProgramData mutation may occur before verification.


## Revocation and offline operation policy

The current verifier sets `fdwRevocationChecks = WTD_REVOKE_NONE` and uses cache-only URL retrieval. This is an explicit offline-availability choice, not evidence that the certificate has not been revoked. A successful result therefore establishes Windows Authenticode policy acceptance under the locally available trust state plus the pinned certificate identity; it does **not** establish fresh revocation status. Do not describe this mode as revocation-checked.

Before production release, choose and document one of these policies:

- **Strict online release validation:** require a successful revocation check at release/bootstrap time, fail closed when revocation data cannot be obtained, and clearly disclose that initial verification requires network access.
- **Offline-capable pinned-certificate policy:** retain cache-only/no-revocation behavior for offline installation, but document the residual revocation risk, define certificate-compromise response (including a new pinned fingerprint and replacement launcher), and ensure users receive the updated trust material through an independently authenticated channel.

The product requirement that normal installed operation works without Internet does not by itself decide whether first-time release verification may require network access. That decision must be explicit; neither behavior is to be inferred from the current flags.

## Privilege boundary

The launcher must verify the package before elevation. The preferred model is a standard-user launcher that verifies first and then starts the already verified installer through a narrowly defined elevated helper/child flow. Any elevation transition must preserve the verified package identity and handoff; the elevated process must not re-open untrusted paths or repeat a path-only check. If Windows cannot securely preserve the handle-bound handoff across the elevation boundary, the design must stop and be revised rather than downgrade to path-based trust.

## Required negative and adversarial tests

- Modified launcher, wrong signer, expired certificate, missing trust anchor, invalid Authenticode signature.
- Modified/missing manifest, modified CMS signature, signer mismatch, multiple signers, invalid EKU, invalid validity period, unknown schema.
- Duplicate JSON keys, path traversal, case collisions, alternate data streams, reparse points, hard links, extra/missing files, empty directories.
- File replacement, rename, directory replacement, and write/delete attempts between enumeration, hashing, child creation, and installer use.
- Missing/modified PowerShell entry script or module, invalid Authenticode signature, and module signer mismatch.
- Direct invocation of `install.ps1`, `install.bat`, or an individual module without a valid launcher handoff must fail before any mutation.
- Failure at every verification stage must prove zero elevation, log creation, lock acquisition, registry/COM/service changes, file writes, or ProgramData writes.
- Test Windows PowerShell 5.1 compatibility and supported Windows versions. Run all fixtures in temporary directories and HKCU-only registry hives.

## Implementation gates

1. **Fail-closed scaffold complete:** add the native launcher target and a CTest that launches it and confirms exit code 78. The current executable deliberately performs no verification and never launches the installer. This is only a fail-closed placeholder, not a trusted launcher.
2. **Authenticode verifier component implemented, integration pending:** `MicBridgeBootstrapTrust.cpp` calls `WinVerifyTrust` with UI and revocation retrieval disabled, obtains the verified signer from the WinTrust provider state, and compares the certificate SHA-256 to the pinned release fingerprint. A negative CTest passes an unsigned executable. The launcher does not call this component yet; the test does not prove correct acceptance of a genuine signed binary, rejection of a wrong signer, or end-to-end package trust.
3. Add unit-testable parsing/crypto/path modules without changing installer behavior.
4. Implement and test manifest/CMS verification independently of PowerShell.
5. Implement file-handle and directory-handle pinning, race tests, and exact-file-set checks.
6. Implement the authenticated handoff and installer-side rejection of direct invocation.
7. Sign the launcher and PowerShell files in the protected release workflow; verify all signatures and the signed manifest in a clean staging directory.
8. Only after all negative tests pass may the verifier report `BootstrapTrustEstablished=true` for a launcher-authenticated handoff.
9. Keep release tagging, PFX use, target-machine trust enrollment, installation, and legacy cleanup as separate explicit approvals.

## Non-goals

- The launcher does not prove ownership of existing files, COM registrations, APO endpoint properties, Realtek components, or Windows state.
- A valid release signature does not authorize cleanup, rollback of unknown state, or deletion.
- A self-signed certificate copied in the same archive is not an independent trust anchor.
- PowerShell ExecutionPolicy, a batch wrapper, a manifest verifier shipped in the same package, and a launcher that verifies only itself are not independent bootstrap roots.
