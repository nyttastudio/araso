# Real typing into Chrome and Edge through the installed input method (issue #36: Chrome went down
# while a tag was searched for in Korean on Threads). Pages in windows/scripts/browser: a plain
# contenteditable, one drawn again on every input with a tag list under the #tag, and Lexical (what
# Threads' composer is built on) with its hashtag nodes. Each case starts the browser afresh, sends
# key events and says whether the browser and the page are still running, and what the field says.
#   pwsh windows/scripts/browser-test.ps1 build/Araso-Setup.exe [out folder]
# Takes over the keyboard and the focus: run it on a machine nobody is using (the CI's).
param([string]$Installer = "build/Araso-Setup.exe", [string]$Out = "build/browser")
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$log = Join-Path $Out "araso.log"
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "Machine")
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "User")
$env:ARASO_LOG = $log

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Keys {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool InstallLayoutOrTip(string profile, uint flags);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool SetDefaultLayoutOrTip(string profile, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint x, uint y, uint data, IntPtr extra);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    const uint SCANCODE = 0x8, KEYUP = 0x2, EXTENDED = 0x1;
    public static void Key(ushort scan, bool up, bool extended) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wScan = scan;
        input[0].ki.dwFlags = SCANCODE | (up ? KEYUP : 0) | (extended ? EXTENDED : 0);
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Virtual(ushort vk, bool up) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wVk = vk;
        input[0].ki.dwFlags = up ? KEYUP : 0;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x2, 0, 0, 0, IntPtr.Zero);
        mouse_event(0x4, 0, 0, 0, IntPtr.Zero);
    }
    public static bool Front(IntPtr window) {
        IntPtr front = GetForegroundWindow();
        uint thread = front == IntPtr.Zero ? 0 : GetWindowThreadProcessId(front, IntPtr.Zero);
        uint own = GetCurrentThreadId();
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, true);
        bool done = SetForegroundWindow(window);
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, false);
        return done;
    }
}
"@

$language = "0412"
$tip = "0412:{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}{6D6C7D5F-3B7F-4F0E-9A2C-417261736F02}"
$setup = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -PassThru
$setup.WaitForExit()
if ($setup.ExitCode -ne 0) { throw "install failed ($($setup.ExitCode))" }
$folder = "$env:ProgramFiles\Araso"
[Keys]::InstallLayoutOrTip($tip, 0) | Out-Null
[Keys]::SetDefaultLayoutOrTip($tip, 0) | Out-Null
Set-WinDefaultInputMethodOverride -InputTip $tip
Get-Process ArasoHost -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--server"
Start-Sleep -Seconds 8

# Crashes leave a dump here too, when the browser's own handler doesn't take them first.
$dumps = Join-Path $Out "dumps"
New-Item -ItemType Directory -Force $dumps | Out-Null
foreach ($exe in "chrome.exe", "msedge.exe") {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$exe"
    New-Item -Force $key | Out-Null
    Set-ItemProperty $key DumpFolder $dumps
    Set-ItemProperty $key DumpType 2 -Type DWord
}
$started = Get-Date

$browsers = [ordered]@{
    chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
}
foreach ($name in @($browsers.Keys)) {
    if (Test-Path $browsers[$name]) { Write-Host "$name $((Get-Item $browsers[$name]).VersionInfo.ProductVersion)" }
    else { Write-Host "$name not installed"; $browsers.Remove($name) }
}

$scans = @{}
$rows = @(@("1234567890", 0x02), @("qwertyuiop", 0x10), @("asdfghjkl", 0x1E), @("zxcvbnm", 0x2C))
foreach ($row in $rows) { for ($i = 0; $i -lt $row[0].Length; $i++) { $scans[[string]$row[0][$i]] = $row[1] + $i } }

# Keys as text: letters, digits and Space as typed, `#` with Shift, and {name} for the rest:
# {enter} {back} {down} {ralt} (a right Alt tap: Araso's switch key) {wait} (a second).
function Send-Keys([string]$keys) {
    foreach ($token in [regex]::Matches($keys, '\{[a-z]+\}|.')) {
        $t = $token.Value
        $scan = 0; $extended = $false; $shift = $false
        switch ($t) {
            "{enter}" { $scan = 0x1C }
            "{back}" { $scan = 0x0E }
            "{down}" { $scan = 0x50; $extended = $true }
            "{ralt}" { $scan = 0x38; $extended = $true }
            "{wait}" { Start-Sleep -Seconds 1; continue }
            " " { $scan = 0x39 }
            "#" { $scan = 0x04; $shift = $true }
            default { $scan = $scans[$t] }
        }
        if (-not $scan) { continue }
        if ($shift) { [Keys]::Key(0x2A, $false, $false); Start-Sleep -Milliseconds 30 }
        [Keys]::Key($scan, $false, $extended); Start-Sleep -Milliseconds 50
        [Keys]::Key($scan, $true, $extended); Start-Sleep -Milliseconds 50
        if ($shift) { [Keys]::Key(0x2A, $true, $false); Start-Sleep -Milliseconds 30 }
        if ($t -eq "{ralt}") { Start-Sleep -Milliseconds 250 }
    }
}

