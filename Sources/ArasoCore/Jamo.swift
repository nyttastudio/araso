/// Hangul jamo tables and the 2-set (두벌식) QWERTY layout.
///
/// All jamo are represented as Hangul Compatibility Jamo (U+3131…U+3163),
/// which is also what gets emitted for stray, uncombined jamo.
public enum Jamo {
    static let choseong: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let jungseong: [Character] = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// Index 0 is "no final consonant".
    static let jongseong: [Character?] = [nil] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map { $0 }

    static let choIndex = Dictionary(uniqueKeysWithValues: choseong.enumerated().map { ($1, $0) })
    static let jungIndex = Dictionary(uniqueKeysWithValues: jungseong.enumerated().map { ($1, $0) })
    static let jongIndex: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, j) in jongseong.enumerated() { if let j { map[j] = i } }
        return map
    }()

    static let vowelCombos: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ",
        "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ",
        "ㅡㅣ": "ㅢ",
    ]

    static let finalCombos: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ",
        "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ",
        "ㅂㅅ": "ㅄ",
    ]

    /// Inverse of `finalCombos`: compound final → (stays as final, moves to next syllable).
    static let finalSplits: [Character: (Character, Character)] = {
        var map: [Character: (Character, Character)] = [:]
        for (pair, combined) in finalCombos {
            let parts = Array(pair)
            map[combined] = (parts[0], parts[1])
        }
        return map
    }()

    static func isConsonant(_ j: Character) -> Bool { choIndex[j] != nil || jongIndex[j] != nil }
    static func isVowel(_ j: Character) -> Bool { jungIndex[j] != nil }

    static func syllable(cho: Character, jung: Character, jong: Character?) -> Character {
        let c = choIndex[cho]!, v = jungIndex[jung]!
        let f = jong.flatMap { jongIndex[$0] } ?? 0
        return Character(Unicode.Scalar(0xAC00 + (c * 21 + v) * 28 + f)!)
    }
}

