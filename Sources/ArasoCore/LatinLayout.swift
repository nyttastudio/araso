import Foundation

/// The layout the user types English (and romaji) on: `settings.json`'s `"latinLayout"`.
///
/// Keys are kept as this layout's letters, so English and romaji read them as they are, and only
/// Korean looks through to the physical key: 2-set Korean sits on the keys where QWERTY has its
/// letters, whatever layout the letters come from (`DubeolsikLayout` asks `seat(of:)`). On QWERTY
/// a letter and its seat are the same character, so nothing changes there.
///
/// Dvorak is left out on purpose: it puts `'`, `,`, `.` and `;` on the keys of ㅂ, ㅈ, ㄷ and ㅋ,
/// and a word can't end on punctuation and keep composing on it at once without a rule for which
/// one was meant (docs/keyboard-layouts.md).
public enum LatinLayout: String, Codable, CaseIterable, Sendable {
    case qwerty
    case colemak
    /// Colemak Mod-DH, ANSI rows (no angle mod): D and H move to the bottom row.
    case colemakDH
    /// Norwegian (bokmål): QWERTY's letters, with ø, æ and å on the ; ' [ keys as on a Norwegian
    /// Mac keyboard. Those three keys type letters here, so a word with one of them is Latin,
    /// never Korean (2-set has no jamo on them).
    case norwegian

    /// How the settings show it.
    public var name: String {
        switch self {
        case .qwerty: return "QWERTY"
        case .colemak: return "Colemak"
        case .colemakDH: return "Colemak-DH"
        case .norwegian: return "Norsk (QWERTY + æøå)"
        }
    }

    /// The letters outside a–z this layout types: the Latin model's extra symbols.
    public static let extraLetters: [Character] = ["æ", "ø", "å"]

    /// What the input controllers type with: set from the settings when they load.
    nonisolated(unsafe) public static var active: LatinLayout = .qwerty
    /// For a test (or a tool) that types on another layout without touching `active`.
    @TaskLocal public static var override: LatinLayout?
    public static var current: LatinLayout { override ?? active }

    /// The layout romaji is typed on, when it isn't the English one (`settings.json`'s
    /// `"japaneseLayout"`): English on Colemak, romaji on QWERTY.
    nonisolated(unsafe) public static var activeRomaji: LatinLayout?
    @TaskLocal public static var romajiOverride: LatinLayout?
    public static var romaji: LatinLayout { romajiOverride ?? activeRomaji ?? current }

    /// Keys (the English layout's letters) as romaji's layout spells them: each key's character
    /// on romaji's layout, as 2-set looks through to the key. The same keys when the layouts match.
    public static func romajiKeys(_ keys: String) -> String {
        let english = current, romaji = romaji
        guard romaji != english else { return keys }
        return String(keys.map { romaji.character(onSeat: english.seat(of: $0)) })
    }

    /// QWERTY's character on each key, unshifted, in the order of `rows`. The [ and ' keys are
    /// in because the Norwegian layout has letters on them (å, æ); elsewhere they type themselves.
    private static let qwertyRows = ["qwertyuiop[", "asdfghjkl;'", "zxcvbnm"]

    private var rows: [String] {
        switch self {
        case .qwerty: return Self.qwertyRows
        case .colemak: return ["qwfpgjluy;[", "arstdhneio'", "zxcvbkm"]
        case .colemakDH: return ["qwfpbjluy;[", "arstgmneio'", "zxcdvkh"]
        case .norwegian: return ["qwertyuiopå", "asdfghjkløæ", "zxcvbnm"]
        }
    }

    /// The layout's character on the key with QWERTY's `seat` (unshifted or shifted), e.g. Colemak
    /// types `f` on the e key and `o` on the ; key. Keys the rows don't cover type the same everywhere.
    public func character(onSeat seat: Character) -> Character {
        guard self != .qwerty, let (row, column, shifted) = Self.position(of: seat) else { return seat }
        let ch = Array(rows[row])[column]
        return shifted ? Self.shift(ch) : ch
    }

    /// The QWERTY key a character of this layout is typed on: the inverse of `character(onSeat:)`.
    public func seat(of character: Character) -> Character {
        guard self != .qwerty else { return character }
        let lowered = Self.unshift(character)
        let shifted = lowered != character
        for (r, row) in rows.enumerated() {
            if let c = Array(row).firstIndex(of: lowered) {
                let seat = Array(Self.qwertyRows[r])[c]
                return shifted ? Self.shift(seat) : seat
            }
        }
        return character
    }

    /// Whether the key typing `character` is one of QWERTY's letter keys, where 2-set Korean has
    /// its jamo, or romaji's layout types a letter: Colemak's `;` (on the p key, ㅔ) is part of a
    /// word too, and so is QWERTY's `;` when romaji is on Colemak (its o).
    public func isLetterSeat(_ character: Character) -> Bool {
        let seat = seat(of: character)
        return seat.isASCII && seat.isLetter || self.character(onSeat: seat).isLetter
            || Self.romaji.character(onSeat: seat).isLetter
    }

    private static func position(of seat: Character) -> (Int, Int, Bool)? {
        let lowered = unshift(seat)
        for (r, row) in qwertyRows.enumerated() {
            if let c = Array(row).firstIndex(of: lowered) { return (r, c, lowered != seat) }
        }
        return nil
    }

    private static let shiftedSymbols: [Character: Character] = [";": ":", "'": "\"", "[": "{"]
    private static let unshiftedSymbols: [Character: Character] = [":": ";", "\"": "'", "{": "["]

    private static func shift(_ ch: Character) -> Character {
        shiftedSymbols[ch] ?? Character(ch.uppercased())
    }

    private static func unshift(_ ch: Character) -> Character {
        unshiftedSymbols[ch] ?? Character(ch.lowercased())
    }

    /// The character a key types on this layout, from its virtual key code (ANSI positions), with
    /// Shift (or Caps Lock, for letters) as given; nil for keys outside the letter rows.
    public func character(keyCode: UInt16, shift: Bool, capsLock: Bool) -> Character? {
        guard let seat = Self.seatsByKeyCode[keyCode] else { return nil }
        var ch = character(onSeat: seat)
        if shift || (capsLock && ch.isLetter) { ch = Self.shift(ch) }
        return ch
    }

    private static let seatsByKeyCode: [UInt16: Character] = [
        12: "q", 13: "w", 14: "e", 15: "r", 17: "t", 16: "y", 32: "u", 34: "i", 31: "o", 35: "p",
        0: "a", 1: "s", 2: "d", 3: "f", 5: "g", 4: "h", 38: "j", 40: "k", 37: "l", 41: ";", 39: "'",
        6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 45: "n", 46: "m", 33: "[",
    ]
}
