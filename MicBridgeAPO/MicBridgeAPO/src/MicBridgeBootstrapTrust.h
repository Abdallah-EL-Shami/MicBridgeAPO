#pragma once

#include <windows.h>

#include <string>

namespace micbridge::bootstrap {
    // Requires a valid Windows Authenticode trust result and the pinned
    // release-signing certificate SHA-256 fingerprint.
    bool VerifyPinnedAuthenticodeSigner(const std::wstring& filePath);
}

namespace micbridge::bootstrap {
    // Test-only seam; excluded from production builds and never used to set the production pin.
    bool TestCertificateEncodingMatchesSha256Pin(const BYTE* encoded, DWORD encodedSize,
                                                  const wchar_t* expectedSha256);
}
