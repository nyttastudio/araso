# Real typing through the installed input method (scripts/typing-test on macOS): installs
# Araso-Setup.exe silently, makes Araso the input method for new windows, opens Notepad, sends key
# events (scan codes, as a keyboard does) and reads Notepad's text back.
#   pwsh windows/scripts/typing-test.ps1 build/Araso-Setup.exe
# Takes over the keyboard and the focus: run it on a machine nobody is using (the CI's).
param([string]$Installer = "build/Araso-Setup.exe")
$ErrorActionPreference = "Stop"
# The text service and the host log here too (machine-wide, so Notepad and the host both see it).
$log = Join-Path $env:TEMP "araso.log"
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "Machine")
[Environment]::SetEnvironmentVariable("ARASO_LOG", $log, "User")
$env:ARASO_LOG = $log

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Keys {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool WaitNamedPipe(string name, uint timeout);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool InstallLayoutOrTip(string profile, uint flags);
    [DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool SetDefaultLayoutOrTip(string profile, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    const uint SCANCODE = 0x8, KEYUP = 0x2, EXTENDED = 0x1;
    public static void Key(ushort scan, bool up, bool extended) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wScan = scan;
        input[0].ki.dwFlags = SCANCODE | (up ? KEYUP : 0) | (extended ? EXTENDED : 0);
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    /// A key by its virtual-key code, as a Korean keyboard's 한/영 and 한자 keys arrive.
    public static void Virtual(ushort vk, bool up) {
        var input = new INPUT[1];
        input[0].type = 1;
        input[0].ki.wVk = vk;
        input[0].ki.dwFlags = up ? KEYUP : 0;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    /// The first multi-line Edit control in a window (Try Typing's field in the settings window).
    public static IntPtr FindMultilineEdit(IntPtr parent) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (window, data) => {
            var name = new StringBuilder(32);
            GetClassName(window, name, 32);
            if (name.ToString() == "Edit" && (GetWindowLong(window, -16) & 0x4) != 0) { found = window; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr window);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    /// Gives a control in another app the keyboard focus, as a click in it would.
    public static void Focus(IntPtr control) {
        uint thread = GetWindowThreadProcessId(control, IntPtr.Zero);
        AttachThreadInput(GetCurrentThreadId(), thread, true);
        SetFocus(control);
        AttachThreadInput(GetCurrentThreadId(), thread, false);
    }
    /// Brings a window to the front even when Windows' foreground lock would refuse: as the
    /// window in front's own thread asks it.
    public static bool Front(IntPtr window) {
        IntPtr front = GetForegroundWindow();
        uint thread = front == IntPtr.Zero ? 0 : GetWindowThreadProcessId(front, IntPtr.Zero);
        uint own = GetCurrentThreadId();
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, true);
        bool done = SetForegroundWindow(window);
        if (thread != 0 && thread != own) AttachThreadInput(own, thread, false);
        return done;
    }
    public static string Text(IntPtr edit) {
        int length = (int)SendMessage(edit, 0x0E /* WM_GETTEXTLENGTH */, IntPtr.Zero, IntPtr.Zero);
        var text = new StringBuilder(length + 1);
        SendMessage(edit, 0x0D /* WM_GETTEXT */, (IntPtr)(length + 1), text);
        return text.ToString();
    }
}
"@

$script:language = "0412"
$tip = "0412:{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}{6D6C7D5F-3B7F-4F0E-9A2C-417261736F02}"
# Only the installer is waited for: -Wait would also wait for the host it starts, which stays.
# (Not $installer: PowerShell's names ignore case, and the [string] parameter would take the process.)
$setup = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -PassThru
$setup.WaitForExit()
if ($setup.ExitCode -ne 0) { throw "install failed ($($setup.ExitCode))" }
Write-Host "installed"
$folder = "$env:ProgramFiles\Araso"
if (-not (Test-Path "$folder\ArasoTip.dll")) { throw "not installed in $folder" }
[Keys]::InstallLayoutOrTip($tip, 0) | Out-Null
if (-not [Keys]::SetDefaultLayoutOrTip($tip, 0)) { Write-Host "SetDefaultLayoutOrTip failed" }
# A new window starts in the default input method only when it overrides the language list's first.
Set-WinDefaultInputMethodOverride -InputTip $tip
# The host warms its models up before it opens its pipe (\\.\pipe\Araso.<session>.<user>, as
# PipeName() in Common.cpp names it): wait for the pipe, not a fixed time. A host started while
# another is still exiting (the installer's, just killed) finds the single-instance mutex taken and
# quits at once, leaving none: wait for the old one to go, and start it again if it quit.
# Only this session's host counts: the mutex and the pipe are per session, as a host is.
function Get-SessionHost { Get-Process ArasoHost -ErrorAction SilentlyContinue | Where-Object SessionId -eq $script:session }
function Start-Host {
    $script:session = (Get-Process -Id $PID).SessionId
    Get-SessionHost | Stop-Process -Force -ErrorAction SilentlyContinue
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-SessionHost) -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
    $pipe = "\\.\pipe\Araso.$script:session.$env:USERNAME"
    $starts = 0
    $clock.Restart()
    # WaitNamedPipe doesn't connect. It fails with ERROR_FILE_NOT_FOUND (2) while there's no pipe and
    # ERROR_SEM_TIMEOUT (121) while every instance is busy; anything else is no host to type through.
    while (-not [Keys]::WaitNamedPipe($pipe, 1)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($code -ne 2 -and $code -ne 121) { throw "host: waiting for its pipe failed ($code)" }
        if ($clock.Elapsed.TotalSeconds -ge 60) { throw "host: no pipe after 60 s ($starts starts)" }
        if (-not (Get-SessionHost)) {
            Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--server"
            $starts++
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "host: pipe open after $([Math]::Round($clock.Elapsed.TotalSeconds, 1)) s ($starts starts)"
}
# A host started by the installer doesn't have ARASO_LOG: start it afresh.
Start-Host

# The text service created as TSF creates it, in an x64 process (ArasoHost.exe) and in one of this
# machine's own (PowerShell): on ARM64 Windows the forwarder must hand each its own build.
$created = @()
Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--load-text-service" -Wait
$x64 = (Get-Content $log -ErrorAction SilentlyContinue | Select-String "text service:" | Select-Object -Last 1) -as [string]
Write-Host "x64 process: $x64"
$created += $x64 -match "created"
try {
    $service = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]"6D6C7D5F-3B7F-4F0E-9A2C-417261736F01"))
    $own = (Get-Process -Id $PID).Modules | Where-Object { $_.ModuleName -like "ArasoTip*.dll" } | ForEach-Object FileName
    Write-Host "text service in this $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) process: created, $($own -join ', ')"
    [Runtime.InteropServices.Marshal]::ReleaseComObject($service) | Out-Null
    $created += $true
} catch {
    Write-Host "text service in this process: FAILED ($($_.Exception.Message))"
    $created += $false
}
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $x64ok = $x64 -match "ArasoTipX64.dll"
    $ownok = ($own -join ",") -match "ArasoTipArm64.dll"
    $created += $x64ok, $ownok
}

