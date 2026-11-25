// MicBridgeAPO.cpp
// Endpoint-effect APO للمايك: يرسل الصوت إلى Cantabile بصيغة ReaStream
// ويستقبل الصوت المعالج بصيغة ReaStream ويضعه مكان المايك.
//
// صيغة حزمة ReaStream (مأخوذة من التقاط Wireshark، كل الأرقام little-endian):
//   0  : "MRSR"            4 بايت
//   4  : حجم الحزمة كاملة   uint32  (47 + حجم الصوت)
//   8  : المعرّف            32 بايت (نص + أصفار)
//   40 : عدد القنوات        uint8
//   41 : معدل العينة        uint32
//   45 : حجم الصوت بالبايت  uint16
//   47 : عينات float32 (أقصاها 1200 بايت = 300 عينة في الحزمة)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <unknwn.h>
#include <objbase.h>
#include <winreg.h>
#include <mmreg.h>
#include <audioenginebaseapo.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <vector>
#include "mb_core.h"

// {A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}
static const GUID CLSID_MicBridgeAPO =
    {0xA3F6C1D2, 0x7B84, 0x4E19, {0x9C, 0x55, 0x2D, 0x8E, 0x1F, 0x0B, 0x6A, 0x47}};

static std::atomic<long> g_objects{0};
static std::atomic<long> g_factoryRefs{0};
static std::atomic<long> g_serverLocks{0};
static HMODULE g_module = nullptr;

// ---------------------------------------------------------------- مسارات وسجل
static void DataPath(wchar_t* out, size_t n, const wchar_t* file) {
    wchar_t base[MAX_PATH];
    DWORD r = GetEnvironmentVariableW(L"ProgramData", base, MAX_PATH);
    if (!r || r >= MAX_PATH) wcscpy_s(base, L"C:\\ProgramData");
    swprintf_s(out, n, L"%s\\MicBridgeAPO\\%s", base, file);
}

static ULONG EnumerateLocalIPv4(std::vector<DWORD>& addresses) {
    addresses.clear();
    addresses.push_back(htonl(INADDR_LOOPBACK));

    ULONG bytes = 0;
    ULONG rc = GetAdaptersAddresses(AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, nullptr, &bytes);
    if (rc == ERROR_NO_DATA) return NO_ERROR;
    if (rc != ERROR_BUFFER_OVERFLOW || bytes == 0) return rc;

    std::vector<BYTE> storage(bytes);
    auto* adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(storage.data());
    rc = GetAdaptersAddresses(AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &bytes);
    if (rc != NO_ERROR) return rc;

    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
            if (!unicast->Address.lpSockaddr || unicast->Address.lpSockaddr->sa_family != AF_INET)
                continue;
            const auto* address = reinterpret_cast<const sockaddr_in*>(unicast->Address.lpSockaddr);
            if (address->sin_addr.s_addr != htonl(INADDR_ANY) &&
                address->sin_addr.s_addr != htonl(INADDR_BROADCAST))
                addresses.push_back(address->sin_addr.s_addr);
        }
    }
    std::sort(addresses.begin(), addresses.end());
    addresses.erase(std::unique(addresses.begin(), addresses.end()), addresses.end());
    return NO_ERROR;
}
static bool IsLocalIPv4(DWORD address, const std::vector<DWORD>& localAddresses) {
    return std::find(localAddresses.begin(), localAddresses.end(), address) != localAddresses.end();
}

static SRWLOCK g_logLock = SRWLOCK_INIT;

static bool Log(const char* fmt, ...) {
    AcquireSRWLockExclusive(&g_logLock);
    bool ok = false;
    wchar_t dir[MAX_PATH], path[MAX_PATH], oldPath[MAX_PATH];
    DataPath(dir, MAX_PATH, L"");
    size_t dirLen = wcslen(dir);
    while (dirLen && (dir[dirLen - 1] == L'\\' || dir[dirLen - 1] == L'/')) dir[--dirLen] = L'\0';
    if (!CreateDirectoryW(dir, nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        OutputDebugStringW(L"[MicBridge] unable to create ProgramData\\MicBridgeAPO directory\n");
        ReleaseSRWLockExclusive(&g_logLock);
        return false;
    }
    DataPath(path, MAX_PATH, L"MicBridge.log");
    DataPath(oldPath, MAX_PATH, L"MicBridge.log.1");

    // Keep a bounded rolling log instead of silently stopping diagnostics at 1 MiB.
    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &fad)) {
        ULARGE_INTEGER size{};
        size.HighPart = fad.nFileSizeHigh;
        size.LowPart = fad.nFileSizeLow;
        if (size.QuadPart > (1ull << 20)) {
            DeleteFileW(oldPath);
            if (!MoveFileExW(path, oldPath, MOVEFILE_REPLACE_EXISTING))
                OutputDebugStringW(L"[MicBridge] warning: could not rotate MicBridge.log\n");
        }
    }

    HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        OutputDebugStringA("[MicBridge] unable to open/create MicBridge.log\n");
        ReleaseSRWLockExclusive(&g_logLock);
        return false;
    }

    char line[768];
    SYSTEMTIME st;
    GetLocalTime(&st);
    int n = _snprintf_s(line, sizeof line, _TRUNCATE, "%04d-%02d-%02d %02d:%02d:%02d.%03d [PID=%lu TID=%lu] ",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
        GetCurrentProcessId(), GetCurrentThreadId());
    if (n < 0) n = 0;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - (size_t)n - 3, fmt, ap);
    va_end(ap);
    strcat_s(line, "\r\n");
    DWORD written = 0;
    ok = WriteFile(h, line, (DWORD)strlen(line), &written, nullptr) && written == strlen(line);
    CloseHandle(h);
    OutputDebugStringA(line);
    ReleaseSRWLockExclusive(&g_logLock);
    return ok;
}

