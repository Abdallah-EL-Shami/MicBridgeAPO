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
#include <windows.h>
#include <unknwn.h>
#include <objbase.h>
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

// {A3F6C1D2-7B84-4E19-9C55-2D8E1F0B6A47}
static const GUID CLSID_MicBridgeAPO =
    {0xA3F6C1D2, 0x7B84, 0x4E19, {0x9C, 0x55, 0x2D, 0x8E, 0x1F, 0x0B, 0x6A, 0x47}};

static std::atomic<long> g_objects{0};
static HMODULE g_module = nullptr;

// ---------------------------------------------------------------- مسارات وسجل
static void DataPath(wchar_t* out, size_t n, const wchar_t* file) {
    wchar_t base[MAX_PATH];
    DWORD r = GetEnvironmentVariableW(L"ProgramData", base, MAX_PATH);
    if (!r || r >= MAX_PATH) wcscpy_s(base, L"C:\\ProgramData");
    swprintf_s(out, n, L"%s\\MicBridgeAPO\\%s", base, file);
}

static void Log(const char* fmt, ...) {
    wchar_t path[MAX_PATH];
    DataPath(path, MAX_PATH, L"MicBridge.log");
    HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER sz{};
    if (GetFileSizeEx(h, &sz) && sz.QuadPart > (1 << 20)) { CloseHandle(h); return; }  // سقف 1MB
    char line[512];
    SYSTEMTIME st;
    GetLocalTime(&st);
    int n = _snprintf_s(line, sizeof line, _TRUNCATE, "%02d:%02d:%02d.%03d ", st.wHour, st.wMinute,
                        st.wSecond, st.wMilliseconds);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n - 3, fmt, ap);
    va_end(ap);
    strcat_s(line, "\r\n");
    DWORD w;
    WriteFile(h, line, (DWORD)strlen(line), &w, nullptr);
    CloseHandle(h);
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
    static APO_REG_PROPERTIES p;
    static bool init = false;
    if (!init) {
        memset(&p, 0, sizeof p);
        p.clsid = CLSID_MicBridgeAPO;
        p.Flags = (APO_FLAG)(APO_FLAG_SAMPLESPERFRAME_MUST_MATCH | APO_FLAG_FRAMESPERSECOND_MUST_MATCH |
                             APO_FLAG_BITSPERSAMPLE_MUST_MATCH | APO_FLAG_INPLACE);
        wcscpy_s(p.szFriendlyName, L"MicBridge APO");
        wcscpy_s(p.szCopyrightInfo, L"MicBridge APO");
        p.u32MajorVersion = 1;
        p.u32MinorVersion = 0;
        p.u32MinInputConnections = 1;
        p.u32MaxInputConnections = 1;
        p.u32MinOutputConnections = 1;
        p.u32MaxOutputConnections = 1;
        p.u32MaxInstances = 0xFFFFFFFF;
        p.u32NumAPOInterfaces = 1;
        p.iidAPOInterfaceList[0] = __uuidof(IAudioProcessingObject);
        init = true;
    }
    return &p;
}