/// The 2-set layout, and where the rest of the code asks about Korean keys: with 3-set chosen
/// (`KoreanLayout`), the public statics answer for `Sebeolsik` instead.
public enum DubeolsikLayout {
    private static let lower: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
    ]
    private static let shifted: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
    ]

    /// Keys whose shifted form produces a different jamo. Shift on any other
    /// letter is a signal the user is typing English.
    public static func isKoreanShiftKey(_ key: Character) -> Bool {
        if KoreanLayout.current.isSebeolsik { return Sebeolsik.isKoreanShiftKey(key) }
        return shifted[seat(key)] != nil
    }

    /// The QWERTY key `key` was typed on (`LatinLayout`): 2-set Korean goes by key, not letter.
    private static func seat(_ key: Character) -> Character { LatinLayout.current.seat(of: key) }

    /// A capital on a key with no shifted jamo, not counting a lingering Shift: Shift still down
    /// for the one key right after a Korean shift key (어떤 typed fast is djEJs, 바뀌 is qkRNl:
    /// Shift was still down for the vowel after ㄸ or ㄲ). Such keys read as Korean or English by
    /// their scores, and so do keys Shift was held over on purpose (`heldOver`); any other capital
    /// (Hello, API, dHello) is only ever English. A Shift lingers between lowercase keys, so a word
    /// typed in capitals throughout (TM, RN, TL: acronyms) gets no such allowance, nor does ㅒ/ㅖ
    /// with no consonant before it (PDF, OAuth).
    public static func hasEnglishOnlyCapital(_ keys: String) -> Bool {
        if KoreanLayout.current.isSebeolsik { return Sebeolsik.hasEnglishOnlyCapital(keys) }
        return unshiftedCapitals(keys).contains(.english)
    }

    /// Capitals that only Shift held on over them explains (`heldOver`; the A of RNARkwl, 꿈까지),
    /// none that are English for sure. Such keys may as well be an acronym typed before a particle
    /// (RNA까지), which is for the particle splitter to judge. Never in 3-set, which holds no Shift.
    public static func hasHeldOverCapital(_ keys: String) -> Bool {
        if KoreanLayout.current.isSebeolsik { return false }
        let kinds = unshiftedCapitals(keys)
        return kinds.contains(.held) && !kinds.contains(.english)
    }

    /// Why a capital with no shifted jamo is there: Shift lingering for the one key after a Korean
    /// shift key, Shift held on over it (`heldOver`), or neither, English.
    private enum UnshiftedCapital { case lingering, held, english }

    private static func unshiftedCapitals(_ keys: String) -> [UnshiftedCapital] {
        let raw = Array(keys)
        let chars = raw.map(seat)
        let hasLowercase = chars.contains(where: \.isLowercase)
        return chars.indices.filter { chars[$0].isUppercase && shifted[chars[$0]] == nil }.map { i in
            if hasLowercase, i >= 1, lingers(after: chars[i - 1], twoBack: i >= 2 ? chars[i - 2] : nil, on: chars[i]) {
                return .lingering
            }
            return heldOver(i, in: raw, keys: keys) ? .held : .english
        }
    }

    /// Shift held down from a Korean shift key over the keys after it, since Shift doesn't change
    /// them: 깔끔하다 as RKFRMAgkek (held from ㄲ to ㄲ and on through 끔), 빨리 as QKFfl. The run of
    /// capitals has to start on a Korean shift key, end before the word does (a word in capitals
    /// throughout is an acronym: RKFRMA, QUICK), and the keys have to spell whole Hangul, so
    /// TFxla, PCqkd and OAuth stay English.
    private static func heldOver(_ i: Int, in chars: [Character], keys: String) -> Bool {
        guard let run = capitalRuns(chars).first(where: { $0.contains(i) }), isKoreanShiftKey(chars[run.lowerBound]),
              run.upperBound < chars.count, chars[run.upperBound].isLowercase else { return false }
        return HangulComposer.compose(keys: keys).map { !$0.isBroken } == true
    }

    /// Every run of capitals begins on a Korean shift key (RKFRMA, rjtQNS), as when Shift is held
    /// on from a double consonant; not Hello, OpenAI or TypeScript.
    public static func capitalRunsStartOnShiftKeys(_ keys: String) -> Bool {
        let chars = Array(keys)
        return capitalRuns(chars).allSatisfy { isKoreanShiftKey(chars[$0.lowerBound]) }
    }

    /// The runs of consecutive capitals, as ranges of positions.
    private static func capitalRuns(_ chars: [Character]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isUppercase else { i += 1; continue }
            let start = i
            while i < chars.count, chars[i].isUppercase { i += 1 }
            runs.append(start..<i)
        }
        return runs
    }

    /// Shift still down for `key`, right after `shiftKey`, a Korean shift key that needed it. After
    /// a double consonant comes a vowel (djEJs, 어떤), or, when the double consonant is a final one
    /// (a vowel key before it), the next syllable's consonant (dlTDj, 있어). After ㅒ or ㅖ typed on a
    /// consonant comes a consonant (dPFmf, 예를); at the start of a word (PDF, OAuth) nothing lingers.
    /// The key before has to be lowercase: a capital there (RPA, TPS) was Shift on purpose.
    /// Takes seats (`hasEnglishOnlyCapital` translated them).
    private static func lingers(after shiftKey: Character, twoBack: Character?, on key: Character) -> Bool {
        let before = twoBack.flatMap { $0.isLowercase ? jamo(onSeat: $0) : nil }
        switch shifted[shiftKey] {
        case "ㅃ", "ㅉ", "ㄸ", "ㄲ", "ㅆ":
            if isVowelKey(key) { return true }
            return before.map(Jamo.isVowel) == true && isConsonantKey(key)
        case "ㅒ", "ㅖ":
            return before.map(Jamo.isConsonant) == true && isConsonantKey(key)
        default:
            return false
        }
    }

    private static func isVowelKey(_ seat: Character) -> Bool { jamo(onSeat: seat).map(Jamo.isVowel) ?? false }
    private static func isConsonantKey(_ seat: Character) -> Bool { jamo(onSeat: seat).map(Jamo.isConsonant) ?? false }

    /// The jamo a key produces, or nil for non-letters.
    /// Uppercase letters without a shifted jamo fall back to the lowercase jamo,
    /// mirroring how the macOS 2-set keyboard behaves.
    public static func jamo(for key: Character) -> Character? {
        if KoreanLayout.current.isSebeolsik { return Sebeolsik.jamo(for: key)?.jamo }
        return jamo(onSeat: seat(key))
    }

    private static func jamo(onSeat key: Character) -> Character? {
        if let j = shifted[key] { return j }
        guard key.isASCII, let lowered = key.lowercased().first else { return nil }
        return lower[lowered]
    }
}
