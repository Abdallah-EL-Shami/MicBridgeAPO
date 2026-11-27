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
    if (micbridge::bootstrap::VerifyPinnedAuthenticodeSigner(argv[1])) {
        std::wcerr << L"FAIL: unsigned test executable unexpectedly passed Authenticode pinning.\n";
        return 3;
    }
    std::wcout << L"PASS: unsigned executable rejected by Authenticode trust/pin verification.\n";
    return 0;
}