// ---------------------------------------------------------------- فحص الصيغة (float32 فقط)
static bool IsFloat32(IAudioMediaType* t) {
    if (!t) return false;
    const WAVEFORMATEX* w = t->GetAudioFormat();
    if (!w || w->wBitsPerSample != 32) return false;
    if (w->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && w->cbSize >= 22) {
        static const GUID kFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
        const WAVEFORMATEXTENSIBLE* e = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(w);
        return IsEqualGUID(e->SubFormat, kFloat) != 0;
    }
    return false;
}
static bool SameLayout(IAudioMediaType* a, IAudioMediaType* b) {
    const WAVEFORMATEX* x = a->GetAudioFormat();
    const WAVEFORMATEX* y = b->GetAudioFormat();
    return x && y && x->nSamplesPerSec == y->nSamplesPerSec && x->nChannels == y->nChannels;
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
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IAudioProcessingObject))
            *ppv = static_cast<IAudioProcessingObject*>(this);
        else if (iid == __uuidof(IAudioProcessingObjectRT))
            *ppv = static_cast<IAudioProcessingObjectRT*>(this);
        else if (iid == __uuidof(IAudioProcessingObjectConfiguration))
            *ppv = static_cast<IAudioProcessingObjectConfiguration*>(this);
        else if (iid == __uuidof(IAudioSystemEffects))
            *ppv = static_cast<IAudioSystemEffects*>(this);
        else
            return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    STDMETHOD_(ULONG, AddRef)() override { return (ULONG)++m_ref; }
    STDMETHOD_(ULONG, Release)() override {
        long r = --m_ref;
        if (r == 0) delete this;
        return (ULONG)r;
    }

    // IAudioProcessingObject (كانت في الفئة الأساسية، ننفذها بأنفسنا)
    STDMETHOD(Reset)() override { return S_OK; }
    STDMETHOD(GetLatency)(HNSTIME* pTime) override {
        if (!pTime) return E_POINTER;
        *pTime = 0;
        return S_OK;
    }
    STDMETHOD(GetRegistrationProperties)(APO_REG_PROPERTIES** ppRegProps) override {
        if (!ppRegProps) return E_POINTER;
        *ppRegProps = static_cast<APO_REG_PROPERTIES*>(CoTaskMemAlloc(sizeof(APO_REG_PROPERTIES)));
        if (!*ppRegProps) return E_OUTOFMEMORY;
        memcpy(*ppRegProps, RegProps(), sizeof(APO_REG_PROPERTIES));
        return S_OK;
    }
    STDMETHOD(Initialize)(UINT32, BYTE*) override { return S_OK; }
    STDMETHOD(IsInputFormatSupported)(IAudioMediaType* pOut, IAudioMediaType* pReq,
                                      IAudioMediaType** ppSupported) override {
        if (!pReq || !ppSupported) return E_POINTER;
        *ppSupported = nullptr;
        if (!IsFloat32(pReq)) return APOERR_FORMAT_NOT_SUPPORTED;
        if (pOut && !SameLayout(pOut, pReq)) return APOERR_FORMAT_NOT_SUPPORTED;
        *ppSupported = pReq;
        pReq->AddRef();
        return S_OK;
    }
    STDMETHOD(IsOutputFormatSupported)(IAudioMediaType* pIn, IAudioMediaType* pReq,
                                       IAudioMediaType** ppSupported) override {
        if (!pReq || !ppSupported) return E_POINTER;
        *ppSupported = nullptr;
        if (!IsFloat32(pReq)) return APOERR_FORMAT_NOT_SUPPORTED;
        if (pIn && !SameLayout(pIn, pReq)) return APOERR_FORMAT_NOT_SUPPORTED;
        *ppSupported = pReq;
        pReq->AddRef();
        return S_OK;
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
        if (nIn != 1 || nOut != 1 || !ppIn || !ppOut) return E_INVALIDARG;
        // الصيغة تأتي من محرك الصوت: هي نفس ما ضُبط في Advanced (معدل العينة وعدد القنوات).
        // عمق البت (24-bit مثلًا) لا يهم لأن المحرك يسلّم float32 دائمًا.
        const WAVEFORMATEX* wf = nullptr;
        UINT32 maxFrames = 0;
        if (nIn > 0 && ppIn[0] && ppIn[0]->pFormat) {
            wf = ppIn[0]->pFormat->GetAudioFormat();
            maxFrames = ppIn[0]->u32MaxFrameCount;
        }
        if (wf) {
            m_rate = wf->nSamplesPerSec;
            m_ch = wf->nChannels ? wf->nChannels : 1;
        }
        m_maxFrames = maxFrames;
        StartBridge();
        return S_OK;
    }
    STDMETHOD(UnlockForProcess)(void) override {
        StopBridge();
        return S_OK;
    }

    // IAudioProcessingObjectRT
    STDMETHOD_(void, APOProcess)(UINT32 nIn, APO_CONNECTION_PROPERTY** ppIn, UINT32 nOut,
                                 APO_CONNECTION_PROPERTY** ppOut) override {
        if (nIn < 1 || nOut < 1) return;
        APO_CONNECTION_PROPERTY* in = ppIn[0];
        APO_CONNECTION_PROPERTY* out = ppOut[0];
        const UINT32 frames = in->u32ValidFrameCount;
        const uint32_t ch = m_ch;
        float* inb = reinterpret_cast<float*>(in->pBuffer);
        float* outb = reinterpret_cast<float*>(out->pBuffer);
        const bool silent = (in->u32BufferFlags == BUFFER_SILENT);

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

        // 2) استقبال الصوت المعالج
        uint64_t avail = m_recvRing.available();
        if (!m_primed && avail >= m_jitter) m_primed = true;
        if (m_primed) {
            if (avail > m_hi) {  // انجراف الساعات: نعيد التأخير إلى الحد الطبيعي
                m_recvRing.skip(avail - m_jitter);
                avail = m_recvRing.available();
            }
            if (avail >= frames) {
                m_recvRing.pop(tmp, frames);
                if (ch == 1) {
                    memcpy(outb, tmp, frames * sizeof(float));
                } else {
                    for (UINT32 i = 0; i < frames; ++i)
                        for (uint32_t c = 0; c < ch; ++c) outb[i * ch + c] = tmp[i];
                }
                out->u32BufferFlags = BUFFER_VALID;
                return;
            }
            m_primed = false;  // نقص بيانات: نرجع للاحتياط حتى يمتلئ المخزن من جديد
            ++m_underruns;
        }

        // 3) لا يوجد صوت معالج
        if (m_cfg.fallback) {
            passthrough();
        } else {
            memset(outb, 0, (size_t)frames * ch * sizeof(float));
            out->u32BufferFlags = BUFFER_VALID;
        }
    }

