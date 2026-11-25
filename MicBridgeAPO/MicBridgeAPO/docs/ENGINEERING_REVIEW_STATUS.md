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
- Added a Windows Winsock smoke test for two SO_REUSEADDR listeners receiving the same local-broadcast datagram. The APO receive path uses this shared-port mode for ReaStream and validates sender addresses against the host's local IPv4 interfaces. The target probe reports AudioDG/Cantabile process owners because Windows bind-sharing rules can depend on whether both listeners run under the same account.
- Confirmed the registration flags as APO_FLAG_DEFAULT | APO_FLAG_INPLACE; APOProcess handles both aliased in-place buffers and distinct input/output buffers, and the COM smoke test now asserts this registration contract.
- Changed endpoint-effect registration to use PKEY_CompositeFX_EndpointEffectClsid (REG_MULTI_SZ) on Windows 10 1803+, merging MicBridge into the current vendor list, preserving the original list separately, and removing only MicBridge on uninstall while retaining later vendor additions.
- Added a separate composite-EFX recovery record; the original first-install backup.json is not overwritten, including during legacy-backup compatibility handling.
- Added per-attempt installer snapshots for endpoint registry values, endpoint ACLs, audio policy value, COM registration keys, DLL state, selected install files, shortcut, and configuration ACLs. The installer catch path attempts to restore that snapshot rather than blindly invoking uninstall.

## Still unverified / remaining engineering work

1. The expanded Windows build and test suite has not yet been confirmed green for the latest commit. No package from the latest source should be installed until CI is verified.
2. Static installer checks are not a PowerShell execution test. The transaction rollback must be exercised on a disposable Windows VM with injected failures at each mutation stage.
3. The uninstaller now stops before COM/DLL removal if endpoint ACL restoration fails, but it still needs failure-injection testing for each registry/ACL restoration stage.
4. Composite EFX registration preserves current vendor entries and avoids replacing the legacy single-effect value, but does not prove Audio Engine activation, effect order, or compatibility with the exact Realtek driver. Verify on the target endpoint.
5. ReaStream's 47-byte header and planar Float32 interpretation are empirical assumptions. The Windows UDP shared-broadcast smoke test must pass, and the target Cantabile ReaStream instance must be configured for `127.255.255.255` broadcast (not unicast). Also confirm AudioDG and Cantabile run under compatible user identities; Windows warns that SO_REUSEADDR port sharing can be nondeterministic and vulnerable to local port hijacking. Validate the exact plugin version, mono/stereo packet layout, chunk sizes, and sample-rate behavior with a packet capture.
6. The current 4096-byte receive-payload ceiling is a defensive cap, not a proven maximum for every ReaStream version. Larger packets are rejected.
7. Socket startup readiness is checked, but persistent runtime worker-health reporting and recovery after an unexpected worker exit still need implementation.
8. APO_FLAG_INPLACE is now documented and tested against the SDK contract; frame-count constraints and real-time memory residency still need target Audio Engine review.
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
