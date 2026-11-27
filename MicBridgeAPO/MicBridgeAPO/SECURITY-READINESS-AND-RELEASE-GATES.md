# MicBridgeAPO security readiness and release gates

## Current decision

The legacy cleanup feature is NOT approved for execution and is NOT part of the installer package. The audit, planner, journal, approval, preflight, provenance-manifest, and file-handle-lease components are evidence-gathering prototypes. None grants deletion authorization.

## Verified CI baseline

The latest confirmed successful run for the current recovery branch is run **1607** (`46048429140`) on commit `20dacc0bbec24a3aaf3acd33485071afdc6fdc76` (`recovery/provenance-from-run-1548`). Every job step passed, including build, Windows APO COM smoke test, installer/rollback checks, legacy audit and approval tests, signed manifest verification, mutation-resistant package file leases, transaction receipt, installer provenance gate, Windows PowerShell 5.1 compatibility, release-workflow invariants, isolated COM rollback, DLL/file/metadata rollback, endpoint rollback, package staging, and artifact upload. This is a CI validation result for that exact commit, not a security certification, not a real PFX-backed tag release, and not proof of bootstrap trust or historical COM ownership. Runs 1603–1606 failed in test/fixture integration; the parser defect was corrected in commit `20dacc0`, and run 1607 passed.

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
