#include "MicBridgeBootstrapTrust.h"

#include <windows.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <bcrypt.h>

#include <array>
#include <cstddef>

#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "bcrypt.lib")

namespace micbridge {
namespace bootstrap {
namespace detail {

constexpr wchar_t kPinnedSignerSha256[] =
    L"CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369";

bool CertificateEncodingMatchesSha256(const BYTE* encoded, DWORD encodedSize,
                                         const wchar_t* expectedSha256)
{
    if (encoded == nullptr || encodedSize == 0 || expectedSha256 == nullptr ||
        expectedSha256[0] == L'\\0') {
        return false;
    }

    std::array<BYTE, 32> digest{};
    DWORD digestSize = static_cast<DWORD>(digest.size());
    if (!CryptHashCertificate2(BCRYPT_SHA256_ALGORITHM, 0, nullptr,
                               encoded, encodedSize, digest.data(), &digestSize) ||
        digestSize != digest.size()) {
        return false;
    }

    static constexpr wchar_t hex[] = L"0123456789ABCDEF";
    wchar_t actual[65]{};
    for (std::size_t i = 0; i < digest.size(); ++i) {
        actual[i * 2] = hex[digest[i] >> 4];
        actual[i * 2 + 1] = hex[digest[i] & 0x0F];
    }

    return CompareStringOrdinal(actual, -1, expectedSha256, -1, TRUE) == CSTR_EQUAL;
}

bool IsPinnedCertificate(PCCERT_CONTEXT certificate)
{
    return certificate != nullptr &&
        CertificateEncodingMatchesSha256(certificate->pbCertEncoded,
                                          certificate->cbCertEncoded,
                                          kPinnedSignerSha256);
}

bool ExtractAndCheckSigner(WINTRUST_DATA& trust)
{
    if (trust.hWVTStateData == nullptr) {
        return false;
    }

    CRYPT_PROVIDER_DATA* provider = WTHelperProvDataFromStateData(trust.hWVTStateData);
    if (provider == nullptr) {
        return false;
    }

    CRYPT_PROVIDER_SGNR* signer = WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0);
    if (signer == nullptr || signer->csCertChain == 0) {
        return false;
    }

    CRYPT_PROVIDER_CERT* signerCertificate = WTHelperGetProvCertFromChain(signer, 0);
    if (signerCertificate == nullptr || signerCertificate->pCert == nullptr) {
        return false;
    }

    return IsPinnedCertificate(signerCertificate->pCert);
}

} // namespace detail

#ifdef MICBRIDGE_BOOTSTRAP_TESTING
bool TestCertificateEncodingMatchesSha256Pin(const BYTE* encoded, DWORD encodedSize,
                                              const wchar_t* expectedSha256)
{
    return detail::CertificateEncodingMatchesSha256(encoded, encodedSize, expectedSha256);
}
#endif

bool VerifyPinnedAuthenticodeSigner(const std::wstring& filePath)
{
    if (filePath.empty()) {
        return false;
    }

    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = filePath.c_str();

    WINTRUST_DATA trust{};
    trust.cbStruct = sizeof(trust);
    trust.dwUIChoice = WTD_UI_NONE;
    trust.fdwRevocationChecks = WTD_REVOKE_NONE;
    trust.dwUnionChoice = WTD_CHOICE_FILE;
    trust.pFile = &fileInfo;
    trust.dwStateAction = WTD_STATEACTION_VERIFY;
    trust.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL |
                        WTD_REVOCATION_CHECK_NONE |
                        WTD_DISABLE_MD2_MD4;

    GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    const LONG status = WinVerifyTrust(nullptr, &policy, &trust);
    const bool signerPinned =
        status == ERROR_SUCCESS && detail::ExtractAndCheckSigner(trust);

    trust.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(nullptr, &policy, &trust);

    return status == ERROR_SUCCESS && signerPinned;
}

} // namespace bootstrap
} // namespace micbridge
