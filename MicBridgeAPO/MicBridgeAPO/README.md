# MicBridge APO

## البناء (بدون تثبيت شيء) - GitHub Actions
ارفع المجلد، ثم Actions > build-dll > Run workflow، ونزّل MicBridgeAPO-dll.

## التثبيت
1. ضع في مجلد واحد: MicBridgeAPO.dll و install.ps1 و install.bat و uninstall.ps1 و uninstall.bat و MicBridgeUI.ps1 و MicBridge.ini
2. انقر مرتين على install.bat (يطلب صلاحيات المسؤول تلقائيًا).
   لتثبيت مايك آخر: powershell -ExecutionPolicy Bypass -File install.ps1 -DeviceName "الاسم"

## الواجهة
اختصار MicBridge على سطح المكتب: زر تشغيل/إيقاف، والتأخير وحمل المعالج والحزم.
الإيقاف يمرّر المايك الأصلي فقط ولا يغيّر أي شيء آخر في النظام.
الواجهة تعرض بيانات فقط أثناء استخدام برنامج للمايك (كروم مثلًا).

## Cantabile
- ReaStream Receive بالمعرّف APO_MIC_RAW في أول السلسلة.
- ReaStream Send بالمعرّف APO_MIC_FX في آخرها (Mono). وضع الشبكة: Local broadcast.
- استخدم Local broadcast في الإرسال؛ لا تستخدم عنوان Unicast. كل من ReaStream وMicBridge يستقبلان على UDP/58710 ويحتاجان نسخة من حزمة البث نفسها.
- الاختبار الآلي يتحقق من مشاركة المنفذ على Windows؛ يجب أيضًا التأكد من وصول الحزم إلى عدادي ReaStream وMicBridge على الجهاز الفعلي.

## الإزالة
انقر مرتين على uninstall.bat. يعيد القيم الأصلية ومالك المفتاح وصلاحياته (SDDL).