# The page's report in the window title: T:<beat>:[<text>].
function Read-Page($process) {
    $process.Refresh()
    $title = $process.MainWindowTitle
    $m = [regex]::Match($title, '^T:(\d+):\[(.*)\]')
    if (-not $m.Success) { return @{ beat = -1; text = $null; title = $title } }
    $text = try { $m.Groups[2].Value | ConvertFrom-Json } catch { $m.Groups[2].Value }
    return @{ beat = [int]$m.Groups[1].Value; text = $text; title = $title }
}

function Shot([string]$name, [IntPtr]$window) {
    Add-Type -AssemblyName System.Drawing
    $rect = New-Object Keys+RECT
    [Keys]::GetWindowRect($window, [ref]$rect) | Out-Null
    if ($rect.Right -le $rect.Left) { return }
    $bitmap = New-Object System.Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}

$pages = Join-Path $PSScriptRoot "browser"
$results = @()
function Case([string]$browser, [string]$page, [string]$label, [string]$keys, [string]$expected, [string]$ime = "araso") {
    $name = if ($ime -eq "araso") { "$browser-$page-$label" } else { "$ime-$browser-$page-$label" }
    $userData = Join-Path $env:TEMP "araso-$name"
    Remove-Item -Recurse -Force $userData -ErrorAction SilentlyContinue
    $url = "file:///" + ((Join-Path $pages "$page.html") -replace '\\', '/')
    $arguments = @("--user-data-dir=$userData", "--no-first-run", "--no-default-browser-check", "--disable-sync",
        "--disable-search-engine-choice-screen", "--disable-features=Translate,msEdgeFirstRunExperience",
        "--enable-logging", "--v=0", "--window-position=0,0", "--window-size=900,600", "--new-window", $url)
    $process = Start-Process -FilePath $browsers[$browser] -ArgumentList $arguments -PassThru
    for ($i = 0; $i -lt 80; $i++) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and (Read-Page $process).beat -ge 0) { break }
        Start-Sleep -Milliseconds 250
    }
    $window = $process.MainWindowHandle
    if ($page -eq "lexical") { Start-Sleep -Seconds 3 } else { Start-Sleep -Seconds 1 } # the modules load
    for ($i = 0; $i -lt 10 -and [Keys]::GetForegroundWindow() -ne $window; $i++) { [Keys]::Front($window) | Out-Null; Start-Sleep -Milliseconds 300 }
    $rect = New-Object Keys+RECT
    [Keys]::GetWindowRect($window, [ref]$rect) | Out-Null
    [Keys]::Click($rect.Left + 300, $rect.Top + 260) # into the field, under the browser's toolbar
    Start-Sleep -Milliseconds 500
    $thread = [Keys]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
    for ($i = 0; $i -lt 10 -and -not ("{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()).EndsWith($language); $i++) {
        $hkl = [IntPtr][Convert]::ToInt64($language + $language, 16)
        [Keys]::PostMessage($window, 0x50 <# WM_INPUTLANGCHANGEREQUEST #>, [IntPtr]::Zero, $hkl) | Out-Null
        Start-Sleep -Milliseconds 800
    }
    $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    $loaded = $null
    try { $loaded = $process.Modules | Where-Object { $_.ModuleName -like "ArasoTip*.dll" } | Select-Object -First 1 } catch {}
    $microsoft = $null
    try { $microsoft = $process.Modules | Where-Object { $_.ModuleName -like "imkr*.dll" } | Select-Object -First 1 } catch {}
    Write-Host "${name}: front $([Keys]::GetForegroundWindow() -eq $window), layout $layout, ArasoTip $(if ($loaded) { 'loaded' } else { 'not loaded' }), Microsoft's $(if ($microsoft) { $microsoft.ModuleName } else { 'not loaded' })"
    # Microsoft's Korean input method starts in English: 한/영 once.
    if ($ime -eq "microsoft") { [Keys]::Virtual(0x15, $false); Start-Sleep -Milliseconds 60; [Keys]::Virtual(0x15, $true); Start-Sleep -Milliseconds 300 }

    Send-Keys $keys
    Start-Sleep -Milliseconds 1500
    Shot $name $window
    $first = Read-Page $process
    Start-Sleep -Milliseconds 700
    $second = Read-Page $process
    $alive = -not $process.HasExited
    $running = $alive -and $second.beat -gt $first.beat
    $verdict = if (-not $alive) { "BROWSER GONE (exit $($process.ExitCode))" } elseif (-not $running) { "PAGE NOT RUNNING ('$($second.title)')" } else { "ok" }
    Write-Host "${name}: $verdict, text '$($second.text)'"
    Get-Process chrome, msedge -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $debugLog = Join-Path $userData "chrome_debug.log"
    if (Test-Path $debugLog) { Copy-Item $debugLog (Join-Path $Out "$name.chrome_debug.log") }
    $reports = Get-ChildItem -Recurse -Path (Join-Path $userData "Crashpad") -Filter *.dmp -ErrorAction SilentlyContinue
    foreach ($dump in $reports) { Copy-Item $dump.FullName (Join-Path $dumps "$name-$($dump.Name)"); Write-Host "${name}: crash report $($dump.Name)" }
    $as = if (-not $expected) { "" } elseif ($second.text -eq $expected) { "as expected" } else { "EXPECTED '$expected'" }
    if ($as) { Write-Host "${name}: $as" }
    $script:results += [pscustomobject]@{ case = $name; ok = $running -and -not $reports; verdict = $verdict; text = $second.text; as = $as }
}

# Keys, and the text they should leave where the page leaves the field alone (Return on a word
# being typed only puts it in, `returnConfirmsOnly`).
$sequences = [ordered]@{
    # #한글, the list comes up, Space.
    "space" = @("#gksrmf{wait}{wait} ", "#한글 ")
    # #한글, the list comes up, Return.
    "enter" = @("#gksrmf{wait}{wait}{enter}", "#한글")
    # 안녕 #태그 with letters taken back and typed again, then ↓ Return.
    "edit" = @("dkssud #xorm{wait}{back}{back}rmf{wait}{down}{enter}", $null)
    # #hello switched to Korean by the switch key while the list is up, then Space.
    "switch" = @("#hello{wait}{ralt}{wait} ", "#ㅗ디ㅣㅐ ")
    # One tag after another, without waiting.
    "fast" = @("#gksrmf #dlftkd #ajrwkd ", "#한글 #일상 #먹장 ")
}
foreach ($browser in $browsers.Keys) {
    foreach ($page in "plain", "rerender", "lexical") {
        foreach ($label in $sequences.Keys) { Case $browser $page $label $sequences[$label][0] $sequences[$label][1] }
    }
}

# The same pages with Microsoft's Korean input method, for what a page does to any input method
# (the field drawn again while a word is composed): not required to pass.
$microsoftTip = "0412:{A028AE76-01B1-46C2-99C4-ACD9858AE02F}{B5FE1F02-D5F2-4445-9C03-C568F23C99A1}"
$required = $results.Count
if ($browsers.Contains("chrome") -and [Keys]::InstallLayoutOrTip($microsoftTip, 0)) {
    [Keys]::SetDefaultLayoutOrTip($microsoftTip, 0) | Out-Null
    Set-WinDefaultInputMethodOverride -InputTip $microsoftTip
    foreach ($page in "plain", "rerender", "lexical") {
        foreach ($label in "space", "enter", "fast") { Case "chrome" $page $label $sequences[$label][0] $null "microsoft" }
    }
    [Keys]::SetDefaultLayoutOrTip($tip, 0) | Out-Null
    Set-WinDefaultInputMethodOverride -InputTip $tip
} else {
    Write-Host "Microsoft's Korean input method: not here"
}

$results | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $started } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -in "Application Error", "Windows Error Reporting", "Application Hang" } |
    ForEach-Object { Write-Host "--- event $($_.Id) $($_.ProviderName)"; Write-Host $_.Message }

# Any dump: where it went down, with Microsoft's and Chromium's symbols (ArasoTip has none: an offset).
$cdb = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
foreach ($dump in Get-ChildItem $dumps -Filter *.dmp) {
    Write-Host "--- dump $($dump.Name)"
    if (-not $cdb) { Write-Host "no cdb here"; continue }
    $symbols = "srv*$env:TEMP\symbols*https://msdl.microsoft.com/download/symbols;srv*$env:TEMP\symbols*https://chromium-browser-symsrv.commondatastorage.googleapis.com"
    & $cdb.FullName -z $dump.FullName -y $symbols -c ".ecxr; kn 40; lm m Araso*; q" 2>&1 | Select-Object -Last 90 | Out-Host
}

if (Test-Path $log) { Write-Host "--- araso.log"; Get-Content $log | Select-String -NotMatch "scan code" | Select-Object -Last 300 | Out-Host }
if ($results | Select-Object -First $required | Where-Object { -not $_.ok }) { throw "browser test: a browser or its page went down" }
Write-Host "browser test: ok"
