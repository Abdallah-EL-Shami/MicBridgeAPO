# Install rollback recovery design

Status: design only; not an implementation or release-readiness claim.

## Current behavior confirmed in install.ps1

- The installer serializes operations with the MicBridge recovery operation lock.
- It scans `ProgramData\\MicBridgeAPO\\transactions-*` for an unfinished
  `rollback-recovery.json` and fails closed. It does not replay the transaction.
- Each install transaction currently declares one journal step:
  `RestorePreviousInstallState`.
- The rollback action is embedded in the installer's `catch` block. A new
  installer process cannot call that action independently.
- The action restores endpoint values, endpoint ACLs, COM registrations,
  installer-owned files, shortcut, ProgramData ACLs, and possibly the audio
  service in one large callback. The journal can mark this step incomplete
  after a process crash, but there is no startup replay implementation.
- The durable transaction snapshot is written before the installation
  mutations. DLL backup provenance is appended later, immediately before the
  DLL replacement boundary. A replay implementation must treat a missing or
  inconsistent field as an error, never infer it from the live machine.

## Required architecture before enabling replay

1. **Strict transaction preflight (read-only).**
   - Acquire the same operation lock used by install and uninstall.
   - Read and validate the journal schema, operation, endpoint GUID, transaction
     directory, and exact expected step list.
   - Read state.json and validate its schema and DeviceId against the journal.
   - Canonicalize every recorded backup path and require it to remain beneath
     that transaction's own backup directory (or the explicitly designated
     durable DLL backup directory).
   - Verify every required backup exists and matches its recorded SHA-256.
   - Validate COM export headers/root keys and hashes before any mutation.
   - If any check fails, stop without changing Registry, ACLs, files, or service.

2. **Replay as small, independently journaled idempotent steps.**
   Suggested ordered steps:
   - RestoreEndpointValues
   - RestoreEndpointAcl
   - RestoreComRegistration
   - RestoreDll
   - RestoreInstallerFilesAndShortcut
   - RestoreProgramDataAclAndConfig
   - VerifyPreviousState
   - RestartAudioService (only if the rollback contract requires it)
   Each step must use the journal's Action/Verify protocol. An incomplete step
   may be re-entered after a crash; its action must converge on the snapshot
   rather than toggle or delete unrelated state.

3. **Ownership and scope constraints.**
   - Registry writes/deletes must be limited to the exact endpoint and MicBridge
     CLSID/APO keys recorded by this transaction.
   - Preserve vendor EFX entries that appeared after the snapshot unless the
     transaction can prove they were introduced by this install attempt.
   - Restore ACLs only from the transaction's validated SDDL snapshot.
   - Never alter AudioDG protection settings.
   - Do not remove a directory that contains files not owned by this transaction.
   - Do not delete snapshots or journals until every verification step succeeds.

4. **Verification.**
   Compare actual registry value existence, kind and data; endpoint key
   existence; SDDL; COM tree state; file existence and SHA-256; shortcut hash;
   and saved configuration/ACL state. A mismatch leaves the journal pending
   and the installer fail-closed.

## Test requirements

- Unit tests for malformed/missing state, wrong endpoint GUID, path traversal,
  backup hash mismatch, malformed COM export, and stale/foreign transaction.
- Child-process crash injection after each external effect but before journal
  completion, followed by a fresh-process replay.
- Re-running a completed step must not change the restored state.
- Tests must distinguish mocked Registry/ACL/service effects from real Windows
  integration tests. A marker standing in for a service restart is not evidence
  that Audiosrv was restarted.
- CI parser tests and all existing installer/uninstaller tests must pass.

## Release gate

Do not enable automatic replay, remove the startup fail-closed guard, publish
an install artifact as release-ready, or ask the user to install until the
preflight, replay, crash-injection, verification, and artifact checks above
are implemented and green.
