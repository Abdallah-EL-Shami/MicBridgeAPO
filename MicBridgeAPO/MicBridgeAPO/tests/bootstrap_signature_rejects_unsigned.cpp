#include "MicBridgeBootstrapTrust.h"

#include <windows.h>

#include <iostream>
#include <string>

int wmain(int argc, wchar_t** argv)
{
    if (argc != 2) {
        std::wcerr << L"Expected an unsigned test executable path.\n";
        return 2;
    }

    if (micbridge::bootstrap::VerifyPinnedAuthenticodeSigner(L"")) {
        std::wcerr << L"FAIL: empty path unexpectedly passed Authenticode pinning.\n";
        return 3;
    }

    const std::wstring missingPath =
        std::wstring(argv[1]) + L".micbridge-intentionally-missing";
    if (micbridge::bootstrap::VerifyPinnedAuthenticodeSigner(missingPath)) {
        std::wcerr << L"FAIL: nonexistent file unexpectedly passed Authenticode pinning.\n";
        return 4;
    }

    if (micbridge::bootstrap::VerifyPinnedAuthenticodeSigner(argv[1])) {
        std::wcerr << L"FAIL: unsigned test executable unexpectedly passed Authenticode pinning.\n";
        return 5;
    }

    std::wcout
        << L"PASS: empty path, nonexistent file, and unsigned executable are rejected.\n";
    return 0;
}
