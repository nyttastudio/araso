# Unit tests for the typing harness, without installing Araso or sending real keys.
# Run in a fresh PowerShell process: pwsh -NoProfile -File windows/scripts/typing-test.tests.ps1
$ErrorActionPreference = 'Stop'

# Load only the functions under test. Dot-sourcing the harness would install the input method
# and take control of the desktop. The fake Keys type stands in for its Win32 calls.
$source = Join-Path $PSScriptRoot 'typing-test.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Cannot parse typing-test.ps1: $errors" }
Add-Type @'
using System;
using System.Collections.Generic;
public static class Keys {
    public static IntPtr Foreground, Layout;
    public static int FrontCalls, FrontSucceedsAt, Posts, LayoutChangesAt;
    public static bool LoseFocusOnPost;
    public static uint ProcessId;
    public static string WindowTitle;
    public static List<string> Events = new List<string>();
    public static IntPtr GetForegroundWindow() { return Foreground; }
    public static bool Front(IntPtr window) {
        FrontCalls++;
        if (FrontSucceedsAt > 0 && FrontCalls >= FrontSucceedsAt) Foreground = window;
        return true;
    }
    public static uint GetWindowThreadProcessId(IntPtr window, IntPtr ignored) { return 1; }
    public static uint GetWindowThreadProcessId(IntPtr window, out uint process) { process = ProcessId; return 1; }
    public static string Title(IntPtr window) { return WindowTitle; }
    public static IntPtr GetKeyboardLayout(uint thread) { return Layout; }
    public static bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l) {
        Posts++;
        if (LayoutChangesAt > 0 && Posts >= LayoutChangesAt) Layout = l;
        if (LoseFocusOnPost) Foreground = IntPtr.Zero;
        return true;
    }
    public static void Key(ushort scan, bool up, bool extended) {
        Events.Add(scan + ":" + up + ":" + extended);
    }
}
'@
foreach ($name in 'Front-Window', 'Clear-FirstSignIn', 'Ready', 'Case') {
    $matches = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false))
    if ($matches.Count -ne 1) { throw "Expected one $name function" }
    Invoke-Expression $matches[0].Extent.Text
}

