#include "MicBridgeBootstrapTrust.h"

#include <windows.h>
#include <wincrypt.h>
#include <bcrypt.h>

#include <array>
#include <cstddef>

#include <iostream>
#include <string>

namespace {
bool TestCertificatePinComparison()
{
    // Deterministic test bytes are sufficient here: this unit isolates the
    // SHA-256 pin comparator, not certificate-chain or Authenticode policy.
    const std::array<BYTE, 8> fixture{{0x30, 0x06, 0x02, 0x01, 0x01, 0x04, 0x01, 0x00}};
    std::array<BYTE, 32> digest{};
    DWORD digestSize = static_cast<DWORD>(digest.size());
    if (!CryptHashCertificate2(BCRYPT_SHA256_ALGORITHM, 0, nullptr,
                               fixture.data(), static_cast<DWORD>(fixture.size()),
                               digest.data(), &digestSize) || digestSize != digest.size()) {
        std::wcerr << L"FAIL: could not hash deterministic pin-test fixture.\n";
        return false;
    }

    static constexpr wchar_t hex[] = L"0123456789abcdef";
    wchar_t expected[65]{};
    for (std::size_t i = 0; i < digest.size(); ++i) {
        expected[i * 2] = hex[digest[i] >> 4];
        expected[i * 2 + 1] = hex[digest[i] & 0x0F];
    }

    if (!micbridge::bootstrap::TestCertificateEncodingMatchesSha256Pin(
            fixture.data(), static_cast<DWORD>(fixture.size()), expected)) {
        std::wcerr << L"FAIL: matching SHA-256 pin was rejected.\n";
        return false;
    }
    if (micbridge::bootstrap::TestCertificateEncodingMatchesSha256Pin(
            fixture.data(), static_cast<DWORD>(fixture.size()),
            L"0000000000000000000000000000000000000000000000000000000000000000")) {
        std::wcerr << L"FAIL: mismatching SHA-256 pin was accepted.\n";
        return false;
    }
    if (micbridge::bootstrap::TestCertificateEncodingMatchesSha256Pin(
            nullptr, static_cast<DWORD>(fixture.size()), expected) ||
        micbridge::bootstrap::TestCertificateEncodingMatchesSha256Pin(
            fixture.data(), 0, expected) ||
        micbridge::bootstrap::TestCertificateEncodingMatchesSha256Pin(
            fixture.data(), static_cast<DWORD>(fixture.size()), L"")) {
        std::wcerr << L"FAIL: malformed pin-comparison input was accepted.\n";
        return false;
    }
    return true;
}
}

int wmain(int argc, wchar_t** argv)
{
    if (!TestCertificatePinComparison()) return 6;\n\n    if (argc != 2) {
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
        << L"PASS: matching/mismatching SHA-256 pins, malformed inputs, and unsigned executable rejection are verified.\n";
    return 0;
}
