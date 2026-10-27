// Real typing through fcitx5: a fcitx5 Instance with the Araso addon (and its Swift bridge) loaded,
// and a text field that behaves as an app does (FakeTextField's part on macOS): it shows the
// preedit, takes commits and deletions around its caret, sends its text as surrounding text, and
// types a key the input method didn't take. Run by `ctest` (linux/tests/CMakeLists.txt sets the
// environment: the addon's folders, a scratch settings folder, the bridge).
#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/candidatelist.h>
#include <fcitx/statusarea.h>
#include <fcitx/action.h>
#include <fcitx/menu.h>
#include <fcitx/userinterfacemanager.h>

#include <dlfcn.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include "Document.h"

using namespace fcitx;

static int failures = 0;
static void Expect(bool ok, const std::string &what, const std::string &got) {
    if (ok) return;
    std::fprintf(stderr, "FAIL %s: got \"%s\"\n", what.c_str(), got.c_str());
    ++failures;
}

/// An app's text field.
class Field : public InputContext {
public:
    Field(InputContextManager &manager, const std::string &program, bool surrounding)
        : InputContext(manager, program), surrounding_(surrounding) {
        created();
        CapabilityFlags flags{CapabilityFlag::Preedit, CapabilityFlag::FormattedPreedit};
        if (surrounding) flags |= CapabilityFlag::SurroundingText;
        setCapabilityFlags(flags);
        sync();
    }
    ~Field() override { destroy(); }
    const char *frontend() const override { return "araso-test"; }

    std::u16string text;
    size_t caret = 0;
    std::string preedit;

    /// What the field shows: its text with the preedit at the caret.
    std::string shown() const {
        return araso::Utf8(text.substr(0, caret)) + preedit + araso::Utf8(text.substr(caret));
    }
    std::string value() const { return araso::Utf8(text); }

    /// A key down and up, as the user presses it; the app's own handling when the input method
    /// doesn't take it.
    void press(KeySym sym, int evdev, KeyStates states = KeyStates()) {
        Key key(sym, states, evdev + 8);
        KeyEvent down(this, key, false);
        if (!keyEvent(down)) typeItself(sym, states);
        KeyEvent up(this, Key(sym, states, evdev + 8), true);
        keyEvent(up);
    }

    void type(const std::string &keys);

protected:
    void commitStringImpl(const std::string &string) override {
        std::u16string inserted = araso::Utf16(string);
        text.insert(caret, inserted);
        caret += inserted.size();
        sync();
    }
    void deleteSurroundingTextImpl(int offset, unsigned int size) override {
        // In characters; this field's text is all one unit per character but emoji.
        long from = static_cast<long>(caret) + offset;
        if (from < 0) from = 0;
        size_t end = std::min(text.size(), static_cast<size_t>(from) + size);
        if (static_cast<size_t>(from) < caret) caret = static_cast<size_t>(from) + (caret > end ? caret - end : 0);
        text.erase(static_cast<size_t>(from), end - static_cast<size_t>(from));
        sync();
    }
    void forwardKeyImpl(const ForwardKeyEvent &) override {}
    void updatePreeditImpl() override { preedit = inputPanel().clientPreedit().toString(); }

private:
    bool surrounding_;

    void sync() {
        if (!surrounding_) return;
        auto cursor = static_cast<unsigned>(CountChars(text.substr(0, caret)));
        surroundingText().setText(araso::Utf8(text), cursor, cursor);
        updateSurroundingText();
    }
    static size_t CountChars(const std::u16string &s) {
        size_t n = 0;
        for (char16_t u : s) if (u < 0xDC00 || u > 0xDFFF) ++n;
        return n;
    }
    void typeItself(KeySym sym, KeyStates states) {
        if (states.test(KeyState::Ctrl) || states.test(KeyState::Alt) || states.test(KeyState::Super)) return;
        if (sym == FcitxKey_BackSpace) {
            if (caret > 0) { text.erase(caret - 1, 1); --caret; }
        } else if (sym == FcitxKey_Return) {
            text.insert(caret++, 1, u'\n');
        } else if (sym >= 0x20 && sym < 0x7F) {
            text.insert(caret++, 1, static_cast<char16_t>(sym));
        } else {
            return;
        }
        sync();
    }
};

