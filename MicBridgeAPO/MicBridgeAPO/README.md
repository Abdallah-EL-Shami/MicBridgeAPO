# MicBridge APO

## البناء (بدون تثبيت شيء) - GitHub Actions
ارفع المجلد، ثم Actions > build-dll > Run workflow، ونزّل MicBridgeAPO-dll.

## حالة نسخة التحقق الحالية
هذه النسخة على فرع الاستعادة مخصصة لاختبارات CI ومراجعة التراجع فقط، وليست إصدارًا معتمدًا للتثبيت. لا تثبّت حزمة Actions الناتجة من هذا الفرع حتى صدور موافقة صريحة على الإصدار.

## التثبيت (بعد اعتماد إصدار رسمي فقط)
1. نزّل ملف MicBridgeAPO-Install-Package وفك ضغطه كاملًا في مجلد واحد. لا تنقل الملفات منفردة ولا تحذف مجلد tools؛ يجب أن تبقى وحدات tools\\MicBridge.RecoveryJournal.psm1 وtools\\MicBridge.InstallRollbackValidation.psm1 وtools\\MicBridge.EndpointRegistryRollback.psm1 وtools\\MicBridge.InstallRollbackActions.psm1 بجانب ملفات التثبيت.
2. انقر مرتين على install.bat (يطلب صلاحيات المسؤول تلقائيًا).
   لتثبيت مايك آخر: powershell -ExecutionPolicy Bypass -File install.ps1 -DeviceName "الاسم"

## الواجهة
اختصار MicBridge على سطح المكتب: زر تشغيل/إيقاف، والتأخير وحمل المعالج والحزم.
الإيقاف يمرّر المايك الأصلي فقط ولا يغيّر أي شيء آخر في النظام.
الواجهة تعرض بيانات فقط أثناء استخدام برنامج للمايك (كروم مثلًا).

## Cantabile
- ReaStream Receive بالمعرّف APO_MIC_RAW في أول السلسلة.
- ReaStream Send بالمعرّف APO_MIC_FX في آخرها (Mono). اكتب `127.255.255.255` في خانة IP للإرسال.
- لا تستخدم عنوان Unicast. كل من ReaStream وMicBridge يستقبلان على UDP/58710 ويحتاجان نسخة من حزمة البث نفسها؛ عنوان البث المحلي المحدد يطابق `MicBridge.ini`.
- الاختبار الآلي يتحقق من مشاركة المنفذ على Windows؛ يجب أيضًا التأكد من وصول الحزم إلى عدادي ReaStream وMicBridge على الجهاز الفعلي.

## اختبار التشغيل على الجهاز
افتح Cantabile أولًا مع تفعيل ReaStream Receive/Send، ثم من مجلد الحزمة بعد التثبيت شغّل PowerShell x64 كمسؤول ونفّذ `powershell -ExecutionPolicy Bypass -File .\Test-ApoRuntime.ps1 -DurationSeconds 60`. عند الطلب ابدأ تسجيلًا فعليًا من AT2040USB ثم أوقفه؛ سيحفظ التقرير في `C:\ProgramData\MicBridgeAPO` ويتحقق من مالكي UDP/58710. الاختبار للقراءة فقط.

## الإزالة
انقر مرتين على uninstall.bat. يعيد القيم الأصلية ومالك المفتاح وصلاحياته (SDDL).
