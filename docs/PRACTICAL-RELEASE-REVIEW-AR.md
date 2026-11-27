# مراجعة مسار الإصدار العملي — 2026-11-27

## النتيجة التنفيذية

المراجعة تمت على الفرع `release/practical-stability`، commit الأساس الذي يحتوي ملف التسليم هو:
`b94917e3373059ffe8136cfe91dc324545989dba`.

آخر CI لهذا commit:
- Run: 1674
- Run ID: 46059449094
- النتيجة: success
- الرابط: https://github.com/Abdallah-EL-Shami/MicBridgeAPO/actions/runs/46059449094
- نجح بناء DLL واختبار COM smoke وجميع خطوات اختبارات السلامة والـfixtures.
- artifacts: `MicBridgeAPO-dll` و`MicBridgeAPO-Install-Package`.
- هذا ليس signed release حقيقيًا، ولا يثبت تحميل APO داخل audiodg.exe على جهاز المستخدم.

## ما تم التحقق منه في الكود

### APO DLL
المصدر: `MicBridgeAPO/MicBridgeAPO/src/MicBridgeAPO.cpp`
- يعرّف COM APO بـCLSID ثابت، ويدعم `IAudioProcessingObject` و`IAudioProcessingObjectRT` و`IAudioProcessingObjectConfiguration` و`IAudioSystemEffects`.
- `Initialize` يقبل payload صفريًا، ويتحقق من APOInitBaseStruct/CLSID إذا وصل payload.
- `LockForProcess` يقبل اتصالًا واحدًا داخلًا وواحدًا خارجًا، ويشترط Float32 متطابقًا ومعدل/قنوات متطابقة، ثم يبدأ جسر UDP.
- `APOProcess` يحافظ على dry input كمسار pass-through عند تعطيل الجسر أو فشله، ويعمل crossfade إلى الصوت المستلم عند نشاط الجسر.
- يبدأ الجسر خيطي إرسال واستقبال UDP عند LockForProcess، ويتطلب جاهزية الخيطين قبل إعلان الحالة active؛ عند فشل الشبكة يرجع إلى pass-through.
- توجد سجلات تشخيصية لمرحلة COM وتهيئة APO وتنسيقات الصوت وLockForProcess وAPOProcess وUDP.

### ما لا يثبته اختبار COM الحالي
`tests/apo_com_smoke.cpp` يحمّل DLL مباشرة بـLoadLibrary، يستدعي DllGetClassObject، ينشئ COM factory/APO، يفحص خصائص التسجيل وواجهات COM وInitialize.
لكنه لا يستدعي دورة Windows Audio Engine الفعلية كاملة ولا يثبت:
- تسجيل CLSID وAudioEngine APO بصورة صحيحة في HKLM على جهاز حقيقي.
- أن audiodg.exe حمّل هذه النسخة من DLL.
- أن Capture endpoint المقصود استدعى APO.
- أن مؤشر استخدام الميكروفون يظهر عند فتح تطبيق له.
- أن Cantabile وMicBridge يشتركان فعليًا في UDP/58710.

### اختبارات عملية موجودة مسبقًا
- `tools/Inspect-ApoEndpoint.ps1`: قراءة فقط، يعرض endpoint properties وCOM/AudioEngine registration ووجود DLL وhash ومحاولة رؤية DLL ضمن audiodg modules.
- `tools/Test-ApoRuntime.ps1`: probe قراءة فقط لمدة محددة؛ أثناء تسجيل حقيقي يراقب audiodg module، logs، DllGetClassObject، Initialize، format acceptance، LockForProcess، UDP TX/RX، ring drops، ومشاركة UDP/58710 مع Cantabile.
- هذه الأدوات ليست اختبار CI؛ تحتاج تشغيلًا على الجهاز المستهدف بعد وجود نسخة مثبتة/مسجلة. فشل تعداد modules وحده لا يثبت عدم التحميل، كما يذكر السكربت.

## العوائق التي تمنع اعتبار الحزمة جاهزة الآن

