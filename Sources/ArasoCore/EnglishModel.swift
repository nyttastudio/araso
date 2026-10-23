import Foundation

/// Character-trigram language model plus a word list with how common each word is, from
/// SCOWL (Data/english_words.txt: word<TAB>level, 10 = most common … 60). With Norwegian on
/// (`Settings.norwegian`) the Latin side is `norwegianModel`: these words and Data/norwegian_words.txt
/// together, æ ø å as letters, and Norwegian inflections.
public final class EnglishModel: @unchecked Sendable {
    // Symbols: 0 = word boundary, 1...26 = a...z, then æ ø å when `norwegian`.
    private let symbols: Int
    /// The Norwegian model: æ ø å are letters, Norwegian inflections and short words count.
    public let norwegian: Bool
    private var trigrams: [Float]
    private var contexts: [Float]
    /// SCOWL level of each word (lowercase, letters only).
    private let levels: [String: Int]
    /// The levels a guessed inflection may take from its stem: the list's own, not `commonWords`
    /// (nil: `levels`).
    private let stemLevels: [String: Int]?
    private let smoothing: Float = 0.5

    /// Words up to this level count as English words (a score floor, protection from kana).
    public static let knownLevel = 50
    /// Words up to this level are everyday English (you, sense, machine, for, got).
    public static let commonLevel = 20
    /// Level given to `commonWords` (tech terms and slang SCOWL lacks): known, not "common".
    static let extraLevel = 35
    /// Letter trigrams come from this list when it's there (macOS ships it): its 235k words
    /// separate English spelling from Korean keys better than SCOWL's 119k (measured).
    public static let spellingListPath = "/usr/share/dict/words"

    /// Loading the word list takes a moment; share one instance of each.
    public static let english = EnglishModel(listURL: Resources.englishWords, spellingPath: spellingListPath)
    public static let norwegianModel = EnglishModel(listURL: Resources.englishWords, norwegianURL: Resources.norwegianWords,
                                                    spellingPath: spellingListPath)
    /// Whether the input controllers use `norwegianModel`: set from the settings when they load.
    nonisolated(unsafe) public static var useNorwegian = false
    /// For a test (or a tool) that decides with one model without touching `useNorwegian`.
    @TaskLocal public static var override: EnglishModel?
    /// The model in use.
    public static var shared: EnglishModel { override ?? (useNorwegian ? norwegianModel : english) }

