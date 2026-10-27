# Araso for Linux

Araso on Linux is the same input method, as a fcitx5 addon: `ArasoCore` (every decision, the
dictionary, kana and kanji) and `ArasoService` (what the Windows port added around it: a session
per text field over a snapshot of it, keys, the menu, the settings files) are shared as they are,
and only the layer fcitx5 talks to is new, in C++. This file maps each macOS piece to its Linux one
and says where the two differ. The Windows port (docs/windows-port.md) came first; Linux reuses
its protocol and much of its shape.

## Shape

```
 every app that types               fcitx5, one daemon per user
┌──────────────────────────┐ D-Bus ┌─────────────────────────────────────────────────┐
│ GTK/Qt module, XIM,      │ ────> │ araso.so (C++, linux/addon): keys, preedit,     │
│ Wayland text-input       │ <──── │  the card and the strip, the menu, the socket   │
│ (fcitx5's own frontends) │       │   └─ libArasoBridge.so (Swift: ArasoService     │
└──────────────────────────┘       │      over ArasoCore), loaded with dlopen        │
                                   └─────────────────────────────────────────────────┘
                                    araso-settings --settings <tab>  (Qt 6, own process)
                                    araso-settings --vim <mode> --app <name>
                                    araso-settings --check-update
```

- **No host process.** On Windows the text service is loaded into every app, so the Swift core
  lives in a host of its own behind a named pipe. fcitx5 is already one process per user that
  every app talks to, as Araso is on macOS, so the bridge is loaded into it: one runtime, one
  dictionary writer, one copy of the models. fcitx5 calls the addon on its main thread only, which
  is the main actor `ArasoBridge` assumes.
- **The field as the session sees it** (`linux/addon/Document.cpp`). fcitx5 keeps the word being
  typed out of the field: the app draws the preedit at its caret, and its surrounding text is the
  field without it. `SnapshotClient` wants the composition in the field, as a Mac field has its
  marked text, so the document is the surrounding text (UTF-8, caret in characters) with the
  preedit put in at the caret, in UTF-16 units. The session's edits come back as ranges of it and
  are made as `deleteSurroundingText` (characters around the caret), `commitString` and the new
  preedit; what lies between a range and the caret goes in again after the text (a word switched
  after its Space keeps its Space). After a commit, the addon writes what the field will hold into
  the input context's surrounding text, so a key that comes before the app reports it sees it.
  An app that sends no surrounding text (xterm over XIM) gets the composition only: what needs the
  text before the caret (a switch right after a word, URLs) doesn't work there, as on Windows.
- **Keys** (`linux/addon/Keys.cpp`) become the `WindowsKey` KeyMapper already reads: evdev numbers
  the main block by PC set 1 scan code (KEY_A = 0x1E), so letters, digits and symbols come from the
  physical key, whatever layout the desktop has, as on macOS and Windows. The keys Windows marks
  extended (right Ctrl and Alt, arrows, keypad Enter and /), 한/영 and 한자 (evdev's, or a layout's
  `Hangul`/`Hangul_Hanja` keysyms, as `korean:ralt_hangul` makes right Alt) are mapped one by one.
  A key without a code (a virtual keyboard), or a character on a key that types none on a PC
  keyboard (a virtual keyboard with a keymap of its own, as wtype makes), is placed by what it types.
- **No test/keep dance.** TSF holds a text service to what it answered before seeing a key; fcitx5
  lets the addon take a key or not after handling it. A key the session doesn't take reaches the
  app after the edits it made (Space after a word, typed by the app as on macOS), so `claimed` and
  `replay` aren't used.
- **One socket** (`$XDG_RUNTIME_DIR/araso/ime`, a datagram per request) takes what comes from
  outside: the settings window's `reload` (as `settingsChanged` does on macOS) and vim's mode. The
  settings window listens on `…/settings` for the addon's notices (the files changed from the menu,
  Try Typing's traces) and for a second copy's "show this pane".

## macOS → Linux

