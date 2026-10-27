<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/logo-dark.svg">
    <img src="docs/media/logo-light.svg" width="150" alt="Araso: A, 아, あ">
  </picture>
</p>

<h1 align="center">Araso</h1>

<p align="center"><b>흐름대로 써진다 · 流れるままに · Type as it flows</b></p>

<p align="center">Araso comes from 알아서 (<i>araseo</i>), Korean for “on its own”: whatever language you type, it picks it for you.<br>
<sub>It was called Seamtype (0.1.x) and Legato (0.2.0). If you used either, see <a href="#moving-from-seamtype">Moving from an earlier name</a>.</sub></p>

<p align="center">
  <a href="https://github.com/nyttastudio/araso/releases/latest"><img src="https://img.shields.io/github/v/release/nyttastudio/araso?style=flat-square&label=release" alt="Latest release"></a>
  <a href="https://github.com/nyttastudio/araso/stargazers"><img src="https://img.shields.io/github/stars/nyttastudio/araso?style=flat-square&label=stars" alt="Stars"></a>
  <a href="https://github.com/nyttastudio/araso/releases"><img src="https://img.shields.io/github/downloads/nyttastudio/araso/total?style=flat-square" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-555?style=flat-square&logo=apple" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%7C%20Intel-555?style=flat-square" alt="Apple silicon and Intel">
  <a href="https://github.com/nyttastudio/araso/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/nyttastudio/araso/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT license"></a>
</p>

<p align="center"><a href="https://nyttastudio.com/araso/">Website (Korean)</a> · <a href="README.md">한국어</a> · English</p>

<h3 align="center">Stop pressing the language-switch key.</h3>

<p align="center">
Type everything on the English (QWERTY) layout.<br>
Araso decides <b>per word</b> whether you meant English, Korean (2-set / 두벌식, 3-set final / 세벌식 최종 or 3-set 390 / 세벌식 390) or, if you turn it on, Japanese (romaji), and commits the right one.
</p>

```
Stay hungry, stay foolishsms wkqtmdml akfdlek.   →  Stay hungry, stay foolish는 잡스의 말이다.
wagahaihanekodearu␣sms thtpzldml thtjfdlek.      →  吾輩は猫である는 소세키의 소설이다.
Hello, worldhasaishonopuroguramudesu␣.           →  Hello, worldは最初のプログラムです。
```

<p align="center">
  <a href="https://github.com/nyttastudio/araso/releases/latest/download/Araso.pkg"><img src="https://img.shields.io/badge/Download%20Araso.pkg-0071e3?style=for-the-badge&logo=apple&logoColor=white" width="292" alt="Download Araso.pkg"></a>
</p>

<p align="center">
  <img src="docs/media/demo.gif" width="720" alt="Choosing Araso once from the input menu, then typing on QWERTY into Safari without switching the input source again, with the keys pressed and the language each word came out in shown below: Stay hungry, stay foolish는 잡스의 말이다. / 吾輩は猫である는 소세키의 소설이다. / Hello, worldは最初のプログラムです。">
</p>

## At a glance

