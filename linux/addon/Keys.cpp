#include "Keys.h"

#include <fcitx-utils/keysym.h>

#include <cctype>
#include <cstring>

namespace araso {

namespace {

// Virtual keys (winuser.h), as KeyMapper names them.
enum : int {
    vkBack = 0x08, vkTab = 0x09, vkReturn = 0x0D, vkPause = 0x13, vkCapital = 0x14, vkHangul = 0x15,
    vkHanja = 0x19, vkEscape = 0x1B, vkSpace = 0x20, vkPrior = 0x21, vkNext = 0x22, vkEnd = 0x23,
    vkHome = 0x24, vkLeft = 0x25, vkUp = 0x26, vkRight = 0x27, vkDown = 0x28, vkInsert = 0x2D,
    vkDelete = 0x2E, vkLWin = 0x5B, vkRWin = 0x5C, vkApps = 0x5D, vkNumpad0 = 0x60, vkMultiply = 0x6A,
    vkAdd = 0x6B, vkSubtract = 0x6D, vkDecimal = 0x6E, vkDivide = 0x6F, vkF1 = 0x70, vkF13 = 0x7C,
    vkNumLock = 0x90, vkScroll = 0x91, vkLShift = 0xA0, vkRShift = 0xA1, vkLControl = 0xA2,
    vkRControl = 0xA3, vkLMenu = 0xA4, vkRMenu = 0xA5,
};

struct Code {
    int vk;
    int scan;
    bool extended;
};

/// evdev code → virtual key, scan code (set 1) and whether Windows marks it extended. The main
/// block's scan code is the evdev code; its virtual key matters only for the keys KeyMapper reads
/// by it (Return, Esc, Space, F-keys, modifiers…), so letters and symbols carry their US letter or 0.
bool Lookup(int evdev, Code &code) {
    static const char *const kUs = "\0\0" "1234567890-=\0\0" "QWERTYUIOP[]\0\0" "ASDFGHJKL;'`\0\\" "ZXCVBNM,./";
    if (evdev >= 1 && evdev <= 0x58) {
        code = {0, evdev, false};
        switch (evdev) {
        case 1: code.vk = vkEscape; break;
        case 14: code.vk = vkBack; break;
        case 15: code.vk = vkTab; break;
        case 28: code.vk = vkReturn; break;
        case 29: code.vk = vkLControl; break;
        case 42: code.vk = vkLShift; break;
        case 54: code.vk = vkRShift; break;
        case 55: code.vk = vkMultiply; break;
        case 56: code.vk = vkLMenu; break;
        case 57: code.vk = vkSpace; break;
        case 58: code.vk = vkCapital; break;
        case 69: code.vk = vkNumLock; break;
        case 70: code.vk = vkScroll; break;
        case 74: code.vk = vkSubtract; break;
        case 78: code.vk = vkAdd; break;
        case 87: code.vk = vkF1 + 10; break;
        case 88: code.vk = vkF1 + 11; break;
        default:
            if (evdev >= 59 && evdev <= 68) code.vk = vkF1 + (evdev - 59);
            else if (evdev < 0x36 && kUs[evdev] && std::isalnum(static_cast<unsigned char>(kUs[evdev])))
                code.vk = kUs[evdev];
        }
        return true;
    }
    switch (evdev) {
    case 96: code = {vkReturn, 0x1C, true}; return true;   // keypad Enter
    case 97: code = {vkRControl, 0x1D, true}; return true;
    case 98: code = {vkDivide, 0x35, true}; return true;
    case 100: code = {vkRMenu, 0x38, true}; return true;    // right Alt (AltGr)
    case 102: code = {vkHome, 0x47, true}; return true;
    case 103: code = {vkUp, 0x48, true}; return true;
    case 104: code = {vkPrior, 0x49, true}; return true;
    case 105: code = {vkLeft, 0x4B, true}; return true;
    case 106: code = {vkRight, 0x4D, true}; return true;
    case 107: code = {vkEnd, 0x4F, true}; return true;
    case 108: code = {vkDown, 0x50, true}; return true;
    case 109: code = {vkNext, 0x51, true}; return true;
    case 110: code = {vkInsert, 0x52, true}; return true;
    case 111: code = {vkDelete, 0x53, true}; return true;
    case 119: code = {vkPause, 0x45, false}; return true;
    case 122: code = {vkHangul, 0x72, false}; return true;  // 한/영
    case 123: code = {vkHanja, 0x71, false}; return true;   // 한자
    case 125: code = {vkLWin, 0x5B, true}; return true;
    case 126: code = {vkRWin, 0x5C, true}; return true;
    case 127: code = {vkApps, 0x5D, true}; return true;
    default: break;
    }
    if (evdev >= 183 && evdev <= 190) {  // F13–F20
        code = {vkF13 + (evdev - 183), 0x64 + (evdev - 183), false};
        return true;
    }
    return false;
}

/// A key with no code (a virtual keyboard, a test): its place on a US keyboard, from what it types.
bool FromSym(fcitx::KeySym sym, Code &code) {
    static const char *const kRows[] = {"1234567890-=", "qwertyuiop[]", "asdfghjkl;'`", "zxcvbnm,./"};
    static const char *const kShifted[] = {"!@#$%^&*()_+", "QWERTYUIOP{}", "ASDFGHJKL:\"~", "ZXCVBNM<>?"};
    static const int kFirst[] = {2, 16, 30, 44};
    if (sym >= 0x20 && sym < 0x7F) {
        char ch = static_cast<char>(sym);
        if (ch == ' ') return Lookup(57, code);
        if (ch == '\\' || ch == '|') return Lookup(43, code);
        for (int row = 0; row < 4; ++row) {
            const char *at = std::strchr(kRows[row], ch);
            if (!at || !*at) at = std::strchr(kShifted[row], ch);
            if (at && *at) {
                const char *base = std::strchr(kRows[row], ch) ? kRows[row] : kShifted[row];
                return Lookup(kFirst[row] + static_cast<int>(at - base), code);
            }
        }
        return false;
    }
    switch (sym) {
    case FcitxKey_BackSpace: return Lookup(14, code);
    case FcitxKey_Tab: return Lookup(15, code);
    case FcitxKey_Return: return Lookup(28, code);
    case FcitxKey_Escape: return Lookup(1, code);
    case FcitxKey_Left: return Lookup(105, code);
    case FcitxKey_Right: return Lookup(106, code);
    case FcitxKey_Up: return Lookup(103, code);
    case FcitxKey_Down: return Lookup(108, code);
    case FcitxKey_Shift_L: return Lookup(42, code);
    case FcitxKey_Shift_R: return Lookup(54, code);
    case FcitxKey_Control_L: return Lookup(29, code);
    case FcitxKey_Control_R: return Lookup(97, code);
    case FcitxKey_Alt_L: return Lookup(56, code);
    case FcitxKey_Alt_R: case FcitxKey_ISO_Level3_Shift: return Lookup(100, code);
    case FcitxKey_Super_L: return Lookup(125, code);
    case FcitxKey_Super_R: return Lookup(126, code);
    case FcitxKey_Hangul: return Lookup(122, code);
    case FcitxKey_Hangul_Hanja: return Lookup(123, code);
    case FcitxKey_Caps_Lock: return Lookup(58, code);
    default: break;
    }
    if (sym >= FcitxKey_F1 && sym <= FcitxKey_F10) return Lookup(59 + static_cast<int>(sym - FcitxKey_F1), code);
    if (sym == FcitxKey_F11) return Lookup(87, code);
    if (sym == FcitxKey_F12) return Lookup(88, code);
    return false;
}

/// The keys that type characters on a PC keyboard (evdev), keypad aside.
bool IsCharacterSeat(int evdev) {
    return (evdev >= 2 && evdev <= 13) || (evdev >= 16 && evdev <= 27) || (evdev >= 30 && evdev <= 41) ||
           (evdev >= 43 && evdev <= 53) || evdev == 57 || evdev == 86;
}

bool IsKeypad(int evdev) { return evdev == 55 || (evdev >= 71 && evdev <= 83) || evdev == 96 || evdev == 98; }

}  // namespace

Json WindowsKey(const fcitx::Key &key) {
    Code code{};
    int evdev = key.code() - 8;
    bool found = key.code() > 8 ? Lookup(evdev, code) : false;
    // A character on a key that types none on a keyboard: a virtual keyboard with a keymap of its
    // own (wtype's). Placed by what it types instead.
    if (found && key.sym() > 0x20 && key.sym() < 0x7F && !IsCharacterSeat(evdev) && !IsKeypad(evdev)) found = false;
    if (!found && !FromSym(key.sym(), code)) return Json();
    fcitx::KeySym sym = key.sym();
    // Where the desktop's layout makes a key 한/영 or 한자 (korean:ralt_hangul…), it is that key.
    if (sym == FcitxKey_Hangul) code = {vkHangul, 0x72, false};
    if (sym == FcitxKey_Hangul_Hanja) code = {vkHanja, 0x71, false};
    // The keypad: digits while NumLock is on (its keysyms say so), else the keys printed under them.
    if (sym >= FcitxKey_KP_0 && sym <= FcitxKey_KP_9) code.vk = vkNumpad0 + static_cast<int>(sym - FcitxKey_KP_0);
    else if (sym == FcitxKey_KP_Decimal) code.vk = vkDecimal;
    auto states = key.states();
    Json out = Json::object();
    out.set("vk", code.vk);
    out.set("scan", code.scan);
    out.set("extended", code.extended);
    out.set("shift", states.test(fcitx::KeyState::Shift));
    out.set("ctrl", states.test(fcitx::KeyState::Ctrl));
    out.set("alt", states.test(fcitx::KeyState::Alt));
    out.set("win", states.test(fcitx::KeyState::Super) || states.test(fcitx::KeyState::Super2));
    out.set("capsLock", states.test(fcitx::KeyState::CapsLock));
    return out;
}

bool IsModifier(const fcitx::Key &key) {
    Json mapped = WindowsKey(key);
    int vk = mapped["vk"].asInt();
    return vk == vkLShift || vk == vkRShift || vk == vkLControl || vk == vkRControl || vk == vkLMenu ||
           vk == vkRMenu || vk == vkLWin || vk == vkRWin;
}

}  // namespace araso