/// US keyboard: the evdev code and Shift for each character.
static bool UsKey(char ch, int &code, bool &shift) {
    static const char *rows[] = {"1234567890-=", "qwertyuiop[]", "asdfghjkl;'`", "zxcvbnm,./"};
    static const char *shifted[] = {"!@#$%^&*()_+", "QWERTYUIOP{}", "ASDFGHJKL:\"~", "ZXCVBNM<>?"};
    static const int first[] = {2, 16, 30, 44};
    shift = false;
    if (ch == ' ') { code = 57; return true; }
    for (int row = 0; row < 4; ++row) {
        for (int i = 0; rows[row][i]; ++i) {
            if (rows[row][i] == ch) { code = first[row] + i; return true; }
            if (shifted[row][i] == ch) { code = first[row] + i; shift = true; return true; }
        }
    }
    return false;
}

/// Types `keys`: characters as on a US keyboard; ⏎ Return, ⌫ Backspace, ⎋ Esc, ⌥ a right Alt tap
/// (the switch key), ⌘ a right Ctrl tap (the pause key), → and ← arrows.
void Field::type(const std::string &keys) {
    std::u16string units = araso::Utf16(keys);
    for (char16_t unit : units) {
        switch (unit) {
        case u'⏎': press(FcitxKey_Return, 28); continue;
        case u'⌫': press(FcitxKey_BackSpace, 14); continue;
        case u'⎋': press(FcitxKey_Escape, 1); continue;
        case u'→': press(FcitxKey_Right, 106); continue;
        case u'←': press(FcitxKey_Left, 105); continue;
        case u'⌥': press(FcitxKey_Alt_R, 100); continue;
        case u'⌘': press(FcitxKey_Control_R, 97); continue;
        default: break;
        }
        int code = 0;
        bool shift = false;
        char ch = static_cast<char>(unit);
        if (unit >= 0x80 || !UsKey(ch, code, shift)) continue;
        if (shift) {
            Key down(FcitxKey_Shift_L, KeyStates(), 42 + 8);
            KeyEvent event(this, down, false);
            keyEvent(event);
        }
        press(static_cast<KeySym>(static_cast<unsigned char>(ch)), code, shift ? KeyStates(KeyState::Shift) : KeyStates());
        if (shift) {
            KeyEvent event(this, Key(FcitxKey_Shift_L, KeyStates{KeyState::Shift}, 42 + 8), true);
            keyEvent(event);
        }
    }
}

struct Case {
    std::string name;
    std::function<void(Instance &)> run;
};

/// Each case starts with what a new user has: no settings, an empty dictionary.
static void WriteSettings(const std::string &json);
static void Fresh() {
    std::remove((std::string(std::getenv("ARASO_SUPPORT_DIR")) + "/dictionary.json").c_str());
    WriteSettings("{}");
}

static Field *Open(Instance &instance, const std::string &program, bool surrounding = true) {
    auto *field = new Field(instance.inputContextManager(), program, surrounding);
    field->focusIn();
    instance.setCurrentInputMethod(field, "araso", true);
    return field;
}

static void Check(Field *field, const std::string &what, const std::string &expected) {
    Expect(field->shown() == expected, what + " → \"" + expected + "\"", field->shown());
}

/// Writes settings.json and has the running bridge read it again, as the settings window's notice
/// does (the addon loaded the same library: dlopen hands back that one).
static void WriteSettings(const std::string &json) {
    const char *dir = std::getenv("ARASO_SUPPORT_DIR");
    std::ofstream(std::string(dir) + "/settings.json") << json;
    void *bridge = dlopen(std::getenv("ARASO_BRIDGE"), RTLD_NOW | RTLD_NOLOAD);
    auto request = bridge ? reinterpret_cast<char *(*)(const char *)>(dlsym(bridge, "araso_request")) : nullptr;
    auto release = bridge ? reinterpret_cast<void (*)(char *)>(dlsym(bridge, "araso_free")) : nullptr;
    if (request && release) release(request(R"({"op":"reload"})"));
}

