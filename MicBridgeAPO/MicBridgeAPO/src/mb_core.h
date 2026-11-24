// mb_core.h - المنطق الصوتي الخالص (بدون أي اعتماد على ويندوز) حتى يمكن اختباره على أي منصة.
//  * رأس MRSR بطول 47 بايت شوهد في التقاط واحد؛ تخطيط الحمولة والقنوات ما زال يحتاج تحققًا مستقلًا
//  * حلقة مخزن SPSC بحجم ثابت بلا تخصيص أثناء التشغيل
//  * محوّل معدل عينة خطي
//  * Blender: مخزن الجيتر + التبديل الناعم بين المايك الأصلي والصوت المعالَج
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace mb {

// ---------------------------------------------------------------- ReaStream
constexpr size_t   kHeaderSize    = 47;
constexpr size_t   kMaxChunkBytes = 1200;   // أقصى حمولة صوت لاحظناها في الحزم الحقيقية (300 float)
constexpr size_t   kMaxRxBytes    = 4096;   // سقف أمان عند الاستقبال
constexpr uint32_t kMaxChannels   = 8;
constexpr uint32_t kMinRate       = 8000;
constexpr uint32_t kMaxRate       = 384000;

#pragma pack(push, 1)
struct ReaHdr {
    char     magic[4];  // "MRSR" صوت ، "mRSR" ميدي
    uint32_t size;      // حجم الحزمة كاملة (الترويسة + الصوت)
    uint8_t  id[32];    // المعرّف، نص مكمّل بأصفار
    uint8_t  ch;        // عدد القنوات
    uint32_t sr;        // معدل العينة
    uint16_t bytes;     // حجم الصوت بالبايت
};
#pragma pack(pop)
static_assert(sizeof(ReaHdr) == kHeaderSize, "ReaStream header must be 47 bytes");

inline void MakeId(const char* s, uint8_t out[32]) {
    std::memset(out, 0, 32);
    size_t n = 0;
    while (s && s[n] && n < 32) ++n;
    std::memcpy(out, s, n);  // 32 بايت كحد أقصى، بلا مساس بالحقل التالي
}

// يبني حزمة صوت. يعيد حجمها أو 0 عند الفشل. القنوات منفصلة بالتتابع (planar).
inline size_t PackAudio(uint8_t* out, size_t cap, const uint8_t id[32], uint32_t ch, uint32_t sr,
                        const float* samples, size_t nFloats) {
    if (!out || !id || !samples || ch == 0 || ch > kMaxChannels ||
        sr < kMinRate || sr > kMaxRate || nFloats == 0 || nFloats % ch) return 0;
    if (nFloats > kMaxChunkBytes / sizeof(float)) return 0;
    const size_t bytes = nFloats * sizeof(float);
    if (kHeaderSize + bytes > cap) return 0;
    ReaHdr h;
    std::memset(&h, 0, sizeof h);
    std::memcpy(h.magic, "MRSR", 4);
    h.size  = (uint32_t)(kHeaderSize + bytes);
    std::memcpy(h.id, id, 32);
    h.ch    = (uint8_t)ch;
    h.sr    = sr;
    h.bytes = (uint16_t)bytes;
    std::memcpy(out, &h, kHeaderSize);
    std::memcpy(out + kHeaderSize, samples, bytes);
    return kHeaderSize + bytes;
}

enum class Parse { Ok, TooShort, NotAudio, BadId, BadChannels, BadRate, BadLength, Misaligned };

struct Parsed {
    uint32_t       ch = 0, sr = 0, bytes = 0, frames = 0;
    const uint8_t* data = nullptr;
    bool           sizeFieldMismatch = false;
};

// BadId / NotAudio = حزمة غريبة (تُتجاهل بصمت)، الباقي = حزمة تخصنا لكنها تالفة (تُعدّ).
inline Parse ParseAudio(const uint8_t* p, size_t n, const uint8_t expectId[32], Parsed& o) {
    if (!p || !expectId || n < kHeaderSize) return Parse::TooShort;
    if (std::memcmp(p, "MRSR", 4) != 0) return Parse::NotAudio;
    ReaHdr h;
    std::memcpy(&h, p, kHeaderSize);
    if (std::memcmp(h.id, expectId, 32) != 0) return Parse::BadId;
    if (h.ch < 1 || h.ch > kMaxChannels) return Parse::BadChannels;
    if (h.sr < kMinRate || h.sr > kMaxRate) return Parse::BadRate;
    if (h.bytes == 0 || h.bytes > kMaxRxBytes || kHeaderSize + (size_t)h.bytes > n) return Parse::BadLength;
    if ((h.bytes % 4) != 0 || ((h.bytes / 4) % h.ch) != 0) return Parse::Misaligned;
    o.ch = h.ch;
    o.sr = h.sr;
    o.bytes = h.bytes;
    o.frames = h.bytes / 4 / h.ch;
    o.data = p + kHeaderSize;
    o.sizeFieldMismatch = (h.size != n);
    return Parse::Ok;
}

inline float Sanitize(float v) {
    if (!std::isfinite(v)) return 0.f;
    return v > 1.f ? 1.f : (v < -1.f ? -1.f : v);
}

// يستخرج قناة أحادية من بيانات منفصلة بالتتابع. sel >= 0: قناة محددة ، sel < 0 (أو خارج المدى): متوسط القنوات.
// ملاحظة: القراءة بـ memcpy لأن البيانات غير محاذاة داخل الحزمة (الإزاحة 47).
inline void ExtractMono(const uint8_t* data, uint32_t frames, uint32_t ch, int sel, float* out) {
    if (!data || !out || frames == 0 || ch == 0 || ch > kMaxChannels) return;
    const bool single = sel >= 0 && (uint32_t)sel < ch;
    for (uint32_t i = 0; i < frames; ++i) {
        float v;
        if (single) {
            std::memcpy(&v, data + ((size_t)sel * frames + i) * 4, 4);
            out[i] = Sanitize(v);
        } else {
            float acc = 0.f;
            for (uint32_t c = 0; c < ch; ++c) {
                std::memcpy(&v, data + ((size_t)c * frames + i) * 4, 4);
                acc += Sanitize(v);
            }
            out[i] = acc / (float)ch;
        }
    }
}

// ---------------------------------------------------------------- حلقة المخزن (منتج واحد / مستهلك واحد)
class SpscRing {
public:
    explicit SpscRing(size_t requested = (size_t)1 << 16)
        : mask_(NormalizeCapacity(requested) - 1), buf_(mask_ + 1, 0.f) {}
    uint64_t available() const { return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire); }
    // المنتج فقط. يعيد عدد العينات المرفوضة بسبب الامتلاء.
    uint64_t push(const float* s, uint64_t n) {
        if (!s && n) return n;
        const uint64_t h = head_.load(std::memory_order_relaxed);
        const uint64_t t = tail_.load(std::memory_order_acquire);
        const uint64_t freeSpace = (mask_ + 1) - (h - t);
        const uint64_t take = n > freeSpace ? freeSpace : n;
        for (uint64_t i = 0; i < take; ++i) buf_[(h + i) & mask_] = s[i];
        head_.store(h + take, std::memory_order_release);
        return n - take;
    }
    // المستهلك فقط.
    uint64_t pop(float* d, uint64_t n) {
        if (!d && n) return 0;
        const uint64_t t = tail_.load(std::memory_order_relaxed);
        const uint64_t a = head_.load(std::memory_order_acquire) - t;
        const uint64_t take = n > a ? a : n;
        for (uint64_t i = 0; i < take; ++i) d[i] = buf_[(t + i) & mask_];
        tail_.store(t + take, std::memory_order_release);
        return take;
    }
    void skip(uint64_t n) {  // المستهلك فقط
        const uint64_t t = tail_.load(std::memory_order_relaxed);
        const uint64_t a = head_.load(std::memory_order_acquire) - t;
        tail_.store(t + (n > a ? a : n), std::memory_order_release);
    }
    void reset() {  // فقط والخيوط متوقفة
        head_.store(0);
        tail_.store(0);
    }
    size_t capacity() const { return mask_ + 1; }

private:
    static size_t NormalizeCapacity(size_t requested) {
        size_t cap = 2;
        while (cap < requested && cap <= (static_cast<size_t>(-1) >> 1)) cap <<= 1;
        return cap;
    }
    const size_t mask_;
    std::vector<float> buf_;
    std::atomic<uint64_t> head_{0}, tail_{0};
};