function Assert-Equal($actual, $expected, [string]$message) {
    if ($actual -cne $expected) { throw "${message}: expected [$expected], got [$actual]" }
}
function Assert-List($actual, $expected, [string]$message) {
    Assert-Equal (($actual | ForEach-Object { "[$_]" }) -join ',') (($expected | ForEach-Object { "[$_]" }) -join ',') $message
}
function Start-Sleep { param($Milliseconds, $Seconds) }
function Write-Host { param([Parameter(ValueFromRemainingArguments)] $Message) $script:messages += ($Message -join ' ') }
function Get-Process {
    [CmdletBinding()] param([Parameter(Position=0)] $Name, $Id)
    if ($PSBoundParameters.ContainsKey('Id')) { return $script:processesById["$Id"] }
    if ($Name -eq 'WindowsTerminal') { return $script:terminals }
    if ($Name -eq 'wsl') { return $script:wslProcesses }
}
function Stop-Process {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)] $InputObject, $Id, [switch]$Force)
    process { if ($InputObject) { $script:stopped += $InputObject.Id } else { $script:stopped += $Id } }
}
$originalArchitecture = $env:PROCESSOR_ARCHITECTURE
try {
    $script:messages = @(); $script:processesById = @{}
    [Keys]::Foreground = [IntPtr]42; [Keys]::ProcessId = 12; [Keys]::WindowTitle = 'Microsoft account'
    $script:processesById['12'] = [pscustomobject]@{ ProcessName = 'WWAHost' }
    Assert-Equal (Front-Window) "WWAHost 'Microsoft account'" 'foreground process and title'
    $script:processesById.Clear()
    Assert-Equal (Front-Window) " 'Microsoft account'" 'foreground process can exit before lookup'

    # Feed the actual clearing function a sequence of foreground windows.
    function Front-Window {
        $index = [Math]::Min($script:frontIndex, $script:fronts.Count - 1)
        $script:frontIndex++
        return $script:fronts[$index]
    }
    function Reset-Clear([string]$architecture, [string[]]$fronts) {
        $env:PROCESSOR_ARCHITECTURE = $architecture
        $script:fronts = $fronts; $script:frontIndex = 0
        $script:terminals = @(); $script:wslProcesses = @(); $script:stopped = @()
        [Keys]::Events.Clear()
    }
    Reset-Clear 'ARM64' @("WWAHost 'Microsoft account'", "WWAHost 'Microsoft account'", "SearchHost 'Search'", "StartMenuExperienceHost 'Start'", "Widgets 'Widgets'", "field 'typing'")
    Clear-FirstSignIn
    Assert-List ([Keys]::Events) @('28:False:False', '28:True:False', '28:False:False', '28:True:False', '1:False:False', '1:True:False', '1:False:False', '1:True:False', '1:False:False', '1:True:False') 'Return and Escape key down/up sequence'

    Reset-Clear 'ARM64' @("field 'typing'")
    $script:terminals = @(
        [pscustomobject]@{ Id = 1; MainWindowTitle = 'Terminal' },
        [pscustomobject]@{ Id = 2; MainWindowTitle = 'C:\Windows\wsl.exe' },
        [pscustomobject]@{ Id = 3; MainWindowTitle = 'hosted-compute-agent' },
        [pscustomobject]@{ Id = 4; MainWindowTitle = 'wsl.exe - work' }
    )
    $script:wslProcesses = @([pscustomobject]@{ Id = 5 })
    Clear-FirstSignIn
    Assert-List $script:stopped @(1, 2, 5) 'only matching ARM terminals and WSL are stopped'
    Assert-Equal ([Keys]::Events.Count) 0 'unrelated foreground is left alone'

    Reset-Clear 'ARM64' @("field 'typing'")
    $script:terminals = @([pscustomobject]@{ Id = 3; MainWindowTitle = 'hosted-compute-agent' })
    $script:wslProcesses = @([pscustomobject]@{ Id = 5 })
    Clear-FirstSignIn
    Assert-Equal $script:stopped.Count 0 'WSL is retained when no terminal title matches'

    Reset-Clear 'AMD64' @("WWAHost 'Other account'")
    $script:terminals = @([pscustomobject]@{ Id = 1; MainWindowTitle = 'Terminal' })
    $script:wslProcesses = @([pscustomobject]@{ Id = 5 })
    Clear-FirstSignIn
    Assert-Equal $script:stopped.Count 0 'x64 never closes terminal or WSL'
    Assert-Equal ([Keys]::Events.Count) 0 'unrecognized privacy title is left alone'

    Reset-Clear 'ARM64' (@("SearchHost 'Search'") * 8 + @("field 'typing'"))
    Clear-FirstSignIn
    Assert-Equal ([Keys]::Events.Count) 16 'clearing can succeed after the eighth key'
    Reset-Clear 'ARM64' @("SearchHost 'Search'")
    $failure = $null
    try { Clear-FirstSignIn } catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*stays in front after 8 keys*') { throw "Expected bounded clearing failure, got [$failure]" }
    Assert-Equal ([Keys]::Events.Count) 16 'persistent obstruction receives at most eight keys'

    # Ready retries focus only after another clearing pass, and reports final focus after language requests.
    function Clear-FirstSignIn { $script:clearCalls++ }
    $script:language = '0412'
    $field = @{ window = [IntPtr]42; process = [pscustomobject]@{ Id = 7 } }
    $script:processesById['7'] = [pscustomobject]@{ Modules = @() }
    $script:clearCalls = 0; $script:messages = @()
    [Keys]::Foreground = [IntPtr]42; [Keys]::Layout = [IntPtr]0x04120412
    [Keys]::FrontCalls = 0; [Keys]::FrontSucceedsAt = 0; [Keys]::Posts = 0; [Keys]::LayoutChangesAt = 0; [Keys]::LoseFocusOnPost = $false
    Ready $field 'wpf'
    Assert-Equal $script:clearCalls 1 'already focused field is cleared once'
    Assert-Equal ([Keys]::FrontCalls) 0 'already focused field does not request focus'

    $script:clearCalls = 0; [Keys]::Foreground = [IntPtr]::Zero; [Keys]::FrontCalls = 0; [Keys]::FrontSucceedsAt = 11
    Ready $field 'wpf'
    Assert-Equal $script:clearCalls 2 'focus retry clears again'
    Assert-Equal ([Keys]::FrontCalls) 11 'focus retry succeeds with a fresh attempt'

    $script:clearCalls = 0; $script:messages = @(); [Keys]::Foreground = [IntPtr]::Zero; [Keys]::FrontCalls = 0; [Keys]::FrontSucceedsAt = 0
    Ready $field 'wpf'
    Assert-Equal ([Keys]::FrontCalls) 15 'focus attempts are bounded'
    if (-not ($script:messages -match 'is in front')) { throw 'Missing foreground diagnostic after focus failure' }

    $script:clearCalls = 0; $script:messages = @(); [Keys]::Foreground = [IntPtr]42; [Keys]::FrontCalls = 0
    [Keys]::Layout = [IntPtr]0x04090409; [Keys]::Posts = 0; [Keys]::LayoutChangesAt = 1; [Keys]::LoseFocusOnPost = $true
    Ready $field 'wpf'
    Assert-Equal ([Keys]::Posts) 1 'language request stops after Korean layout appears'
    if (-not ($script:messages -match 'in front False')) { throw 'Ready must report focus after the language request' }
    [Keys]::LoseFocusOnPost = $false
    [Keys]::Foreground = [IntPtr]42; [Keys]::Layout = [IntPtr]0x04090409; [Keys]::Posts = 0; [Keys]::LayoutChangesAt = 0
    Ready $field 'wpf'
    Assert-Equal ([Keys]::Posts) 10 'language requests are bounded when the layout stays English'

    # Case reads each new field separately and closes it before deciding whether to retry.
    function Open-Field([string]$kind) {
        $script:opened++
        $text = $script:answers[$script:opened - 1]
        $script:kinds += $kind
        return @{ process = [pscustomobject]@{ Id = $script:opened }; window = [IntPtr]42; read = { $text }.GetNewClosure() }
    }
    function Ready($field, [string]$kind) { $script:readyIds += $field.process.Id }
    function Send-Keys([string]$keys) { $script:sent += $keys }
    function Reset-Case([string]$architecture, [string[]]$answers) {
        $env:PROCESSOR_ARCHITECTURE = $architecture; $script:answers = $answers
        $script:opened = 0; $script:stopped = @(); $script:kinds = @(); $script:readyIds = @(); $script:sent = @(); $script:afterCalls = 0
        [Keys]::Foreground = [IntPtr]42
    }
    Reset-Case 'ARM64' @('wrong', 'expected')
    Assert-Equal (Case 'abc' 'expected' { $script:afterCalls++ } 'wpf') $true 'ARM retry can pass'
    Assert-List $script:stopped @(1, 2) 'both attempted fields are closed'
    Assert-List $script:readyIds @(1, 2) 'retry prepares a fresh field'
    Assert-List $script:kinds @('wpf', 'wpf') 'retry preserves field kind'
    Assert-List $script:sent @('abc', 'abc') 'retry sends the same keys'
    Assert-Equal $script:afterCalls 2 'retry repeats after action'

    Reset-Case 'ARM64' @('expected', 'wrong')
    Assert-Equal (Case 'abc' 'expected' $null) $true 'ARM success does not retry'
    Assert-Equal $script:opened 1 'no extra field on first success'
    Reset-Case 'ARM64' @('', '')
    Assert-Equal (Case 'abc' 'expected' $null) $false 'two empty ARM results fail'
    Assert-Equal $script:opened 2 'ARM retry limit'
    Reset-Case 'AMD64' @('wrong', 'expected')
    Assert-Equal (Case 'abc' 'expected' $null) $false 'x64 failure does not retry'
    Assert-Equal $script:opened 1 'x64 uses one field'
    Assert-List $script:stopped @(1) 'x64 failed field is closed'

    # Exercise the actual final result gate, including the all-failed ARM regression.
    $gate = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^if \(\$results -contains \$false\)' }, $false))
    if ($gate.Count -ne 1) { throw 'Expected one required-results gate' }
    $createdGate = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^if \(\$created -contains \$false\)' }, $false))
    if ($createdGate.Count -ne 1) { throw 'Expected one text-service creation gate' }
    $earlyExits = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] -and $node.Extent.StartOffset -ge $createdGate[0].Extent.EndOffset -and $node.Extent.EndOffset -le $gate[0].Extent.StartOffset }, $true))
    Assert-Equal $earlyExits.Count 0 'results must not be bypassed by an early exit'
    function Get-ChildItem { [CmdletBinding()] param([Parameter(Position=0)] $Path) }
    $env:APPDATA = [IO.Path]::GetTempPath()
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    $results = @($false, $false); $failure = $null
    try { Invoke-Expression $gate[0].Extent.Text } catch { $failure = $_.Exception.Message }
    if ($failure -ne 'typing test failed') { throw "All-failed results must fail, got [$failure]" }
    $results = @($true, $false); $failure = $null
    try { Invoke-Expression $gate[0].Extent.Text } catch { $failure = $_.Exception.Message }
    if ($failure -ne 'typing test failed') { throw "A single failing result must fail, got [$failure]" }
    $results = @($true, $true)
    Invoke-Expression $gate[0].Extent.Text
} finally {
    $env:PROCESSOR_ARCHITECTURE = $originalArchitecture
}
Microsoft.PowerShell.Utility\Write-Host 'typing harness unit tests: ok'