int main(int argc, char **argv) {
    char arg0[] = "araso-typing-tests";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=araso,keyboard";
    char *args[] = {arg0, arg1, arg2};
    Instance instance(3, args);
    instance.addonManager().registerDefaultLoader(nullptr);

    std::vector<Case> cases = {
        {"Korean and English decided per word", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssud hello ");
             Check(field, "dkssud hello ", "안녕 hello ");
             delete field;
         }},
        {"the word is underlined while typed", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssud");
             Expect(field->preedit == "안녕" && field->value().empty(), "preedit 안녕, nothing in the field", field->preedit);
             field->type(" ");
             Check(field, "then Space", "안녕 ");
             delete field;
         }},
        {"an app that sends no surrounding text", [](Instance &instance) {
             auto *field = Open(instance, "xterm", false);
             field->type("dkssudgktpdy. hello world");
             // Return on an underlined word only confirms it (returnConfirmsOnly); a second one goes to the app.
             field->type("⏎");
             Check(field, "dkssudgktpdy. hello world⏎", "안녕하세요. hello world");
             field->type("⏎");
             Check(field, "and ⏎ again", "안녕하세요. hello world\n");
             delete field;
         }},
        {"the switch key while typing", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssud⌥ ");
             Check(field, "dkssud ⌥ Space", "dkssud ");
             delete field;
         }},
        {"the switch key right after the word", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssud ⌥");
             Check(field, "dkssud Space ⌥", "dkssud ");
             field->type("hello ");
             Check(field, "then hello", "dkssud hello ");
             delete field;
         }},
        {"Backspace while composing", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssuf⌫d ");
             Check(field, "dkssuf⌫d ", "안녕 ");
             delete field;
         }},
        {"English with a Korean particle", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("githubdp ");
             Check(field, "githubdp ", "github에 ");
             delete field;
         }},
        {"the pause key", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("⌘dkssud ⌘dkssud ");
             Check(field, "paused, then not", "dkssud 안녕 ");
             delete field;
         }},
        {"Return after a word confirms it", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             field->type("dkssud⏎");
             Check(field, "dkssud⏎", "안녕");
             delete field;
         }},
        {"the menu lists the Mac items", [](Instance &instance) {
             auto *field = Open(instance, "gedit");
             auto *action = instance.userInterfaceManager().lookupAction("araso-menu");
             bool found = false;
             std::string titles;
             if (action && action->menu()) {
                 for (auto *item : action->menu()->actions()) {
                     titles += item->shortText(field) + "|";
                     if (item->shortText(field).find("Japanese Input") != std::string::npos) found = true;
                 }
             }
             Expect(found, "menu has Japanese Input", titles);
             delete field;
         }},
        {"Japanese: kana, then kanji in the card", [](Instance &instance) {
             WriteSettings(R"({"japanese": true})");
             auto *field = Open(instance, "gedit");
             field->type("kyouha");
             Expect(field->preedit == "きょうは", "preedit きょうは", field->preedit);
             field->type(" ");
             auto list = field->inputPanel().candidateList();
             Expect(list && list->size() > 0, "candidates after Space", field->preedit);
             field->type("⏎");
             Check(field, "kyouha Space ⏎", "今日は");
             delete field;
         }},
    };

    instance.eventLoop().addTimeEvent(CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 1000, 0,
                                      [&](EventSourceTime *, uint64_t) {
        auto group = instance.inputMethodManager().currentGroup();
        group.inputMethodList().clear();
        group.inputMethodList().push_back(InputMethodGroupItem("keyboard-us"));
        group.inputMethodList().push_back(InputMethodGroupItem("araso"));
        group.setDefaultInputMethod("keyboard-us");
        instance.inputMethodManager().setGroup(group);
        std::string only = argc > 1 ? argv[1] : "";
        for (auto &c : cases) {
            if (!only.empty() && c.name.find(only) == std::string::npos) continue;
            int before = failures;
            Fresh();
            c.run(instance);
            std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", c.name.c_str());
        }
        instance.exit();
        return true;
    }).release();
    instance.exec();
    if (failures) std::fprintf(stderr, "%d failed\n", failures);
    return failures ? 1 : 0;
}
