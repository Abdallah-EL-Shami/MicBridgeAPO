# Audio format contract

## Three different formats must not be conflated

1. **Hardware/device format** — the AT2040USB format shown by Windows Sound Control Panel. The user currently sees 24-bit PCM here.
2. **Audio Engine / APO connection format** — the format negotiated between the Windows Audio Engine and this APO. The APO accepts IEEE Float32 only.
3. **ReaStream transport format** — the bridge's UDP payload is Float32. It is independent of the USB device's advertised PCM format.

A 24-bit PCM device format does not, by itself, mean the APO receives 24-bit PCM buffers. In shared-mode audio, Windows can convert between standard PCM stream formats and the floating-point samples used internally by the audio engine. Microsoft's format-negotiation documentation describes the engine's proposed format for LFX; the actual format passed to this endpoint APO must still be confirmed from its own negotiation and LockForProcess diagnostics.

## Current format validation

The APO accepts plain IEEE_FLOAT or WAVE_FORMAT_EXTENSIBLE with IEEE_FLOAT subformat, 32 valid bits, 1–8 channels, sample rates from 8 kHz to 384 kHz, consistent block alignment and average byte rate, and a channel mask whose population matches the channel count when a mask is supplied. Input and output layouts must also agree on rate, channels, bit depth, block alignment, average byte rate, and channel mask.

It does not reinterpret 24-bit PCM bytes as floats. Supporting PCM24 requires a real conversion path and matching output-format negotiation, not merely relaxing a bit-depth check.

## ReaStream payload contract and limits

- The current implementation parses a 47-byte header and a Float32 payload, with a receive payload ceiling of 4096 bytes.
- It accepts mono or stereo return packets only; stereo is downmixed by averaging the two channels.
- The implementation treats payloads as planar Float32. This remains an observed/inferred protocol assumption, not an official ReaStream specification. Validate it against the exact installed ReaStream version with captured mono and stereo packets before release.
- Receive-side sample-rate conversion now uses the same stateful LinearResampler implementation exercised by portable tests. A sample-rate change resets its phase/history.
- The APO output uses the tested Blender for a gradual dry/wet transition, underrun fallback, recovery, and queue-overrun control.
- The bridge reports its configured jitter-buffer target as APO latency. Actual end-to-end network latency can vary and is not fully represented by this target.

## EFX coexistence

On Windows 10 version 1803 and later, the installer registers MicBridge in PKEY_CompositeFX_EndpointEffectClsid (property ID 15, REG_MULTI_SZ) and preserves the original composite list in a separate recovery record. It restores the original legacy PKEY_FX_EndpointEffectClsid value rather than replacing it with MicBridge. The uninstaller removes only MicBridge from the live list and retains other entries, including vendor APOs added after installation.

This preserves the prior EFX CLSIDs in the registry, but it does not prove that Windows activates the complete chain or that the chosen order is appropriate for every Realtek APO. Verify actual graph activation and audio ordering on the target machine.

## Required verification before release

- Capture the APO's format-negotiation and LockForProcess logs on the target Windows 10 machine.
- Confirm the negotiated input/output formats and frame counts on the target Audio Engine.
- Capture actual ReaStream packets from the installed plugin version and verify header fields, planar/interleaved layout, mono/stereo, packet size, and rate changes.
- Verify that Windows builds the intended composite EFX chain and that Realtek processing is preserved in the expected order.
- Test startup, sustained processing, underrun, recovery, and application close/reopen behavior.
