#include <iostream>

int wmain()
{
    // Deliberately fail closed until independent package verification, file
    // pinning, and an authenticated installer handoff are implemented.
    std::wcerr
        << L"MicBridgeBootstrap: verification is not implemented; "
        << L"installation is blocked.\\n";
    return 78;
}