private:
    // ------------------------------------------------------------ تشغيل/إيقاف الجسر
    void StartBridge() {
        StopBridge();
        LoadConfig(m_cfg);
        if (!m_cfg.enabled) {
            Log("Disabled in INI: pass-through");
            return;
        }
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            Log("WSAStartup failed");
            return;
        }
        m_wsa = true;
        m_jitter = std::max<uint64_t>((uint64_t)m_rate * m_cfg.jitterMs / 1000, 2ull * m_maxFrames);
        m_hi = m_jitter + m_rate / 10;  // الحد الأعلى: الحماية + 100ms
        m_scratch.assign(std::max<size_t>(m_maxFrames, 16384), 0.f);
        m_rs.assign(32768, 0.f);
        m_rsPos = 0;
        m_rsLast = 0;
        m_sendRing.reset();
        m_recvRing.reset();
        m_primed = false;
        m_pktRx = 0;
        m_pktTx = 0;
        m_underruns = 0;
        m_stop = false;
        m_sendEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        m_thSend = CreateThread(nullptr, 0, SendThunk, this, 0, nullptr);
        m_thRecv = CreateThread(nullptr, 0, RecvThunk, this, 0, nullptr);
        if (m_thSend) SetThreadPriority(m_thSend, THREAD_PRIORITY_HIGHEST);
        if (m_thRecv) SetThreadPriority(m_thRecv, THREAD_PRIORITY_HIGHEST);
        m_active = true;
        Log("Started: rate=%u ch=%u maxFrames=%u send='%s' recv='%s' port=%d jitter=%llu samples",
            m_rate, m_ch, m_maxFrames, m_cfg.sendId, m_cfg.recvId, m_cfg.port, (unsigned long long)m_jitter);
    }

    void StopBridge() {
        if (!m_thSend && !m_thRecv && !m_wsa) return;
        m_active = false;
        m_stop = true;
        if (m_sendEvt) SetEvent(m_sendEvt);
        if (m_thSend) { WaitForSingleObject(m_thSend, 2000); CloseHandle(m_thSend); m_thSend = nullptr; }
        if (m_thRecv) { WaitForSingleObject(m_thRecv, 2000); CloseHandle(m_thRecv); m_thRecv = nullptr; }
        if (m_sendEvt) { CloseHandle(m_sendEvt); m_sendEvt = nullptr; }
        if (m_wsa) { WSACleanup(); m_wsa = false; }
        Log("Stopped: tx=%u rx=%u underruns=%u", m_pktTx.load(), m_pktRx.load(), m_underruns.load());
    }

    static DWORD WINAPI SendThunk(LPVOID p) { static_cast<MicBridgeAPO*>(p)->SendLoop(); return 0; }
    static DWORD WINAPI RecvThunk(LPVOID p) { static_cast<MicBridgeAPO*>(p)->RecvLoop(); return 0; }

    // ------------------------------------------------------------ خيط الإرسال
    void SendLoop() {
        SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) { Log("send: socket failed %d", WSAGetLastError()); return; }
        BOOL on = TRUE;
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, (const char*)&on, sizeof on);
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons((u_short)m_cfg.port);
        if (inet_pton(AF_INET, m_cfg.bcast, &dst.sin_addr) != 1) {
            Log("send: bad BroadcastAddress '%s'", m_cfg.bcast);
            closesocket(s);
            return;
        }
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
                strncpy_s(h->id, sizeof h->id + 1, m_cfg.sendId, 32);
                h->ch = 1;
                h->sr = m_rate;
                h->bytes = (uint16_t)(n * sizeof(float));
                h->size = (uint32_t)(sizeof(ReaHdr) + h->bytes);
                memcpy(pkt + sizeof(ReaHdr), samples, h->bytes);
                if (sendto(s, (const char*)pkt, (int)h->size, 0, (sockaddr*)&dst, sizeof dst) > 0) ++m_pktTx;
            }
        }
        closesocket(s);
    }

    // ------------------------------------------------------------ خيط الاستقبال
    void RecvLoop() {
        SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) { Log("recv: socket failed %d", WSAGetLastError()); return; }
        BOOL on = TRUE;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&on, sizeof on);
        int rb = 1 << 20;
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char*)&rb, sizeof rb);
        DWORD to = 100;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof to);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons((u_short)m_cfg.port);
        if (inet_pton(AF_INET, m_cfg.bind, &a.sin_addr) != 1) a.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, (sockaddr*)&a, sizeof a) != 0) {
            Log("recv: bind %s:%d failed, error %d (المايك سيمرّ بدون معالجة)", m_cfg.bind, m_cfg.port,
                WSAGetLastError());
            closesocket(s);
            return;
        }
        Log("recv: listening on %s:%d", m_cfg.bind, m_cfg.port);
        uint8_t pkt[4096];
        float in[1024];
        while (!m_stop) {
            int n = recvfrom(s, (char*)pkt, sizeof pkt, 0, nullptr, nullptr);
            if (n <= 0) {
                if (WSAGetLastError() != WSAETIMEDOUT && !m_stop) Sleep(10);
                continue;
            }
            if (n < (int)sizeof(ReaHdr) || memcmp(pkt, "MRSR", 4) != 0) continue;
            const ReaHdr* h = reinterpret_cast<const ReaHdr*>(pkt);
            if (strncmp(h->id, m_cfg.recvId, 32) != 0) continue;  // معرّف مختلف: نتجاهل
            uint32_t chs = h->ch, sr = h->sr, bytes = h->bytes;
            if (chs == 0 || sr < 8000 || sr > 384000) continue;
            if (bytes > sizeof in || sizeof(ReaHdr) + bytes > (size_t)n) continue;
            memcpy(in, pkt + sizeof(ReaHdr), bytes);
            uint32_t frames = bytes / 4 / chs;  // نأخذ القناة الأولى (افتراض: القنوات منفصلة بالتتابع)
            if (frames == 0) continue;
            ++m_pktRx;

            if (sr == m_rate) {
                m_recvRing.push(in, frames);
            } else {  // تحويل معدل بسيط (خطي)
                double step = (double)sr / (double)m_rate;
                size_t outN = 0;
                double p = m_rsPos;
                while (p < (double)frames && outN < m_rs.size()) {
                    int idx = (int)p;
                    double fr = p - idx;
                    float x0 = (idx == 0) ? m_rsLast : in[idx - 1];
                    float x1 = in[idx];
                    m_rs[outN++] = (float)(x0 * (1.0 - fr) + x1 * fr);
                    p += step;
                }
                m_rsPos = p - (double)frames;
                m_rsLast = in[frames - 1];
                m_recvRing.push(m_rs.data(), outN);
            }
        }
        closesocket(s);
    }

    // ------------------------------------------------------------ الحالة
    std::atomic<long> m_ref{1};
    Config m_cfg{};
    uint32_t m_rate = 48000, m_ch = 1, m_maxFrames = 0;
    std::atomic<bool> m_active{false}, m_stop{false};
    bool m_wsa = false;
    FloatRing m_sendRing, m_recvRing;
    bool m_primed = false;
    uint64_t m_jitter = 0, m_hi = 0;
    std::vector<float> m_scratch, m_rs;
    double m_rsPos = 0;
    float m_rsLast = 0;
    HANDLE m_sendEvt = nullptr, m_thSend = nullptr, m_thRecv = nullptr;
    std::atomic<uint32_t> m_pktRx{0}, m_pktTx{0}, m_underruns{0};
};

// ---------------------------------------------------------------- Class factory
class Factory : public IClassFactory {
public:
    STDMETHOD(QueryInterface)(REFIID iid, void** ppv) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IClassFactory)) {
            *ppv = static_cast<IClassFactory*>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHOD_(ULONG, AddRef)() override { return 2; }
    STDMETHOD_(ULONG, Release)() override { return 1; }
    STDMETHOD(CreateInstance)(IUnknown* outer, REFIID iid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        MicBridgeAPO* o = new (std::nothrow) MicBridgeAPO();
        if (!o) return E_OUTOFMEMORY;
        HRESULT hr = o->QueryInterface(iid, ppv);
        o->Release();
        return hr;
    }
    STDMETHOD(LockServer)(BOOL) override { return S_OK; }
};

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    static Factory f;
    if (!IsEqualCLSID(rclsid, CLSID_MicBridgeAPO)) return CLASS_E_CLASSNOTAVAILABLE;
    return f.QueryInterface(riid, ppv);
}

extern "C" HRESULT __stdcall DllCanUnloadNow() { return g_objects.load() == 0 ? S_OK : S_FALSE; }

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = h;
        DisableThreadLibraryCalls(h);
    }
    return TRUE;
}
