#include "MicBridgeBootstrapTrust.h"

#include <windows.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <bcrypt.h>

#include <array>
#include <vector>

#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "bcrypt.lib")

namespace {
constexpr wchar_t kPinnedSignerSha256[] =
    L"CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369";

bool IsPinnedCertificate(PCCERT_CONTEXT certificate)
{
    if (certificate == nullptr) return false;

    std::array<BYTE, 32> digest{};
    DWORD digestSize = static_cast<DWORD>(digest.size());
    if (!CryptHashCertificate2(BCRYPT_SHA256_ALGORITHM, 0, nullptr,
                               certificate->pbCertEncoded,
                               certificate->cbCertEncoded,
                               digest.data(), &digestSize) ||
        digestSize != digest.size()) {
        return false;
    }

    static constexpr wchar_t hex[] = L"0123456789ABCDEF";
    wchar_t actual[65]{};
    for (size_t i = 0; i < digest.size(); ++i) {
        actual[i * 2] = hex[digest[i] >> 4];
        actual[i * 2 + 1] = hex[digest[i] & 0x0F];
    }
    return CompareStringOrdinal(actual, -1, kPinnedSignerSha256, -1, TRUE) == CSTR_EQUAL;
}

bool ExtractAndCheckSigner(const std::wstring& filePath)
{
    DWORD encoding = 0, contentType = 0, formatType = 0;
    HCERTSTORE store = nullptr;
    HCRYPTMSG message = nullptr;
    bool valid = false;

    if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, filePath.c_str(),
                          CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                          CERT_QUERY_FORMAT_FLAG_BINARY, 0,
                          &encoding, &contentType, &formatType,
                          &store, &message, nullptr)) {
        return false;
    }

    DWORD signerBytes = 0;
    if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr, &signerBytes) &&
        signerBytes >= sizeof(CMSG_SIGNER_INFO)) {
        std::vector<BYTE> buffer(signerBytes);
        if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0,
                             buffer.data(), &signerBytes)) {
            const auto* signer = reinterpret_cast<const CMSG_SIGNER_INFO*>(buffer.data());
            CERT_INFO query{};
            query.Issuer = signer->Issuer;
            query.SerialNumber = signer->SerialNumber;
            PCCERT_CONTEXT certificate = CertFindCertificateInStore(
                store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0,
                CERT_FIND_SUBJECT_CERT, &query, nullptr);
            if (certificate != nullptr) {
                valid = IsPinnedCertificate(certificate);
                CertFreeCertificateContext(certificate);
            }
        }
    }

    if (message) CryptMsgClose(message);
    if (store) CertCloseStore(store, 0);
    return valid;
}
}

namespace micbridge::bootstrap {
bool VerifyPinnedAuthenticodeSigner(const std::wstring& filePath)
{
    if (filePath.empty()) return false;

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
    trust.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(nullptr, &policy, &trust);

    if (status != ERROR_SUCCESS) return false;
    return ExtractAndCheckSigner(filePath);
}
}
