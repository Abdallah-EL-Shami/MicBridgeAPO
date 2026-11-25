#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <audioenginebaseapo.h>

#include <cstdio>

static const CLSID CLSID_MicBridgeAPO =
    {0xA3F6C1D2, 0x7B84, 0x4E19, {0x9C, 0x55, 0x2D, 0x8E, 0x1F, 0x0B, 0x6A, 0x47}};

using DllGetClassObjectFn = HRESULT (STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*);

#define CHECK_HR(expr) do { HRESULT _hr=(expr); if (FAILED(_hr)) { std::printf("FAIL line %d: %s -> 0x%08X\\n", __LINE__, #expr, (unsigned)_hr); return 1; } } while (0)
#define CHECK_TRUE(expr) do { if (!(expr)) { std::printf("FAIL line %d: %s\\n", __LINE__, #expr); return 1; } } while (0)

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) {
        wprintf(L"Usage: apo_com_smoke.exe <path-to-MicBridgeAPO.dll>\\n");
        return 2;
    }

    HMODULE module = LoadLibraryW(argv[1]);
    CHECK_TRUE(module != nullptr);
    auto getClassObject = reinterpret_cast<DllGetClassObjectFn>(
        GetProcAddress(module, "DllGetClassObject"));
    CHECK_TRUE(getClassObject != nullptr);

    CHECK_HR(CoInitializeEx(nullptr, COINIT_MULTITHREADED));

    using DllCanUnloadNowFn = HRESULT (STDAPICALLTYPE*)();
    auto canUnload = reinterpret_cast<DllCanUnloadNowFn>(GetProcAddress(module, "DllCanUnloadNow"));
    CHECK_TRUE(canUnload != nullptr);

    IClassFactory* factory = nullptr;
    CHECK_HR(getClassObject(CLSID_MicBridgeAPO, IID_IClassFactory,
                            reinterpret_cast<void**>(&factory)));
    CHECK_TRUE(canUnload() == S_FALSE);

    // Factory references must keep the DLL non-unloadable and balance exactly.
    IUnknown* factoryIdentity = nullptr;
    CHECK_HR(factory->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&factoryIdentity)));
    CHECK_TRUE(canUnload() == S_FALSE);
    factoryIdentity->Release();

    factory->AddRef();
    CHECK_TRUE(canUnload() == S_FALSE);
    factory->Release();

    IAudioProcessingObject* apo = nullptr;
    CHECK_HR(factory->CreateInstance(nullptr, __uuidof(IAudioProcessingObject),
                                     reinterpret_cast<void**>(&apo)));

    APO_REG_PROPERTIES* props = nullptr;
    CHECK_HR(apo->GetRegistrationProperties(&props));
    CHECK_TRUE(props != nullptr);
    CHECK_TRUE(IsEqualCLSID(props->clsid, CLSID_MicBridgeAPO));
    CHECK_TRUE(props->Flags == (APO_FLAG)(APO_FLAG_DEFAULT | APO_FLAG_INPLACE));
    CHECK_TRUE(props->u32MinInputConnections == 1 && props->u32MaxInputConnections == 1);
    CHECK_TRUE(props->u32MinOutputConnections == 1 && props->u32MaxOutputConnections == 1);
    CHECK_TRUE(props->u32NumAPOInterfaces == 1);
    CHECK_TRUE(IsEqualIID(props->iidAPOInterfaceList[0], __uuidof(IAudioProcessingObject)));
    CoTaskMemFree(props);

    IAudioProcessingObjectRT* rt = nullptr;
    IAudioProcessingObjectConfiguration* config = nullptr;
    IAudioSystemEffects* effects = nullptr;
    CHECK_HR(apo->QueryInterface(__uuidof(IAudioProcessingObjectRT), reinterpret_cast<void**>(&rt)));
    CHECK_HR(apo->QueryInterface(__uuidof(IAudioProcessingObjectConfiguration), reinterpret_cast<void**>(&config)));
    CHECK_HR(apo->QueryInterface(__uuidof(IAudioSystemEffects), reinterpret_cast<void**>(&effects)));

    CHECK_HR(apo->Initialize(0, nullptr));
    HRESULT secondInit = apo->Initialize(0, nullptr);
    CHECK_TRUE(secondInit == APOERR_ALREADY_INITIALIZED);

    effects->Release();
    config->Release();
    rt->Release();
    apo->Release();

    // A fresh object must reject a malformed initialization header.
    IAudioProcessingObject* invalidApo = nullptr;
    CHECK_HR(factory->CreateInstance(nullptr, __uuidof(IAudioProcessingObject),
                                     reinterpret_cast<void**>(&invalidApo)));
    APOInitBaseStruct bad{};
    bad.cbSize = sizeof(bad);
    bad.clsid = CLSID_NULL;
    HRESULT badHr = invalidApo->Initialize(sizeof(bad), reinterpret_cast<BYTE*>(&bad));
    CHECK_TRUE(badHr == E_INVALIDARG);
    invalidApo->Release();

    // A correctly formed base header is accepted.
    IAudioProcessingObject* validApo = nullptr;
    CHECK_HR(factory->CreateInstance(nullptr, __uuidof(IAudioProcessingObject),
                                     reinterpret_cast<void**>(&validApo)));
    APOInitBaseStruct good{};
    good.cbSize = sizeof(good);
    good.clsid = CLSID_MicBridgeAPO;
    CHECK_HR(validApo->Initialize(sizeof(good), reinterpret_cast<BYTE*>(&good)));
    validApo->Release();

    // Prove server locks alone keep the module alive after the factory ref is released.
    CHECK_HR(factory->LockServer(TRUE));
    CHECK_HR(factory->LockServer(TRUE));
    factory->Release();
    factory = nullptr;
    CHECK_TRUE(canUnload() == S_FALSE);

    IClassFactory* unlockFactory = nullptr;
    CHECK_HR(getClassObject(CLSID_MicBridgeAPO, IID_IClassFactory,
                            reinterpret_cast<void**>(&unlockFactory)));
    CHECK_HR(unlockFactory->LockServer(FALSE));
    CHECK_TRUE(canUnload() == S_FALSE);
    CHECK_HR(unlockFactory->LockServer(FALSE));
    CHECK_TRUE(unlockFactory->LockServer(FALSE) == E_UNEXPECTED);
    unlockFactory->Release();
    CHECK_HR(canUnload());
    CoUninitialize();
    FreeLibrary(module);

    std::puts("PASS: COM factory refs, LockServer balancing, APO interfaces, registration properties, and Initialize validation");
    return 0;
}