// ---------------------------------------------------------------- محوّل معدل خطي (يُستدعى من خيط واحد)
class LinearResampler {
public:
    void Reset() { pos_ = 0; have_ = false; last_ = 0; }
    // step = معدل الدخل / معدل الخرج. يعيد عدد عينات الخرج (≤ cap).
    size_t Process(const float* in, size_t n, double step, float* out, size_t cap) {
        if (!in || !out || n == 0 || cap == 0 || !std::isfinite(step) || step <= 0.0) return 0;
        if (!have_) { last_ = in[0]; have_ = true; }
        size_t o = 0;
        double p = pos_;
        while (p < (double)n && o < cap) {
            const size_t idx = (size_t)p;
            const double fr = p - (double)idx;
            const float x0 = (idx == 0) ? last_ : in[idx - 1];
            const float x1 = in[idx];
            out[o++] = (float)(x0 * (1.0 - fr) + x1 * fr);
            p += step;
        }
        pos_ = p - (double)n;
        if (pos_ < 0) pos_ = 0;
        last_ = in[n - 1];
        return o;
    }

private:
    double pos_ = 0;
    float last_ = 0;
    bool have_ = false;
};

// ---------------------------------------------------------------- Blender
// يقرّر لكل كتلة: صوت معالَج أم المايك الأصلي، ويبدّل بينهما بمزج ناعم (بلا نقرات).
class Blender {
public:
    void Configure(uint32_t rate, uint64_t jitterSamples, uint64_t hiSamples, bool dryOnFallback, uint32_t rampSamples) {
        rate_ = rate;
        jitter_ = jitterSamples;
        hi_ = hiSamples > jitterSamples ? hiSamples : jitterSamples + 1;
        dryOnFallback_ = dryOnFallback;
        ramp_ = rampSamples ? rampSamples : 1;
        Reset();
    }
    void Reset() { primed_ = false; g_ = 0.f; last_ = 0.f; wetOk_ = false; touched_ = false; }