// ---------------------------------------------------------------- فحص تشخيصي مبكر (قراءة فقط)
static bool ReadRegString(HKEY root, const wchar_t* subKey, const wchar_t* valueName,
                          wchar_t* out, DWORD chars) {
    DWORD bytes = chars * sizeof(wchar_t), type = 0;
    if (RegGetValueW(root, subKey, valueName, RRF_RT_REG_SZ, &type, out, &bytes) != ERROR_SUCCESS) {
        if (chars) out[0] = L'\0';
        return false;
    }
    return true;
}
static bool ReadRegDword(HKEY root, const wchar_t* subKey, const wchar_t* valueName, DWORD* value) {
    DWORD bytes = sizeof(DWORD), type = 0;
    return RegGetValueW(root, subKey, valueName, RRF_RT_REG_DWORD, &type, value, &bytes) == ERROR_SUCCESS;
}
static void RunStartupDiagnostics() {
    wchar_t process[MAX_PATH] = L"<unknown>";
    GetModuleFileNameW(nullptr, process, MAX_PATH);
    Log("=== MicBridge diagnostic session start ===");
    Log("Process image: %ls | PID=%lu", process, GetCurrentProcessId());

    wchar_t dllPath[MAX_PATH] = L"<module unavailable>";
    if (g_module) GetModuleFileNameW(g_module, dllPath, MAX_PATH);
    const DWORD attrs = GetFileAttributesW(dllPath);
    Log("Loaded module: %ls | fileExists=%d", dllPath, attrs != INVALID_FILE_ATTRIBUTES);

    wchar_t clsidKey[160], inprocKey[192], apoKey[192], registeredDll[MAX_PATH] = {};
    swprintf_s(clsidKey, L"SOFTWARE\\Classes\\CLSID\\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}");
    swprintf_s(inprocKey, L"%s\\InprocServer32", clsidKey);
    swprintf_s(apoKey, L"SOFTWARE\\Classes\\AudioEngine\\AudioProcessingObjects\\{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}");
    const bool comOk = ReadRegString(HKEY_LOCAL_MACHINE, inprocKey, nullptr, registeredDll, MAX_PATH);
    Log("COM InprocServer32: present=%d path=%ls", comOk, comOk ? registeredDll : L"<missing>");
    wchar_t friendly[256] = {};
    DWORD flags = 0;
    const bool friendlyOk = ReadRegString(HKEY_LOCAL_MACHINE, apoKey, L"FriendlyName", friendly, 256);
    const bool flagsOk = ReadRegDword(HKEY_LOCAL_MACHINE, apoKey, L"Flags", &flags);
    wchar_t iid[128] = {};
    const bool iidOk = ReadRegString(HKEY_LOCAL_MACHINE, apoKey, L"APOInterface0", iid, 128);
    Log("AudioEngine registration: FriendlyName=%ls(%d) Flags=%lu(%d) APOInterface0=%ls(%d)",
        friendly, friendlyOk, flags, flagsOk, iid, iidOk);
    if (comOk && _wcsicmp(registeredDll, dllPath) != 0)
        Log("WARNING: registered COM DLL path differs from loaded module path");

    DWORD protectedDg = 0;
    const bool protectedOk = ReadRegDword(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Audio",
        L"DisableProtectedAudioDG", &protectedDg);
    Log("DisableProtectedAudioDG: present=%d value=%lu", protectedOk, protectedDg);

    wchar_t ini[MAX_PATH] = {};
    DataPath(ini, MAX_PATH, L"MicBridge.ini");
    const DWORD iniAttrs = GetFileAttributesW(ini);
    Log("Config file: %ls | exists=%d", ini, iniAttrs != INVALID_FILE_ATTRIBUTES);
    if (iniAttrs != INVALID_FILE_ATTRIBUTES) {
        wchar_t enabled[16] = {}, port[16] = {}, sendId[64] = {}, recvId[64] = {};
        GetPrivateProfileStringW(L"Bridge", L"Enabled", L"<default:1>", enabled, 16, ini);
        GetPrivateProfileStringW(L"Bridge", L"Port", L"<default:58710>", port, 16, ini);
        GetPrivateProfileStringW(L"Bridge", L"SendId", L"<default>", sendId, 64, ini);
        GetPrivateProfileStringW(L"Bridge", L"ReceiveId", L"<default>", recvId, 64, ini);
        Log("Config values: Enabled=%ls Port=%ls SendId=%ls ReceiveId=%ls", enabled, port, sendId, recvId);
    }

    // Scan active/inactive capture endpoint FxProperties without changing the registry.
    HKEY capture = nullptr;
    LONG openRc = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Capture",
        0, KEY_READ, &capture);
    unsigned matched = 0;
    if (openRc == ERROR_SUCCESS) {
        for (DWORD index = 0;; ++index) {
            wchar_t endpoint[256]; DWORD cch = 256;
            LONG enumRc = RegEnumKeyExW(capture, index, endpoint, &cch, nullptr, nullptr, nullptr, nullptr);
            if (enumRc == ERROR_NO_MORE_ITEMS) break;
            if (enumRc != ERROR_SUCCESS) continue;
            wchar_t fxKey[512], effect[128] = {}, association[128] = {};
            swprintf_s(fxKey, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Capture\\%s\\FxProperties", endpoint);
            const bool effectOk = ReadRegString(HKEY_LOCAL_MACHINE, fxKey,
                L"{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D},7", effect, 128);
            if (effectOk && _wcsicmp(effect, L"{A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}") == 0) {
                DWORD state = 0;
                wchar_t stateKey[512];
                swprintf_s(stateKey, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Capture\\%s", endpoint);
                const bool stateOk = ReadRegDword(HKEY_LOCAL_MACHINE, stateKey, L"DeviceState", &state);
                const bool assocOk = ReadRegString(HKEY_LOCAL_MACHINE, fxKey,
                    L"{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D},0", association, 128);
                ++matched;
                Log("APO endpoint match #%u: id=%ls DeviceState=%lu(present=%d) Association=%ls(present=%d)",
                    matched, endpoint, state, stateOk, assocOk ? association : L"<missing>", assocOk);
            }
        }
        RegCloseKey(capture);
    } else {
        Log("WARNING: cannot enumerate Capture endpoints, registry error=%ld", openRc);
    }
    Log("Capture endpoints registered to this APO: %u", matched);
    if (!matched) Log("WARNING: no Capture endpoint currently references this APO CLSID");
    Log("=== Startup diagnostic checks completed ===");
}

// ---------------------------------------------------------------- الإعدادات
struct Config {
    char sendId[33];
    char recvId[33];
    char bcast[64];
    char bind[64];
    int port;
    bool enabled;
    bool fallback;
    int jitterMs;
};

static void ReadStr(const wchar_t* key, const wchar_t* def, const wchar_t* ini, char* out, size_t max) {
    wchar_t w[128];
    GetPrivateProfileStringW(L"Bridge", key, def, w, 128, ini);
    char tmp[256] = {};
    WideCharToMultiByte(CP_UTF8, 0, w, -1, tmp, sizeof tmp - 1, nullptr, nullptr);
    strncpy_s(out, max + 1, tmp, max);
}

static void LoadConfig(Config& c) {
    wchar_t ini[MAX_PATH];
    DataPath(ini, MAX_PATH, L"MicBridge.ini");
    memset(&c, 0, sizeof c);
    ReadStr(L"SendId", L"APO_MIC_RAW", ini, c.sendId, 32);
    ReadStr(L"ReceiveId", L"APO_MIC_FX", ini, c.recvId, 32);
    ReadStr(L"BroadcastAddress", L"127.255.255.255", ini, c.bcast, 63);
    ReadStr(L"BindAddress", L"0.0.0.0", ini, c.bind, 63);
    c.port = (int)GetPrivateProfileIntW(L"Bridge", L"Port", 58710, ini);
    c.enabled = GetPrivateProfileIntW(L"Bridge", L"Enabled", 1, ini) != 0;
    c.fallback = GetPrivateProfileIntW(L"Bridge", L"Fallback", 1, ini) != 0;
    c.jitterMs = (int)GetPrivateProfileIntW(L"Bridge", L"JitterBufferMs", 40, ini);
    if (c.jitterMs < 10) c.jitterMs = 10;
    if (c.jitterMs > 500) c.jitterMs = 500;
}

// ---------------------------------------------------------------- Ring buffer (منتج واحد / مستهلك واحد)
class FloatRing {
public:
    static constexpr uint64_t N = 1u << 16;  // 65536 عينة
    FloatRing() : buf(N) {}
    uint64_t available() const { return head.load(std::memory_order_acquire) - tail.load(std::memory_order_acquire); }
    void push(const float* s, uint64_t n) {  // المنتج فقط
        uint64_t h = head.load(std::memory_order_relaxed);
        uint64_t t = tail.load(std::memory_order_acquire);
        uint64_t freeSpace = N - (h - t);
        if (n > freeSpace) n = freeSpace;  // الامتلاء: نتجاهل الأحدث
        for (uint64_t i = 0; i < n; ++i) buf[(h + i) & (N - 1)] = s[i];
        head.store(h + n, std::memory_order_release);
    }
    uint64_t pop(float* d, uint64_t n) {  // المستهلك فقط
        uint64_t t = tail.load(std::memory_order_relaxed);
        uint64_t a = head.load(std::memory_order_acquire) - t;
        if (n > a) n = a;
        for (uint64_t i = 0; i < n; ++i) d[i] = buf[(t + i) & (N - 1)];
        tail.store(t + n, std::memory_order_release);
        return n;
    }
    void skip(uint64_t n) {  // المستهلك فقط
        uint64_t t = tail.load(std::memory_order_relaxed);
        uint64_t a = head.load(std::memory_order_acquire) - t;
        if (n > a) n = a;
        tail.store(t + n, std::memory_order_release);
    }
    void reset() {  // فقط والخيوط متوقفة
        head.store(0);
        tail.store(0);
    }

private:
    std::vector<float> buf;
    std::atomic<uint64_t> head{0}, tail{0};
};

#pragma pack(push, 1)
struct ReaHdr {
    char magic[4];
    uint32_t size;
    char id[32];
    uint8_t ch;
    uint32_t sr;
    uint16_t bytes;
};
#pragma pack(pop)
static_assert(sizeof(ReaHdr) == 47, "ReaStream header must be 47 bytes");

// ---------------------------------------------------------------- تسجيل الـ APO
static const APO_REG_PROPERTIES* RegProps() {
    static const APO_REG_PROPERTIES p = [] {
        APO_REG_PROPERTIES value{};
        value.clsid = CLSID_MicBridgeAPO;
        value.Flags = (APO_FLAG)(APO_FLAG_SAMPLESPERFRAME_MUST_MATCH | APO_FLAG_FRAMESPERSECOND_MUST_MATCH |
                             APO_FLAG_BITSPERSAMPLE_MUST_MATCH | APO_FLAG_INPLACE);
        wcscpy_s(value.szFriendlyName, L"MicBridge APO");
        wcscpy_s(value.szCopyrightInfo, L"MicBridge APO");
        value.u32MajorVersion = 1;
        value.u32MinorVersion = 0;
        value.u32MinInputConnections = 1;
        value.u32MaxInputConnections = 1;
        value.u32MinOutputConnections = 1;
        value.u32MaxOutputConnections = 1;
        value.u32MaxInstances = 0xFFFFFFFF;
        value.u32NumAPOInterfaces = 1;
        value.iidAPOInterfaceList[0] = __uuidof(IAudioProcessingObject);
        return value;
    }();
    return &p;
}

// ---------------------------------------------------------------- فحص الصيغة (float32 فقط)
static bool IsFloat32(IAudioMediaType* t) {
    if (!t) return false;
    const WAVEFORMATEX* w = t->GetAudioFormat();
    if (!w || w->wBitsPerSample != 32 || w->nChannels == 0 || w->nChannels > 8 ||
        w->nSamplesPerSec < mb::kMinRate || w->nSamplesPerSec > mb::kMaxRate ||
        w->nBlockAlign != w->nChannels * sizeof(float) ||
        w->nAvgBytesPerSec != w->nSamplesPerSec * w->nBlockAlign) return false;
    if (w->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return w->cbSize == 0;
    if (w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && w->cbSize >= 22) {
        static const GUID kFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
        const WAVEFORMATEXTENSIBLE* e = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(w);
        if (!IsEqualGUID(e->SubFormat, kFloat) || e->Samples.wValidBitsPerSample != 32) return false;
        if (e->dwChannelMask) {
            DWORD mask = e->dwChannelMask; UINT32 count = 0;
            while (mask) { count += (mask & 1u); mask >>= 1; }
            if (count != w->nChannels) return false;
        }
        return true;
    }
    return false;
}
static DWORD ChannelMask(IAudioMediaType* t) {
    const WAVEFORMATEX* w = t ? t->GetAudioFormat() : nullptr;
    if (w && w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && w->cbSize >= 22)
        return reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(w)->dwChannelMask;
    return 0;
}
static bool SameLayout(IAudioMediaType* a, IAudioMediaType* b) {
    if (!a || !b) return false;
    const WAVEFORMATEX* x = a->GetAudioFormat();
    const WAVEFORMATEX* y = b->GetAudioFormat();
    return x && y && x->nSamplesPerSec == y->nSamplesPerSec && x->nChannels == y->nChannels &&
           x->wBitsPerSample == y->wBitsPerSample && x->nBlockAlign == y->nBlockAlign &&
           x->nAvgBytesPerSec == y->nAvgBytesPerSec && ChannelMask(a) == ChannelMask(b);
}
static void LogMediaType(const char* stage, IAudioMediaType* type, HRESULT hr) {
    const WAVEFORMATEX* wf = type ? type->GetAudioFormat() : nullptr;
    if (!wf) { Log("%s hr=0x%08X format=null", stage, (unsigned)hr); return; }
    Log("%s hr=0x%08X tag=%u rate=%u ch=%u bits=%u block=%u cb=%u",
        stage, (unsigned)hr, wf->wFormatTag, wf->nSamplesPerSec, wf->nChannels,
        wf->wBitsPerSample, wf->nBlockAlign, wf->cbSize);
}

// ---------------------------------------------------------------- الـ APO
class MicBridgeAPO : public IAudioProcessingObject,
                     public IAudioProcessingObjectRT,
                     public IAudioProcessingObjectConfiguration,
                     public IAudioSystemEffects {
public:
    MicBridgeAPO() { ++g_objects; }
    virtual ~MicBridgeAPO() { StopBridge(); --g_objects; }

    // IUnknown
    STDMETHOD(QueryInterface)(REFIID iid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        HRESULT hr = E_NOINTERFACE;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IAudioProcessingObject))
            *ppv = static_cast<IAudioProcessingObject*>(this);
        else if (iid == __uuidof(IAudioProcessingObjectRT))
            *ppv = static_cast<IAudioProcessingObjectRT*>(this);
        else if (iid == __uuidof(IAudioProcessingObjectConfiguration))
            *ppv = static_cast<IAudioProcessingObjectConfiguration*>(this);
        else if (iid == __uuidof(IAudioSystemEffects))
            *ppv = static_cast<IAudioSystemEffects*>(this);
        if (*ppv) {
            AddRef();
            hr = S_OK;
        }
        wchar_t iidText[40] = {};
        StringFromGUID2(iid, iidText, ARRAYSIZE(iidText));
        Log("MicBridgeAPO::QueryInterface iid=%ls hr=0x%08X", iidText, (unsigned)hr);
        return hr;
    }
    STDMETHOD_(ULONG, AddRef)() override { return (ULONG)++m_ref; }
    STDMETHOD_(ULONG, Release)() override {
        long r = --m_ref;
        if (r == 0) delete this;
        return (ULONG)r;
    }

    // IAudioProcessingObject (كانت في الفئة الأساسية، ننفذها بأنفسنا)
    STDMETHOD(Reset)() override {
        // Defer state changes to each owning thread: Reset may race with APOProcess
        // and the UDP receive worker. No shared SPSC indices are reset here.
        m_resetProcessRequested.store(true, std::memory_order_release);
        m_resetRecvRequested.store(true, std::memory_order_release);
        return S_OK;
    }
    STDMETHOD(GetLatency)(HNSTIME* pTime) override {
        if (!pTime) return E_POINTER;
        *pTime = m_latencyHns.load(std::memory_order_acquire);
        return S_OK;
    }
    STDMETHOD(GetRegistrationProperties)(APO_REG_PROPERTIES** ppRegProps) override {
        if (!ppRegProps) return E_POINTER;
        *ppRegProps = static_cast<APO_REG_PROPERTIES*>(CoTaskMemAlloc(sizeof(APO_REG_PROPERTIES)));
        if (!*ppRegProps) return E_OUTOFMEMORY;
        memcpy(*ppRegProps, RegProps(), sizeof(APO_REG_PROPERTIES));
        return S_OK;
    }
    STDMETHOD(Initialize)(UINT32 cbDataSize, BYTE* pbyData) override {
        if (cbDataSize != 0 && !pbyData) {
            Log("Initialize rejected: null payload with size=%u", cbDataSize);
            return E_POINTER;
        }
        if (m_initialized) {
            Log("Initialize rejected: already initialized");
            return APOERR_ALREADY_INITIALIZED;
        }
        // A zero-length payload is explicitly valid. If data is supplied, require
        // the documented APOInitBaseStruct prefix and verify its size and CLSID.
        if (cbDataSize != 0) {
            if (cbDataSize < sizeof(APOInitBaseStruct)) {
                Log("Initialize rejected: payload too small (%u)", cbDataSize);
                return E_INVALIDARG;
            }
            const auto* base = reinterpret_cast<const APOInitBaseStruct*>(pbyData);
            if (base->cbSize < sizeof(APOInitBaseStruct) || base->cbSize > cbDataSize ||
                !IsEqualCLSID(base->clsid, CLSID_MicBridgeAPO)) {
                Log("Initialize rejected: invalid base header cbSize=%u payload=%u clsidMatch=%d",
                    base->cbSize, cbDataSize, IsEqualCLSID(base->clsid, CLSID_MicBridgeAPO));
                return E_INVALIDARG;
            }
        }
        m_initialized = true;
        Log("Initialize succeeded: cbDataSize=%u", cbDataSize);
        return S_OK;
    }
    STDMETHOD(IsInputFormatSupported)(IAudioMediaType* pOut, IAudioMediaType* pReq,
                                      IAudioMediaType** ppSupported) override {
        if (!pReq || !ppSupported) return E_POINTER;
        *ppSupported = nullptr;
        if (!IsFloat32(pReq) || (pOut && (!IsFloat32(pOut) || !SameLayout(pOut, pReq)))) {
            LogMediaType("IsInputFormatSupported rejected", pReq, APOERR_FORMAT_NOT_SUPPORTED);
            if (pOut) LogMediaType("IsInputFormatSupported output", pOut, APOERR_FORMAT_NOT_SUPPORTED);
            return APOERR_FORMAT_NOT_SUPPORTED;
        }
        *ppSupported = pReq; pReq->AddRef();
        LogMediaType("IsInputFormatSupported accepted", pReq, S_OK); return S_OK;
    }
    STDMETHOD(IsOutputFormatSupported)(IAudioMediaType* pIn, IAudioMediaType* pReq,
                                       IAudioMediaType** ppSupported) override {
        if (!pReq || !ppSupported) return E_POINTER;
        *ppSupported = nullptr;
        if (!IsFloat32(pReq) || (pIn && (!IsFloat32(pIn) || !SameLayout(pIn, pReq)))) {
            LogMediaType("IsOutputFormatSupported rejected", pReq, APOERR_FORMAT_NOT_SUPPORTED);
            if (pIn) LogMediaType("IsOutputFormatSupported input", pIn, APOERR_FORMAT_NOT_SUPPORTED);
            return APOERR_FORMAT_NOT_SUPPORTED;
        }
        *ppSupported = pReq; pReq->AddRef();
        LogMediaType("IsOutputFormatSupported accepted", pReq, S_OK); return S_OK;
    }
    STDMETHOD(GetInputChannelCount)(UINT32* pCount) override {
        if (!pCount) return E_POINTER;
        *pCount = m_ch;
        return S_OK;
    }
    // IAudioProcessingObjectRT
    STDMETHOD_(UINT32, CalcInputFrames)(UINT32 outFrames) override { return outFrames; }
    STDMETHOD_(UINT32, CalcOutputFrames)(UINT32 inFrames) override { return inFrames; }

    // IAudioProcessingObjectConfiguration
    STDMETHOD(LockForProcess)(UINT32 nIn, APO_CONNECTION_DESCRIPTOR** ppIn, UINT32 nOut,
                              APO_CONNECTION_DESCRIPTOR** ppOut) override {
        if (nIn != 1 || nOut != 1) { Log("LockForProcess rejected: connections in=%u out=%u",nIn,nOut); return APOERR_NUM_CONNECTIONS_INVALID; }
        if (!ppIn || !ppOut || !ppIn[0] || !ppOut[0] || !ppIn[0]->pFormat || !ppOut[0]->pFormat) { Log("LockForProcess rejected: null descriptor/format"); return E_POINTER; }
        if (!m_initialized || m_locked) { Log("LockForProcess rejected: initialized=%d locked=%d",m_initialized,m_locked); return E_UNEXPECTED; }
        const WAVEFORMATEX* iw=ppIn[0]->pFormat->GetAudioFormat(); const WAVEFORMATEX* ow=ppOut[0]->pFormat->GetAudioFormat();
        UINT32 fi=ppIn[0]->u32MaxFrameCount, fo=ppOut[0]->u32MaxFrameCount;
        if (!iw || !ow || !IsFloat32(ppIn[0]->pFormat) || !IsFloat32(ppOut[0]->pFormat) ||
            iw->nSamplesPerSec!=ow->nSamplesPerSec || iw->nChannels!=ow->nChannels || iw->nChannels==0 || iw->nChannels>8 || fi==0 || fi>16384 || fo<fi || fo>16384) {
            Log("LockForProcess rejected: format/frame mismatch in=%u/%u/%u out=%u/%u/%u",iw?iw->nSamplesPerSec:0,iw?iw->nChannels:0,fi,ow?ow->nSamplesPerSec:0,ow?ow->nChannels:0,fo);
            return APOERR_FORMAT_NOT_SUPPORTED;
        }
        m_rate=iw->nSamplesPerSec; m_ch=iw->nChannels; m_maxFrames=fi; m_locked=true;
        Log("LockForProcess entered rate=%u ch=%u bits=%u frames=%u",m_rate,m_ch,iw->wBitsPerSample,m_maxFrames);
        StartBridge(); Log("LockForProcess succeeded"); return S_OK;
    }
    STDMETHOD(UnlockForProcess)(void) override {
        if (!m_locked) { Log("UnlockForProcess while not locked"); return S_OK; }
        StopBridge();
        Log("APOProcess summary: calls=%llu frames=%llu silentCalls=%llu invalidCalls=%llu underruns=%u overruns=%u primings=%u",
            (unsigned long long)m_processCalls.load(), (unsigned long long)m_processFrames.load(),
            (unsigned long long)m_silentCalls.load(), (unsigned long long)m_invalidCalls.load(),
            m_blender.underruns(), m_blender.overruns(), m_blender.primings());
        m_locked=false; Log("UnlockForProcess succeeded"); return S_OK;
    }

    // IAudioProcessingObjectRT
    STDMETHOD_(void, APOProcess)(UINT32 nIn, APO_CONNECTION_PROPERTY** ppIn, UINT32 nOut,
                                 APO_CONNECTION_PROPERTY** ppOut) override {
        ++m_processCalls;
        if (nIn < 1 || nOut < 1 || !ppIn || !ppOut || !ppIn[0] || !ppOut[0]) { ++m_invalidCalls; return; }
        APO_CONNECTION_PROPERTY* in = ppIn[0];
        APO_CONNECTION_PROPERTY* out = ppOut[0];
        if (!in || !out || !in->pBuffer || !out->pBuffer) { ++m_invalidCalls; return; }
        const UINT32 frames = in->u32ValidFrameCount;
        m_processFrames += frames;
        const uint32_t ch = m_ch;
        float* inb = reinterpret_cast<float*>(in->pBuffer);
        float* outb = reinterpret_cast<float*>(out->pBuffer);
        const bool silent = (in->u32BufferFlags == BUFFER_SILENT);
        if (silent) ++m_silentCalls;
        if (m_resetProcessRequested.exchange(false, std::memory_order_acq_rel)) {
            m_blender.Reset();
            m_recvRing.skip(m_recvRing.available());
        }

        out->u32ValidFrameCount = frames;
        out->u32BufferFlags = in->u32BufferFlags;

        auto passthrough = [&]() {
            if (!silent && inb != outb) memcpy(outb, inb, (size_t)frames * ch * sizeof(float));
        };

        if (!m_active.load(std::memory_order_relaxed) || frames == 0 || frames > m_scratch.size()) {
            passthrough();
            return;
        }

        // 1) إرسال المايك (قناة أحادية: متوسط القنوات)
        float* tmp = m_scratch.data();
        if (silent) {
            memset(tmp, 0, frames * sizeof(float));
        } else if (ch == 1) {
            memcpy(tmp, inb, frames * sizeof(float));
        } else {
            for (UINT32 i = 0; i < frames; ++i) {
                float s = 0;
                for (uint32_t c = 0; c < ch; ++c) s += inb[i * ch + c];
                tmp[i] = s / (float)ch;
            }
        }
        m_sendRing.push(tmp, frames);
        SetEvent(m_sendEvt);

        // Preserve the dry input in the output buffer, then crossfade to wet audio.
        // Blender runs on the APO processing thread and performs no allocation or I/O.
        if (silent) {
            memset(outb, 0, (size_t)frames * ch * sizeof(float));
        } else if (inb != outb) {
            memcpy(outb, inb, (size_t)frames * ch * sizeof(float));
        }
        m_blender.Process(outb, frames, ch, m_recvRing, true, tmp);
        out->u32BufferFlags = (silent && !m_blender.touchedWet()) ? BUFFER_SILENT : BUFFER_VALID;
    }

private:
    // ------------------------------------------------------------ تشغيل/إيقاف الجسر
    void StartBridge() {
        StopBridge();
        LoadConfig(m_cfg);
        if (!m_cfg.enabled) {
            m_latencyHns.store(0, std::memory_order_release);
            Log("Disabled in INI: pass-through");
            return;
        }
        WSADATA wsa;
        int wsaRc = WSAStartup(MAKEWORD(2, 2), &wsa);
        if (wsaRc != 0) {
            Log("WSAStartup failed: rc=%d", wsaRc);
            return;
        }
        m_wsa = true;
        const uint64_t requestedJitter = std::max<uint64_t>((uint64_t)m_rate * m_cfg.jitterMs / 1000, 2ull * m_maxFrames);
        // Keep the target and high-water mark within the fixed SPSC ring capacity.
        m_jitter = std::min<uint64_t>(requestedJitter, m_recvRing.capacity() / 2);
        m_hi = std::min<uint64_t>(m_jitter + m_rate / 10, m_recvRing.capacity() - 1);
        m_scratch.assign(16384, 0.f);
        // A 4096-byte stereo/mono payload contains at most 1024 mono frames.
        // The largest supported rate ratio is 384 kHz / 8 kHz = 48:1.
        m_rs.assign(65536, 0.f);
        m_resampler.Reset();
        m_resamplerInputRate = 0;
        m_sendRing.reset();
        m_recvRing.reset();
        m_blender.Configure(m_rate, m_jitter, m_hi, m_cfg.fallback,
                            std::max<uint32_t>(1, m_rate / 200));
        m_pktRx = 0;
        m_pktTx = 0;
        m_underruns = 0;
        m_stop = false;
        m_sendStartup.store(0, std::memory_order_release);
        m_recvStartup.store(0, std::memory_order_release);
        m_sendEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        m_thSend = CreateThread(nullptr, 0, SendThunk, this, 0, nullptr);
        m_thRecv = CreateThread(nullptr, 0, RecvThunk, this, 0, nullptr);
        if (!m_sendEvt || !m_thSend || !m_thRecv) {
            Log("Bridge startup failed: event=%d sendThread=%d recvThread=%d winerr=%lu",
                m_sendEvt != nullptr, m_thSend != nullptr, m_thRecv != nullptr, GetLastError());
            StopBridge();
            return;
        }
        if (!SetThreadPriority(m_thSend, THREAD_PRIORITY_HIGHEST))
            Log("WARNING: SetThreadPriority(send) failed: %lu", GetLastError());
        if (!SetThreadPriority(m_thRecv, THREAD_PRIORITY_HIGHEST))
            Log("WARNING: SetThreadPriority(recv) failed: %lu", GetLastError());

        // Do not advertise an active bridge until both worker sockets are ready.
        // LockForProcess is a control-path callback, so a bounded startup wait is safe here.
        const ULONGLONG deadline = GetTickCount64() + 1500;
        while (GetTickCount64() < deadline &&
               m_sendStartup.load(std::memory_order_acquire) == 0 &&
               m_recvStartup.load(std::memory_order_acquire) == 0) Sleep(5);
        while (GetTickCount64() < deadline &&
               (m_sendStartup.load(std::memory_order_acquire) == 0 ||
                m_recvStartup.load(std::memory_order_acquire) == 0)) Sleep(5);
        const int sendState = m_sendStartup.load(std::memory_order_acquire);
        const int recvState = m_recvStartup.load(std::memory_order_acquire);
        if (sendState != 1 || recvState != 1) {
            Log("Bridge startup degraded: sendState=%d recvState=%d; keeping safe pass-through", sendState, recvState);
            StopBridge();
            return;
        }
        m_latencyHns.store((HNSTIME)((m_jitter * 10000000ull) / m_rate), std::memory_order_release);
        m_active = true;
        Log("Started: rate=%u ch=%u maxFrames=%u send='%s' recv='%s' port=%d jitter=%llu samples latencyHns=%lld",
            m_rate, m_ch, m_maxFrames, m_cfg.sendId, m_cfg.recvId, m_cfg.port, (unsigned long long)m_jitter,
            (long long)m_latencyHns.load(std::memory_order_relaxed));
    }

    void StopBridge() {
        if (!m_thSend && !m_thRecv && !m_wsa) return;
        m_active = false;
        m_latencyHns.store(0, std::memory_order_release);
        m_stop = true;
        if (m_sendEvt) SetEvent(m_sendEvt);
        if (m_thSend) {
            DWORD wait = WaitForSingleObject(m_thSend, 5000);
            if (wait != WAIT_OBJECT_0) {
                Log("WARNING: send thread still active after 5s: wait=%lu error=%lu; waiting for safe shutdown", wait, GetLastError());
                WaitForSingleObject(m_thSend, INFINITE);
            }
            CloseHandle(m_thSend); m_thSend = nullptr;
        }
        if (m_thRecv) {
            DWORD wait = WaitForSingleObject(m_thRecv, 5000);
            if (wait != WAIT_OBJECT_0) {
                Log("WARNING: receive thread still active after 5s: wait=%lu error=%lu; waiting for safe shutdown", wait, GetLastError());
                WaitForSingleObject(m_thRecv, INFINITE);
            }
            CloseHandle(m_thRecv); m_thRecv = nullptr;
        }
        if (m_sendEvt) { CloseHandle(m_sendEvt); m_sendEvt = nullptr; }
        if (m_wsa) { WSACleanup(); m_wsa = false; }
        Log("Stopped: tx=%u rx=%u underruns=%u overruns=%u resampleCapacityHits=%u sendErrors=%u malformed=%u idMismatch=%u nonLocal=%u", m_pktTx.load(), m_pktRx.load(), m_blender.underruns(), m_blender.overruns(), m_resampleCapacityHits.load(), m_sendErrors.load(), m_badPackets.load(), m_idMismatches.load(), m_nonLocalPackets.load());
    }

    static DWORD WINAPI SendThunk(LPVOID p) { static_cast<MicBridgeAPO*>(p)->SendLoop(); return 0; }
    static DWORD WINAPI RecvThunk(LPVOID p) { static_cast<MicBridgeAPO*>(p)->RecvLoop(); return 0; }

    // ------------------------------------------------------------ خيط الإرسال
    void SendLoop() {
        SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) { m_sendStartup.store(-1, std::memory_order_release); Log("send: socket failed %d", WSAGetLastError()); return; }
        Log("send: UDP socket created");
        BOOL on = TRUE;
        if (setsockopt(s, SOL_SOCKET, SO_BROADCAST, (const char*)&on, sizeof on) != 0) {
            const int error = WSAGetLastError(); m_sendStartup.store(-1, std::memory_order_release);
            Log("send: SO_BROADCAST failed %d", error); closesocket(s); return;
        }
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons((u_short)m_cfg.port);
        if (inet_pton(AF_INET, m_cfg.bcast, &dst.sin_addr) != 1) {
            m_sendStartup.store(-1, std::memory_order_release);
            Log("send: bad BroadcastAddress '%s'", m_cfg.bcast);
            closesocket(s);
            return;
        }
        m_sendStartup.store(1, std::memory_order_release);
        uint8_t pkt[sizeof(ReaHdr) + 1200];
        ReaHdr* h = reinterpret_cast<ReaHdr*>(pkt);
        float samples[300];
        while (!m_stop) {
            WaitForSingleObject(m_sendEvt, 20);
            for (;;) {
                uint64_t n = m_sendRing.available();
                if (n == 0 || m_stop) break;
                if (n > 300) n = 300;
                m_sendRing.pop(samples, n);
                memset(h, 0, sizeof *h);
                memcpy(h->magic, "MRSR", 4);
                strncpy_s(h->id, sizeof h->id, m_cfg.sendId, _TRUNCATE);
                h->ch = 1;
                h->sr = m_rate;
                h->bytes = (uint16_t)(n * sizeof(float));
                h->size = (uint32_t)(sizeof(ReaHdr) + h->bytes);
                memcpy(pkt + sizeof(ReaHdr), samples, h->bytes);
                int sent = sendto(s, (const char*)pkt, (int)h->size, 0, (sockaddr*)&dst, sizeof dst);
                if (sent == (int)h->size) ++m_pktTx;
                else { ++m_sendErrors; Log("send: sendto failed/short: sent=%d expected=%u error=%d", sent, h->size, sent == SOCKET_ERROR ? WSAGetLastError() : 0); }
            }
        }
        closesocket(s);
    }

    // ------------------------------------------------------------ خيط الاستقبال
    void RecvLoop() {
        SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) { m_recvStartup.store(-1, std::memory_order_release); Log("recv: socket failed %d", WSAGetLastError()); return; }
        Log("recv: UDP socket created");
        // ReaStream's fixed UDP/58710 listener and MicBridge must both receive
        // the same local-broadcast datagrams. Windows requires SO_REUSEADDR
        // for the second bind; unicast fan-out is not guaranteed, so use broadcast.
        BOOL reuse = TRUE;
        if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof reuse) != 0) {
            const int error = WSAGetLastError();
            m_recvStartup.store(-1, std::memory_order_release);
            Log("recv: SO_REUSEADDR failed %d", error); closesocket(s); return;
        }
        int rb = 1 << 20;
        if (setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char*)&rb, sizeof rb) != 0)
            Log("recv: SO_RCVBUF tuning failed %d (continuing with system default)", WSAGetLastError());
        DWORD to = 100;
        if (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof to) != 0) {
            const int error = WSAGetLastError();
            m_recvStartup.store(-1, std::memory_order_release);
            Log("recv: SO_RCVTIMEO failed %d", error); closesocket(s); return;
        }
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons((u_short)m_cfg.port);
        if (inet_pton(AF_INET, m_cfg.bind, &a.sin_addr) != 1) {
            m_recvStartup.store(-1, std::memory_order_release);
            Log("recv: invalid BindAddress '%s'", m_cfg.bind);
            closesocket(s);
            return;
        }
        if (bind(s, (sockaddr*)&a, sizeof a) != 0) {
            const int error = WSAGetLastError();
            m_recvStartup.store(-1, std::memory_order_release);
            Log("recv: bind %s:%d failed, error %d (المايك سيمرّ بدون معالجة)", m_cfg.bind, m_cfg.port,
                error);
            closesocket(s);
            return;
        }
        Log("recv: listening on %s:%d", m_cfg.bind, m_cfg.port);
        m_recvStartup.store(1, std::memory_order_release);
        uint8_t pkt[mb::kHeaderSize + mb::kMaxRxBytes];
        float in[mb::kMaxRxBytes / sizeof(float)];
        uint8_t expectedId[32];
        mb::MakeId(m_cfg.recvId, expectedId);
        std::vector<DWORD> localAddresses;
        const ULONG addressStatus = EnumerateLocalIPv4(localAddresses);
        if (addressStatus != NO_ERROR)
            Log("recv: GetAdaptersAddresses failed %lu; only loopback will be accepted", addressStatus);
        else
            Log("recv: enumerated %u local IPv4 addresses", (unsigned)localAddresses.size());
        while (!m_stop) {
            if (m_resetRecvRequested.exchange(false, std::memory_order_acq_rel)) {
                m_resampler.Reset();
                m_resamplerInputRate = 0;
            }
            sockaddr_in sender{};
            int senderLen = sizeof(sender);
            int n = recvfrom(s, (char*)pkt, sizeof pkt, 0,
                             (sockaddr*)&sender, &senderLen);
            if (n <= 0) {
                if (WSAGetLastError() != WSAETIMEDOUT && !m_stop) Sleep(10);
                continue;
            }
            // ReaStream's *local broadcast can originate from any local NIC address.
            // Accept local interface addresses (including loopback), reject remote hosts.
            if (!IsLocalIPv4(sender.sin_addr.s_addr, localAddresses)) {
                ++m_nonLocalPackets;
                continue;
            }
            if (n < (int)mb::kHeaderSize) { ++m_badPackets; continue; }
            mb::Parsed parsed{};
            const mb::Parse parse = mb::ParseAudio(pkt, (size_t)n, expectedId, parsed);
            if (parse == mb::Parse::BadId) { ++m_idMismatches; continue; }
            if (parse != mb::Parse::Ok || parsed.sizeFieldMismatch ||
                (parsed.ch != 1 && parsed.ch != 2)) {
                ++m_badPackets;
                continue;
            }
            const uint32_t chs = parsed.ch, sr = parsed.sr, frames = parsed.frames;
            // The capture endpoint is mono; average mono/stereo ReaStream payloads.
            // ParseAudio validates the 47-byte header, payload bounds and float alignment.
            if (frames == 0) continue;

            // ReaStream Float32 payload is planar: [all channel 0][all channel 1].
            // ExtractMono averages the channels into the mono bridge stream.
            mb::ExtractMono(parsed.data, frames, chs, -1, in);
            ++m_pktRx;

            if (sr == m_rate) {
                m_resampler.Reset();
                m_resamplerInputRate = 0;
                m_recvRing.push(in, frames);
            } else {
                if (m_resamplerInputRate != sr) {
                    m_resampler.Reset();
                    m_resamplerInputRate = sr;
                }
                const double step = (double)sr / (double)m_rate;
                const size_t outN = m_resampler.Process(in, frames, step, m_rs.data(), m_rs.size());
                if (outN == m_rs.size()) ++m_resampleCapacityHits;
                m_recvRing.push(m_rs.data(), outN);
            }
        }
        closesocket(s);
    }

    // ------------------------------------------------------------ الحالة
    std::atomic<long> m_ref{1};
    bool m_initialized = false;
    bool m_locked = false;
    Config m_cfg{};
    uint32_t m_rate = 48000, m_ch = 1, m_maxFrames = 0;
    std::atomic<bool> m_active{false}, m_stop{false};
    std::atomic<HNSTIME> m_latencyHns{0};
    std::atomic<bool> m_resetProcessRequested{false}, m_resetRecvRequested{false};
    std::atomic<int> m_sendStartup{0}, m_recvStartup{0}; // 0=pending, 1=ready, -1=failed
    bool m_wsa = false;
    mb::SpscRing m_sendRing{1u << 16}, m_recvRing{1u << 16};
    mb::Blender m_blender;
    uint64_t m_jitter = 0, m_hi = 0;
    std::vector<float> m_scratch, m_rs;
    mb::LinearResampler m_resampler;
    uint32_t m_resamplerInputRate = 0;
    std::atomic<uint32_t> m_resampleCapacityHits{0}, m_nonLocalPackets{0};
    HANDLE m_sendEvt = nullptr, m_thSend = nullptr, m_thRecv = nullptr;
    std::atomic<uint32_t> m_pktRx{0}, m_pktTx{0}, m_underruns{0}, m_badPackets{0}, m_idMismatches{0}, m_sendErrors{0};
    std::atomic<uint64_t> m_processCalls{0}, m_processFrames{0}, m_silentCalls{0}, m_invalidCalls{0};
};