| macOS | Linux | Notes |
| --- | --- | --- |
| selecting Araso as the input source (on everywhere) | fcitx5's Active By Default, turned on once the first time the addon starts (`fcitx5-active-by-default` in the settings folder marks it done) | fcitx5 otherwise starts each field in the group's first input method, a keyboard layout, until Ctrl+Space. The settings window's **On in every text field** reads fcitx5's `config` and asks the addon (`activeByDefault` on the `ime` socket) to change it, since fcitx5 rewrites that file. |
| IMKInputController, `handle(_:client:)` | `InputMethodEngineV2::keyEvent` (`linux/addon/Engine.cpp`) | Releases matter only for modifiers (taps). |
| `IMKClient` (`TextClient`) | `SnapshotClient` over `Document` | UTF-16 positions in both; fcitx5's surrounding text counts characters. |
| marked text, clause underlines | preedit (`setClientPreedit`, or fcitx5's panel for apps that draw none) | Underlined; while converting, the clause the candidates are for highlighted. |
| the candidate card (`CaretPanel.swift`) | fcitx5's candidate list: nine to a page, numbered, the reading and the page under them | Drawn by fcitx5's own UI (classic UI, KDE's kimpanel), in its theme. A click chooses (`choose`). |
| the strip of readings | a horizontal candidate list: each reading with its tag, ✓ after the remembered one and ✎ after one corrected once | A click switches to it (`pick`). fcitx5 has no animated strip. |
| the capsule after a correction (Noted, Learned, Reset) | the panel's upper line for a moment (`✎ 안녕 · 한 번 고침`) | |
| `PauseHUD` (the icon under the caret) | the tray icon turns to `araso-paused`, and fcitx5 shows "Araso 일시정지" by the caret | The icon can change on Linux. |
| input menu (`menu()`) | the status area's Araso menu (tray, kimpanel), built by `ServiceRuntime.menu` | The same items and names; a check only on what is on. |
| bundle identifier (`apps.json`) | the program name fcitx5 reports, lowercase (`firefox`, `org.gnome.texteditor`, `kitty`) | A key ending in `.` still matches as a prefix. Wayland's text-input doesn't name the app: there the default applies. |
| right ⌥ tap (switch key) | right Alt (AltGr) tap, or the 한/영 key | fcitx5 takes 한/영 (`Hangul`) to turn input methods on and off before an input method sees it; in a field Araso types in, the addon takes it first (a `PreInputMethod` watcher) where right Alt is a switch key, and leaves it to fcitx5 elsewhere. |
| right ⇧ tap, ⌥Space, Esc, ⇧Esc | right Shift tap, Alt+Space, Esc, Shift+Esc | |
| ⌘ | Ctrl (the shortcut key), as on Windows | Right Ctrl tapped alone pauses (the default); the 한자 key too. Super plays ⌃. |
| pause shortcut | Ctrl/Alt/Super + key | settings.json keeps macOS key codes and modifier names, so the file is the same everywhere. |
| ⌃J/⌃K, F6/F7 | F6/F7 | As on Windows. |
| Secure Event Input (`MaskedField`) | the field's `Password` capability | Keys go to the app as typed. |
| `Araso --vim` | `araso-settings --vim … --app <name>` (to the socket) | `scripts/vim` finds `/usr/bin/araso-settings`; the app is `$ARASO_APP`, or the terminal guessed from its variables (`KITTY_WINDOW_ID`, `KONSOLE_VERSION`, `VTE_VERSION`…). |
| text replacements (System Settings) | `replacements.json` in the settings folder | As on Windows: Araso puts the phrase in itself when Space or a symbol ends a shortcut. |
| macOS Japanese engine | AzooKey | As on Windows. |
| `/usr/share/dict/words` (English letter trigrams) | the same file when the system has it, else `Data/english_spelling.txt` | |
| `~/Library/Application Support/Araso` | `$XDG_CONFIG_HOME/araso` (`~/.config/araso`) | Same files and format. |
| Settings window (SwiftUI) | `araso-settings` (Qt 6 Widgets, `linux/settings`) | Languages, Keys, Apps, Dictionary, Try Typing, About: the Windows window's panes, through its own bridge. |
| Updater (pkg) | the daily check (`araso-settings --check-update`, started by the addon) and About's Check Now; Install opens the release page | A release's `Araso-linux-<arch>.tar.gz` is installed with its `install.sh`. |
| pkg, Registration, Uninstaller | `linux/scripts/install.sh` (finds fcitx5's addon folder, restarts fcitx5) and `/usr/lib/araso/uninstall.sh` (About's Uninstall… runs it through pkexec) | As on macOS, no installer turns Araso on: the user adds it in fcitx5's settings once. |
| `Localizable.strings` | the same file, plus `linux/Resources/ko.lproj/Linux.strings` | Korean when `LANGUAGE`/`LC_ALL`/`LC_MESSAGES`/`LANG` starts with `ko`. |
| `os.Logger` | fcitx5's log, category `araso` (`fcitx5 --verbose=araso=5`) | Errors only, never text. |

## Installed files

- `<fcitx5 addon folder>/araso.so` (Debian/Ubuntu `/usr/lib/<triplet>/fcitx5`, Fedora
  `/usr/lib64/fcitx5`, Arch `/usr/lib/fcitx5`), `/usr/share/fcitx5/addon/araso.conf`,
  `/usr/share/fcitx5/inputmethod/araso.conf`.
- `/usr/lib/araso`: `libArasoBridge.so` with the Swift runtime beside it (its RUNPATH is
  `$ORIGIN`; users have no Swift toolchain), `uninstall.sh`.
- `/usr/share/araso`: the data files, the kanji dictionary (`Dictionary`), `ko.lproj`.
- `/usr/bin/araso-settings`, its `.desktop` file, and the icons (`araso`, `araso-paused`) in
  hicolor, drawn by `swift windows/scripts/make-icon.swift [--slash] linux/data/icons`.

## Building

- Packages (Ubuntu names): `swift` 6.2, `cmake`, `ninja-build`, `pkg-config`,
  `extra-cmake-modules`, `fcitx5`, `libfcitx5core-dev`, `libfcitx5config-dev`,
  `libfcitx5utils-dev`, `fcitx5-modules-dev`, and `qtbase5-dev` or `qt6-base-dev`.
- The settings window builds on Qt 6 or Qt 5 (`ARASO_QT=5|6`; empty: Qt 6 when there is one).
  Releases use Qt 5: Ubuntu 22.04's Qt 6 has no input method plugins at all, so a Qt 6 window
  can't be typed into there, while fcitx5's Qt 5 module is on every distribution.
- `linux/scripts/build.sh [--test] [--tar]`: the bridge (`swift build -c release --product
  ArasoBridge`, RUNPATH `$ORIGIN`), the Swift runtime it needs (`ldd`), the addon and the settings
  window (`cmake -S linux`), then `build/linux/package/Araso-linux-<arch>/` (`install.sh`,
  `uninstall.sh`, `files/`) and with `--tar` `Araso-linux-<arch>.tar.gz`.
- `linux/scripts/install.sh`: from a source checkout it builds first; from a package it installs.
- `swift test` runs the shared tests on Linux too. With a scratch path other than `.build`, set
  `ARASO_RESOURCES` to the AzooKey checkout's `azooKey_dictionary_storage` for the kanji tests.
- `.github/workflows/linux.yml` builds on Ubuntu 22.04 (glibc 2.35, so the package runs on that and
  newer) for x86_64 and aarch64, runs the tests and the typing test, and leaves the tarball as an
  artifact; on a `v<version>` tag it goes into the draft release once the repository variable
  `ARASO_LINUX_RELEASE` is `true`.

## Testing

- `linux/tests` (`ctest` in the CMake build): `DocumentTests` checks the document model alone;
  `TypingTests` runs a fcitx5 `Instance` with the addon and the real bridge, and types into a text
  field that behaves as an app does (it shows the preedit, takes commits and deletions, sends its
  text as surrounding text, types a key the addon doesn't take): Korean and English, a switch while
  typing and after a word, Backspace, a particle, the pause tap, Return, the menu, and kanji from
  the card.
- `linux/scripts/typing-test/run.sh` (Docker, from a Mac too): builds the package in a Swift
  container on Ubuntu 22.04, installs it on a clean Ubuntu with only fcitx5 and apps, and types
  with real key events: on X (`inside.sh`, xdotool on Xvfb) into a GTK field and the settings
  window's Try Typing (Qt), through fcitx5's GTK and Qt modules (Korean and English, a particle, the
  right Alt switch while typing and after a word, the right Ctrl pause, the 한/영 and 한자 keys,
  Return, vim's modes, kanji from the card); on Wayland (`wayland.sh`, a headless sway) into a GTK
  field through fcitx5's GTK module and through Wayland's text-input, typed by `vkbd`, a virtual
  keyboard with the US keymap and real evdev codes (`vkbd.c`). Screenshots land in
  `build/linux/shots`. `.github/workflows/linux.yml` runs the same on x86_64 and aarch64.
- The package built on 22.04 types for real on clean 22.04 (fcitx5 5.0) and 24.04 (fcitx5 5.1),
  on X and on Wayland (sway), aarch64 natively and x86_64 under emulation (`ARASO_SLOW=30` gives
  `inside.sh` the time the models and the kanji dictionary take to load there). 22.04 has no fcitx5 module for Qt 6 (`fcitx5-frontend-qt6`), so
  other Qt 6 apps there don't type through fcitx5; the settings window is Qt 5 for that reason.
- Not yet checked: GNOME's and KDE's Wayland sessions (their own input method plumbing), hardware
  keyboards (the tests send the same evdev codes a Korean keyboard's 한/영 and 한자 keys do), and
  distributions other than Ubuntu.

## Not on Linux

- The strip's and the card's look: fcitx5 draws its own candidate window, in its theme.
- IBus: GNOME's default input method framework. Araso needs fcitx5 (packaged by every
  distribution; on GNOME it works through its IBus-compatible frontend or the Wayland protocols).
- `scripts/record-demo`: macOS automation.
