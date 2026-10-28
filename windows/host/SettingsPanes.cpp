// The Languages, Keys and Apps panes (SettingsWindow.swift's on macOS).
#include "SettingsInternal.h"

#include <tlhelp32.h>
#include <windowsx.h>

#include <algorithm>
#include <cctype>
#include <set>

namespace araso {
namespace settings {

namespace {

const char *kLatinLayouts[] = {"qwerty", "colemak", "colemakDH"};
const wchar_t *kLatinNames[] = {L"QWERTY", L"Colemak", L"Colemak-DH"};

int LatinIndex(const std::string &layout) {
    for (int k = 0; k < 3; k++) if (layout == kLatinLayouts[k]) return k;
    return 0;
}

const char *kKoreanLayouts[] = {"dubeolsik", "sebeolsikFinal", "sebeolsik390"};

int KoreanIndex(const std::string &layout) {
    for (int k = 0; k < 3; k++) if (layout == kKoreanLayouts[k]) return k;
    return 0;
}

double Strict() { return g.model["strictThreshold"].asNumber(0.97); }

}  // namespace

// MARK: - Languages

void BuildLanguages() {
    const Json &settings = g.model["settings"];
    const Json &policy = g.model["defaultPolicy"];
    bool japanese = settings["japanese"].asBool();

    Heading(L("Languages"));
    Check(L("Convert words"), policy["enabled"].asBool(true), true, [](bool on) {
        ChangeDefault([on](Json &p) { p.set("enabled", on); });
    });
    Note(L("Off: keys go to the app as typed, as with the ABC layout. Apps can differ, under Apps."), S(20));
    Make(L"STATIC", L("Korean · English") + L"   —   " + L("Always on"), SS_NOPREFIX, Pad() + S(20), g.y,
         ContentWidth() - S(20), S(22), g.font);
    g.y += S(28);
    Check(L("Japanese"), japanese, true, [](bool on) { ChangeSettings([on](Json &s) { s.set("japanese", on); }); });
    Note(L("Type Japanese with romaji; Space converts to kanji."), S(20));

    Heading(L("Layouts"));
    Combo(L("Hangul"), {L("2-set"), L("3-set final"), L("3-set 390")}, KoreanIndex(settings["koreanLayout"].asString()),
          true, [](int index) {
              ChangeSettings([index](Json &s) { s.set("koreanLayout", kKoreanLayouts[std::max(0, index)]); });
          });
    Note(L("3-set types jamo on the digit and symbol keys too; a number on its own stays a number."), S(160));
    int latin = LatinIndex(settings["latinLayout"].asString());
    Combo(L("English letters"), {kLatinNames[0], kLatinNames[1], kLatinNames[2]}, latin, true, [](int index) {
        ChangeSettings([index](Json &s) { s.set("latinLayout", kLatinLayouts[std::max(0, index)]); });
    });
    const Json &romaji = settings["japaneseLayout"];
    int romajiIndex = romaji.isString() ? LatinIndex(romaji.asString()) + 1 : 0;
    Combo(L("Romaji"), {L("Same as English (%@)", {kLatinNames[latin]}), kLatinNames[0], kLatinNames[1], kLatinNames[2]},
          romajiIndex, japanese, [](int index) {
              ChangeSettings([index](Json &s) {
                  if (index <= 0) s.remove("japaneseLayout");
                  else s.set("japaneseLayout", kLatinLayouts[index - 1]);
              });
          });
    Note(L("Used with Japanese on."), S(160));

    Heading(L("Japanese input"));
    Check(L("Live conversion"), settings["liveConversion"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("liveConversion", on); }); });
    Note(L("Shows the top kanji candidate as you type."), S(20));
    Check(L("Full-width numbers"), settings["fullWidthDigits"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("fullWidthDigits", on); }); });
    Note(L("１２３ after Japanese; Space offers 123."), S(20));
    Check(L("Full-width space"), settings["fullWidthSpace"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("fullWidthSpace", on); }); });
    Note(L("A full-width space after Japanese; Shift+Space types the other width."), S(20));
    Make(L"STATIC", L("Kanji candidate order"), SS_NOPREFIX | SS_CENTERIMAGE, Pad(), g.y, S(200), S(28), g.font);
    Push(L("Reset…"), Pad() + S(210), S(120), [] {
        if (!Confirm(L("Reset the kanji candidate order?"),
                     L("Kanji you picked before won't come first anymore. Remembered words stay."))) return;
        Json change = Json::object();
        change.set("resetKanji", true);
        Apply(change, true);
    }, japanese);
    g.y += S(32);
    Note(L("Kanji you pick come first next time."));
}

