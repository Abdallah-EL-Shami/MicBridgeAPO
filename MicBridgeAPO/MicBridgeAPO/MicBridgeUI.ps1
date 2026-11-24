# واجهة MicBridge: تشغيل/إيقاف + معلومات مختصرة
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$dir        = Join-Path $env:ProgramData 'MicBridgeAPO'
$statusFile = Join-Path $dir 'status.txt'
$ctrlFile   = Join-Path $dir 'control.ini'
$inv        = [Globalization.CultureInfo]::InvariantCulture

function Read-Status {
    $h = @{}
    try {
        $fs = New-Object IO.FileStream($statusFile, 'Open', 'Read', 'ReadWrite,Delete')
        $txt = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
        foreach ($l in ($txt -split "`n")) { $p = $l.Trim() -split '=', 2; if ($p.Count -eq 2) { $h[$p[0]] = $p[1] } }
    } catch {}
    return $h
}
function Get-Enabled {
    try { return -not ((Get-Content $ctrlFile -Raw) -match 'Enabled\s*=\s*0') } catch { return $true }
}
function Set-Enabled([int]$v) { [IO.File]::WriteAllText($ctrlFile, "[Control]`r`nEnabled=$v`r`n") }
function Num($h, $k) { try { return [double]::Parse($h[$k], $inv) } catch { return 0 } }

$form = New-Object Windows.Forms.Form
$form.Text = 'MicBridge'
$form.Size = New-Object Drawing.Size(440, 330)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

function New-Label($y, $size, $bold) {
    $l = New-Object Windows.Forms.Label
    $l.Location = New-Object Drawing.Point(15, $y); $l.Size = New-Object Drawing.Size(395, $size)
    if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }
    $form.Controls.Add($l); return $l
}
$lblState = New-Label 15 44 $true
$lblLat   = New-Label 70 24 $false
$lblCpu   = New-Label 98 24 $false
$lblFmt   = New-Label 126 24 $false
$lblPkt   = New-Label 154 24 $false
$lblWarn  = New-Label 182 24 $false
$lblWarn.ForeColor = [Drawing.Color]::DarkRed
$lblNote  = New-Label 262 30 $false
$lblNote.Font = New-Object Drawing.Font('Segoe UI', 8)
$lblNote.ForeColor = [Drawing.Color]::Gray
$lblNote.Text = 'التأخير تقريبي من جهة البرنامج ولا يشمل تأخير Cantabile. الحمل نسبة من نواة واحدة.'

$btn = New-Object Windows.Forms.Button
$btn.Location = New-Object Drawing.Point(15, 212); $btn.Size = New-Object Drawing.Size(395, 42)
$btn.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($btn)

function Refresh-Ui {
    $enabled = Get-Enabled
    if ($enabled) { $btn.Text = 'إيقاف (تمرير المايك الأصلي)' } else { $btn.Text = 'تشغيل المعالجة' }
    $h = Read-Status
    $fresh = $false
    if ($h.ContainsKey('ts')) {
        try { $age = ([DateTime]::UtcNow - [DateTime]::FromFileTimeUtc([int64]$h['ts'])).TotalSeconds; $fresh = ($age -lt 3.5) } catch {}
    }
    $lblWarn.Text = ''
    if (-not $fresh -or $h['state'] -eq 'IDLE') {
        $lblState.Text = 'الحالة: لا يوجد برنامج يستخدم المايك الآن (انتظار)'
        $lblState.ForeColor = [Drawing.Color]::Gray
        $lblLat.Text = 'التأخير الإضافي: -'; $lblCpu.Text = 'حمل المعالج: -'; $lblFmt.Text = 'الصيغة: -'; $lblPkt.Text = 'الحزم: -'
        return
    }
    switch ($h['state']) {
        'PROCESSING' { $lblState.Text = 'الحالة: يعمل، الصوت يمر عبر Cantabile'; $lblState.ForeColor = [Drawing.Color]::DarkGreen }
        'FALLBACK'   { $lblState.Text = 'الحالة: لا يصل صوت من Cantabile، يمرّر المايك الأصلي'; $lblState.ForeColor = [Drawing.Color]::DarkOrange }
        'BYPASS'     { $lblState.Text = 'الحالة: متوقف بأمرك، يمرّر المايك الأصلي'; $lblState.ForeColor = [Drawing.Color]::Gray }
        'DISABLED'   { $lblState.Text = 'الحالة: معطّل من ملف الإعدادات (Enabled=0)'; $lblState.ForeColor = [Drawing.Color]::Gray }
        default      { $lblState.Text = 'الحالة: ' + $h['state']; $lblState.ForeColor = [Drawing.Color]::Black }
    }
    $lat = (Num $h 'bufMs') + (Num $h 'blockMs')
    $lblLat.Text = ('التأخير الإضافي التقريبي: {0:N0} ms' -f $lat)
    $lblCpu.Text = ('حمل المعالج (الـ APO): {0:N2} %' -f (Num $h 'cpu'))
    $lblFmt.Text = ('الصيغة: {0} Hz، {1} قناة' -f (Num $h 'rate'), (Num $h 'ch'))
    $lblPkt.Text = ('حزم/ثانية: إرسال {0:N0} | استقبال {1:N0} | انقطاعات: {2}' -f (Num $h 'tx'), (Num $h 'rx'), (Num $h 'underruns'))
    if ($h['bind'] -eq '0') { $lblWarn.Text = 'تحذير: تعذّر فتح منفذ الاستقبال، راجع MicBridge.log' }
}

$btn.Add_Click({
    try { if (Get-Enabled) { Set-Enabled 0 } else { Set-Enabled 1 }; Refresh-Ui }
    catch { [Windows.Forms.MessageBox]::Show("تعذر تغيير الحالة: $($_.Exception.Message)", 'MicBridge') | Out-Null }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ Refresh-Ui })
$timer.Start()
Refresh-Ui
[void]$form.ShowDialog()
