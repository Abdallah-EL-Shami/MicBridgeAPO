# MicBridgeAPO security readiness and release gates

## Current decision

The legacy cleanup feature is NOT approved for execution and is NOT part of the installer package. The audit, planner, journal, approval, preflight, provenance-manifest, and file-handle-lease components are evidence-gathering prototypes. None grants deletion authorization.

## Verified CI baseline

The latest confirmed CI run on the current recovery branch is run **1615** (`46050360347`) on commit `8c42c8d7038fdd80424bddfb5aa99791c3a98ac7`. Run 1615 confirms the bootstrap-boundary test correction; it does not close the bootstrap trust gap or constitute a production release. These are CI validation results, not a security certification, not a real PFX-backed tag release, and not proof of bootstrap trust or historical COM ownership.

## Bootstrap trust boundary (not yet closed)

The current package has two separate mechanisms that must not be conflated:

- The release workflow Authenticode-signs staged PowerShell scripts and verifies signature integrity plus the pinned signer thumbprint in CI. CI deliberately accepts `NotTrusted` for this integrity check and does not enroll the self-signed certificate.
- The package manifest is CMS-signed and checked by the PowerShell verifier. The verifier itself is part of the package, so it cannot be the independent root that authenticates its own first execution. More specifically, `install.ps1` executes `Import-Module -Name $provenanceVerifier` before calling `Test-MBInstallProvenanceManifest`; the imported `.psm1` code therefore runs before the package authenticates that module. This is an actual bootstrap execution gap, not merely a theoretical limitation.

`install.bat` only launches `install.ps1` with `-ExecutionPolicy AllSigned`. PowerShell execution policy is not a security boundary against a user who can invoke PowerShell differently or replace the bootstrap. Therefore the batch wrapper and the manifest verifier do not establish bootstrap trust. The current pre-elevation check does not cure the earlier execution of the untrusted verifier module.

Before production use, select and implement one independently trusted bootstrap model:
1. A separately distributed, Authenticode-signed native launcher whose signer is already trusted on the target and which verifies the package manifest before launching any package script; or
2. A documented manual bootstrap procedure where the operator independently obtains and compares the certificate fingerprint, deliberately provisions the exact public certificate, verifies the signed package, and only then invokes the installer.

For either model, add negative tests for a modified launcher, modified verifier, altered certificate, wrong signer thumbprint, missing trust anchor, and tampered package; prove that no elevation, logging, lock creation, registry/COM change, or file mutation occurs before verification. Do not treat a certificate shipped inside the same untrusted archive as an independent trust anchor. Do not claim protection against a hostile local administrator.

The CI bootstrap audit now explicitly asserts that this import-before-verification condition remains disclosed; it is a guard against overstating readiness, not a mitigation. The installer gate has been tightened to require `BootstrapTrustEstablished=true`; the current verifier deliberately returns false, so the installer now stops before elevation, log creation, locks, preflight, or system mutation. This is a fail-closed production block, not a fix for the earlier verifier-module execution: an untrusted `.psm1` must still not be run at all until a separately trusted bootstrap validates it.

No launcher implementation or target-machine trust enrollment is approved by this change. Until one bootstrap model is selected, implemented, and independently reviewed, BootstrapTrustEstablished must remain false and production installation remains blocked.

## Manifest verifier limitations

The current verifier checks CMS signature integrity, a caller-supplied signer thumbprint allowlist, certificate validity dates, Code Signing EKU, digital-signature key usage, manifest identity, relative paths, reparse-point attributes, duplicate paths, and file SHA-256 values.

The verifier still performs path-based file and directory inspection followed by path-based hashing. Those operations are not an atomic handle-relative traversal. A path component or file can potentially change between checks and hashing. Therefore:
- Verification is not race-safe authorization.
- A verified result must not be used to authorize deletion, replacement, or installation.
- The caller-supplied thumbprint list is an external trust input; this module does not provision, protect, rotate, or revoke that trust anchor.
- Checking NotBefore/NotAfter is not certificate-chain validation or revocation checking.
- A signed manifest is evidence of signed content, not proof that an authentic installer transaction created the historical machine state.
- File provenance does not prove ownership of shared COM/APO registrations.

The result explicitly reports VerificationConsistency=PathBasedNonAtomic and RaceSafeForExecution=false.

## Required work before any executor

1. Define and protect signer trust provisioning outside the package and manifest; document rotation, compromise recovery, and revocation.
2. Implement Windows handle-relative traversal and file hashing using stable handles, with explicit volume/file identity checks and reparse-point rejection at each component. Prove behavior on supported filesystems and fail closed where unsupported.
3. Add deterministic Windows tests for ancestor replacement, leaf replacement, junction/symlink/mount-point traversal, hard links, concurrent rename, sharing violations, and cleanup of all handles. Do not rely on timing-only flaky race tests.
4. Define an installer transaction record created atomically by a trusted installer, authenticated independently, with product/version/file identities and recovery semantics.
5. Keep COM ownership separate. Shared COM/APO keys remain manual-review-only unless ownership can be independently and unambiguously established.
6. Have an independent security review of the implementation and tests.
7. Only then design a separate, resumable executor with per-item revalidation, durable journal, explicit user confirmation, rollback/stop behavior, and postcondition verification.
8. Keep the executor out of install.ps1 and the package until all gates pass and a separate release approval is recorded.

## Installer and system safety

The installer legacy gate is intended to be read-only and fail closed when legacy or ambiguous state is found. CI's static gate test checks ordering and absence of mutation commands in the gate. This static test does not prove all installer behavior under every Windows state.

All development tests must remain isolated: temporary directories for files, HKCU-only registry fixtures, and no HKLM/system endpoint mutation. Do not restore an unknown backup or alter Realtek/vendor registrations.

## Release checklist

- [ ] Trust-anchor lifecycle and revocation design implemented and tested.
- [ ] Atomic handle-relative verifier implemented and independently reviewed.
- [ ] Deterministic path-race tests pass on each supported filesystem.
- [ ] Trusted installer transaction provenance implemented and tested.
- [ ] COM ownership policy independently reviewed.
- [ ] Cleanup executor separately implemented, tested, and reviewed.
- [ ] Installer/package integration approved by explicit release review.
- [ ] Clean build and complete CI pass on the exact release commit.
- [ ] Main branch and PR merge actions explicitly approved by the repository owner.

Until every applicable item is complete, cleanup execution remains disabled.


## Independent bootstrap launcher implementation plan

A detailed native-launcher security design is recorded in [`docs/BOOTSTRAP-LAUNCHER-SECURITY-DESIGN.md`](../../docs/BOOTSTRAP-LAUNCHER-SECURITY-DESIGN.md). It specifies an independently Authenticode-trusted native launcher, CMS and payload verification before any package PowerShell executes, handle-bound file pinning, a process-bound verification handoff, and negative/race tests. This is a design only: no launcher binary or code has been implemented, the current verifier still returns `BootstrapTrustEstablished=false`, and production installation remains blocked. The current static CI test checks that this limitation and design remain disclosed; it is not a runtime security proof.
