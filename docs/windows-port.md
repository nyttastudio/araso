# Araso for Windows

Araso on Windows is the same input method: `ArasoCore` (every decision, the dictionary, kana and
kanji) is shared as is, and only the layer that macOS's InputMethodKit and the Araso app gave is
new. This file maps each macOS piece to its Windows one and says where the two differ.

## Shape

```
 every app that types                          one per user session
┌───────────────────────────────┐  named pipe  ┌──────────────────────────────────────────┐
│ ArasoTip.dll (C++, TSF)       │ ───────────> │ ArasoHost.exe --server (C++)             │
│  key sink, composition,       │ JSON request │  ArasoBridge.dll (Swift: ArasoService    │
│  display attributes, the      │ <─────────── │   over ArasoCore) makes every decision   │
│  input indicator's menu       │  edits + UI  │  the strip and candidate card, pause,    │
│  x64, x86 and ARM64 builds    │              │  daily update check                      │
└───────────────────────────────┘              └──────────────────────────────────────────┘
                                                ArasoHost.exe --settings <tab>  (own process)
                                                ArasoHost.exe --vim <mode> --app <exe>
```

- **Why a host process and not the Swift core in every app.** On macOS one Araso process serves
  every app, and learning writes `dictionary.json` from that one process. Loaded into every app,
  the core would write the dictionary from many processes at once, load the models (and the 35 MB
  kanji dictionary) once per app, and need the Swift runtime in 32-bit and sandboxed apps. The
  TSF DLL stays small C++ with no Swift in it, so it builds for x86 and ARM64 too.
- **The text field is snapshotted.** `InputSession` talks to a `TextClient` that it may ask for
  the selection, the marked range and text before the caret. The DLL sends those with each key
  (`TextContext`: the selection and composition as ACP offsets, and the text from 256 UTF-16 units
  before them to the end of the line after them, up to 4096 units, for a word fixed later in the
  line and the caret's way back to the line's end); `SnapshotClient` answers from it, applies each edit to its copy and records it with
  the range it replaces; the DLL makes the recorded edits in its edit session, in order.
  `Tests/ArasoServiceTests` drive the runtime the same way (`FakeDocument`).