// MARK: - Keys

void BuildKeys() {
    const Json &settings = g.model["settings"];
    const Json &policy = g.model["defaultPolicy"];
    const Json &keys = policy["switchKeys"];
    const Json &pause = settings["pauseKey"];
    // The switch key the pause key takes, if any: the two are never chosen together.
    std::string taken;
    if (pause.isString()) {
        if (pause.asString() == "rightOption") taken = "rightOption";
        if (pause.asString() == "rightShift") taken = "rightShift";
    } else if (pause.isObject() && pause["keyCode"].asInt() == 49 && pause["modifiers"].size() == 1 &&
               pause["modifiers"][0].asString() == "option") {
        taken = "optionSpace";
    }

    Heading(L("Switch a word's language"));
    Note(L("Turns the word being typed, or the one just typed, into the next reading. Choose one or more."));
    for (const auto &info : kSwitchKeys) {
        std::string id = info.id;
        Check(L(info.name), HasKey(keys, id), taken != id, [id](bool on) {
            ChangeDefault([id, on](Json &p) { p.set("switchKeys", WithKey(p["switchKeys"], id, on)); });
        });
        Note(taken == id ? L("This key pauses. Choose another pause key first.") : L(info.note), S(20));
    }
    std::wstring names = KeyNames(keys);
    if (names.empty()) Note(L("Nothing switches a word's language."));
    else if (keys.size() == 5) Note(L("All of these switch languages."));
    else Note(L("Switching: %@. The others go to the app as usual.", {names}));
    Note(L("A right Alt or Shift tap with other modifiers is left to what it's bound to."));

    Heading(L("Apps with their own keys"));
    int own = 0;
    for (const Json &app : g.model["apps"].items()) if (app["entry"]["switchKeys"].isArray()) own++;
    Note(own == 0 ? L("Every app uses these keys.") : own == 1 ? L("One app uses its own keys.")
                                                              : L("%ld apps use their own keys.", {std::to_wstring(own)}));
    Push(L("Set in Apps…"), Pad(), S(180), [] { ShowPane(2); });
    g.y += S(36);

    Heading(L("Other keys"));
    Check(L("Return only confirms"), settings["returnConfirmsOnly"].asBool(true), true,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("returnConfirmsOnly", on); }); });
    Note(L("Return on an underlined word confirms it; press it again for a new line. Japanese is always only confirmed."), S(20));

    Heading(L("Pause"));
    // Off, the right-hand taps (Ctrl plays ⌘'s part on Windows), and a recorded shortcut.
    std::vector<std::wstring> items = {L("Off"), L("Right Ctrl tap (한자 on Korean keyboards)"), L("Right Alt tap"),
                                       L("Right Shift tap"), L("Right Win tap")};
    const char *taps[] = {"off", "rightCommand", "rightOption", "rightShift", "rightControl"};
    for (int k = 2; k <= 3; k++) {
        if (HasKey(keys, taps[k])) items[k] = L("%@ — switches languages", {items[k]});
    }
    int selected = 0;
    if (pause.isString()) {
        for (int k = 0; k < 5; k++) if (pause.asString() == taps[k]) selected = k;
    } else if (pause.isObject()) {
        std::wstring name;
        for (const Json &modifier : pause["modifiers"].items()) {
            std::string m = modifier.asString();
            name += m == "command" ? L"Ctrl+" : m == "option" ? L"Alt+" : m == "shift" ? L"Shift+" : L"Win+";
        }
        items.push_back(name + Wide(pause["key"].asString()));
        selected = static_cast<int>(items.size()) - 1;
    }
    Combo(L("Pause"), items, selected, true, [taps, selected](int index) {
        if (index < 0 || index > 4 || index == selected) return;
        std::string tap = taps[index];
        ChangeSettings([tap](Json &s) { s.set("pauseKey", tap); });
    });
    Push(L("Record Shortcut…"), Pad() + S(160), S(180), [] {
        Dialog dialog(L("Type a shortcut"), 360, 150);
        HWND field = dialog.Add(L"STATIC", L("Type a shortcut"), SS_CENTER | SS_CENTERIMAGE | WS_BORDER | SS_NOTIFY,
                                20, 16, 320, 48, nullptr, g.bold);
        HWND hint = dialog.Add(L"STATIC", L("Add Ctrl, Alt or Win: without one the key types. F-keys can go alone.") +
                                              L" " + L("Press Esc to cancel."),
                               SS_NOPREFIX, 20, 72, 320, 48, nullptr, g.fine);
        WithoutInputMethod(field);
        Json chosen;
        dialog.TakeKeys(field, [&](WPARAM vk, LPARAM lParam) {
            if (vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_LWIN || vk == VK_RWIN) return true;
            bool modified = GetKeyState(VK_CONTROL) < 0 || GetKeyState(VK_MENU) < 0 || GetKeyState(VK_LWIN) < 0 ||
                            GetKeyState(VK_RWIN) < 0 || GetKeyState(VK_SHIFT) < 0;
            if (vk == VK_ESCAPE && !modified) { dialog.Close(false); return true; }
            Json key = Json::object();
            key.set("vk", static_cast<int>(vk));
            key.set("scan", static_cast<int>((lParam >> 16) & 0xFF));
            key.set("extended", ((lParam >> 24) & 1) != 0);
            key.set("shift", GetKeyState(VK_SHIFT) < 0);
            key.set("ctrl", GetKeyState(VK_CONTROL) < 0);
            key.set("alt", GetKeyState(VK_MENU) < 0);
            key.set("win", GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0);
            key.set("capsLock", false);
            Json request = Json::object();
            request.set("op", "shortcut");
            request.set("key", key);
            Json answer = Request(request);
            std::wstring name = Wide(answer["shortcutName"].asString());
            std::string problem = answer["problem"].asString();
            SetWindowTextW(field, name.c_str());
            if (!answer["shortcut"].isObject()) return true;
            if (problem == "types") {
                SetWindowTextW(hint, L("Add Ctrl, Alt or Win: without one the key types. F-keys can go alone.").c_str());
            } else if (problem == "arasos") {
                SetWindowTextW(hint, L("%@ types hiragana or katakana.", {name}).c_str());
            } else if (problem == "switchKey") {
                SetWindowTextW(hint, L("%@ switches a word's language. Turn that off first.", {name}).c_str());
            } else {
                chosen = answer["shortcut"];
                dialog.Close(true);
            }
            return true;
        });
        if (dialog.Run() && chosen.isObject()) ChangeSettings([chosen](Json &s) { s.set("pauseKey", chosen); });
    });
    g.y += S(36);
    Note(L("Keys go through as typed in that text field, for hjkl in terminal programs. Press it again to resume."));
}

