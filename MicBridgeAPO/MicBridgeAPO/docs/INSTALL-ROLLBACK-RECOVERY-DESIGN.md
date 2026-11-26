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

## Implemented safety increments (not a release gate completion)

- Added `tools/MicBridge.LegacyInstallAudit.psm1` with
  `Test-MBLegacyInstallationState`. It inventories the fixed product CLSID and
  AudioEngine APO registration, server path/hash, and files under the known
  install/data directories. It does not mutate Registry, files, ACLs, or
  services; it never claims that the original Windows baseline is proven and
  always reports `CleanupAllowed = false`.
- The audit now validates the permanent `backup.json` schema, endpoint identity,
  fixed COM backup paths, hashes and Registry roots, plus the composite EFX
  backup schema. It distinguishes a structurally valid backup candidate from
  proof of the true Windows baseline; it never asserts the latter.
- `install.ps1` and `uninstall.ps1` now call this read-only audit before their
  restore-point/recovery-plan and Registry/COM/file mutation phases. Both stop
  on ambiguous legacy state and preserve the files for manual review. The module
  is staged in the install package. No cleanup or automatic repair is performed.
- HKCU/temp-only tests cover missing backup, valid candidate backup, endpoint
  mismatch, tampered COM export, unknown install files, and no mutation of
  Registry/file state. These tests and the installer/uninstaller static checks
  passed in Windows CI run 924.
- Hardened transaction preflight so a hash-valid COM export must also have the
  Windows Registry Editor header, contain the exact fixed MicBridge CLSID or
  AudioEngine APO root, and contain no key outside that root or its children.
  Added a test that rejects an export containing an unrelated CLSID key.
- These changes do not constitute a legacy cleanup routine. A structurally
  valid permanent backup remains evidence, not cryptographic proof of the
  original Windows state. Do not delete or rewrite it automatically.

## COM recovery prototype (isolated, not yet wired into installer)

- Added `MicBridge.ComRegistrationRollback.psm1`. It has only two fixed targets:
  the product CLSID and its AudioEngine APO key. It checks the exact transaction
  filename, snapshot SHA-256, Registry export header/root/child-key bounds, and
  reparse-point-free transaction path before import.
- A saved CLSID snapshot is considered restorable only when its
  `InprocServer32` path resolves to `MicBridgeAPO.dll` inside the fixed install
  directory. If the current CLSID points elsewhere, the action refuses to
  overwrite or delete it. An APO key without a product-owned CLSID is preserved.
- Added `MicBridge.ComRegistrationExecutor.psm1` with a separate durable
  component journal. It deliberately leaves the existing three-step main
  transaction journal pending; it does not claim the entire rollback is done.
- HKCU-only action tests cover restoration of pre-existing CLSID/APO keys,
  removal of keys absent from the snapshot, idempotence, tampered snapshot
  rejection, foreign CLSID preservation, and child-process termination after
  the Registry side effect followed by fresh-process journal resume.
- A full-transaction HKCU fixture now exercises the COM executor alongside the
  DLL executor, including transaction preflight, component journal completion,
  and fresh-process re-entry. The separate COM action test also kills a child
  PowerShell process after the Registry side effect and proves a new process
  completes the Running journal without repeating the import. These tests passed
  in Windows CI run 924.
- Added `MicBridge.InstallFileRollback.psm1` and
  `MicBridge.InstallFileExecutor.psm1`. They restore the four fixed installer
  support files using transaction-owned backups and both original/package SHA-256
  values; they refuse reparse paths and unexpected third-party edits. A separate
  component journal makes restoration idempotent and keeps the grouped main
  transaction step pending.
- The installer now records the exact package hash for each support file before
  publishing the update. Tests cover restoration, idempotence, removal of files
  absent before installation, backup tampering, preservation of externally
  modified files, and fresh-process executor re-entry. Windows CI run 948 passed
  these tests and the existing COM/DLL/endpoint/ACL suites.
- Added `MicBridge.InstallMetadataRollback.psm1` and
  `MicBridge.MetadataExecutor.psm1` for the two configuration files, the
  desktop shortcut, and ProgramData/Control-file ACLs. The installer now records
  hashes for pre-existing config files, exact hashes for new config content, and
  the new shortcut hash before publishing it. Rollback removes only files whose
  bytes match the transaction's recorded hash; it preserves unrelated edits.
- Metadata tests cover created-file removal, shortcut ownership, restoration of
  a missing pre-existing shortcut, ACL restoration (including Windows' derived
  DACL auto-inherited marker), idempotence, and preservation of foreign edits.
  The durable transaction fixture also re-enters metadata recovery from a new
  PowerShell process. Windows CI run 978 passed the complete suite and staged
  the updated installer package.
- Added `MicBridge.FullInstallRollbackExecutor.psm1`. It reconstructs the
  three fixed main rollback steps from the durable transaction snapshot and
  coordinates endpoint FX values, endpoint ACLs, COM, DLL, support files,
  configuration files, shortcut, and ProgramData ACL restoration. The grouped
  `RestorePreviousInstallState` action is now replayable from a fresh process;
  if a pre-existing install directory has disappeared, it fails closed rather
  than recreating it without a captured ACL baseline.
- The full coordinator is exercised in the HKCU/temp transaction fixture after
  the isolated component executors, and a separate PowerShell process re-enters
  the completed transaction. All Windows CI checks, including package staging,
  passed in run 1001.

- The support-file executor is not yet called by startup recovery or the
  installer failure handler.
- The COM executor is still not called by `install.ps1` or startup recovery and
  is not staged into the installer package. The main grouped
  `RestorePreviousInstallState` step is therefore not yet fully replayable
  after process death. Production defaults remain HKLM; all Registry mutation
  tests use HKCU. Do not install this branch yet.