    /// From a word<TAB>level file; a missing file leaves only `commonWords` (logged). Trigrams
    /// are trained on `spellingPath`'s words when it can be read, otherwise on the list. A
    /// `norwegianURL` (same format) makes the Norwegian model: its words join the list (a word in
    /// both takes the lower level) and the trigrams.
    public convenience init(listURL: URL?, norwegianURL: URL? = nil, spellingPath: String? = nil,
                            extraWords: [String] = EnglishModel.commonWords) {
        func read(_ url: URL?) -> [String: Int] {
            var levels: [String: Int] = [:]
            if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: "\t")
                    if parts.count == 2, let level = Int(parts[1]) { levels[String(parts[0])] = level }
                }
            }
            if levels.isEmpty { NSLog("Araso: word list missing (%@)", url?.path ?? "nil") }
            return levels
        }
        var levels = read(listURL)
        let norwegianWords = norwegianURL.map(read)
        levels.merge(norwegianWords ?? [:], uniquingKeysWith: min)
        let listed = levels
        for word in extraWords { levels[word.lowercased()] = min(levels[word.lowercased()] ?? Self.extraLevel, Self.extraLevel) }
        let spelling = spellingPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline).map { $0.lowercased() }
        // Norwegian spelling and æ ø å come from the Norwegian words: macOS's list is English.
        let extraSpelling = Array((norwegianWords ?? [:]).keys) + extraWords
        self.init(levels: levels, spelling: spelling.map { $0 + extraSpelling }, stems: listed,
                  norwegian: norwegianWords != nil)
    }

    /// For tests: these words at a middle level.
    public convenience init(words list: [String]) {
        self.init(levels: Dictionary(list.map { ($0.lowercased(), Self.extraLevel) }, uniquingKeysWith: min))
    }

    public init(levels raw: [String: Int], spelling: [String]? = nil, stems: [String: Int]? = nil, norwegian: Bool = false) {
        self.norwegian = norwegian
        let n = 27 + (norwegian ? LatinLayout.extraLetters.count : 0)
        symbols = n
        let isLetter: (Character) -> Bool = norwegian ? Self.isLatinLetter : { $0.isASCII && $0.isLetter }
        let short = norwegian ? Self.shortWords.union(Self.norwegianShortWords) : Self.shortWords
        var tri = [Float](repeating: 0, count: n * n * n)
        var ctx = [Float](repeating: 0, count: n * n)
        func normalized(_ raw: [String: Int]) -> [String: Int] {
            var levels: [String: Int] = [:]
            levels.reserveCapacity(raw.count)
            for (raw, level) in raw {
                let word = raw.filter { $0 != "'" }
                guard !word.isEmpty, word.allSatisfy(isLetter) else { continue }
                // Many 1–2 letter list entries aren't words people type ("ra", "ko"); only real ones count.
                if word.count > 2 || short.contains(word) { levels[word] = min(levels[word] ?? level, level) }
            }
            return levels
        }
        let levels = normalized(raw)
        stemLevels = stems.map(normalized)
        for word in spelling ?? Array(levels.keys) where !word.isEmpty && word.allSatisfy(isLetter) {
            let codes = Self.encode(word, norwegian: norwegian)
            for i in 2..<codes.count {
                tri[(codes[i - 2] * n + codes[i - 1]) * n + codes[i]] += 1
                ctx[codes[i - 2] * n + codes[i - 1]] += 1
            }
        }
        trigrams = tri
        contexts = ctx
        self.levels = levels
    }

    public var wordCount: Int { levels.count }

    /// [^, ^, letters..., $] with ^ and $ both encoded as 0.
    private static func encode(_ word: String, norwegian: Bool) -> [Int] {
        var codes = [0, 0]
        if norwegian {
            for ch in word {
                if let code = extraCodes[ch] {
                    codes.append(code)
                } else if ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first.map({ Int($0.value) }), v >= 97 && v <= 122 {
                    codes.append(v - 96)
                }
            }
        } else {
            for scalar in word.unicodeScalars {
                let v = Int(scalar.value)
                if v >= 97 && v <= 122 { codes.append(v - 96) }
            }
        }
        codes.append(0)
        return codes
    }

    private static let extraCodes: [Character: Int] = Dictionary(uniqueKeysWithValues:
        LatinLayout.extraLetters.enumerated().map { ($1, 27 + $0) })

    /// A letter the Norwegian model reads: a–z or æ ø å (`LatinLayout.extraLetters`), either case.
    static func isLatinLetter(_ ch: Character) -> Bool {
        ch.isASCII && ch.isLetter || ch.lowercased().first.flatMap { extraCodes[$0] } != nil
    }

    /// Average natural-log probability per symbol (letters + end marker).
    /// Real English words land around -1.8…-2.4; keyboard mash around -3.5 or lower.
    public func averageLogProbability(_ token: String) -> Double {
        let n = symbols
        let codes = Self.encode(token.lowercased(), norwegian: norwegian)
        guard codes.count > 3 else { return -10 }
        var total: Double = 0
        for i in 2..<codes.count {
            let c = trigrams[(codes[i - 2] * n + codes[i - 1]) * n + codes[i]]
            let t = contexts[codes[i - 2] * n + codes[i - 1]]
            total += Double(log((c + smoothing) / (t + smoothing * Float(n))))
        }
        return total / Double(codes.count - 2)
    }

    /// The word's level, also for regular inflections of a listed word (nil: not a word).
    public func level(_ token: String) -> Int? {
        let w = token.lowercased().filter { $0 != "'" }
        if let level = levels[w] { return level }
        var best: Int?
        // SCOWL lists the inflections of its words, so a guessed one counts only for a stem the
        // list itself ranks above its rarest known level: thru (50, and 35 only as one of
        // `commonWords`) + s is no word, and thrus is 소견.
        func consider(_ stem: String) {
            if let l = (stemLevels ?? levels)[stem], l < Self.knownLevel { best = min(best ?? l, l) }
        }
        // Stems of 3+ letters: ths isn't the+s, ehs isn't eh+s.
        for suffix in norwegian ? Self.englishSuffixes + Self.norwegianSuffixes : Self.englishSuffixes
        where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            let stem = String(w.dropLast(suffix.count))
            consider(stem)
            consider(stem + "e")
            // running → run, stopped → stop
            if let last = stem.last, stem.dropLast().last == last { consider(String(stem.dropLast())) }
        }
        // stories → story, denied → deny, heavier → heavy
        for suffix in ["ies", "ied", "ier", "iest", "iers"] where w.count > suffix.count + 1 && w.hasSuffix(suffix) {
            consider(String(w.dropLast(suffix.count)) + "y")
        }
        return best
    }

    /// A word people use (SCOWL level ≤ 50, or one of `commonWords`).
    public func isKnownWord(_ token: String) -> Bool {
        level(token).map { $0 <= Self.knownLevel } ?? false
    }

    /// Everyday English (level ≤ 20): kept English even right after Korean or Japanese.
    public func isCommonWord(_ token: String) -> Bool {
        level(token).map { $0 <= Self.commonLevel } ?? false
    }

    private static let englishSuffixes = ["s", "es", "ed", "d", "ing", "ly", "er", "ers", "est"]
    /// bilen, huset, bilene (en, et, ene; er is English's too), kjøpte, levde (te, de).
    private static let norwegianSuffixes = ["en", "et", "ene", "te", "de"]

    static let norwegianShortWords: Set<String> = Set("""
    å og er du de en et ei på om så nå ja da ut vi av ha la se si gå få bo by øl øy ås må to nei ok
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static let shortWords: Set<String> = Set("""
    a i ad ah am an as at aw ax be by do eh go ha he hi hm if in is it lo ma me mo my no of oh ok on or ow ox pa
    pc so to tv uh um up us we ya ye yo id ex vs ai ui ux os js ts
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Everyday/technical words SCOWL is missing or ranks rare.
    public static let commonWords: [String] = """
    ok okay hi hey yeah yep nope lol omg btw thx thanks pls please email emails app apps api apis url urls
    http https www github git commit push pull merge branch repo json yaml xml html css js ts swift python java
    kotlin rust golang npm yarn pnpm node react vue svelte docker kubernetes ios macos android iphone ipad mac wifi bluetooth usb
    login logout signup username password online offline website blog vlog youtube google slack notion figma
    debug deploy refactor config backend frontend database cache server client async await todo todos ai llm gpt
    claude chatgpt laptop smartphone selfie emoji internet podcast startup dev devs devops ui ux
    wanna gonna gotta kinda sorta outta lemme gimme dunno yeah yup nah ain cuz tho thru hiya kiddo sayin
    goin doin nothin somethin y'all ya yo hey oi aye
    wouldn couldn shouldn didn doesn isn wasn weren hasn haven hadn needn mustn aren mightn
    makeup brooklyn shakespeare einstein techno pesto americano cosmo promo garde kanji kana romaji ramen
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}