// ---------------------------------------------------------------- Class factory
class Factory : public IClassFactory {
public:
    STDMETHOD(QueryInterface)(REFIID iid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        HRESULT hr = E_NOINTERFACE;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IClassFactory)) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            hr = S_OK;
        }
        wchar_t iidText[40] = {};
        StringFromGUID2(iid, iidText, ARRAYSIZE(iidText));
        Log("Factory::QueryInterface iid=%ls hr=0x%08X", iidText, (unsigned)hr);
        return hr;
    }
    STDMETHOD_(ULONG, AddRef)() override {
        const long refs = ++m_ref;
        ++g_factoryRefs;
        return static_cast<ULONG>(refs);
    }
    STDMETHOD_(ULONG, Release)() override {
        const long refs = --m_ref;
        --g_factoryRefs;
        return static_cast<ULONG>(refs);
    }
    STDMETHOD(CreateInstance)(IUnknown* outer, REFIID iid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (outer) {
            Log("ClassFactory::CreateInstance rejected aggregation");
            return CLASS_E_NOAGGREGATION;
        }
        wchar_t iidText[40] = {};
        StringFromGUID2(iid, iidText, ARRAYSIZE(iidText));
        Log("ClassFactory::CreateInstance requested iid=%ls", iidText);
        MicBridgeAPO* o = new (std::nothrow) MicBridgeAPO();
        if (!o) {
            Log("ClassFactory::CreateInstance allocation failed: E_OUTOFMEMORY");
            return E_OUTOFMEMORY;
        }
        HRESULT hr = o->QueryInterface(iid, ppv);
        Log("ClassFactory::CreateInstance QI hr=0x%08X", (unsigned)hr);
        o->Release();
        return hr;
    }
    STDMETHOD(LockServer)(BOOL lock) override {
        if (lock) {
            ++g_serverLocks;
        } else {
            long current = g_serverLocks.load();
            while (current > 0 && !g_serverLocks.compare_exchange_weak(current, current - 1)) {}
            if (current <= 0) {
                Log("Factory::LockServer(FALSE) ignored: no matching server lock");
                return E_UNEXPECTED;
            }
        }
        return S_OK;
    }