- **Decided per word**: English, Korean or Japanese, whichever each word is. No input source to switch.
- **Mixed words too**: `githubdp` → `github에`, `PDFvkdlf` → `PDF파일`, `githubde` → `githubで`
- **One key to fix it**: tap right ⌥ to cycle English → English+particle → Korean → Japanese, every reading shown in a strip under the word, even right after a word is committed.
- **Remembers your fixes**: one correction leans that way, the same correction twice sticks, and switching back to Araso's own reading forgets it; after a correction the strip says what it learned.
- **Kanji conversion**: clause by clause, with live conversion, through the engine of macOS's own Japanese input, its candidates on Araso's card, nine to a page.
- **Per app**: Strict in a terminal, off in a game. It follows vim's modes, and a pause key passes keys straight through.
- **On this Mac only**: keystrokes never leave the input method. A keystroke's preview takes at most ~3 ms.
- **99.5% accurate**: on about 6,000 held-out words and phrases (Japanese on, [held-out results](#held-out-results)).

## Contents

- [Why](#why)
- [Install](#install) · [Updates](#updates) · [Moving from an earlier name](#moving-from-seamtype) · [Uninstall](#uninstall)
- [Keys](#keys) · [Language switch keys](#language-switch-keys) · [Undo after commit, and learning](#undo-after-commit-and-learning) · [Text replacements](#text-replacements) · [Pause](#pause) · [vim](#vim)
- [Settings](#settings) · [Settings files](#settings-files)
- [How it decides](#how-it-decides) · [Held-out results](#held-out-results)
- [Known limits](#known-limits)
- [Develop](#develop)
- [License and data](#license-and-data)

## Why

I live in Japan and mix Korean, English and Japanese every day. With three input sources, I was
forever pressing the switch key, or typing a word in the wrong language. Then
[Meltype](https://github.com/yksr-melt/Meltype), which mixes Japanese and English without switching,
inspired me to build one input method for all three.

## Install

1. Download [`Araso.pkg`](https://github.com/nyttastudio/araso/releases/latest/download/Araso.pkg),
   open it and follow the steps. It installs into `/Library/Input Methods` and registers the input source.
2. Pick **Araso** in the input menu in the menu bar.
3. To mix in Japanese as in the examples above, turn on **Japanese Input** in the input menu.
   **Japanese is off by default.**

It runs on macOS 13 or later, on Apple silicon and Intel, and is notarized by Apple. It takes ~50 MB of
memory (plus the ~35 MB Japanese dictionary when Japanese is on) and ~47 MB on disk, with nothing
else running.

> [!TIP]
> If Araso isn't in the input menu, add it in **System Settings → Keyboard → Input Sources →
> Edit… → + → Korean → Araso**. If it isn't listed there either, log out and back in once.

<details>
<summary>Install from Terminal</summary>

Instead of the pkg, this installs the latest release into `~/Library/Input Methods` and registers it.
If Araso is already installed, it asks what to do.

```sh
curl -fsSL https://raw.githubusercontent.com/nyttastudio/araso/main/scripts/get.sh | sh
```

To choose without the question, add `| sh -s -- --reinstall` (keeps settings and learned words),
`--clean` (removes everything, then installs) or `--uninstall [--delete-data]`. Use either this or the
pkg, not both.

</details>

<details>
<summary>Windows (beta)</summary>

The same input method on Windows 10 (1809) or later. Deciding words, the dictionary and learning are
the same code as on macOS; kanji conversion is AzooKey's.

1. Download `Araso-Setup.exe` from the [Windows beta](https://github.com/nyttastudio/araso/releases/tag/windows-beta-1)
   and install it. It registers Araso and adds it to Korean's input methods, on x64 and ARM64 PCs
   alike. It isn't code-signed yet: when "Windows protected your PC" shows, choose **More info → Run anyway**.
2. Pick **Araso** in the taskbar's input indicator. Its menu is the macOS input menu.

Where it differs from macOS:

- Ctrl plays ⌘'s part: right Ctrl (the 한자 key) tapped alone pauses, and right Alt (the 한/영
  key) tapped alone switches readings.
- Apps are named by program (`notepad.exe`), and the settings files are in `%APPDATA%\Araso`.
- Text replacements come from `replacements.json` in that folder (`{"addr": ["123 Main St"]}`),
  and Araso replaces them itself.
- In older apps (Windows 10's Notepad, for one), the word being typed is shown underlined in a
  small window at the caret and goes in whole when it ends: such apps don't let a Korean input
  method compose a whole word.
- The beta doesn't update itself. Install a newer beta from the [releases](https://github.com/nyttastudio/araso/releases)
  over it.

The rest is mapped in [docs/windows-port.md](docs/windows-port.md). Report what doesn't work in
[Issues](https://github.com/nyttastudio/araso/issues), with the app's program name (`notepad.exe`).

</details>

<details>
<summary>Linux (beta)</summary>

The same input method, for fcitx5. Deciding words, the dictionary and learning are the same code
as on macOS; kanji conversion is AzooKey's. It runs on x86_64 and aarch64 with Ubuntu 22.04 or later
and distributions like it (glibc 2.35 or later).

1. Install fcitx5 and make it the input method framework (Ubuntu: `sudo apt install fcitx5 fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5`,
   plus `fcitx5-frontend-qt6` from 24.04 on; then `im-config -n fcitx5` and log out; 22.04 has no `fcitx5-frontend-qt6`, so Qt 6 apps don't type through it there).
2. Download `Araso-linux-<arch>.tar.gz` for your architecture (`uname -m`) from the
   [Linux beta](https://github.com/nyttastudio/araso/releases/tag/linux-beta-1), unpack it and run
   its `./install.sh`; it asks for your password. To install from source instead (Swift 6.2, CMake,
   fcitx5's development files and Qt 6; the list is in [docs/linux-port.md](docs/linux-port.md)):

   ```sh
   git clone https://github.com/nyttastudio/araso && araso/linux/scripts/install.sh
   ```
3. Add **Araso** under **Input Method** in fcitx5's settings (`fcitx5-configtool`); the installer
   doesn't turn it on. The Araso menu in the tray is the macOS input menu, and the settings window
   is `araso-settings`.

Where it differs from macOS:

- Ctrl plays ⌘'s part: right Ctrl (the 한자 key) tapped alone pauses, and right Alt (the 한/영
  key) tapped alone switches readings. fcitx5 turns input methods on and off with 한/영, but in a
  field Araso types in, Araso takes it first as its switch key.
- Araso starts on in every text field: the first time it starts, it turns on fcitx5's Active By
  Default. Off (**On in every text field** under Languages in the settings window), a field starts
  in the keyboard layout until Ctrl+Space, as fcitx5 does by default.
- Apps are named by the program name fcitx5 knows (`firefox`, `kitty`, `org.gnome.texteditor`), and
  the settings files are in `~/.config/araso`. Wayland apps don't tell their name, so they follow
  the default.
- fcitx5 draws the candidates and the readings, in its theme. Pausing changes the tray icon and
  shows a moment by the caret.
- Text replacements come from `replacements.json` in the settings folder (`{"addr": ["123 Main St"]}`),
  and Araso replaces them itself.
- The settings window's About tells of updates; they download from the release page. Uninstall
  with About's **Uninstall…** or `sudo /usr/lib/araso/uninstall.sh`.

The rest is mapped in [docs/linux-port.md](docs/linux-port.md). Report what doesn't work in
[Issues](https://github.com/nyttastudio/araso/issues), with the distribution, the desktop (GNOME,
KDE…), X11 or Wayland, and the app's name.

</details>

### Updates

When a new version is out, the input menu shows **Update to Araso …**, and **About** in the
settings window lists what changed and installs it (**Check Now** checks by hand). It downloads the
installer, checks its signature and opens it, so you only enter your password.

- Checks happen once a day and when the settings window opens. They ask GitHub only for the latest
  version number, and nothing you type is sent. Turn them off with **Check for updates
  automatically** in About.
- You can also download the new `Araso.pkg` and install it the same way. It replaces the app and
  keeps your settings and learned words, with no logout or restart.
- For a clean reinstall, tick **Reset settings and learned words** under **Customize** in the installer.

<a id="moving-from-seamtype"></a><a id="from-seamtype"></a><a id="from-legato"></a>

### Moving from an earlier name

Seamtype (0.1.x) became Legato in 0.2.0 and Araso in 0.2.1. Each name is a different input method to
macOS, so if you used Seamtype or Legato, once:

1. Update from the input menu or the settings window's **About**, or download and open the new
   `Araso.pkg`. The installer removes Seamtype and Legato and registers Araso. Settings, per-app rules, the
   dictionary and kanji learning move over as they are the first time Araso runs.
2. Add it in **System Settings → Keyboard → Input Sources → Edit… → + → Korean → Araso** (the
   installer opens Keyboard settings when it's done). macOS doesn't let an installer turn a new input
   method on, so this step is yours. Remove Seamtype or Legato (−) if still listed, and pick **Araso**
   from the input menu. If Araso isn't listed, or shows without a name, restart the Mac once
   (logging out didn't always do).
3. Set any keyboard shortcut or per-app input source you had for the old name again for Araso.
4. If you use the vim integration, replace `seamtype.*` / `legato.*` with the new
   [`araso.lua` / `araso.vim`](#vim). The old scripts can't find their app and do nothing.

The same goes for a terminal install (`get.sh`): the new `get.sh` removes Seamtype and Legato, asking for your
password for a copy in `/Library`.

### Uninstall

In the settings window, click **About → Uninstall Araso → Uninstall…**. It removes Araso
from both Input Methods folders (macOS asks for your password if you used the pkg) and switches to
another input source. Settings and learned words go only if you tick that in the confirmation.

- If Araso still shows in the input source list in System Settings afterwards, log out and back in once.
- If you reinstall and it isn't in the input menu, remove it from that list with − and add it again with +.

<details>
<summary>Uninstall in Terminal</summary>

Does what the settings window does. Add `--delete-data` only to drop settings and learned words too.

```sh
"/Library/Input Methods/Araso.app/Contents/MacOS/Araso" --uninstall --delete-data
```

</details>

## Keys

While a word is being typed it is underlined and shows the language Araso expects.

| Key | English / Korean word | Japanese phrase |
| --- | --- | --- |
| letters | extend the word | extend the phrase (kana preview) |
| letters with Caps Lock on | read as if Caps Lock were off (`GKAUS` → `하면`); English goes in in capitals (`OUTPUT`), and so do keys that would be loose jamo throughout, two or more (`RST`, `RD`, chat jamo too: `ZZ`); a word in the dictionary keeps its language. Toggled inside a word, a new word starts there | same |
| **[Language switch keys](#language-switch-keys)** (by default right ⌥ tapped on its own, and ⇧Esc) | switch reading: English → English+particle → Korean → Japanese | same (with live conversion, the kana first) |
| Esc | commit; the app gets the Esc (when chosen as a switch key, as above) | with live conversion, the kana first; on the kana, cancel the phrase (the app doesn't get it) |
| Delete | English: the last letter. Korean: the syllable being typed jamo by jamo, earlier ones whole (한국 → 한구 → 한ㄱ → 한 → gone, as the system's 2-set does) | one kana at a time (かんこく → かんこ); with live conversion the last clause goes back to kana less one, the ones before it staying as shown (今日はいい天気 → 今日はいいてん), as in macOS's Japanese input |
| **Space** | commit, then a space | **convert to kanji** (candidate window) |
| `, . ? !` and other symbols | commit, then the key | join the phrase, full-width: 、。？！ （）＿ 「」(`[ ]`) ・(`/`) 〜(`~`) |
| `-` | commit, then `-` | ー |
| Return | commit only (press again for a newline or to send; a setting) | commit as shown, kana or live-converted kanji (no newline) |
| ⌃K / F7, ⌃J / F6 | (the app's shortcut) | katakana / hiragana (Space flips, Return commits) |
| Tab, arrows, ⌘/⌃/⌥ | commit, the app gets the key | same |
| **Right ⌘** (tapped on its own; a setting) | [pause](#pause) / resume Araso in this text field | same |

<details>
<summary>While converting (candidate window open)</summary>

| Key | Effect |
| --- | --- |
| Space / ↓, ↑ | next / previous candidate |
| ←, → | shorten / lengthen the first clause (`今日は｜いいてんき`) |
| 1–9 | commit that candidate of the page shown |
| Return | commit the selected candidate |
| Esc | back to the kana |
| Delete | as in macOS's Japanese input: without live conversion, commit the conversion shown less its last character (変換 → 変); with it, back to typing the phrase, its last clause as kana less one (今日はいい天気 → 今日はいいてん) |
| letters, punctuation | commit, then keep typing |

Conversion goes clause by clause. The clause the candidates are for is underlined thick and the rest
of the reading thin, so you see where ←/→ put the boundary (apps that ignore underline styles show one
line). A candidate that covers only the start of the reading (`今日は`
for きょうはいいてんきですね) commits that part and keeps converting the rest. The candidate window lists
every homophone the engine has, rare kanji toward the end (`硝` for しょう). It drops down under the clause
on the switch key strip's paper, each candidate starting where the clause does, the current one in the
same blue capsule: nine to a page, numbered, with the reading and the page under them (`きょうは · 1/2`),
the tenth candidate bringing the next page up. It is as wide as the longest candidate on any page, so
turning a page moves nothing, and near the bottom of the screen it opens above the clause. A click
chooses one too.

</details>

<details>
<summary>Symbols and numbers after Japanese</summary>

A symbol typed on its own after Japanese is full-width and stays underlined, as in a Japanese IME
(`！`, `＿`, `「`).

- Return confirms it (no newline), Space offers its other forms (`!`, `‼︎`, `『`…), and a letter
  confirms it and starts a new word.
- Inside numbers (`3.5`, `10:30`) it stays half-width, and a bracket opened full-width closes
  full-width even after an English word (`日本語（English）`).

With Japanese on, numbers and symbols can be Japanese too.

- Typed on their own at the start of a sentence or after Korean or English, they go in half-width,
  but a language switch key right after them turns them into their Japanese form, underlined
  (`123` → `１２３`, `[` → `「`, `?` → `？`).
- In Japanese text, a word typed straight after a number reads as a counter, and Space converts it
  together with the number (`3ji` → `3時`, `5fun` → `5分`). Units that aren't romaji, like `5km` or
  `3pm`, stay English.

</details>

### Language switch keys

Choose the keys that switch readings in the settings window's **Keys** pane, keycaps you click:
right ⌥ tapped alone, ⌥Space, right ⇧ tapped alone, Esc and ⇧Esc, as many as you like. By default
they are **right ⌥ tapped alone** and **⇧Esc**. A key not chosen goes to the app.

Pressing one shows the word's readings in a one-line strip under it (`dkssud · 안녕`). The reading on
screen sits in a blue capsule like the one macOS shows under the caret when you switch input sources,
and the others sit beside it as they would go in, so you see what more presses bring; any other key puts
the strip away at once, and a click on a reading switches to it. Long readings are cut at 140 pt, and
near the bottom of the screen the strip shows above the word. The motion is over within 0.2 s, and there
is none with Reduce motion on in System Settings.

- **Right ⌥ or right ⇧ tapped alone**: apps don't react to a lone modifier, so it never closes a
  window or clears input. A tap with other modifiers isn't taken, so a key remapped as a Hyper key
  (⌃⌥⇧⌘ at once, by Raycast or Karabiner) keeps doing what it's bound to; choose another key then.
- **⌥Space**: it otherwise types a no-break space, which it no longer does once chosen.
- **Esc**: quick if you're used to it. But Chromium-based apps such as Claude's desktop app or Slack
  also see an Esc the input method took, so they may close their window or cancel the input while
  the word changes. With nothing to change, Esc goes to the app.
- **⇧Esc**: with nothing to change, it does nothing and never reaches the app.

The per-app settings can choose other keys for one app: switch with Esc by default, say, and leave
Esc out where it has to reach the app, as in an editor. The input menu's "Esc Switches Language"
adds or removes only Esc for the app in front. In the Japanese candidate window, and with live
conversion while kanji are shown, Esc goes back to the kana first whatever keys are chosen; on a
phrase live conversion leaves as kana (`たけ`), a switch key switches at once.

### Undo after commit, and learning

Right after a word is committed with Space or punctuation, a language switch key switches it to its
next reading, and pressing it again keeps cycling. Deleting the space or punctuation first keeps
that chance; any other key ends it. This needs the caret still right after the word, and an app that
lets Araso read the text there.

A word corrected once leans that way from then on: a close call (`so`/`내`) turns, a clear one
doesn't, so a stray switch doesn't do much. It is forgotten after 30 days unless corrected or typed
that way again. Correct the same keys the same way a second time and Araso always writes them so, also with a
particle after them (remember `ghostty` and you get `ghostty에`);
switching a word back to Araso's own guess forgets it, and switching a remembered word to yet another
reading moves the memory there the second time. In the switch
key's strip, a check (✓) after a reading marks the one the dictionary remembers (corrected twice, or a
word you added yourself), a pencil (✎) one corrected once. The key after a correction folds the strip to
the chosen reading, whose capsule moves under the word's first letter and says what happened for a
moment: a pencil and **Noted** after the first correction, the check drawing itself and **Learned**
when the word is learned, an arrow back (↺) and **Reset** on gray when switching back to Araso's pick
forgot it. When nothing changed, the strip just closes.
To tell whether a word went in because of the dictionary, open **Changed by the Dictionary** in the
input menu: it lists the last five words the dictionary decided, as `ghostty → English`, and choosing
one forgets it (the list is kept only until the input method restarts, and never saved). If a word
stuck by mistake, choose **Undo Last Learned** in the
input menu. Long tokens (over 20 keys, such as a
sentence switched as one) aren't remembered.

<details>
<summary>In apps where that can't work: hold the word after Space or punctuation</summary>

In an app that doesn't let Araso read the text, such as a terminal, turn on **Hold the word after
Space or punctuation** for that app (the input menu, or Apps in the settings window; `holdSpace` in
`apps.json`). Space or a punctuation mark (any symbol such as `. , ? !`, not digits) then doesn't
end the word but goes inside the underline too.

- While underlined it is the word being typed: a language switch key changes it (`dkssud.` →
  `안녕.`, the mark stays as typed), and Delete deletes (the space or mark first).
- Starting the next word puts it in with that character. So does pressing ⌘, so a ⌘V pastes after
  the word (a terminal pastes on ⌘V itself, without showing Araso the key); after that a switch key
  can't change the word any more.
- Only one character is held: after `안녕.` a Space or a second mark ends the word and is handled as
  with holding off (to the app, usually; after a word that went in as Japanese, by the rules for
  symbols after Japanese text).
- Return only confirms it, as on any underlined word, so press it again for a new line or to run a
  command.
- The app never gets the Space key, so its text replacements don't fire.

</details>

### Text replacements

A shortcut in System Settings → Keyboard → Text Replacements that reads as Korean or Japanese
(`주소`, `ㅈㅅ`, `よろ`) shows in that language whatever the guess, so the app replaces it on Space as
it does with the system's input. English shortcuts are decided as usual.

- A Japanese shortcut's phrase is the first candidate on Space, and a shortcut entered more than
  once offers every phrase in turn. Enter a Japanese shortcut as its hiragana reading (`よろ`, `ぐー`).
- A Korean or English shortcut entered more than once (two phrases or more) offers them in the
  same candidate window on Space, then the shortcut as typed: the one chosen goes in with the
  space, and Esc goes back to the shortcut. With one phrase the app replaces it as before (macOS
  hands apps one phrase per shortcut).
- The app does the replacing, so apps without text replacement (terminals, Chrome…) only get the
  phrases chosen in the candidate window.
- Edits to the list apply the next time a text field becomes active.

### Pause

Where every key is a command, like lazygit or htop in a terminal, tap **right ⌘** on its own. The
word in progress goes in, and in that text field keys go through as typed. Tap again, move to
another app or text field, or change a setting, to resume.

Each tap shows Araso's icon under the caret for a moment, like the input source indicator,
struck through when paused. The menu bar icon doesn't change, so to check later, look for the tick
in the input menu.

Change the pause key under **Keys** in the settings window: right ⌘, ⌥, ⇧ or ⌃ tapped on its own, a
recorded shortcut (one with ⌘, ⌃ or ⌥, like ⌃⌥P, or a function key alone), or none. A key that
switches languages (right ⌥ or ⇧, ⌥Space) or types kana (⌃J, ⌃K, F6, F7) can't be chosen. A
shortcut the app also has in its menus may reach the app first.

### vim

For neovim put [`scripts/vim/araso.lua`](scripts/vim/araso.lua) in `~/.config/nvim/plugin/`;
for Vim (8.2 or later, `+job`) put [`scripts/vim/araso.vim`](scripts/vim/araso.vim) in
`~/.vim/plugin/`.

Vim then tells Araso on every mode change, so words are decided only in insert mode, and in
normal, visual and command-line mode keys go straight to vim: `s`, `dd`, `ciw` and `:wq⏎` run key
by key. Inside vim, Esc always goes to vim, so no per-app setting is needed. Once vim quits, words
are decided again at the shell.

<details>
<summary>How it works, and caveats</summary>

- The signal is `Araso --vim insert|normal|off --app <bundle id>` (`ArasoHost.exe` on Windows,
  `araso-settings` on Linux), sent on mode changes
  (entering and leaving insert mode, start, quit, focus), not on keys.
- The bundle identifier is `$__CFBundleIdentifier`, which macOS sets for every app, so nothing
  needs setting up per terminal (Ghostty, Terminal, iTerm2, VS Code…), and the signal reaches only
  that app's text field. A signal without `--app` is taken only where Esc isn't a switch key.
- Attached to tmux from a different terminal than the one that started its server, the bundle
  identifiers differ and the signal is ignored.
- If Vim doesn't see the terminal's focus changes, Araso can't tell when you move from its pane
  to a shell pane; press ⇧Esc there (when it's a switch key) to start deciding words again.

</details>

## Settings

From the input menu (the menu bar, while Araso is selected) you can:

- pause Araso in this text field (like the pause key)
- turn word conversion on or off for the app in front, set its conversion threshold
  (Normal/Strict), whether Esc switches languages and whether the word is held after Space or
  punctuation, or drop its settings. Those are greyed while conversion is off
- turn Japanese Input and Live Conversion on or off
- undo the last learned word, see and forget the words the dictionary changed lately, and open Try
  Typing, the dictionary or the settings window

The settings window has these panes, and changes apply at once.

| Pane | What's there |
| --- | --- |
| Languages | converting words on or off, Japanese on or off, the Layouts card (Hangul: 2-set, 3-set final, 3-set 390; English and romaji: QWERTY, Colemak, Colemak-DH), Japanese input and its options, resetting the kanji candidate order |
| Keys | the language switch keys, Return, the pause key |
| Apps | how sure a word must be to convert (Normal, Strict) and per-app behavior (`apps.json`) |
| Dictionary | words you added and words learned, in one list (`dictionary.json`): **+** to type keys and pick their reading (English, Korean, Japanese) and app; from a row's ⋯, keep a learned word for good or remove it. A word corrected once shows how long until it's forgotten |
| Try Typing | how each word was decided, with scores, and adding its keys to the dictionary |
| About | version, what changed, updates, uninstall |

### Settings files

The menu and the settings window both write JSON files in `~/Library/Application Support/Araso/`.
You can edit them by hand; missing keys, and values of the wrong type (`"true"` in quotes), keep the
default. A file that isn't readable JSON is moved aside, such as to `settings.json.unreadable`,
rather than written over (`apps.json` and `dictionary.json` too). After editing these files by hand,
restart the input method: `pkill -x Araso`.

<details>
<summary><code>settings.json</code>: global settings</summary>

```json
{ "japanese": true, "liveConversion": true }
```

| Key | Default | What it does |
| --- | --- | --- |
| `japanese` | **off** | Detect romaji Japanese and convert it. |
| `liveConversion` | off | While you type a Japanese phrase, show its top kanji candidate (`今日はいい天気でs`); Return commits it as shown. Like macOS Live Conversion. |
| `returnConfirmsOnly` | on | Return on an underlined word only confirms it. Off, the app gets that Return too (a Japanese phrase is still only confirmed). |
| `pauseKey` | `"rightCommand"` | The pause key (see [Pause](#pause)): `"rightCommand"`, `"rightOption"`, `"rightShift"` or `"rightControl"` tapped alone, `"off"`, or a shortcut such as `{ "keyCode": 35, "modifiers": ["control", "option"], "key": "P" }`. The older `"rightCommandPause": false` reads as `"off"`. |
| `fullWidthDigits` | off | Numbers after Japanese come out full-width (`１２３`, `０３－１２３４` in addresses and phone numbers), underlined, with Space offering `123` (half-width) or conversions like `三月`. |
| `fullWidthSpace` | off | Space after Japanese types a full-width space (`　`). ⇧Space types the other width (full-width while this is off). |
| `latinLayout` | `"qwerty"` | The layout English and romaji are typed on; also `"colemak"` or `"colemakDH"`. Korean stays on its usual keys (QWERTY's) whatever the layout. Words learned on one layout are learned again on another: their keys differ. |
| `japaneseLayout` | none | The layout romaji is typed on (`"qwerty"`, `"colemak"`, `"colemakDH"`); without it, `latinLayout`'s. English on Colemak with romaji on QWERTY, for one. |
| `koreanLayout` | `"dubeolsik"` | The Korean layout; `"sebeolsikFinal"` is 3-set final (세벌식 최종), `"sebeolsik390"` 3-set 390 (세벌식 390). Jamo on digit and symbol keys (ㅆ of 갔 on 2, ㅂ of 밥 on ;) read as jamo inside a word where they fit, and as the symbol where they don't (the ! of 안녕!). Digits alone stay a number, except 00 after Korean, which is ㅋㅋ (other ㅋㅋ and ㅠㅠ (55) take a switch key). Keys that type a digit or symbol on 3-set (on 최종 ⇧B ?, ⇧/ !, ⇧H 0, [ (; on 390 ⇧B !, ⇧M 1) type 3-set's straight after a Korean word and in the symbols that follow it, and QWERTY's anywhere else (Bob); a switch key right after takes them back to the keys as typed (지냈어? → ldhr2jtB). |
| `japaneseEngine` | `"apple"` | Kanji conversion: `"apple"` uses the engine of macOS's Japanese input, `"azooKey"` the AzooKey converter in the app. |
| `checkForUpdates` | on | Once a day, ask GitHub for the latest release's version (nothing else is sent), and say so in the input menu and About when it is newer. |

With live conversion:

- Space opens the candidate window at the next candidate. With the kana still on screen (`しょう`),
  it opens at the first conversion (`翔`).
- Esc shows the kana. Esc again switches language where Esc is a switch key, else cancels the phrase,
  as macOS's Japanese input does (the app doesn't get it).
- Short readings only change into kanji (`と` stays `と`, `私` converts).
- The top candidate is right for about 4 in 5 short phrases and 3 in 4 whole sentences
  ([held-out results](#held-out-results)), so glance before Return. Conversion takes 8–21 ms a
  keystroke.

</details>

<details>
<summary><code>apps.json</code>: per-app behavior</summary>

`"*"` is your default for every app; an app (by bundle identifier) names only the keys that differ
from it. A key ending in `.` matches as a prefix, the longest one when several do. No app is listed
unless you list it.

```json
{ "*":                     { "switchKeys": ["escape", "shiftEscape"] },
  "com.microsoft.VSCode":  { "switchKeys": ["rightOption", "shiftEscape"] },
  "com.apple.Terminal":    { "conversionThreshold": 0.97 },
  "com.example.Game":      { "enabled": false } }
```

| Key | Default | What it does |
| --- | --- | --- |
| `enabled` | `true` | `false` passes every key through (plain English). |
| `conversionThreshold` | `0.5` | Convert away from the typed letters only when at least this sure. `0.97` (Strict) keeps short shell commands from turning into Hangul in a terminal; `0.5` converts more Korean when you write prose. |
| `switchKeys` | `["rightOption", "shiftEscape"]` | The keys that switch readings ([language switch keys](#language-switch-keys)): `"rightOption"` (right ⌥ tapped alone), `"optionSpace"` (⌥Space), `"rightShift"` (right ⇧ tapped alone), `"escape"` (Esc), `"shiftEscape"` (⇧Esc). A key not chosen goes to the app. `escapeToApp`, from 0.1.8 and earlier, is read and carried over. |
| `holdSpace` | `false` | Space or a punctuation mark (not a digit) goes inside the underline instead of ending the word. Like a word being typed, a switch key changes it and Delete deletes; the next word puts it in with that character. For terminals, which can't change a committed word, so set per app only (not in `"*"`); Return only confirms it, and text replacements don't fire. |
| `fullWidth` | `true` | `false` keeps numbers and spaces half-width in this app whatever the full-width settings say (terminals, code editors). |

</details>

## How it decides

Locally, in this order. A keystroke's preview takes at most ~3 ms and a word's final decision
~7 ms, even 70 letters into a phrase.

1. **Your corrections**: words corrected twice ([learning](#undo-after-commit-and-learning)) always
   win (`dictionary.json`; 0.1.16's `lexicon.json` moves into it when first read). A word corrected
   once only nudges the scores.
2. **Mixed words**: two languages run together, like `github에`, `PDF파일` or `githubで`, are split,
   in an app set to Strict too.
3. **Rules**: what the keys alone settle, like a capital typed with Shift.
4. **Heuristic**: the keys are scored per keystroke in all three languages, plus a nudge toward the
   previous word's language.

None of this happens inside a URL or path. Once a run of text without spaces has a marker like
`://`, `www.` or `~/` at its start, or an `@` with something before it (an email), what follows goes
in as typed, in English with half-width symbols, until the next space (`https://a.io/?q=dl`). A lone
`.` or `/` isn't one (`L.A.로`, `남/여`, `@홍길동`).

<details>
<summary>Each step in detail</summary>

**2. Mixed words**

- **English + particle**, when the end is a Korean particle or ending and reading it that way beats
  reading the whole token as Hangul or as English. The more common the English word (or an acronym
  or name typed in capitals) and the less the whole reads as a Korean word, the likelier the split.
  - `githubdp` → `github에`, `UIrkxdmsrjs` → `UI같은건`, `formdptj` → `form에서` (래그 is no word).
    `gosemfdmf` stays `핸들을`.
  - Of 은/는, 을/를 and 이/가, the form that fits the end of the word before counts as likelier. An
    acronym ends as its last letter is said (`TMdms` → `TM은`, 티엠), and whole Hangul with the wrong
    form (`씨을`) isn't taken as a word + particle.
  - An acronym shaped like a double consonant with a lingering Shift stays Hangul when that reading
    is right too: `TMsms` → `쓰는` (TM takes `은`), `TLdp` → `씨에` (`에` has one form).
- **A single English letter + particle**, as in a variable name: `xdp` → `x에`, `Xfmf` → `X를`. Not
  `도`/`나` after a lowercase letter, which are common English endings (`heh`, `tsk`); a capital gives
  `X도`.
- **English + Korean word**, by the same score comparison as English + particle: when the split
  reading leads reading the token whole.
  - After an acronym or a name typed with its capitals it splits readily: `PDFvkdlf` → `PDF파일`,
    `PCzkxhr` → `PC카톡`, `iPhonevkdlf` → `iPhone파일`.
  - After an ordinary English word, a rarer pair, only when the whole token spells nothing like
    English: `hellodnjfem` → `hello월드`, `githubtjqj` → `github서버`; `cartman` isn't `car스무`.
  - One shaped like a double consonant with a lingering Shift (`EU` is `뗘`) splits only when that
    syllable doesn't exist in Korean and a word from the list follows: `EUwjdcor` → `EU정책`.
    `TMwjdcor` is `쓰정책` (쓰 is a common syllable) and `EUdlswmd` is `뗘인증` (인증 isn't in the
    list); type such acronyms as `TM 정책`, with a space.
- **Korean, then an English word**: `dhsmfdmsgoogledptj` → `오늘은google에서`. The Korean goes in and
  the rest keeps composing.
- **With Japanese on**:
  - English + one case particle, compared the same way with reading the whole as kana:
    `githubde` → `githubで`, `APIwo` → `APIを`, `redde` → `redで`. What reads naturally as Japanese
    stays kana (`sitede` → `してで`).
  - Japanese after Korean: `dlfurrireki` → `이력りれき` (Space for `履歴`)
  - A Korean particle or word after Japanese: `rirekifmf` → `りれき를`, `kyouhaehtlfkrdms` →
    `きょうは도시락은`. The Japanese part is committed on the spot, so with live conversion it goes in
    as `履歴를`, `今日は도시락은`.
  - These split only when the Korean side breaks, so ordinary Japanese phrases stay whole.

**3. Rules**

- Shift on a letter with no shifted jamo (`Hello`, `API`) is English.
- The exception is a Shift that lingers from a double consonant or ㅒ/ㅖ onto the one key right after
  (`djEJs` → `어떤`, `dlTDj` → `있어`, `dPFmf` → `예를`): those go by the scores.
- An acronym typed in capitals throughout (`TM`, `RN`) or a word starting on O or P (`PDFvkdlf` →
  `PDF파일`, `OAuth`) stays English.
- A word with a capital in it is never read as Japanese: as in macOS's Japanese input method, a
  letter typed with ⇧ stays a letter (`O` is `O`, not `お`; `Kyouha` stays as typed).

**4. Heuristic**

- English: character trigrams, and a floor for words in the SCOWL list, by how common they are
- Korean: 2-set syllable frequencies, and a floor for words seen in Korean text
- Japanese: romaji → kana trigrams, with English words inside the phrase split out
- The nudge is weaker when the keys are a word of another language and not of the previous one,
  which is someone switching language.
- A known English word needs a clear Japanese win before it turns into kana.

</details>

**Kanji** come from the conversion engine of macOS's Japanese input (libmecabra), with the top
candidate re-picked by a character trigram model of written Japanese. So variant kanji like `髙`
(`たか`, `たかはし` → `髙橋`), English spellings of names (`とぅいっち` → `Twitch`) and completions
of a partial reading (`ゆーちゅ` → `YouTube`, after the top candidate) come up as in the system's
input. Araso remembers what you pick for each reading and puts it first next time. The engine is
private to macOS, so where it can't be loaded the app's own
[AzooKey](https://github.com/azooKey/AzooKeyKanaKanjiConverter) dictionary converter stands in.

### Held-out results

2,011 English words, 1,987 Korean words and 2,000 Japanese phrases from held-out sentences,
never used to build the models (`tools/prepare.sh`):

| | Japanese off (en/ko) | Japanese on (en/ko/ja) |
| --- | --- | --- |
| Accuracy | 99.82% | 99.50% |

Kanji conversion, top candidate exactly matching the original text (held-out Tatoeba):

| | macOS engine | + reranking | correct one in the list | AzooKey + reranking |
| --- | --- | --- | --- | --- |
| 2–3 word phrases | 74.5% | **81.0%** | 96.2% | 81.0% |
| whole sentences | 71.2% | **74.0%** | 91.5% | 67.2% |

Exact match counts kana/kanji style differences (ひとまとめ vs 一まとめ) as misses.

<details>
<summary>Common words in context: after another language</summary>

The set above counts every word once and seldom puts it after the other language. But real text is
mostly its most frequent words, and switching language mid-sentence is the point, so the 10,000
most frequent English and Korean words are also scored after each kind of word
(`tools/eval_context.py`, Japanese on). Wrong among the top 1,000 / top 10,000:

| | after nothing | after the same language | after the other | after Japanese |
| --- | --- | --- | --- | --- |
| Korean words | 9 / 33 | 2 / 15 | 14 / 63 | 9 / 34 |
| English words | 2 / 47 | 0 / 21 | 8 / 71 | 2 / 86 |

Before the SCOWL and Korean word lists and the switch-aware nudge, that was 94 / 785 in all; now
it is 46 / 370. These lists were used while tuning those rules, so they're a guide, not a
held-out score. Many remaining misses are genuinely ambiguous keys: `so`/내, `go`/해, `did`/양.

</details>

## Known limits

- Never tested end to end in every app.
- Secure fields (passwords) bypass input methods. A masked field that still reaches it (KakaoTalk's
  login, App Store's password sheet) gets the keys as typed, with no word decided.
- Undo after commit needs apps that report their caret and text. In a terminal, set
  `"holdSpace": true` to keep the word underlined after Space or punctuation instead.
- Where Esc is a switch key, Esc right after a word (e.g. to close a popup) changes that word first.
  Once only leans that way; it isn't always written so unless repeated; leave Esc out for such apps in the per-app settings.
- Japanese: only the first clause is resized with ←/→ (Return commits it and moves on to the
  rest). Rare words still need the candidate list.

## Develop

To contribute, start with [CONTRIBUTING.en.md](CONTRIBUTING.en.md). Building needs Xcode 26 or later (Swift 6.2 or later).

```sh
swift test                     # tests: composers, engines, sessions, settings, end to end
scripts/install.sh             # build, self-test and install into ~/Library/Input Methods (development; stops if the pkg's copy is there)
scripts/typing-test/run.sh     # real key events into the settings window's typing pane through the installed Araso
swift scripts/make-readme-logo.swift docs/media  # the README logo (animated SVG)
scripts/release.sh             # universal (arm64 + x86_64) zip and pkg for a release; with a Developer ID also signed and notarized (app and pkg)
tools/prepare.sh               # accuracy (downloads word lists, Tatoeba and SCOWL once)
tools/prepare.sh --models      # rebuild the data in Sources/ArasoCore/Data first (not korean_vocabulary.txt)
ARASO_TIMING=1 swift run -c release araso-cli --decide --japanese < keys.tsv  # + time per decision
swift run araso-cli -v "dkssud gksrmf hello"               # English/Korean, with scores
printf 'kyouhagoogledekensaku\t\n' | swift run araso-cli --decide --japanese
printf 'きょうはいいてんきですね\n' | swift run araso-cli --convert
```

| Path | What |
| --- | --- |
| `Sources/ArasoCore` | composers, engines, conversion, `InputSession` (all typing logic) |
| `Sources/Araso` | InputMethodKit server, a thin controller over `InputSession`, candidate window, settings window |
| `Sources/ArasoCore/Data` | kana and written-Japanese trigrams, Korean syllables and words, English words |
| `tools/` | corpus → romaji, model builders, evaluation set and accuracy (python3, no packages) |
| `windows/`, `linux/` | the Windows (TSF) and Linux (fcitx5) input methods: [docs/windows-port.md](docs/windows-port.md), [docs/linux-port.md](docs/linux-port.md) |

## License and data

Araso is MIT licensed ([LICENSE](LICENSE)). The app carries the licenses of everything compiled
or copied into it in `Contents/Resources/ThirdPartyNotices.txt`, collected by
`scripts/build-app.sh`.

- Kanji conversion: the Japanese engine that ships with macOS, loaded at runtime (not bundled).
- AzooKey Kana-Kanji Converter (the stand-in): MIT; its dictionary: Apache-2.0.
- Tatoeba sentences (kana and written-Japanese models, Korean syllable and word counts;
  evaluation): CC-BY 2.0 FR, https://tatoeba.org.
- English words and how common they are: [SCOWL](http://wordlist.aspell.net) (permissive,
  notice in the app). macOS's `/usr/share/dict/words` trains the letter trigrams at runtime.
- English/Korean frequency lists:
  [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords), CC-BY-SA 4.0. Used
  for evaluation; the full Korean list (words seen at least twice) also ships as
  `korean_vocabulary.txt` (for splitting an English word from a Korean one, and for Korean words
  Tatoeba's sentences lack: 혜택, 닥터, 촉매), under the same license, with its notice in the app.
