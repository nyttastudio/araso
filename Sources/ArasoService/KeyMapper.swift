import ArasoCore
import Foundation

/// Windows keys in the terms the rest of Araso uses, which came from macOS: InputSession's keys, the
/// Mac's virtual key codes (ANSI positions, which settings.json's pause shortcut stores) and its
/// modifiers, by the role each key plays on Windows:
///
/// - Ctrl is ⌘ (the shortcut key: ⌘V is Ctrl+V), so right Ctrl tapped alone is the right ⌘ tap
///   that pauses by default, and Ctrl going down puts a held word in before a paste.
/// - The Windows key is ⌃, Alt is ⌥ (right Alt tapped alone switches readings), Shift is ⇧.
/// - On Korean keyboards the right Alt and right Ctrl keys are 한/영 and 한자. Keys of their own, not
///   modifiers (some keyboards send no release for them): 한/영 switches readings as soon as it goes
///   down where right ⌥ is a switch key, and 한자 pauses where right ⌘ is the pause key.
///
/// Letters, digits and symbols come from the physical key (its scan code) as on a US keyboard,
/// whatever layout Windows has, as the Mac input method has macOS type on the US layout.
public enum KeyMapper {
    /// Where the keys come from: Linux (the fcitx5 addon) sends the same keys, its evdev codes
    /// being these scan codes, and names the ⌃ key Super where Windows names it Win.
    public enum Platform: String, Sendable {
        case windows, linux

        var superName: String { self == .linux ? "Super" : "Win" }
    }

    // Virtual keys (winuser.h).
    public static let vkBack = 0x08, vkTab = 0x09, vkReturn = 0x0D, vkShift = 0x10, vkControl = 0x11,
                      vkMenu = 0x12, vkPause = 0x13, vkCapital = 0x14, vkHangul = 0x15, vkHanja = 0x19,
                      vkEscape = 0x1B, vkSpace = 0x20, vkLeft = 0x25, vkUp = 0x26, vkRight = 0x27,
                      vkDown = 0x28, vkLWin = 0x5B, vkRWin = 0x5C, vkNumpad0 = 0x60, vkMultiply = 0x6A,
                      vkAdd = 0x6B, vkSubtract = 0x6D, vkDecimal = 0x6E, vkDivide = 0x6F, vkF1 = 0x70,
                      vkF6 = 0x75, vkF7 = 0x76, vkLShift = 0xA0, vkRShift = 0xA1, vkLControl = 0xA2,
                      vkRControl = 0xA3, vkLMenu = 0xA4, vkRMenu = 0xA5, vkProcessKey = 0xE5

    /// A modifier key, by which one it physically is.
    public enum Modifier: Equatable, Sendable {
        case leftShift, rightShift, leftControl, rightControl, leftAlt, rightAlt, leftWin, rightWin

        /// The Mac key it stands for: what `PauseKey.Tap.keyCode` names.
        public var macKeyCode: UInt16 {
            switch self {
            case .leftShift: return 56
            case .rightShift: return 60
            case .leftControl: return 55   // left ⌘
            case .rightControl: return 54  // right ⌘
            case .leftAlt: return 58
            case .rightAlt: return 61     // right ⌥
            case .leftWin: return 59       // left ⌃
            case .rightWin: return 62      // right ⌃
            }
        }

        /// The modifier flag it sets, as a Mac modifier.
        public var flag: KeyModifiers {
            switch self {
            case .leftShift, .rightShift: return .shift
            case .leftControl, .rightControl: return .command
            case .leftAlt, .rightAlt: return .option
            case .leftWin, .rightWin: return .control
            }
        }

        /// Ctrl (⌘'s role): going down puts a held word in.
        public var isCommand: Bool { self == .leftControl || self == .rightControl }
    }