// MARK: - Apps

namespace {

/// A per-app value as the list shows it: the entry's own, or the default's after "Default ·".
std::wstring Value(const Json &entry, const char *key, const std::wstring &own, const std::wstring &fallback) {
    return entry[key].isNull() ? L("Default · %@", {fallback}) : own;
}

std::wstring OnOff(bool on) { return on ? L("On") : L("Off"); }

std::vector<std::wstring> RunningApps() {
    std::set<std::wstring> names;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W entry = {sizeof entry};
        DWORD session = 0;
        ProcessIdToSessionId(GetCurrentProcessId(), &session);
        for (BOOL ok = Process32FirstW(snapshot, &entry); ok; ok = Process32NextW(snapshot, &entry)) {
            DWORD theirs = 0;
            if (!ProcessIdToSessionId(entry.th32ProcessID, &theirs) || theirs != session) continue;
            std::wstring name = entry.szExeFile;
            CharLowerBuffW(name.data(), static_cast<DWORD>(name.size()));
            if (name.size() > 4 && name.compare(name.size() - 4, 4, L".exe") == 0) names.insert(name);
        }
        CloseHandle(snapshot);
    }
    return {names.begin(), names.end()};
}

void AddApp() {
    Dialog dialog(L("Add App…"), 380, 330);
    dialog.Add(L"STATIC", L("Add an app by its program name, such as notepad.exe."), SS_NOPREFIX, 20, 14, 340, 36);
    dialog.Add(L"STATIC", L("Program name"), SS_NOPREFIX, 20, 54, 340, 20);
    HWND name = dialog.Add(WC_EDITW, L"", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL, 20, 74, 340, 26);
    dialog.Add(L"STATIC", L("Running apps"), SS_NOPREFIX, 20, 108, 340, 20);
    HWND list = dialog.Add(WC_LISTBOXW, L"", WS_BORDER | WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY, 20, 128, 340, 140,
                           [&name](HWND control, int code) {
                               if (code != LBN_SELCHANGE) return;
                               int index = ListBox_GetCurSel(control);
                               wchar_t text[260] = L"";
                               if (index >= 0 && ListBox_GetTextLen(control, index) < 260) ListBox_GetText(control, index, text);
                               SetWindowTextW(name, text);
                           });
    for (const auto &app : RunningApps()) ListBox_AddString(list, app.c_str());
    dialog.Add(L"BUTTON", L("Cancel"), BS_PUSHBUTTON | WS_TABSTOP, 160, 284, 96, 28, [&dialog](HWND, int) { dialog.Close(false); });
    dialog.Add(L"BUTTON", L("Add"), BS_DEFPUSHBUTTON | WS_TABSTOP, 264, 284, 96, 28, [&dialog](HWND, int) { dialog.Close(true); });
    WithoutInputMethod(name);
    SetFocus(name);
    if (!dialog.Run()) return;
    wchar_t text[260] = L"";
    GetWindowTextW(name, text, 260);
    std::string app = Utf8(text);
    while (!app.empty() && app.back() == ' ') app.pop_back();
    if (app.empty()) return;
    std::transform(app.begin(), app.end(), app.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    g.selectedApp = app;
    Json change = Json::object();
    change.set("app", app);
    change.set("entry", Json::object());
    Apply(change);
}

}  // namespace

