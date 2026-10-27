// fcitx5 keys as the WindowsKey KeyMapper reads.
#include "Keys.h"

#include <fcitx-utils/keysym.h>

#include <cstdio>

static int failures = 0;
#define EXPECT(condition)                                                              \
    do {                                                                               \
        if (!(condition)) {                                                            \
            std::fprintf(stderr, "%s:%d: expected %s\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                                \
        }                                                                              \
    } while (0)

using fcitx::Key;
using fcitx::KeyState;
using fcitx::KeyStates;

int main() {
    // A keyboard: d is evdev 32, X keycode 40; its scan code is its evdev code.
    araso::Json d = araso::WindowsKey(Key(FcitxKey_d, KeyStates(), 40));
    EXPECT(d["scan"].asInt() == 0x20 && !d["extended"].asBool() && !d["shift"].asBool());
    // Colemak's s sits on QWERTY's d: the key, not the letter, is what goes to the session.
    EXPECT(araso::WindowsKey(Key(FcitxKey_s, KeyStates(), 40))["scan"].asInt() == 0x20);
    // A virtual keyboard whose keymap puts d where Esc is (wtype's): placed by what it types.
    EXPECT(araso::WindowsKey(Key(FcitxKey_d, KeyStates(), 9))["scan"].asInt() == 0x20);
    // Right Alt (AltGr), right Ctrl: extended, as Windows marks them.
    araso::Json alt = araso::WindowsKey(Key(FcitxKey_ISO_Level3_Shift, KeyStates(), 108));
    EXPECT(alt["vk"].asInt() == 0xA5 && alt["extended"].asBool());
    EXPECT(araso::WindowsKey(Key(FcitxKey_Control_R, KeyStates(), 105))["vk"].asInt() == 0xA3);
    // 한/영 and 한자, by their keys or by a layout that makes right Alt 한/영.
    EXPECT(araso::WindowsKey(Key(FcitxKey_Hangul, KeyStates(), 130))["vk"].asInt() == 0x15);
    EXPECT(araso::WindowsKey(Key(FcitxKey_Hangul, KeyStates(), 108))["vk"].asInt() == 0x15);
    EXPECT(araso::WindowsKey(Key(FcitxKey_Hangul_Hanja, KeyStates(), 131))["vk"].asInt() == 0x19);
    // The keypad's 1 with NumLock on; Super held reads as Win.
    EXPECT(araso::WindowsKey(Key(FcitxKey_KP_1, KeyStates(), 87))["vk"].asInt() == 0x61);
    EXPECT(araso::WindowsKey(Key(FcitxKey_a, KeyStates(KeyState::Super), 38))["win"].asBool());
    // A key with no code (a test, an on-screen keyboard): its place on a US keyboard.
    araso::Json question = araso::WindowsKey(Key(FcitxKey_question, KeyStates(KeyState::Shift), 0));
    EXPECT(question["scan"].asInt() == 0x35 && question["shift"].asBool());
    EXPECT(araso::IsModifier(Key(FcitxKey_Shift_R, KeyStates(), 62)));
    EXPECT(!araso::IsModifier(Key(FcitxKey_a, KeyStates(), 38)));
    if (failures) std::fprintf(stderr, "%d failed\n", failures);
    else std::printf("key tests passed\n");
    return failures ? 1 : 0;
}