1. `install.ps1` يشترط signed Manifest وملف CMS وملفات الحزمة المثبتة بمقابض.
2. شرط المثبت يرفض إذا كان `BootstrapTrustEstablished` غير صحيح. الحالة الحالية في verifier متعمدة أن تكون false لأن المشغّل المستقل لم يكتمل.
3. شرط المثبت يتطلب أيضًا عدم الادعاء بأن path-based verifier وحده جعل التنفيذ RaceSafe أو أثبت ownership.
4. بعد ذلك، بوابة Legacy audit لا تسمح بالتثبيت إلا إذا كانت النتيجة `NoLegacyResidueDetected`. أي نسخة قديمة/بقايا أو ملكية غير محسومة تمنع التثبيت بلا تنظيف تلقائي.
5. لذلك لا يمكن أخذ artifact العادي من CI وتشغيل install.ps1، ولا يجوز حذف هذه الحواجز أو قلب قيمها إلى true لتسهيل الإصدار.
6. المستخدم لديه تثبيت قديم من مرحلة التطوير؛ يجب ألا نفترض أن backup القديم يثبت baseline الأصلي أو ملكية COM/DLL.

## مسار الإنجاز الأسرع دون تجاوز السلامة

### المحطة 1 — التشخيص العملي read-only
- جهّز تعليمات تشغيل `Inspect-ApoEndpoint.ps1` و`Test-ApoRuntime.ps1` على النسخة الموجودة حاليًا، دون تثبيت أو حذف أو تعديل Registry.
- اجمع تقرير endpoint وProcmon/logs.
- حدّد هل المشكلة الحالية في تسجيل APO، تحميل DLL داخل audiodg، استدعاء Initialize/LockForProcess، أو جسر UDP.
- هذه الخطوة تمنع تغيير المثبت بينما العطل في طبقة مختلفة.

### المحطة 2 — أصغر إصلاح مثبت بالأدلة
- لا تغيّر DSP أو مسار الصوت إذا لم تثبت الحاجة.
- أصلح فقط ما تثبته نتائج التشخيص.
- أضف اختبارًا مناسبًا يمنع رجوع العطل في CI قدر الإمكان.
- احتفظ بالـpass-through عند فشل bridge.

### المحطة 3 — مسار تثبيت موثوق
- إكمال الحد الأدنى الآمن من Bootstrap الذي يتحقق من توقيع launcher/الحزمة/Manifest قبل تحميل أي كود PowerShell من الحزمة.
- توفير handoff يمنع تشغيل install.ps1 مباشرة.
- لا تزيل بوابة legacy؛ افحص الأدلة الخاصة بالتثبيت القديم. إذا تعذر إثبات baseline أو ownership، توقف ولا تنظف تلقائيًا.
- لا تستخدم PFX أو tag/signed-release إلا بإذن صريح.

### المحطة 4 — CI ثم اختبار المالك
- CI build + tests + artifact audit.
- تشغيل تشخيص read-only قبل وبعد الاختبار.
- اختبار الميكروفون مع تطبيقين، التأكد من indicator وaudiodg/DLL وUDP، ومراجعة عدم تغير Realtek/الأجهزة الأخرى.
- لا يعلن الإصدار مستقرًا إلا بعد هذه النتائج.

## تقدير الوقت

تقدير تقريبي مشروط بنتيجة التشخيص:
- التشخيص read-only على النسخة الحالية: جلسة واحدة من 20–40 دقيقة من وقت المستخدم بعد تجهيز التعليمات.
- إصلاح برمجي محدود + CI: من نصف يوم إلى يوم عمل.
- إذا احتجنا تعديلًا معماريًا في APO أو توافقًا مع Audio Engine/Protected Audio Path: قد يستغرق أكثر، ولا يمكن تقديره قبل الأدلة.
- أصغر Bootstrap آمن واختباراته: من يوم إلى يومين إذا لم تظهر عقبات.
- اختبار القبول النهائي على جهاز المستخدم: جلسة 30–60 دقيقة تقريبًا.

**التقدير الأسرع الواقعي:** يومان إلى أربعة أيام عمل برمجية إذا كانت المشكلة محدودة، إضافة إلى جلسة اختبار الجهاز. ليس وعدًا بموعد؛ أي عائق في Protected Audio Path أو baseline القديم قد يمدد ذلك.

## حدود السلامة

- لا تغيير في إعداد `DisableProtectedAudioDG`.
- لا تغيير أو حذف لتعريفات Realtek أو ملفات Windows.
- لا تنظيف تلقائي للنسخة القديمة أو مفاتيح COM المشتركة.
- لا تعديل Registry في CI خارج HKCU fixtures.
- لا تثبيت/إزالة على جهاز المالك من طرف التطوير.
- لا signed release حقيقي أو استخدام أسرار PFX دون إذن.
