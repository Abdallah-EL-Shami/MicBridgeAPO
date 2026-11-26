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

## Legacy installation audit before upgrading an existing installation

This is a separate prerequisite from transaction rollback. A transaction snapshot
records the machine as it exists immediately before the new attempt; it does not
prove that this state is the original Windows state or that an older MicBridge
release did not already leave incorrect changes behind.

### Safety contract

- Run a read-only inventory before creating a new install transaction or changing
  any machine state.
- Treat existing `backup.json`, `composite-efx-backup.json`, COM exports,
  transaction snapshots, journals, install logs, and ownership markers as
  evidence with provenance, not as unquestionable truth.
- A saved snapshot is eligible as a baseline only when its schema, endpoint
  identity, transaction identity where applicable, expected fixed registry root,
  file hash, and creation provenance all validate. A hash proves byte integrity,
  not that the captured values were correct or genuinely pre-install.
- Classify files and registrations as MicBridge-owned only when fixed product
  identity and ownership evidence agree. A matching filename or CLSID alone is
  insufficient; inspect the CLSID's server path and ensure it resolves inside
  the product install directory before considering a registration removable.
- Never infer the original Windows state from the current live state after a
  legacy install has already modified it. If no trustworthy pre-install record
  exists, report the state as unknown and require an explicit recovery decision.
- Never automatically import an old COM export merely because it exists.
  Validate its exact root key, server path, product ownership, schema and hash;
  if it contains a foreign server or unexpected subkeys, preserve it and stop.
- Do not recursively delete a legacy install directory. Remove only individually
  verified MicBridge-owned files; preserve unknown files and any DLL referenced
  by a registration that is being retained.
- Do not change Realtek/vendor APO registrations, unrelated endpoint effects,
  AudioDG security settings, or Windows audio services.
- The audit itself must not write Registry, alter ACLs, stop/restart services,
  delete files, or create a "baseline" by copying the already-modified live state.

### Audit outcomes

1. **Clean / proven compatible:** ownership and required snapshots validate;
   proceed to the normal transaction snapshot and installer preflight.
2. **MicBridge residue proven, original baseline proven:** offer a separately
   journaled cleanup plan limited to those proven product-owned artifacts, then
   re-audit before installation.
3. **Residue proven but original baseline unknown:** do not claim restoration
   to Windows defaults. Preserve evidence and block automatic cleanup; require
   a reviewed recovery plan.
4. **Foreign or ambiguous registration/file:** preserve it and fail closed.

### Required implementation and tests

- Add a read-only `Test-MBLegacyInstallationState` preflight module and invoke it
  before any install mutation or transaction snapshot is created.
- Inventory the fixed product CLSID and AudioEngine APO registration, their
  `InprocServer32` values, referenced DLL paths and hashes, known install/data
  directories, backup metadata, old transaction directories, and ownership
  markers. Report findings without changing them.
- Include fixtures for: a clean machine; a previous MicBridge DLL with a valid
  product registration; a stale MicBridge registration pointing outside the
  install directory; a foreign CLSID tree; missing/old backup schema; mismatched
  endpoint identity; corrupt/tampered COM export; and unknown files in the
  install directory.
- Assert that every audit outcome is read-only by comparing registry exports,
  file hashes, ACLs, and service state before and after the audit.
- Only after this audit is implemented and its Windows CI tests pass may a
  separate, explicit cleanup executor be designed. Cleanup must not be folded
  into ordinary install or rollback actions.