    /// The modifier this key is, if it is one.
    public static func modifier(_ key: WindowsKey) -> Modifier? {
        switch key.vk {
        case vkShift, vkLShift, vkRShift:
            // Right Shift has its own scan code, not the extended flag.
            return key.vk == vkRShift || key.scan == 0x36 ? .rightShift : .leftShift
        case vkControl, vkLControl, vkRControl:
            return key.vk == vkRControl || key.extended ? .rightControl : .leftControl
        case vkMenu, vkLMenu, vkRMenu:
            return key.vk == vkRMenu || key.extended ? .rightAlt : .leftAlt
        case vkLWin: return .leftWin
        case vkRWin: return .rightWin
        default: return nil
        }
    }

    /// Keys that only change state and never type: they are left to the app as they come.
    public static func isLock(_ key: WindowsKey) -> Bool {
        [vkCapital, 0x90 /* NumLock */, 0x91 /* ScrollLock */, vkProcessKey].contains(key.vk)
    }

    /// The modifiers held with the key, as Mac modifiers.
    public static func modifiers(_ key: WindowsKey) -> KeyModifiers {
        var flags: KeyModifiers = []
        if key.ctrl { flags.insert(.command) }
        if key.win { flags.insert(.control) }
        if key.alt { flags.insert(.option) }
        if key.shift { flags.insert(.shift) }
        return flags
    }

    /// The Mac key code for the key in the same place, for shortcuts; nil for keys a Mac keyboard
    /// doesn't have.
    public static func macKeyCode(_ key: WindowsKey) -> UInt16? {
        if let modifier = modifier(key) { return modifier.macKeyCode }
        if let code = byVK[key.vk] { return code }
        if key.extended { return extendedScan[key.scan] }
        return byScan[key.scan]
    }

    /// The key as InputSession takes it (InputController's `key(for:)` on macOS).
    public static func sessionKey(_ key: WindowsKey, policy: AppPolicy) -> InputSession.Key {
        let modifiers = modifiers(key).intersection([.command, .control, .option])
        if modifiers == .option, !key.shift, key.vk == vkSpace, policy.switchKeys.contains(.optionSpace) {
            return .cycle // Alt+Space chosen as a switch key
        }
        // Ctrl+J/K type kana on macOS (⌃J/⌃K); on Windows Ctrl is the shortcut key, so F6/F7 only.
        if !modifiers.isEmpty { return .other }
        if key.vk == vkEscape, key.shift {
            return policy.switchKeys.contains(.shiftEscape) ? .cycle : .other
        }
        switch key.vk {
        case vkF7: return .katakana
        case vkF6: return .hiragana
        case vkBack: return .delete
        case vkEscape: return .escape
        case vkReturn: return .enter
        case vkLeft: return .left
        case vkRight: return .right
        case vkDown: return .down
        case vkUp: return .up
        default: break
        }
        if !key.extended, let code = byScan[key.scan] {
            // Letters from the key, on the layout the settings choose; Colemak's ; (on the p key,
            // 2-set's ㅔ) is part of a word too, as is any key romaji's layout has a letter on.
            let layout = LatinLayout.current
            if let ch = layout.character(keyCode: code, shift: key.shift, capsLock: key.capsLock),
               ch.isLetter || layout.isLetterSeat(ch) {
                return .letter(ch)
            }
        }
        guard let ch = character(key) else { return .other }
        if ch == " ", key.shift { return .shiftSpace }
        return .printable(ch)
    }

    /// What a key the session passed on types, for the host to put in where the app can't (the
    /// text service kept the key from it); nil for one that types nothing (Return, Tab, a shortcut).
    public static func typed(_ key: WindowsKey, policy: AppPolicy) -> String? {
        switch sessionKey(key, policy: policy) {
        case .letter(let ch), .printable(let ch): return String(ch)
        case .shiftSpace: return " "
        default: return nil
        }
    }

    /// What the key types on a US keyboard (no letters: those come from the layout), or nil.
    static func character(_ key: WindowsKey) -> Character? {
        if (vkNumpad0...(vkNumpad0 + 9)).contains(key.vk) {
            return Character(UnicodeScalar(UInt8(ascii: "0") + UInt8(key.vk - vkNumpad0)))
        }
        switch key.vk {
        case vkMultiply: return "*"
        case vkAdd: return "+"
        case vkSubtract: return "-"
        case vkDecimal: return "."
        case vkDivide: return "/"
        default: break
        }
        guard !key.extended, let pair = usSymbols[key.scan] else { return nil }
        return key.shift ? pair.1 : pair.0
    }

