#pragma once

#include <windows.h>

#include <string>

namespace micbridge::bootstrap {
    // Requires a valid Windows Authenticode trust result and the pinned
    // release-signing certificate SHA-256 fingerprint.
    bool VerifyPinnedAuthenticodeSigner(const std::wstring& filePath);
}