void BuildApps() {
    const Json &policy = g.model["defaultPolicy"];
    bool strict = policy["conversionThreshold"].asNumber(0.5) >= Strict();
    Heading(L("Default — every app"));
    if (!policy["enabled"].asBool(true)) Note(L("Convert words is off under Languages, so nothing converts."));
    Combo(L("Conversion"), {L("Normal"), L("Strict")}, strict ? 1 : 0, true, [](int index) {
        ChangeDefault([index](Json &p) { p.set("conversionThreshold", index == 1 ? Strict() : 0.5); });
    });
    Note(strict ? L("Converts only words that are clearly Korean or Japanese, so short commands stay as typed (gst stays gst). For terminals.")
                : L("Converts a word when it reads more like Korean or Japanese than English (gst → ㅎㄴㅅ)."));

    Heading(L("Exceptions — only apps that differ"));
    const Json &apps = g.model["apps"];
    if (apps.size() == 0) Note(L("None. Add an app that should work differently."));
    HWND list = List({{L("App"), 150}, {L("Convert words"), 110}, {L("Conversion"), 110}, {L("Japanese"), 90},
                      {L("Switch keys"), 150}, {L("After Space / punctuation"), 130}}, S(150));
    std::wstring defaultConversion = strict ? L("Strict") : L("Normal");
    // An app's Japanese follows the settings' Japanese unless its entry names its own.
    bool japaneseOn = g.model["settings"]["japanese"].asBool(false);
    int row = 0, selectedRow = -1;
    std::vector<std::string> names;
    for (const Json &item : apps.items()) {
        const Json &entry = item["entry"];
        const Json &own = item["policy"];
        std::string app = item["app"].asString();
        names.push_back(app);
        std::wstring keys = KeyNames(own["switchKeys"]);
        Row(list, row, {Wide(app), Value(entry, "enabled", OnOff(own["enabled"].asBool(true)), OnOff(policy["enabled"].asBool(true))),
                        Value(entry, "conversionThreshold", own["conversionThreshold"].asNumber() >= Strict() ? L("Strict") : L("Normal"), defaultConversion),
                        Value(entry, "japanese", OnOff(own["japanese"].asBool(japaneseOn)), OnOff(japaneseOn)),
                        Value(entry, "switchKeys", keys.empty() ? L("None — can't switch") : keys, KeyNames(policy["switchKeys"])),
                        Value(entry, "holdSpace", own["holdSpace"].asBool() ? L("Hold") : L("Finish"), L("Finish"))});
        if (app == g.selectedApp) selectedRow = row;
        row++;
    }
    if (selectedRow < 0 && !names.empty()) {
        selectedRow = 0;
        g.selectedApp = names[0];
    }
    if (selectedRow >= 0) ListView_SetItemState(list, selectedRow, LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
    int listId = GetDlgCtrlID(list);
    g.notifies[listId] = [names](NMHDR *header) {
        if (header->code != LVN_ITEMCHANGED) return;
        auto *change = reinterpret_cast<NMLISTVIEW *>(header);
        if (!(change->uNewState & LVIS_SELECTED) || change->iItem < 0 || change->iItem >= static_cast<int>(names.size())) return;
        if (g.selectedApp != names[change->iItem]) {
            g.selectedApp = names[change->iItem];
            Rebuild();
        }
    };
    Push(L("Add App…"), Pad(), S(140), AddApp);
    Push(L("Remove"), Pad() + S(150), S(110), [] {
        if (g.selectedApp.empty()) return;
        Json change = Json::object();
        change.set("removeApp", g.selectedApp);
        g.selectedApp.clear();
        Apply(change);
    }, !g.selectedApp.empty());
    g.y += S(38);
    if (g.selectedApp.empty()) return;

    // The selected app: each value its own or the default's.
    std::string app = g.selectedApp;
    Json entry = AppEntry(app);
    Heading(Wide(app));
    Note(L("Grey values follow the default; anything else applies to this app only."));
    auto tri = [&](const char *key, const std::wstring &label, const std::wstring &fallback, const std::wstring &on,
                   const std::wstring &off, Json onValue, Json offValue) {
        const Json &value = entry[key];
        int selected = value.isNull() ? 0 : (value.dump() == onValue.dump() ? 1 : 2);
        if (std::string(key) == "conversionThreshold" && !value.isNull()) selected = value.asNumber() >= Strict() ? 1 : 2;
        std::string name = key;
        Combo(label, {L("Default (%@)", {fallback}), on, off}, selected, true, [app, name, onValue, offValue](int index) {
            ChangeApp(app, [&](Json &e) {
                if (index <= 0) e.remove(name);
                else e.set(name, index == 1 ? onValue : offValue);
            });
        }, S(20));
    };
    tri("enabled", L("Convert words"), OnOff(policy["enabled"].asBool(true)), L("On"), L("Off"), Json(true), Json(false));
    tri("conversionThreshold", L("Conversion"), defaultConversion, L("Strict"), L("Normal"), Json(Strict()), Json(0.5));
    tri("japanese", L("Japanese"), OnOff(japaneseOn), L("On"), L("Off"), Json(true), Json(false));
    Note(L("Off: words here are Korean or English only, as with Japanese off. On: Japanese here even when it is off under Languages."), S(20));
    tri("holdSpace", L("After Space / punctuation"), L("Finish"), L("Hold"), L("Finish"), Json(true), Json(false));
    tri("fullWidth", L("Full-width"), L("On"), L("On"), L("Off"), Json(true), Json(false));
    Note(L("Hold: Space or punctuation goes inside the underline, so the word can still be changed until the next word starts. For terminals."), S(20));

    const Json &own = entry["switchKeys"];
    bool custom = own.isArray();
    Combo(L("Switch keys"), {L("Default (%@)", {KeyNames(policy["switchKeys"])}), L("Custom")}, custom ? 1 : 0, true,
          [app](int index) {
              ChangeApp(app, [index](Json &e) {
                  if (index == 0) e.remove("switchKeys");
                  else e.set("switchKeys", g.model["defaultPolicy"]["switchKeys"]);
              });
          }, S(20));
    if (custom) {
        for (const auto &info : kSwitchKeys) {
            std::string id = info.id;
            Check(L(info.name), HasKey(own, id), true, [app, id](bool on) {
                ChangeApp(app, [id, on](Json &e) { e.set("switchKeys", WithKey(e["switchKeys"], id, on)); });
            }, S(180));
        }
    }
}

}  // namespace settings
}  // namespace araso