    /// Scan code → US characters (unshifted, shifted) of the keys that aren't letters.
    private static let usSymbols: [Int: (Character, Character)] = [
        0x02: ("1", "!"), 0x03: ("2", "@"), 0x04: ("3", "#"), 0x05: ("4", "$"), 0x06: ("5", "%"),
        0x07: ("6", "^"), 0x08: ("7", "&"), 0x09: ("8", "*"), 0x0A: ("9", "("), 0x0B: ("0", ")"),
        0x0C: ("-", "_"), 0x0D: ("=", "+"), 0x1A: ("[", "{"), 0x1B: ("]", "}"), 0x27: (";", ":"),
        0x28: ("'", "\""), 0x29: ("`", "~"), 0x2B: ("\\", "|"), 0x33: (",", "<"), 0x34: (".", ">"),
        0x35: ("/", "?"), 0x39: (" ", " "),
    ]

    /// Scan code (set 1, not extended) → Mac key code.
    static let byScan: [Int: UInt16] = [
        0x01: 53, 0x02: 18, 0x03: 19, 0x04: 20, 0x05: 21, 0x06: 23, 0x07: 22, 0x08: 26, 0x09: 28,
        0x0A: 25, 0x0B: 29, 0x0C: 27, 0x0D: 24, 0x0E: 51, 0x0F: 48,
        0x10: 12, 0x11: 13, 0x12: 14, 0x13: 15, 0x14: 17, 0x15: 16, 0x16: 32, 0x17: 34, 0x18: 31,
        0x19: 35, 0x1A: 33, 0x1B: 30, 0x1C: 36,
        0x1E: 0, 0x1F: 1, 0x20: 2, 0x21: 3, 0x22: 5, 0x23: 4, 0x24: 38, 0x25: 40, 0x26: 37,
        0x27: 41, 0x28: 39, 0x29: 50, 0x2B: 42,
        0x2C: 6, 0x2D: 7, 0x2E: 8, 0x2F: 9, 0x30: 11, 0x31: 45, 0x32: 46, 0x33: 43, 0x34: 47, 0x35: 44,
        0x37: 67, 0x39: 49, 0x3A: 57,
        0x3B: 122, 0x3C: 120, 0x3D: 99, 0x3E: 118, 0x3F: 96, 0x40: 97, 0x41: 98, 0x42: 100, 0x43: 101,
        0x44: 109, 0x57: 103, 0x58: 111,
        0x47: 89, 0x48: 91, 0x49: 92, 0x4A: 78, 0x4B: 86, 0x4C: 87, 0x4D: 88, 0x4E: 69, 0x4F: 83,
        0x50: 84, 0x51: 85, 0x52: 82, 0x53: 65,
        // F13–F20 (scan codes 0x64–0x6B on keyboards that have them).
        0x64: 105, 0x65: 107, 0x66: 113, 0x67: 106, 0x68: 64, 0x69: 79, 0x6A: 80, 0x6B: 90,
    ]

    /// Extended scan code → Mac key code (navigation keys, keypad Enter and /).
    static let extendedScan: [Int: UInt16] = [
        0x1C: 76, 0x35: 75, 0x47: 115, 0x48: 126, 0x49: 116, 0x4B: 123, 0x4D: 124, 0x4F: 119,
        0x50: 125, 0x51: 121, 0x52: 114, 0x53: 117,
    ]

    /// Keys whose virtual key says more than their scan code (the scan code of a numpad digit
    /// depends on NumLock).
    static let byVK: [Int: UInt16] = [
        vkNumpad0: 82, vkNumpad0 + 1: 83, vkNumpad0 + 2: 84, vkNumpad0 + 3: 85, vkNumpad0 + 4: 86,
        vkNumpad0 + 5: 87, vkNumpad0 + 6: 88, vkNumpad0 + 7: 89, vkNumpad0 + 8: 91, vkNumpad0 + 9: 92,
        vkMultiply: 67, vkAdd: 69, vkSubtract: 78, vkDecimal: 65, vkDivide: 75,
    ]

