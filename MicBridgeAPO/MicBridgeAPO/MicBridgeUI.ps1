# MicBridge compact status UI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$dir = Join-Path $env:ProgramData 'MicBridgeAPO'
$statusFile = Join-Path $dir 'status.txt'
$ctrlFile = Join-Path $dir 'control.ini'
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:lastTx = $null
$script:lastTxAt = [DateTime]::UtcNow
$script:lastUnderruns = $null
$script:lastUnderrunAt = $null
$script:lastCpuAt = [DateTime]::UtcNow
$script:lastCpuSeconds = $null
$script:cpuPercent = $null

function Read-Status {
    $h = @{}
    try {
        $fs = New-Object IO.FileStream($statusFile, 'Open', 'Read', 'ReadWrite,Delete')
        try { $txt = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        foreach ($l in ($txt -split "`n")) { $p = $l.Trim() -split '=', 2; if ($p.Count -eq 2) { $h[$p[0]] = $p[1] } }
    } catch {}
    return $h
}
function Get-Enabled {
    try { return -not ((Get-Content $ctrlFile -Raw) -match 'Enabled\\s*=\\s*0') } catch { return $true }
}
function Set-Enabled([int]$v) { [IO.File]::WriteAllText($ctrlFile, "[Control]`r`nEnabled=$v`r`n") }
function Num($h, $k) { try { return [double]::Parse($h[$k], $inv) } catch { return 0 } }

function Update-AudioDgCpu {
    $now = [DateTime]::UtcNow
    try {
        $procs = @(Get-Process -Name audiodg -ErrorAction Stop)
        $cpuSeconds = 0.0
        foreach ($p in $procs) { $cpuSeconds += $p.TotalProcessorTime.TotalSeconds }
        if ($null -ne $script:lastCpuSeconds) {
            $elapsed = ($now - $script:lastCpuAt).TotalSeconds
            if ($elapsed -gt 0.1) {
                $script:cpuPercent = [Math]::Max(0,[Math]::Min(100, (($cpuSeconds - $script:lastCpuSeconds) / $elapsed / [Math]::Max(1,[Environment]::ProcessorCount)) * 100))
            }
        }
        $script:lastCpuSeconds = $cpuSeconds
        $script:lastCpuAt = $now
    } catch {
        $script:cpuPercent = $null
        $script:lastCpuSeconds = $null
        $script:lastCpuAt = $now
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'MicBridge'
$form.Size = New-Object Drawing.Size(440, 330)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

function New-Label($y, $height, $bold) {
    $l = New-Object Windows.Forms.Label
    $l.Location = New-Object Drawing.Point(15, $y)
    $l.Size = New-Object Drawing.Size(395, $height)
    if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }
    $form.Controls.Add($l)
    return $l
}
$lblState = New-Label 14 42 $true
$lblIo = New-Label 62 28 $false
$lblQuality = New-Label 92 26 $false
$lblLat = New-Label 121 24 $false
$lblCpu = New-Label 148 24 $false
$lblFmt = New-Label 175 24 $false
$lblWarn = New-Label 203 28 $false
$lblWarn.ForeColor = [Drawing.Color]::DarkRed
$lblNote = New-Label 287 24 $false
$lblNote.Font = New-Object Drawing.Font('Segoe UI', 8)
$lblNote.ForeColor = [Drawing.Color]::Gray
$lblNote.Text = 'التأخير تقريبي ولا يشمل تأخير Cantabile؛ حمل المعالج محسوب لعملية AudioDG.'

$btn = New-Object Windows.Forms.Button
$btn.Location = New-Object Drawing.Point(15, 238)
$btn.Size = New-Object Drawing.Size(395, 42)
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
        $lblState.Text = 'الحالة: انتظار استخدام الميكروفون'
        $lblState.ForeColor = [Drawing.Color]::Gray
        $lblIo.Text = 'الإرسال: -    |    الاستقبال: -'
        $lblQuality.Text = 'جودة الاتصال: لا توجد جلسة نشطة'
        $lblLat.Text = 'التأخير الإضافي: -'
        $lblCpu.Text = 'حمل AudioDG: -'
        $lblFmt.Text = 'الصيغة: -'
        return
    }
    switch ($h['state']) {
        'PROCESSING' { $lblState.Text = 'الحالة: المعالجة تعمل'; $lblState.ForeColor = [Drawing.Color]::DarkGreen }
        'FALLBACK'   { $lblState.Text = 'الحالة: تمرير المايك الأصلي (لا يصل صوت معالج)'; $lblState.ForeColor = [Drawing.Color]::DarkOrange }
        'BYPASS'     { $lblState.Text = 'الحالة: متوقف بأمرك، تمرير المايك الأصلي'; $lblState.ForeColor = [Drawing.Color]::Gray }
        'DISABLED'   { $lblState.Text = 'الحالة: معطّل من الإعدادات'; $lblState.ForeColor = [Drawing.Color]::Gray }
        default      { $lblState.Text = 'الحالة: ' + $h['state']; $lblState.ForeColor = [Drawing.Color]::Black }
    }

    $tx = [long](Num $h 'tx')
    $rx = [long](Num $h 'rx')
    $now = [DateTime]::UtcNow
    if ($null -eq $script:lastTx -or $tx -ne $script:lastTx) { $script:lastTxAt = $now }
    $script:lastTx = $tx
    $sendOk = (($now - $script:lastTxAt).TotalSeconds -lt 3.0) -and ($tx -gt 0)
    $receiveOk = ($h['state'] -eq 'PROCESSING') -and ($rx -gt 0)
    $sendText = if ($sendOk) { 'يعمل' } else { 'لا توجد بيانات' }
    $receiveText = if ($receiveOk) { 'يعمل' } else { 'لا تصل بيانات' }
    $lblIo.Text = "الإرسال: $sendText    |    الاستقبال: $receiveText"

    $underruns = [long](Num $h 'underruns')
    if ($null -eq $script:lastUnderruns -or $underruns -lt $script:lastUnderruns) {
        # APO restart resets its counters; establish a new baseline without a false warning.
        $script:lastUnderruns = $underruns
    } else {
        if ($underruns -gt $script:lastUnderruns) { $script:lastUnderrunAt = $now }
        $script:lastUnderruns = $underruns
    }
    $recentUnderrun = ($null -ne $script:lastUnderrunAt) -and (($now - $script:lastUnderrunAt).TotalSeconds -lt 5.0)
    if ($h['state'] -eq 'PROCESSING' -and -not $recentUnderrun) {
        $lblQuality.Text = 'جودة الاتصال: جيدة'
        $lblQuality.ForeColor = [Drawing.Color]::DarkGreen
    } elseif ($h['state'] -eq 'PROCESSING') {
        $lblQuality.Text = 'جودة الاتصال: متقطعة'
        $lblQuality.ForeColor = [Drawing.Color]::DarkOrange
    } else {
        $lblQuality.Text = 'جودة الاتصال: غير مستقرة'
        $lblQuality.ForeColor = [Drawing.Color]::DarkOrange
    }

    $lat = (Num $h 'bufMs') + (Num $h 'blockMs')
    $lblLat.Text = ('التأخير الإضافي التقريبي: {0:N0} ms' -f $lat)
    Update-AudioDgCpu
    if ($null -ne $script:cpuPercent) { $lblCpu.Text = ('حمل AudioDG التقريبي: {0:N1}%' -f $script:cpuPercent) }
    else { $lblCpu.Text = 'حمل AudioDG: غير متاح' }
    $lblFmt.Text = ('الصيغة: {0} Hz، {1} قناة' -f (Num $h 'rate'), (Num $h 'ch'))
    if ($h['bind'] -eq '0') { $lblWarn.Text = 'تنبيه: تعذر فتح منفذ الاستقبال؛ راجع سجل الصوت.' }
}

$btn.Add_Click({
    try { if (Get-Enabled) { Set-Enabled 0 } else { Set-Enabled 1 }; Refresh-Ui }
    catch { [Windows.Forms.MessageBox]::Show("تعذر تغيير الحالة: $($_.Exception.Message)", 'MicBridge') | Out-Null }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Refresh-Ui })
$timer.Start()
Refresh-Ui
[void]$form.ShowDialog()
