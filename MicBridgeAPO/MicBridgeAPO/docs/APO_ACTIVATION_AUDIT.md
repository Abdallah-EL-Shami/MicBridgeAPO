# APO activation audit

Branch: `integration/sonnet-core-review`

## Scope

This pass isolates Windows Audio Engine activation from the UDP/ReaStream runtime. The source reviewed is the current `src/MicBridgeAPO.cpp`; this document does not claim that activation has been fixed or that the APO has run inside `audiodg.exe`.

## Confirmed from the current source

- The COM class factory exports `DllGetClassObject` and `DllCanUnloadNow`; the x64 DLL was previously loadable and its class factory could create both `IUnknown` and `IAudioProcessingObject` in a standalone PowerShell test.
- `QueryInterface` exposes the four core interfaces expected of a system-effects APO: `IAudioProcessingObject`, `IAudioProcessingObjectConfiguration`, `IAudioProcessingObjectRT`, and `IAudioSystemEffects`.
- `GetRegistrationProperties` allocates and returns one `APO_REG_PROPERTIES` record. It reports one interface IID, `IAudioProcessingObject`.
- `Initialize` currently returns `S_OK` without validating or recording the initialization payload.
- `IsInputFormatSupported` and `IsOutputFormatSupported` accept only 32-bit float and require matching sample rate/channel count when an opposite format is supplied.
- `LockForProcess` validates only connection counts and the top-level arrays. It does not validate the individual descriptors/formats before reading them, and it returns `S_OK` after calling `StartBridge`.
- The first normal log line is written from `StartBridge`, which is called by `LockForProcess`. There is no stage logging in DLL entry, class creation, `Initialize`, or either format-negotiation method.
- `Log` silently returns if it cannot open the ProgramData log file. Therefore an empty log does not prove that the DLL was never loaded; it also fits an earlier activation failure or a log-access/path failure.
- The real-time `APOProcess` currently performs only memory copies/loops/atomics and signals an event; it does not write the log file. Keep all diagnostic file I/O out of `APOProcess`.

## What Windows activation monitoring tells us

Microsoft documents that the Audio Engine tracks failures from `CoCreateInstance`, `IsInputFormatSupported`, `IsOutputFormatSupported`, and `LockForProcess`. A successful `LockForProcess` is a strong indication that the APO entered the graph. This makes the current logging gap important: we cannot tell which of these stages is failing from the existing empty log.

References:
- Microsoft, Implementing Audio Processing Objects: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/implementing-audio-processing-objects
- Microsoft, APO_REG_PROPERTIES: https://learn.microsoft.com/en-us/windows/win32/api/audioenginebaseapo/ns-audioenginebaseapo-apo_reg_properties
- Microsoft, IAudioProcessingObjectRT::APOProcess: https://learn.microsoft.com/en-us/windows/win32/api/audioenginebaseapo/nf-audioenginebaseapo-iaudioprocessingobjectrt-apoprocess

## Next engineering step

1. Add non-real-time, stage-specific diagnostics to class factory creation, `Initialize`, format negotiation, `LockForProcess`, and `UnlockForProcess`. Record HRESULTs, format tag/subformat, sample rate, channel count, bit depth, frame count, and whether the log open succeeded. Add `OutputDebugStringW/A` fallback so a file ACL/path problem cannot erase all evidence.
2. Harden pointer/descriptor validation in `LockForProcess` and format methods, returning documented failure HRESULTs rather than dereferencing malformed descriptors.
3. Build a small x64 diagnostic executable that calls `GetRegistrationProperties`, checks all expected interface QIs, supplies valid and invalid media types, and exercises `Initialize`/format negotiation. This is a unit/COM diagnostic only; it cannot substitute for a real Audio Engine activation test.
4. Only after those checks, investigate endpoint property-store selection, protected-audio policy, and actual `audiodg.exe` module loading on the user's Windows machine.

## Not changed in this pass

No APO source, installer, registry, or device settings have been modified. The existing installation should remain untouched. The UDP worker lifecycle, ReaStream packet semantics, and DSP integration are separate follow-up tasks and are not activation fixes.
