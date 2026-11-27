#include <windows.h>

#include <iostream>
#include <string>
#include <vector>

int wmain(int argc, wchar_t** argv)
{
    if (argc != 2) {
        std::wcerr << L"Expected the bootstrap executable path.\n";
        return 2;
    }

    std::wstring command = L"\"" + std::wstring(argv[1]) + L"\"";
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(argv[1], mutableCommand.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        std::wcerr << L"CreateProcessW failed: " << GetLastError() << L"\n";
        return 3;
    }

    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 0;
    const BOOL gotExitCode = GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);

    if (!gotExitCode || exitCode != 78) {
        std::wcerr << L"Bootstrap did not fail closed (exit=" << exitCode << ").\n";
        return 4;
    }

    std::wcout << L"PASS: bootstrap refuses to proceed before verification is implemented.\n";
    return 0;
}