    // io: عينات متداخلة (frames*ch) تحمل المايك الأصلي، وتُعدَّل في مكانها.
    // wetScratch: مصفوفة بطول ≥ frames.
    void Process(float* io, uint32_t frames, uint32_t ch, SpscRing& ring, bool wetAllowed, float* wetScratch) {
        if (!io || !wetScratch || frames == 0 || ch == 0) return;
        uint64_t avail = ring.available();
        fillBefore_.store(avail, std::memory_order_relaxed);
        if (!wetAllowed) {
            if (avail) ring.skip(avail);  // حزم قديمة: نتخلص منها
            avail = 0;
            primed_ = false;
        } else {
            if (!primed_ && avail >= jitter_) { primed_ = true; primings_.fetch_add(1, std::memory_order_relaxed); }
            if (primed_ && avail > hi_) {  // انجراف الساعات: نعيد التأخير للحد الطبيعي
                ring.skip(avail - jitter_);
                avail = ring.available();
                overruns_.fetch_add(1, std::memory_order_relaxed);
            }
            if (primed_ && avail < frames) {
                primed_ = false;
                underruns_.fetch_add(1, std::memory_order_relaxed);
            }
        }
        wetOk_ = wetAllowed && primed_;
        uint32_t n = 0;
        if (wetOk_ || g_ > 0.f) n = (uint32_t)ring.pop(wetScratch, frames);  // عند الخروج التدريجي نستهلك ما تبقى
        const float target = wetOk_ ? 1.f : 0.f;
        const float step = 1.f / (float)ramp_;
        touched_ = false;
        for (uint32_t i = 0; i < frames; ++i) {
            if (g_ < target) g_ = std::min(target, g_ + step);
            else if (g_ > target) g_ = std::max(target, g_ - step);
            // Hold the last wet sample only during the short crossfade while dry gain rises.
            // This avoids a discontinuity; the ramp bounds the hold duration.
            const float w = (i < n) ? wetScratch[i] : last_;
            last_ = w;
            const float dryG = dryOnFallback_ ? (1.f - g_) : 0.f;
            if (g_ > 0.f) touched_ = true;
            for (uint32_t c = 0; c < ch; ++c) io[(size_t)i * ch + c] = io[(size_t)i * ch + c] * dryG + w * g_;
        }
    }

    bool wetOk() const { return wetOk_; }
    bool touchedWet() const { return touched_; }
    uint64_t lastFill() const { return fillBefore_.load(std::memory_order_relaxed); }
    uint32_t underruns() const { return underruns_.load(std::memory_order_relaxed); }
    uint32_t overruns() const { return overruns_.load(std::memory_order_relaxed); }
    uint32_t primings() const { return primings_.load(std::memory_order_relaxed); }

private:
    uint32_t rate_ = 48000;
    uint64_t jitter_ = 1920, hi_ = 6720;
    bool dryOnFallback_ = true;
    uint32_t ramp_ = 240;
    bool primed_ = false, wetOk_ = false, touched_ = false;
    float g_ = 0.f, last_ = 0.f;
    std::atomic<uint64_t> fillBefore_{0};
    std::atomic<uint32_t> underruns_{0}, overruns_{0}, primings_{0};
};

}  // namespace mb
