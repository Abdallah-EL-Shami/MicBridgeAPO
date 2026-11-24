# Integration branch status

Branch: `integration/sonnet-core-review`, based on the original `main`.

## Imported and corrected portable core

- `src/mb_core.h`: imported the Sonnet portable DSP/protocol core with defensive validation.
- `tests/core_tests.cpp`: corrected include path, portable PI constant, and claims about the synthetic channel-layout test.
- `design/mb_win.h`: retained as an architectural proposal only; it has declarations, not implementations, and is not linked into the APO.
- CMake separates the Windows APO DLL build from portable core tests.
- CI workflows build the Windows DLL and run portable core tests.

## APO activation diagnostic pass (source changes now in this branch)

The existing `src/MicBridgeAPO.cpp` has received a first activation-hardening pass:

- `RegProps()` now uses thread-safe C++ local-static initialization instead of an unsynchronized mutable static flag.
- `Initialize()` accepts the documented empty payload case, rejects a nonzero size with a null pointer, and when a payload is supplied validates the `APOInitBaseStruct` size and CLSID before marking the object initialized.
- `LockForProcess()` now checks initialization state, duplicate locking, connection count, null descriptors/formats, float32 formats, matching input/output sample rate and channel count, supported channel count, and output frame capacity before starting the bridge.
- Format negotiation logs accepted/rejected media types with format tag, sample rate, channel count, bit depth, block alignment, and extra-format size.
- COM factory and class-object activation now have early diagnostic log points; the log also emits to the debugger and reports log-file open failure.
- `UnlockForProcess()` records and guards the lock state.
- Fixed the send-header ID copy to use the actual 32-byte destination size rather than 33.

These are source-level corrections and diagnostic instrumentation. They do **not** prove that Windows has activated the APO, and they do not yet establish the exact cause of the original activation failure.

## Still unverified / separate work

- A fresh Windows x64 build after the latest source edits must pass.
- A real Audio Engine activation test must confirm the sequence through `Initialize`, format negotiation, and `LockForProcess`; standalone COM creation is not enough.
- The 47-byte MRSR header was observed in a capture, but exact packet-size semantics, planar/interleaved channel layout, and full ReaStream compatibility still require independent validation with real packets from the user's Cantabile configuration.
- The original APO's UDP worker lifecycle, socket/thread failure handling, jitter behavior, real-time memory residency, and full APOProcess correctness still need a separate pass.
- UI/config mismatch (`control.ini` vs `MicBridge.ini`), `status.txt` reporting, and installer/uninstaller backup/rollback remain unchanged.
- The installer still sets `DisableProtectedAudioDG=1`; its necessity and security implications have not been resolved.
- The endpoint registration model must be checked against the user's exact Windows 10 build and audio driver. Microsoft documents componentized APO registration for Windows 10 1809 and later; this may affect packaging/registration strategy.

## Install safety

Development-only branch. Do not install it or remove the current installation until Windows x64 build, protocol validation, Audio Engine activation, live audio, and rollback tests pass.
