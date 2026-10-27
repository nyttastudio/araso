// fcitx5's keys as the `WindowsKey` ArasoService reads (KeyMapper): its virtual key, its PC scan
// code and the modifiers held. Linux numbers keys by evdev code, which for the main block is the PC
// set 1 scan code itself (KEY_A = 0x1E), so letters, digits and symbols come from the physical key
// as on Windows, whatever layout the desktop has; the keys Windows marks extended (right Ctrl and
// Alt, arrows, keypad Enter and /) are mapped one by one.
#pragma once

#include "Json.h"

#include <fcitx-utils/key.h>

namespace araso {

/// The key as `ServiceRequest.key`; Null for a key Araso has no use for (a media key).
Json WindowsKey(const fcitx::Key &key);

/// Whether the key is a modifier (its going up matters: taps).
bool IsModifier(const fcitx::Key &key);

}  // namespace araso