- **What only the host can start** (a click in the strip or the card, a vim mode change that
  commits, the menu's Pause) is queued for the client; the host posts `Araso.Pending` to the DLL's
  message-only window, and the DLL fetches and makes those edits in an edit session.
- **A key kept is never lost.** TSF holds a text service to what `OnTestKeyDown` answered: a key
  it keeps reaches the app nowhere else (a classic app gets `VK_PROCESSKEY`), and one it lets go
  never comes to `OnKeyDown`. So the host answers `test` for every key: letters, digits, Space and
  symbols are kept unless keys pass through (paused, vim's normal mode); any other key, a shortcut
  included, only when the session has a word to finish or a switch to make. A kept key the session
  then passes on is typed by the host after the word (`claimed`: Space after a word, as macOS's
  app types it) or sent again for the app (`replay`: Return, Tab, a shortcut ending a word). A
  kept key's up is kept too. Modifiers are only seen; a modifier's up is kept when it ends a tap
  that does something, so a lone right Alt doesn't open the menu bar.
- **Classic apps get the word at the caret.** Windows' compatibility layer for apps that only
  know IMM32 (CUAS: Notepad's Edit control on Windows 10 and Server, many Win32 apps) treats a
  Korean input method as IMM32's Korean ones: one syllable composed at a time, and a composition
  of a whole word ended as soon as it starts. Araso composes the whole word (its language can
  still change), so in such a context (TSF marks it transitory, or the app was seen ending a
  composition at once) the text service keeps the word itself, shows it to the session as if
  composed at the caret, and the host draws it there underlined (`WordWindow`); it goes in whole
  when the word ends. TSF apps (WPF, Windows 11's Notepad, browsers, Office) compose it in the text.

## macOS → Windows

| macOS | Windows | Notes |
| --- | --- | --- |
| IMKInputController, `handle(_:client:)` | `ITfKeyEventSink` (`windows/tip/TextService.cpp`) | Keys go to the host; a key the session doesn't take still reaches the app (Space after a word, as on macOS). |
| `IMKClient` (`TextClient`) | `SnapshotClient` + edit sessions | UTF-16 offsets in both (NSRange ↔ ACP). A field without ACP positions still works, without the features that read back (a switch right after a commit, URLs). |
| marked text, clause underlines | TSF composition + `ITfDisplayAttributeProvider` | Underlined, as macOS draws marked text; while converting, the reading thin and the clause the candidates are for thick. In classic apps, the host's `WordWindow` at the caret (see above). |
| `StripHUD` (`CaretPanel.swift`) | the host's `StripWindow` (`windows/host/Strip.cpp`) | The same strip on Araso's paper, drawn with Direct2D and DirectWrite in a layered window: the readings on one line under the word, a check after the remembered one and a pencil after one corrected once, a click switching to one (`pick`); the candidates in a card of nine under the clause, as wide as the widest on any page, the reading and the page under them, the next page coming up from below, a click choosing; after a correction, the capsule moving under the word's first letter with Noted, Learned or Reset. The thumb is Windows' accent color, the pencil and the arrow back Windows' icon font. |
| `PauseHUD` | the host's `PauseHud` | Araso's icon under the caret for a moment, struck through when paused. |
| input menu (`menu()`) | the input indicator's menu (`LangBarButton`, `GUID_LBI_INPUTMODE`) | The same items and names, built by `ServiceRuntime.menu`, "Changed by the Dictionary" included. |
| bundle identifier (`apps.json`) | exe name, lowercase (`notepad.exe`, `code.exe`) | A key ending in `.` still matches as a prefix. |
| right ⌥ tap (switch key) | right Alt tap, or the 한/영 key | On Korean keyboards right Alt is 한/영 (`VK_HANGUL`), which switches as it goes down (some keyboards send no release for it). A lone right Alt's release is taken, so the app doesn't open its menu bar. |
| right ⇧ tap, ⌥Space, Esc, ⇧Esc | right Shift tap, Alt+Space, Esc, Shift+Esc | Alt+Space is taken only when chosen. |
| ⌘ | Ctrl (the shortcut key) | Right Ctrl tapped alone pauses (`rightCommand`, the default), and Ctrl going down puts a held word in before a paste. The 한자 key pauses as it goes down. The Windows key plays ⌃ (`rightControl`). |
| pause shortcut (⌃⌥P) | Ctrl/Alt/Win + key | settings.json keeps macOS key codes and modifier names on both, so the file is the same; `KeyMapper` maps scan codes to them. |
| ⌃J/⌃K, F6/F7 | F6/F7 | Ctrl+J/K are app shortcuts on Windows. |
| letters and symbols | from the key's scan code, as on a US keyboard | As macOS has Araso type on the US layout, whatever layout Windows has. |
| Secure Event Input (`MaskedField`) | the field's input scope (`IS_PASSWORD`) | Keys go to the app as typed. |
| `Araso --vim` (distributed notification) | `ArasoHost.exe --vim … --app <exe>` (`WM_COPYDATA` to the host) | `scripts/vim` finds ArasoHost.exe; the app is `$ARASO_APP`, or the terminal guessed from `WT_SESSION`/`TERM_PROGRAM`. |
| text replacements (System Settings) | `replacements.json` in the settings folder | Windows has no system list. Apps don't replace on Windows, so Araso puts the phrase in itself when Space or a symbol ends a shortcut. |
| macOS Japanese engine (`japaneseEngine: "apple"`) | AzooKey | `AppleJapaneseConverter` returns nil off macOS; `"apple"` falls back to AzooKey as it already did. |
| `/usr/share/dict/words` (English letter trigrams) | `Data/english_spelling.txt` | The same web2 list (public domain), shipped: without it English scored differently. |
| `~/Library/Application Support/Araso` | `%APPDATA%\Araso` | Same files and format. |
| Settings window (SwiftUI) | `ArasoHost.exe --settings <tab>` (Win32) | Languages, Keys, Apps, Dictionary, Try Typing, About. Files are written through ArasoBridge, so the JSON is the same. |
| settings-changed notifications | `WM_COPYDATA` both ways (`kCopyReload`, `kCopyFilesChanged`) | Try Typing's traces come from the text service in the settings window's own process. |
| Updater (pkg, `pkgutil --check-signature`) | `Araso-Setup.exe` from the same GitHub release, Authenticode check of the publisher (`WinVerifyTrust`) | A build without a signing identity opens the release page instead. `ARASO_UPDATE_FEED` points the check at a file, as `updateFeed` does on macOS. |
| pkg, Registration, Uninstaller | Inno Setup (`windows/installer/Araso.iss`): regsvr32 of each DLL, `ArasoHost.exe --register` (`InstallLayoutOrTip`), the host in HKLM `Run` | Uninstall from Settings → Apps or About; the uninstaller asks whether to delete `%APPDATA%\Araso`. |
| `Localizable.strings` | the same file, plus `windows/Resources/ko.lproj/Windows.strings`, read by `Strings` (ArasoService) | Korean when Windows' display language is Korean. |
| `os.Logger` | `OutputDebugString` | The kind of key and the app only, never text. |

## Not on Windows

- The strip's shadow is a few rings of fading black rather than a blur (a layered window has no
  Core Animation shadow), and its motion is drawn frame by frame on a 16 ms timer; Windows'
  "Animation effects" off stills it, as Reduce motion does on macOS.
- `scripts/typing-test`, `scripts/record-demo`: macOS automation.
- UI-less mode for full-screen games (`ITfUIElement`): the strip and the card are a topmost window,
  which an exclusive full-screen game may hide.
- What CI checks (`windows/scripts/typing-test.ps1`, on `windows-latest` and `windows-11-arm`):
  real key events into a WPF TextBox, Notepad's Edit control and the settings window's Try Typing
  (Korean, English, a switch while typing and after a word, the pause tap, and 한/영 and 한자 as
  `VK_HANGUL`/`VK_HANJA`, and 한/영's own scan code); a process in an AppContainer, as a Store
  app's text service runs, attaching to the host (`ArasoHost.exe --appcontainer-test`); and on
  ARM64, where the runner has no desktop to type into, the text service created through COM in an
  ARM64 and an x64 process (`ArasoHost.exe --load-text-service`).
  Not yet checked: a real Korean keyboard, and typing on ARM64 hardware.
- In a classic app, the word and its Space reach the Edit control a moment after they go in
  (CUAS posts them), so a switch key pressed within a few tens of milliseconds of the Space finds
  the text before the caret not yet the word and doesn't switch it; a moment later it does.

## Building

- Swift: `swift build -c release --product ArasoBridge` on Windows with Swift 6.4 or later
  (6.2.0's optimizer crashed on a dependency). `swift test` runs the same tests as on macOS.
- C++: `cmake -S windows -B build/windows -A x64 && cmake --build build/windows --config Release`
  (also `-A Win32` for the text service and `-A ARM64`). On ARM64 Windows, x64 apps under emulation
  read the same COM registration as ARM64 apps, so `arm64\ArasoTip.dll` there is an ARM64X
  forwarder (`windows/scripts/arm64x-forwarder.ps1`) to `ArasoTipArm64.dll` and `ArasoTipX64.dll`
  beside it, and registration writes the forwarder's path (x86 apps have their own registry view
  and the x86 build). `windows/scripts/check-cross.sh` compiles
  and links it on macOS or Linux with `zig c++`, to catch errors before CI.
- `.github/workflows/windows.yml` builds and tests both on `windows-latest`, stages them with the
  Swift and Visual C++ runtimes and the data, runs `ArasoHost.exe --selftest`, and leaves
  `Araso-Setup.exe` as an artifact.
- The icons: `swift windows/scripts/make-icon.swift [--slash] windows/Resources/Araso.ico`.