    /// The key as printed on it, for a shortcut ("P", "5", "F5", "Space"); nil for a key with no name.
    public static func keyName(_ key: WindowsKey) -> String? {
        if (vkF1..<(vkF1 + 24)).contains(key.vk) { return "F\(key.vk - vkF1 + 1)" }
        switch key.vk {
        case vkSpace: return "Space"
        case vkReturn: return "Enter"
        case vkTab: return "Tab"
        case vkBack: return "Backspace"
        case vkEscape: return "Esc"
        case vkLeft: return "←"
        case vkRight: return "→"
        case vkUp: return "↑"
        case vkDown: return "↓"
        default: break
        }
        if !key.extended, let code = byScan[key.scan], let ch = LatinLayout.qwerty.character(keyCode: code, shift: false, capsLock: false) {
            return String(ch).uppercased()
        }
        return character(WindowsKey(vk: key.vk, scan: key.scan, extended: key.extended)).map { String($0) }
    }

    /// How a key on Windows (or Linux) is written in the settings window (the Mac glyphs mean nothing there).
    public static func tapName(_ tap: PauseKey.Tap, on platform: Platform = .windows) -> String {
        switch tap {
        case .rightCommand: return "Ctrl"
        case .rightOption: return "Alt"
        case .rightShift: return "Shift"
        case .rightControl: return platform.superName
        }
    }

    /// A shortcut as Windows writes it: Ctrl+Alt+P.
    public static func shortcutName(_ shortcut: PauseKey.Shortcut, on platform: Platform = .windows) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("Ctrl") }
        if shortcut.modifiers.contains(.option) { parts.append("Alt") }
        if shortcut.modifiers.contains(.shift) { parts.append("Shift") }
        if shortcut.modifiers.contains(.control) { parts.append(platform.superName) }
        parts.append(shortcut.key)
        return parts.joined(separator: "+")
    }
}

/// Right modifier taps: a switch key (right Alt, right Shift, 한/영) or the pause key, pressed and
/// released on its own within half a second (InputController's `switchTapChanged` and
/// `pauseTapChanged` on macOS).
public struct TapTracker: Sendable {
    public enum Tap: Equatable, Sendable {
        case pause
        case cycle
    }

    private var pauseDown: Date?
    private var switchDown: (key: UInt16, at: Date)?
    public static let window: TimeInterval = 0.5

    public init() {}

    /// A key that isn't a modifier went down: a modifier held with it is a shortcut, not a tap.
    public mutating func otherKey() {
        pauseDown = nil
        switchDown = nil
    }

    /// A modifier went down; `held` are the modifiers down besides it.
    public mutating func down(_ modifier: KeyMapper.Modifier, held: KeyModifiers, pauseKey: PauseKey,
                              switchKeys: Set<SwitchKey>, now: Date = Date()) {
        let code = modifier.macKeyCode
        let others = held.subtracting(modifier.flag)
        if case .tap(let tap) = pauseKey, tap.keyCode == code {
            // Only on its own: a Hyper key's tap is bound to something else.
            pauseDown = others.isEmpty ? now : nil
            switchDown = nil // the pause key wins where an app chose the same key
            return
        }
        pauseDown = nil // another modifier joined in
        let isSwitch = (code == 61 && switchKeys.contains(.rightOption)) || (code == 60 && switchKeys.contains(.rightShift))
        switchDown = isSwitch && others.isEmpty ? (code, now) : nil
    }

    /// A modifier went up: the tap it ends, if any.
    public mutating func up(_ modifier: KeyMapper.Modifier, pauseKey: PauseKey, now: Date = Date()) -> Tap? {
        let code = modifier.macKeyCode
        if case .tap(let tap) = pauseKey, tap.keyCode == code {
            defer { pauseDown = nil }
            guard let down = pauseDown, now.timeIntervalSince(down) < Self.window else { return nil }
            return .pause
        }
        guard let down = switchDown, down.key == code else { return nil }
        switchDown = nil
        return now.timeIntervalSince(down.at) < Self.window ? .cycle : nil
    }
}
