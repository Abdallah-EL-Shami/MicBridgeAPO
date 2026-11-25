# Engineering review status

Branch: `integration/apo-runtime-hardening`

This is an implementation status report, not release approval. Code changes have been made, but target-machine activation and the latest Windows CI result remain unverified.

## Implemented on this branch

- Corrected COM class-factory reference accounting, added LockServer accounting, and expanded the COM smoke test.
- Waited for both UDP worker sockets to become ready before setting the bridge active; startup failures leave the APO in safe pass-through.
- Wired the tested Blender into APOProcess for gradual dry/wet transitions, underrun fallback, recovery, and overrun control.
- Replaced the duplicate receive-side interpolation loop with the stateful, portable LinearResampler used by core tests.
- Added stricter Float32 format validation for channel count, sample rate, block alignment, average byte rate, valid bits, and channel-mask consistency.
- Implemented deferred Reset requests so the processing thread and receive worker reset only the state they own.
- Added an atomic latency report based on the configured jitter-buffer target.
- Changed endpoint-effect registration to use PKEY_CompositeFX_EndpointEffectClsid (REG_MULTI_SZ) on Windows 10 1803+, preserving the original composite list and restoring the legacy single-CLSID value from the original backup.
- Added a separate composite-EFX recovery record; the original first-install backup.json is not overwritten by this new record.
- Added per-attempt installer snapshots for endpoint registry values, endpoint ACLs, audio policy value, COM registration keys, DLL state, selected install files, shortcut, and configuration ACLs. The installer catch path attempts to restore that snapshot rather than blindly invoking uninstall.

## Still unverified / remaining engineering work

1. The expanded Windows build and test suite has not yet been confirmed green for the latest commit. No package from the latest source should be installed until CI is verified.
2. Static installer checks are not a PowerShell execution test. The transaction rollback must be exercised on a disposable Windows VM with injected failures at each mutation stage.
3. The uninstaller still needs a full failure-atomicity pass, including what happens if restoration of one registry value or ACL fails midway.
4. Composite EFX registration preserves the prior CLSID list but does not prove Audio Engine activation, effect order, or compatibility with the exact Realtek driver. Verify on the target endpoint.
5. ReaStream's 47-byte header and planar Float32 interpretation are empirical assumptions. Validate the exact plugin version, mono/stereo packet layout, chunk sizes, and sample-rate behavior with a packet capture.
6. The current 4096-byte receive-payload ceiling is a defensive cap, not a proven maximum for every ReaStream version. Larger packets are rejected.
7. Socket startup readiness is checked, but persistent runtime worker-health reporting and recovery after an unexpected worker exit still need implementation.
8. The APO's use of APO_FLAG_INPLACE, frame-count constraints, and real-time memory residency need a final Windows SDK contract review.
9. GetLatency reports the configured jitter target, not a measured network round-trip or worst-case end-to-end delay.
10. No target-machine Audio Engine integration test has yet demonstrated COM activation, format negotiation, LockForProcess, APOProcess, and audible capture-graph insertion.

## Release gate

Do not install or distribute a release build until:
- the exact commit has a green Windows build and test run;
- transaction rollback and uninstall restoration pass failure-injection tests on a disposable Windows VM;
- the target endpoint's composite EFX chain is observed and verified with the Realtek driver;
- the installed ReaStream version's packet layout and rate conversion are verified from captures;
- the APO is observed in the intended audiodg.exe capture graph with successful format negotiation and LockForProcess;
- sustained audio tests confirm no clicks, stale packets, unexpected latency, or stuck worker threads;
- the security impact of DisableProtectedAudioDG is justified, minimized, and documented.

Never modify `main` or overwrite the user's original `backup.json` as part of diagnostic work.
