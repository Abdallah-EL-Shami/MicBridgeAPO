# Install rollback recovery design

Status: design only; not an implementation or release-readiness claim.

## Current behavior confirmed in install.ps1

- The installer serializes operations with the MicBridge recovery operation lock.
- It scans `ProgramData\\MicBridgeAPO\\transactions-*` for an unfinished
  `rollback-recovery.json` and fails closed. It does not replay the transaction.
- Each install transaction currently declares three journal steps:
  `RestoreEndpointFxValues`, `RestoreEndpointAcl`, and
  `RestorePreviousInstallState`. The first two are independently journaled;
  the third still groups DLL, COM, installer files, shortcut, configuration,
  and ProgramData ACL restoration into one action.
- The rollback action is embedded in the installer's `catch` block. A new
  installer process cannot call that action independently.
- The `RestorePreviousInstallState` action restores DLL, COM registrations,
  installer-owned files, shortcut, ProgramData ACLs, and configuration in one
  large callback. It is not a durable, process-independent executor.
- The rollback catch path deliberately does **not** restart or otherwise control
  `Audiosrv`. Audio-service control is outside the rollback contract and must
  remain out of any recovery executor. The journal can mark a step incomplete
  after a process crash, but there is no transaction-level startup replay.
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
   - If any check fails, stop without changing Registry, ACLs, or files.

2. **Replay as small, independently journaled idempotent steps.**
   Proposed ordered steps:
   - RestoreEndpointFxValues
   - RestoreEndpointAcl
   - RestoreComClsidRegistration
   - RestoreAudioEngineApoRegistration
   - RestoreDll
   - RestoreInstallerFiles
   - RestoreShortcut
   - RestoreProgramDataAcl
   - RestoreConfiguration
   - VerifyPreviousState

   Each step must use the journal's Action/Verify protocol. An incomplete step
   may be re-entered after a crash; its action must converge on the snapshot
   rather than toggle or delete unrelated state. The existing three-step
   journal must not be reinterpreted as this new plan: old or unknown schemas
   remain fail-closed until an explicit compatibility path is implemented.

3. **Executor contract and ownership boundaries.**
   - The executor accepts only a transaction directory and a validated durable
     snapshot/journal; it must not depend on callbacks captured by the installer.
   - Dispatch is by a fixed allow-list of step IDs implemented inside the
     executor. Never deserialize or evaluate script text from the journal.
   - Registry writes/deletes must be limited to the exact endpoint and MicBridge
     CLSID/APO keys recorded by this transaction.
   - Preserve vendor EFX entries that appeared after the snapshot unless the
     transaction can prove they were introduced by this install attempt.
   - Restore ACLs only from the transaction's validated SDDL snapshot.
   - Never alter AudioDG protection settings or control `Audiosrv`.
   - Do not remove a directory that contains files not owned by this transaction.
   - Do not delete snapshots or journals until every verification step succeeds.

4. **Verification.**
   Compare actual registry value existence, kind and data; endpoint key
   existence; SDDL; COM tree state; file existence and SHA-256; shortcut hash;
   and saved configuration/ACL state. A mismatch leaves the journal pending
   and the installer fail-closed.


## Partial implementation added after this design

- `tools/MicBridge.RollbackExecutor.psm1` now exposes
  `Invoke-MBInstallDllRecovery`. It acquires the install/uninstall operation
  lock, validates the existing transaction snapshot and legacy journal, binds
  a separate `dll-recovery.json` journal to the original transaction ID, then
  runs the existing hash-checked DLL restore action and verifier.
- `tools/Test-MBRollbackExecutor.ps1` creates a temporary transaction fixture
  and checks DLL restoration, journal identity, idempotent re-entry, and that
  the original grouped `RestorePreviousInstallState` step remains pending.
- Windows CI runs this test.
- This is deliberately a **DLL-only component executor**, not full transaction
  recovery. It does not restore endpoint values/ACL, COM, support files,
  configuration, shortcut, or directory ACLs; it does not mark the main
  transaction complete; it is not called automatically at installer startup;
  and it is not included in the install package. The fail-closed startup guard
  remains mandatory. Do not use this component as a reason to install or
  manually alter a live transaction until its Windows CI test is green.

## Test requirements

- Unit tests for malformed/missing state, wrong endpoint GUID, path traversal,
  backup hash mismatch, malformed COM export, and stale/foreign transaction.
- Child-process crash injection after each external effect but before journal
  completion, followed by a fresh-process replay that reads only durable files.
- Re-running a completed step must not change the restored state.
- Exercise every executor step independently in temporary directories and
  HKCU-only registry fixtures; do not use real endpoint HKLM state in unit tests.
- CI parser tests and all existing installer/uninstaller tests must pass.

## Release gate

Do not enable automatic replay, remove the startup fail-closed guard, publish
an install artifact as release-ready, or ask the user to install until the
preflight, executor, crash-injection, verification, and artifact checks above
are implemented and green.