# A Store app (AppContainer) reaching the host: the pipe's security lets such apps in.
$container = Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--appcontainer-test" -Wait -PassThru
Write-Host "AppContainer: $(if ($container.ExitCode -eq 0) { 'attached to the host' } else { "FAILED ($($container.ExitCode))" })"
$created += $container.ExitCode -eq 0

# Letters' scan codes on a US keyboard.
$scans = @{}
$rows = @(@("qwertyuiop", 0x10), @("asdfghjkl", 0x1E), @("zxcvbnm", 0x2C))
foreach ($row in $rows) { for ($i = 0; $i -lt $row[0].Length; $i++) { $scans[[string]$row[0][$i]] = $row[1] + $i } }
$scans[" "] = 0x39

function Send-Keys([string]$keys) {
    foreach ($ch in $keys.ToCharArray()) {
        $scan = $scans[[string]$ch]
        [Keys]::Key($scan, $false, $false); Start-Sleep -Milliseconds 40
        [Keys]::Key($scan, $true, $false); Start-Sleep -Milliseconds 40
    }
}

# A field to type into: Notepad (its Edit control, through IMM32's compatibility layer) or a WPF
# TextBox (TSF's own). Answers what reads its text back.
function Open-Field([string]$kind) {
    if ($kind -eq "host") {
        # Try Typing in Araso's settings window: an x64 app (under emulation on ARM64 Windows).
        $process = Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--settings", "typing" -PassThru
        for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        Start-Sleep -Seconds 2
        $edit = [Keys]::FindMultilineEdit($process.MainWindowHandle)
        if ($edit -eq [IntPtr]::Zero) { Write-Host "host: no Try Typing field" }
        [Keys]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 300
        [Keys]::Focus($edit)
        Start-Sleep -Seconds 1
        return @{ process = $process; window = $process.MainWindowHandle; read = { [Keys]::Text($edit) }.GetNewClosure() }
    }
    if ($kind -ne "notepad") {
        $out = Join-Path $env:TEMP "araso-field.txt"
        Remove-Item $out -ErrorAction SilentlyContinue
        $process = Start-Process powershell -ArgumentList "-STA", "-NoProfile", "-File", "$PSScriptRoot\field.ps1", $kind, $out -PassThru
        for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        Start-Sleep -Seconds 2 # the window draws, then focuses the box
        return @{ process = $process; window = $process.MainWindowHandle; read = { if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { "" } }.GetNewClosure() }
    }
    $process = Start-Process notepad -PassThru
    Start-Sleep -Seconds 3
    $window = $process.MainWindowHandle
    $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "Edit", $null)
    $class = "Edit"
    if ($edit -eq [IntPtr]::Zero) { $edit = [Keys]::FindWindowEx($window, [IntPtr]::Zero, "RichEditD2DPT", $null); $class = "RichEditD2DPT" }
    Write-Host "notepad's field: $class"
    return @{ process = $process; window = $window; read = { [Keys]::Text($edit) }.GetNewClosure() }
}

