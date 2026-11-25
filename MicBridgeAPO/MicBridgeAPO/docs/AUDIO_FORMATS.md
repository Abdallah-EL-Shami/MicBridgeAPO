# Audio format contract

## Three different formats must not be conflated

1. **Hardware/device format** — the AT2040USB format shown by Windows Sound Control Panel. The user currently sees 24-bit PCM here.
2. **Audio Engine / APO connection format** — the format negotiated between the Windows Audio Engine and this APO. The APO currently accepts IEEE Float32 only.
3. **ReaStream transport format** — the bridge's UDP payload is Float32. It is independent of the USB device's advertised PCM format.

A 24-bit PCM device format does not, by itself, mean the APO receives 24-bit PCM buffers. In shared-mode audio, Windows can convert between standard PCM stream formats and the floating-point samples used internally by the audio engine. Microsoft's APO format-negotiation documentation says the engine initially proposes its default Float32-based format to the LFX APO. The actual format passed to this endpoint APO must nevertheless be confirmed from its own IsInputFormatSupported / IsOutputFormatSupported diagnostics and LockForProcess log.

References:
- https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/format-negotiation
- https://learn.microsoft.com/en-us/windows/win32/api/audioenginebaseapo/nf-audioenginebaseapo-iaudioprocessingobject-isinputformatsupported
- https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats

## Current implementation decision

The APO deliberately accepts IEEE Float32 (plain IEEE_FLOAT or WAVE_FORMAT_EXTENSIBLE with IEEE_FLOAT subformat). It does not reinterpret 24-bit PCM bytes as floats. This is intentional: a PCM24 buffer has a different sample representation, alignment, and valid-bit contract. Supporting it would require a real conversion path and matching output-format negotiation, not merely changing the bit-depth check.

If Windows actually negotiates PCM24 at this APO's input or output, the current APO will return APOERR_FORMAT_NOT_SUPPORTED and the diagnostic log should show the format tag, sample rate, channel count, bit depth, block alignment, and extra-format size. In that case, the fix is to negotiate a supported Float32 pair (returning a valid suggested format where appropriate) or implement a tested PCM24-to-float conversion path. Do not infer the APO connection format from the Control Panel display.

## Channel policy

- The intended microphone input is mono.
- The APO currently accepts 1–8 Float32 channels at the connection boundary, while the ReaStream return path is converted to mono and copied to each APO output channel.
- ReaStream payload layout is treated as planar Float32. Stereo downmix is arithmetic mean: 0.5 × (L + R).
- ReaStream packet compatibility (including maximum packet size and actual channel layout emitted by the installed ReaStream version) remains a separate integration test; the 47-byte header observation alone does not prove all payload behavior.

## Required verification before release

- Capture the APO's format-negotiation and LockForProcess logs on the target Windows 10 machine.
- Confirm that the negotiated APO input/output formats are Float32 and that input/output channel count, sample rate, block alignment, and frame counts agree.
- If the APO receives PCM24, do not install a build that merely relaxes IsFloat32; implement and test a proper conversion path first.
