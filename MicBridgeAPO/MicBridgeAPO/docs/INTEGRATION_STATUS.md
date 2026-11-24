# Integration branch status

Branch: `integration/sonnet-core-review`, based on the original `main`.

## Imported and corrected
- `src/mb_core.h`: portable DSP/protocol core from the Sonnet repository, with defensive validation and fixes.
- `tests/core_tests.cpp`: imported core tests, corrected include path, portable PI constant, and honest labeling of the synthetic channel-layout test.
- `design/mb_win.h`: retained as an architectural proposal only. It contains declarations, not implementations, and is not linked into the APO.
- CMake: Windows APO build is separated from portable core tests.

## Corrections in the portable core
- Validate pointers, channel count, sample rate, and payload size before multiplication.
- Normalize SPSC ring capacity to a power of two, as required by its mask-based indexing.
- Guard invalid inputs in parsing, channel extraction, resampling, and blending.
- During underrun/fallback fade, missing wet samples now fade toward zero instead of freezing the last wet sample.
- The test suite no longer claims its fabricated silent second channel proves the real ReaStream channel layout.

## Not yet integrated or verified
- The existing `src/MicBridgeAPO.cpp` remains the original implementation; it does not yet call the new core.
- `design/mb_win.h` has no corresponding implementation.
- The 47-byte MRSR header was observed in a capture, but the exact packet-size semantics, planar/interleaved channel layout, and full ReaStream compatibility still require independent validation using real packets from the user's Cantabile configuration.
- No Windows x64 build, APO activation, or runtime audio test has been executed in this branch operation.
- The original APO's real-time safety, lifecycle/thread shutdown, format negotiation, logging, status/config mismatch, and installer/uninstaller still require a separate reviewed pass.

## Install safety
This branch is development-only. Do not install it and do not remove the currently working installation until a later release candidate passes Windows build, protocol, Audio Engine activation, live audio, and rollback tests.
