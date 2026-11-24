# MicBridge APO

## البناء (Visual Studio 2022)
1. ثبّت workload: Desktop development with C++ ومعه Windows 10/11 SDK.
2. File > Open > Folder... واختر هذا المجلد، ثم اختر x64-Release وابنِ.
3. انسخ MicBridgeAPO.dll الناتج بجانب install.ps1.

## التثبيت
PowerShell كمسؤول:
    Set-ExecutionPolicy -Scope Process Bypass
    .\install.ps1                    # الافتراضي AT2040USB
    .\install.ps1 -DeviceName "اسم آخر"

## Cantabile
- ReaStream Receive بالمعرّف APO_MIC_RAW في أول السلسلة.
- ReaStream Send بالمعرّف APO_MIC_FX في آخرها (اجعله Mono).
- وضع الشبكة في الاثنين: Local broadcast (الافتراضي).

## تغيير المعرّفات
عدّل C:\ProgramData\MicBridgeAPO\MicBridge.ini ثم أعد فتح Chrome.
السجل: C:\ProgramData\MicBridgeAPO\MicBridge.log

## الإزالة
    .\uninstall.ps1

## البناء بدون تثبيت أي شيء (GitHub Actions)
1. أنشئ حسابًا مجانيًا على github.com ثم New repository (يفضّل Private).
2. ارفع محتويات هذا المجلد كلها (Add file > Upload files) مع المجلد المخفي .github
3. تبويب Actions > build-dll > Run workflow، وانتظر دقيقة أو دقيقتين.
4. افتح التشغيل الناجح ونزّل MicBridgeAPO-dll من قسم Artifacts، وفك الضغط.