# Brings a field's window to the front in Korean (Araso's language) and says how it stands.
function Ready($field, [string]$kind) {
    $window = $field.window
    for ($i = 0; $i -lt 10 -and [Keys]::GetForegroundWindow() -ne $window; $i++) {
        [Keys]::Front($window) | Out-Null
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 500
    $thread = [Keys]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
    $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    $front = [Keys]::GetForegroundWindow() -eq $window
    for ($i = 0; $i -lt 10 -and -not $layout.EndsWith($script:language); $i++) {
        [Keys]::Front($window) | Out-Null
        # As the taskbar's indicator does: ask the window to switch to the language Araso is listed under.
        $hkl = [IntPtr][Convert]::ToInt64($script:language + $script:language, 16)
        [Keys]::PostMessage($window, 0x50 <# WM_INPUTLANGCHANGEREQUEST #>, [IntPtr]::Zero, $hkl) | Out-Null
        Start-Sleep -Milliseconds 800
        $layout = "{0:X8}" -f [Keys]::GetKeyboardLayout($thread).ToInt64()
    }
    $loaded = (Get-Process -Id $field.process.Id).Modules | Where-Object { $_.ModuleName -eq "ArasoTip.dll" } | Select-Object -First 1
    Write-Host "${kind}: in front $front, layout $layout, ArasoTip.dll $(if ($loaded) { $loaded.FileName } else { 'not loaded' })"
}

function Case([string]$keys, [string]$expected, [scriptblock]$after, [string]$kind = "notepad") {
    $field = Open-Field $kind
    $notepad = $field.process
    $window = $field.window
    Ready $field $kind
    Send-Keys $keys
    if ($after) { & $after }
    Start-Sleep -Milliseconds 800
    if ([Keys]::GetForegroundWindow() -ne $window) { Write-Host "${kind}: no longer in front after the keys" }
    $text = & $field.read
    Stop-Process -Id $notepad.Id -Force
    Write-Host "$kind typed '$keys' → '$text'"
    return $text -eq $expected
}

# Switching the word just committed comes after a person's pause (300 ms here): in a classic app the
# word and its space reach the Edit control through posted messages, a moment after they go in, and
# a switch before that finds the text before the caret not yet the word.
function Press-Virtual([int]$vk) {
    [Keys]::Virtual($vk, $false); Start-Sleep -Milliseconds 60
    [Keys]::Virtual($vk, $true); Start-Sleep -Milliseconds 200
}

function Tap([int]$scan) {
    [Keys]::Key($scan, $false, $true); Start-Sleep -Milliseconds 60
    [Keys]::Key($scan, $true, $true); Start-Sleep -Milliseconds 200
}

# The classic field: Notepad's Edit control (Windows 10, Server), or the same control in a WinForms
# window where Notepad is Windows 11's own app (CI's ARM64 runner).
$classic = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "winforms" } else { "notepad" }

# The first WPF window of a fresh machine loads .NET's WPF for a while and may come up behind:
# one opened and closed first.
$warm = Open-Field "wpf"
Start-Sleep -Seconds 2
Stop-Process -Id $warm.process.Id -Force

$results = @(
    # A WPF TextBox: a TSF text store, where the word is composed in the text.
    (Case "dkssud hello " "안녕 hello " $null "wpf"),
    # Right Alt tapped alone switches the word just committed (0x38 extended: right Alt).
    (Case "hello " "ㅗ디ㅣㅐ " { Tap 0x38 } "wpf"),
    # Try Typing in the settings window: an x64 app, also on ARM64 Windows.
    (Case "dkssud hello " "안녕 hello " $null "host"),
    # A classic app's Edit control, where the word is drawn at the caret and goes in whole.
    (Case "dkssud hello " "안녕 hello " $null $classic),
    (Case "gksrmf " "한글 " $null $classic),
    # Switched while typing, before the Space.
    (Case "hello" "ㅗ디ㅣㅐ " { Tap 0x38; Send-Keys " " } $classic),
    # Right Ctrl tapped alone pauses (0x1D extended): keys then go in as typed.
    (Case "" "dkssud " { Tap 0x1D; Send-Keys "dkssud " } $classic),
    # A Korean keyboard's 한/영 (VK_HANGUL) switches as it goes down; 한자 (VK_HANJA) pauses.
    (Case "hello " "ㅗ디ㅣㅐ " { Start-Sleep -Milliseconds 300; Press-Virtual 0x15 } $classic),
    (Case "" "dkssud " { Press-Virtual 0x19; Send-Keys "dkssud " } $classic)
)
# Reported, not required: switching the word just committed in a classic app, whose text Araso
# edits only through Windows' compatibility layer.
Case "hello " "ㅗ디ㅣㅐ " { Start-Sleep -Milliseconds 300; Tap 0x38 } $classic | Out-Null
# Reported, not required: a Korean 103-key keyboard's own scan codes for 한/영 (0xF2) and 한자
# (0xF1), which Windows turns into VK_HANGUL and VK_HANJA only with that keyboard type set.
Case "hello " "ㅗ디ㅣㅐ " { [Keys]::Key(0xF2, $false, $false); Start-Sleep -Milliseconds 200 } $classic | Out-Null
Case "" "dkssud " { [Keys]::Key(0xF1, $false, $false); Start-Sleep -Milliseconds 200; Send-Keys "dkssud " } $classic | Out-Null

Write-Host "machine: $env:PROCESSOR_ARCHITECTURE"
# Screenshots of what Araso draws, for looking at the design (ARASO_SCREENSHOTS: the folder; CI
# uploads it). Not on a runner without a desktop.
if ($env:ARASO_SCREENSHOTS -and $env:PROCESSOR_ARCHITECTURE -ne "ARM64") {
    New-Item -ItemType Directory -Force $env:ARASO_SCREENSHOTS | Out-Null
    Add-Type -AssemblyName System.Drawing
    # The window and what is drawn around it (`below`: room for the strip or the card; `left`: room
    # for them before the window, as they start under the word's first letter).
    function Shot([string]$name, [IntPtr]$window, [int]$below = 0, [int]$left = 0) {
        $rect = New-Object Keys+RECT
        [Keys]::GetWindowRect($window, [ref]$rect) | Out-Null
        $width = $rect.Right - $rect.Left + $left
        $height = $rect.Bottom - $rect.Top + $below
        $bitmap = New-Object System.Drawing.Bitmap $width, $height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($rect.Left - $left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $env:ARASO_SCREENSHOTS "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        Write-Host "screenshot: $name"
    }
    function Kept([string]$kind) { $f = Open-Field $kind; Ready $f $kind; return $f }

    # A classic app: the word drawn at the caret.
    $f = Kept $classic
    Send-Keys "gksrmf dkssud"; Start-Sleep -Milliseconds 700
    Shot "1-classic-app-word-at-caret" $f.window 40
    Stop-Process -Id $f.process.Id -Force
    # A TSF app: the word composed in the text, underlined; then the pause indicator.
    $f = Kept "wpf"
    Send-Keys "gksrmf dkssud"; Start-Sleep -Milliseconds 700
    Shot "2-tsf-app-composing" $f.window 40
    Send-Keys " "; Tap 0x1D; Start-Sleep -Milliseconds 150
    Shot "3-paused" $f.window 60
    Tap 0x1D; Start-Sleep -Milliseconds 150
    Shot "4-resumed" $f.window 60
    Stop-Process -Id $f.process.Id -Force

    # Japanese on, for kana and the kanji candidates (the host reads settings.json as it starts).
    $settings = Join-Path $env:APPDATA "Araso\settings.json"
    New-Item -ItemType Directory -Force (Split-Path $settings) | Out-Null
    [IO.File]::WriteAllText($settings, '{ "japanese": true, "liveConversion": false }')
    Start-Host
    $f = Kept "wpf"
    Send-Keys "kyouhaiitenki"; Start-Sleep -Milliseconds 700
    Shot "5-japanese-kana" $f.window 40
    Send-Keys " "; Start-Sleep -Milliseconds 900
    Shot "6-kanji-conversion" $f.window 320 40
    Send-Keys " "; Start-Sleep -Milliseconds 700
    Shot "7-kanji-candidates" $f.window 320 40
    Stop-Process -Id $f.process.Id -Force

    # The switch key's strip, and what a correction did: the first one noted (a pencil), the
    # second learned (a check), the remembered reading marked in the strip after that.
    $f = Kept "wpf"
    Send-Keys "hello "; Tap 0x38; Start-Sleep -Milliseconds 300
    Shot "8-readings-strip" $f.window 80 40
    Tap 0x38; Start-Sleep -Milliseconds 300
    Shot "9-readings-strip-next" $f.window 80 40
    Tap 0x38; Tap 0x38; Start-Sleep -Milliseconds 200 # round to the first switch again
    Send-Keys "x"; Start-Sleep -Milliseconds 550
    Shot "10-correction-noted" $f.window 80 40
    Start-Sleep -Milliseconds 1800
    Send-Keys " hello "; Tap 0x38; Start-Sleep -Milliseconds 300
    Shot "11-readings-corrected-once" $f.window 80 40
    Send-Keys "x"; Start-Sleep -Milliseconds 650
    Shot "12-correction-learned" $f.window 80 40
    Start-Sleep -Milliseconds 1800
    Send-Keys " hello "; Tap 0x38; Start-Sleep -Milliseconds 300
    Shot "13-readings-remembered" $f.window 80 40
    Stop-Process -Id $f.process.Id -Force

    # The same in dark mode: the strip and the card on navy paper.
    $personalize = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    $light = (Get-ItemProperty $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme
    New-Item -Force $personalize -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty $personalize AppsUseLightTheme 0
    $f = Kept "wpf"
    Send-Keys "kyouhaiitenki "; Start-Sleep -Milliseconds 900
    Shot "14-dark-kanji-candidates" $f.window 320 40
    Stop-Process -Id $f.process.Id -Force
    $f = Kept "wpf"
    Send-Keys "dkssud "; Tap 0x38; Start-Sleep -Milliseconds 300
    Shot "15-dark-readings-strip" $f.window 80 40
    Stop-Process -Id $f.process.Id -Force
    if ($null -eq $light) { Remove-ItemProperty $personalize AppsUseLightTheme -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $personalize AppsUseLightTheme $light }

    # The settings window, every tab; Try Typing with a few words in it.
    foreach ($tab in "general", "keys", "apps", "learning", "about") {
        $process = Start-Process -FilePath "$folder\ArasoHost.exe" -ArgumentList "--settings", $tab -PassThru
        for ($i = 0; $i -lt 60 -and $process.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        [Keys]::Front($process.MainWindowHandle) | Out-Null
        Start-Sleep -Seconds 2
        Shot "settings-$tab" $process.MainWindowHandle
        Stop-Process -Id $process.Id -Force
    }
    $f = Kept "host"
    Send-Keys "dkssud hello kyouha "; Start-Sleep -Milliseconds 900
    Shot "settings-typing" $f.window
    Stop-Process -Id $f.process.Id -Force
    Remove-Item $settings -ErrorAction SilentlyContinue
}

if (Test-Path $log) { Write-Host "--- araso.log"; Get-Content $log | Select-String -NotMatch "scan code" | Select-Object -Last 400 | Out-Host }
reg query "HKCU\Software\Microsoft\CTF\TIP" /s 2>$null | Select-String -Pattern "6D6C7D5F" | Out-Host
reg query "HKLM\Software\Microsoft\CTF\TIP\{6D6C7D5F-3B7F-4F0E-9A2C-417261736F01}" /s 2>$null | Select-Object -First 20 | Out-Host
Get-WinUserLanguageList | Format-List | Out-Host
if ($created -contains $false) { throw "the text service couldn't be created" }
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -and -not ($results -contains $true)) {
    # Not one key reached a window: this runner has no interactive desktop to type into.
    Write-Host "typing test: no key reached any window here; the text service was created in ARM64 and x64 processes"
    exit 0
}
if ($results -contains $false) {
    Get-ChildItem "$env:APPDATA\Araso" -ErrorAction SilentlyContinue | Select-Object Name | Out-Host
    throw "typing test failed"
}
Write-Host "typing test: ok"
