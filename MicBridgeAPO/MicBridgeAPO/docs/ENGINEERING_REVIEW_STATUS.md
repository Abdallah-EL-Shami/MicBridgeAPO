# Engineering review status

Branch: `integration/apo-runtime-hardening`

This document distinguishes implemented changes from items that remain unverified. It is not a release approval.

## Implemented on this branch

- Corrected the class factory's COM reference accounting: successful QueryInterface calls AddRef; AddRef/Release update both the factory-local count and the module-wide factory reference count.
- Added LockServer accounting and included factory references and server locks in DllCanUnloadNow.
- Expanded the COM smoke test to exercise factory identity, balanced AddRef/Release, balanced nested LockServer calls, rejection of an unmatched unlock, and unloadability after references are released.
- Added an explicit audio-format contract document. The Control Panel's 24-bit hardware format is not treated as proof that the APO connection is PCM24; the APO continues to accept IEEE Float32 only until the negotiated format is observed or PCM24 conversion is implemented and tested.
- Added UDP worker startup readiness states. The bridge is marked active only after both the send socket and receive socket have completed their initial setup. Invalid broadcast/bind addresses and socket/bind failures leave the APO in safe pass-through instead of falsely logging a fully started bridge.

## Confirmed limitations / remaining work

1. The COM smoke test is not an Audio Engine integration test. It still does not exercise real IAudioMediaType negotiation, LockForProcess descriptors, APOProcess buffer contracts, or activation in audiodg.exe.
2. No target-machine evidence yet proves whether this endpoint APO receives Float32 or PCM24. Do not loosen the Float32 check or reinterpret PCM24 bytes as floats.
3. The installer/uninstaller need a transaction/rollback review. In particular, failure after registry/endpoint changes must restore only values and ACLs owned by this installer, while preserving the original backup file and unrelated vendor properties.
4. EFX selection precedence against the Realtek endpoint's existing effects has not been demonstrated. Registry presence alone is not proof of graph activation.
5. ReaStream interoperability needs a version-specific capture test for actual packet framing, planar/interleaved layout, mono/stereo, chunk boundaries, and sample-rate conversion. The existing golden packet tests are useful but do not establish all plugin versions' behavior.
6. Socket startup readiness only covers initial setup. It does not yet expose a persistent runtime health state if a worker unexpectedly terminates after startup.
7. The current linear resampler in RecvLoop is separate from the tested core resampler; consolidate them only after verifying phase continuity and packet-boundary behavior.
8. Review APO Reset semantics, reported latency, format structural validation (block alignment, average byte rate, channel mask/subformat), and whether APO_FLAG_INPLACE is fully justified by all processing paths.
9. CI must compile and run the expanded tests. A green COM/core test suite still does not replace target Audio Engine integration evidence.

## Release gate

Do not install or distribute a release build until:
- Windows CI is green for the exact commit;
- format negotiation and LockForProcess logs are reviewed on the target machine;
- the APO is observed in the intended capture graph;
- loopback tests establish ReaStream packet compatibility and stable audio behavior;
- installer failure/rollback and uninstall restoration are tested against a preserved backup;
- security impact of DisableProtectedAudioDG is justified, minimized, and documented.

Never modify `main` or overwrite the user's original `backup.json` as part of diagnostic work.