private:
    std::atomic<long> m_ref{0};
};

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    wchar_t clsidText[40] = {}, iidText[40] = {};
    StringFromGUID2(rclsid, clsidText, ARRAYSIZE(clsidText));
    StringFromGUID2(riid, iidText, ARRAYSIZE(iidText));
    Log("DllGetClassObject entry clsid=%ls iid=%ls ppv=%p", clsidText, iidText, ppv);
    if (!ppv) {
        Log("DllGetClassObject rejected: null ppv");
        return E_POINTER;
    }
    *ppv = nullptr;
    if (!IsEqualCLSID(rclsid, CLSID_MicBridgeAPO)) {
        Log("DllGetClassObject rejected: class not available for clsid=%ls", clsidText);
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    Log("DllGetClassObject requested for MicBridgeAPO");
    static INIT_ONCE diagnosticOnce = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce(&diagnosticOnce,
        [](PINIT_ONCE, PVOID, PVOID*) -> BOOL { RunStartupDiagnostics(); return TRUE; },
        nullptr, nullptr);
    static Factory f;
    HRESULT hr = f.QueryInterface(riid, ppv);
    Log("DllGetClassObject hr=0x%08X", (unsigned)hr);
    return hr;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() { return (g_objects.load() == 0 && g_factoryRefs.load() == 0 && g_serverLocks.load() == 0) ? S_OK : S_FALSE; }

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = h;
        DisableThreadLibraryCalls(h);
    }
    return TRUE;
}
