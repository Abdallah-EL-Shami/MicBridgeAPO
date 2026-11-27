# التحقق اليدوي من موثوقية حزمة MicBridgeAPO

هذه الخطوة مطلوبة لأن مشغّل Bootstrap الأصلي ما زال fail-closed ولا يشغّل المثبّت. المسار العملي الحالي يستخدم تحققًا يدويًا خارج الحزمة، ثم يعيد المثبّت التحقق من توقيع كل ملفات PowerShell ومن Manifest وملفات الحزمة.

## قبل تشغيل المثبّت

1. استخرج الحزمة إلى مجلد محلي جديد.
2. افتح PowerShell داخل مجلد الحزمة. لا تشغّل `install.bat` في هذه الخطوة.
3. افحص توقيع ملف الدخول نفسه:

```powershell
$s = Get-AuthenticodeSignature -FilePath .\install.ps1
$s | Format-List Status,StatusMessage,SignerCertificate
if ($null -eq $s.SignerCertificate) { throw 'No Authenticode signer certificate was found.' }
$sha256 = $s.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
$sha1 = $s.SignerCertificate.Thumbprint
"Signer SHA-256: $sha256"
"Signer SHA-1:   $sha1"
```

يجب أن تكون البصمة SHA-256 مساوية تمامًا للقيمة التالية، وأن تكون بصمة SHA-1 مساوية أيضًا:

- SHA-256: `CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369`
- SHA-1: `29BAC42BFC53F2586559A9B95D1FEEB658E8891A`

قد تكون حالة Authenticode هي `NotTrusted` لأن شهادة الناشر ذاتية التوقيع ولم تُثبت في مخازن الثقة. هذا مقبول فقط بعد مطابقة البصمتين أعلاه، مع وجود توقيع سليم وشهادة موقّع. ارفض الحزمة إذا كانت الحالة `HashMismatch` أو `NotSigned` أو لم تظهر شهادة موقّع أو اختلفت أي بصمة.

## تشغيل التثبيت بعد التحقق

بعد نجاح المقارنة يدويًا، شغّل:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -PublisherSignatureVerified
```

سيعيد المثبّت فحص توقيع كل ملفات `.ps1` و`.psm1` داخل الحزمة باستخدام هوية الناشر المثبتة في الكود، ثم يتحقق من توقيع Manifest وبصمات الملفات قبل طلب UAC أو إجراء أي تعديل على النظام.

## جرد النسخة القديمة دون تعديل النظام

لا تنفّذ هذا الفحص إلا من حزمة إصدار موقّعة بعد مطابقة بصمة ملف الدخول وأداة الجرد نفسيهما. لا تستخدم نسخة CI غير الموقّعة لهذا الغرض.

تحقق أولًا من توقيع أداة الجرد وبصمة شهادة الناشر:

```powershell
$s = Get-AuthenticodeSignature -FilePath .\tools\Inspect-MBLegacyInstallation.ps1
$s | Format-List Status,StatusMessage,SignerCertificate
if ($null -eq $s.SignerCertificate) { throw 'No inventory-script signer certificate was found.' }
$sha256 = $s.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
$sha1 = $s.SignerCertificate.Thumbprint
if ($sha256 -ne 'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369' -or $sha1 -ne '29BAC42BFC53F2586559A9B95D1FEEB658E8891A') { throw 'Inventory-script publisher pin mismatch.' }
if ($s.Status -notin @([Management.Automation.SignatureStatus]::Valid,[Management.Automation.SignatureStatus]::NotTrusted)) { throw "Inventory-script signature is not intact: $($s.Status)" }

$s = Get-AuthenticodeSignature -FilePath .\install.ps1
if ($null -eq $s.SignerCertificate -or $s.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -ne 'CF4104CA62A9A1384DE546B41B82E5C336462764AEA30488815922105EF7D369' -or $s.SignerCertificate.Thumbprint -ne '29BAC42BFC53F2586559A9B95D1FEEB658E8891A' -or $s.Status -notin @([Management.Automation.SignatureStatus]::Valid,[Management.Automation.SignatureStatus]::NotTrusted)) { throw 'Installer signature or publisher pin mismatch.' }

& .\tools\Inspect-MBLegacyInstallation.ps1 -PublisherSignatureVerified | Tee-Object -FilePath .\\legacy-inventory.json
```


ملاحظة: أداة الجرد تتحقق بنفسها من توقيع ملف الدخول الحالي ومن توقيع وحدة التدقيق قبل استيرادها. لا تمرّر لها مفتاح تجاوز ثقة. مع ذلك، يجب مطابقة بصمة ملف الدخول يدويًا من قناة مستقلة قبل تشغيله؛ فالفحص الذاتي لا يثبت موثوقية نسخة استُبدلت قبل بدء PowerShell.

أرسل ملف `legacy-inventory.json` للمراجعة قبل أي إزالة. الأداة لا تحذف ملفات أو مفاتيح Registry، ولا تستعيد `backup.json` أو أي نسخة احتياطية. إذا ظهر `ReviewRequired` أو أي عنصر `Ambiguous` أو `ForeignOrSharedServer` أو `ReparsePointPreserved`، لا تحذف ذلك العنصر. التقرير جرد فقط ولا يمنح تصريح تنظيف.

## حدود هذا المسار

- لا تثبّت هذه الخطوة الشهادة في Root أو Trusted Publishers تلقائيًا، ولا تغيّر إعدادات Windows.
- لا تعتبر `ExecutionPolicy` حدًا أمنيًا؛ التحقق يعتمد على التوقيع والبصمات المثبتة.
- هذا المسار يقلل تعقيد Native Bootstrap، لكنه لا يوفر ضمانًا مكافئًا لمشغّل Native موثوق ضد مسؤول نظام محلي خبيث أو تغيير متزامن بعد الفحص. يجب إبقاء الجهاز والحزمة تحت سيطرتك أثناء التحقق والتثبيت.
- لا يعني نجاح CI أن APO يعمل على الميكروفون الحقيقي؛ يلزم اختبار عملي منفصل بعد تجهيز حزمة موقعة.
- لا تنشئ شهادة جديدة لكل إصدار. أعد استخدام شهادة الناشر الحالية وفق سياسة المشروع.
