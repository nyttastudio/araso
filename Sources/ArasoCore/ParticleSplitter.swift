import Foundation

/// An English word with a particle typed straight after it (`githubdp` → `github에`,
/// `githubde` → `githubで`) is one more reading of the keys, scored like the whole-token
/// readings it competes with: average log-probability per keystroke.
///
/// - The front scores as English: a known word gets the dictionary floors `HeuristicEngine`
///   uses, capitals typed on purpose (API, GitHub) a higher one, anything else its spelling.
/// - The particle scores by how common it is, and switching language costs a little.
/// - The whole token scores as Korean (a Korean word, or one with a particle, gets a floor),
///   as unknown English, and with Japanese on as kana.
///
/// The split wins only by `margin`. `form에서` splits because 래그 is no Korean word and form
/// is everyday English; `핸들을` doesn't, because 핸들 is a word.
public struct ParticleSplitter: Sendable {
    public let english: EnglishModel
    public let korean: KoreanModel
    public let japanese: JapaneseModel?
    public var weights: Weights

    /// Log-probabilities for a whole word or particle, not per key, so a longer front or
    /// particle isn't favored for its length.
    public struct Weights: Sendable {
        /// A known English word: `knownBase` minus `perLevel` per SCOWL level (10 = everyday).
        public var knownBase = -4.0
        public var perLevel = 0.15
        /// An acronym (API, UI, PR) or a name with a capital inside (GitHub, VSCode, macOS).
        public var acronym = -6.0
        public var name = -7.0
        /// Taken off once from the spelling score of a front (or token) that isn't a known word.
        public var unknownWord = 3.0
        /// Taken off once more when the front isn't a known word: an unknown word with a
        /// particle after it is rarer than an unknown word (names: adriano, porto, chandi).
        public var unknownFront = 3.0
        /// A common particle (에, 를, で…) and the other endings (처럼, 했어, まで…).
        public var coreParticle = -2.5
        public var otherParticle = -4.5
        /// Once per split, for switching language inside a token.
        public var switchCost = 1.0
        /// Instead of `switchCost` for an ordinary English word and a Korean word (hello월드): rarer
        /// than a particle or an acronym or name with a word after it (github에, PC카톡).
        public var wordSwitchCost = 9.0
        /// Added to a particle of a pair (은/는, 을/를) after an acronym when it is the form the
        /// acronym's last letter takes (TM은, TV는): after another word either form may follow,
        /// after an acronym only that one does, so twice as likely (ln 2).
        public var agreement = 0.7
        /// Per key, the least a Korean word (or a word with a particle) scores.
        public var koreanWordFloor = -1.4
        /// Added per key to the kana reading's score, as `HeuristicEngine.japaneseOffset`.
        public var japaneseOffset = 1.4
        /// How far (per key) the split has to lead the best whole-token reading.
        public var margin = 0.3

        public init() {}
    }

    public enum Split: Equatable, Sendable {
        case korean(MixedWord)
        case japanese(english: String, particle: String)

        public var text: String {
            switch self {
            case .korean(let mixed): mixed.text
            case .japanese(let english, let particle): english + particle
            }
        }
    }

    /// Japanese particles that score `coreParticle` (から, まで, より score `otherParticle`).
    static let coreJapanese: Set<String> = ["で", "に", "を", "は", "が", "の", "と", "も"]
    /// Particles that follow a noun most of the time: they score `coreParticle`.
    static let coreKorean: Set<String> = Set("에 에서 에게 을 를 은 는 이 가 도 로 으로 와 과 의 만 까지 부터 랑 이랑 한테 처럼 보다".split(separator: " ").map(String.init))
    /// Core particles whose keys no English name ends in, after which an unknown word written as
    /// a name (Araso, Esc) pays no `unknownFront`. Not 도, 나 and 이 (eh, sk, di: Neleh, Kursk,
    /// Jordi), nor the endings (해 is go: Thiago).
    static let afterNameParticles: Set<String> = coreKorean.subtracting(["도", "나", "이"])

    public init(english: EnglishModel, korean: KoreanModel = KoreanModel(), japanese: JapaneseModel? = nil,
                weights: Weights = Weights()) {
        self.english = english
        self.korean = korean
        self.japanese = japanese
        self.weights = weights
    }

    /// The best split of `keys`, if it beats reading the whole token as one language.
    /// Japanese particles only with `japaneseOn`.
    public func split(_ keys: String, japaneseOn: Bool) -> Split? {
        scored(keys, japaneseOn: japaneseOn).flatMap { $0.lead >= weights.margin ? $0.split : nil }
    }

    /// The best split and how far it leads the best whole-token reading (for tuning).
    public func scored(_ keys: String, japaneseOn: Bool) -> (split: Split, lead: Double, detail: String)? {
        let chars = Array(keys)
        let n = chars.count
        guard n >= 3, !english.isKnownWord(keys) else { return nil }
        var best: (split: Split, score: Double)?
        func offer(_ split: Split, front: String, particle: Double, korean: String? = nil) {
            guard let w = frontScore(front, asName: korean.map(Self.afterNameParticles.contains) ?? false) else { return }
            var particle = particle
            if let korean, w == weights.acronym,
               MixedWord.particleAgrees(korean, final: MixedWord.finalSound(ofAcronym: front)) == true {
                particle += weights.agreement
            }
            let score = (w + particle - weights.switchCost) / Double(n)
            if best.map({ score > $0.score }) ?? true { best = (split, score) }
        }
        for start in 2..<n {
            let tail = String(chars[start...])
            guard tail.first.map(DubeolsikLayout.startsSyllable) == true,
                  let composed = HangulComposer.compose(keys: tail), composed.strayJamo.isEmpty,
                  MixedWord.suffixes.contains(composed.text) else { continue }
            let front = String(chars[..<start])
            offer(.korean(MixedWord(english: front, koreanKeys: tail, korean: composed.text)), front: front,
                  particle: Self.coreKorean.contains(composed.text) ? weights.coreParticle : weights.otherParticle,
                  korean: composed.text)
        }
        if japaneseOn, japanese != nil {
            for start in max(2, n - 4)..<n {
                let tail = RomajiComposer.compose(String(chars[start...]))
                guard tail.isClean, JapaneseSegmenter.trailingParticles.contains(tail.text) else { continue }
                offer(.japanese(english: String(chars[..<start]), particle: tail.text), front: String(chars[..<start]),
                      particle: Self.coreJapanese.contains(tail.text) ? weights.coreParticle : weights.otherParticle)
            }
        }
        let (w, word) = englishThenKoreanWord(chars)
        guard best != nil || word != nil else { return nil }
        let k = koreanScore(keys)
        let e = english.averageLogProbability(keys) - weights.unknownWord / Double(n)
        let j = japaneseOn ? japaneseScore(keys) : -.infinity
        let whole = max(k, e, j)
        // English + Korean word is a split too, and the particle split has to beat it, but not by
        // `margin`, which is for splitting at all (funeral로 over funer + 미로).
        let detail = String(format: "split=%.2f ko=%.2f en=%.2f ja=%.2f en+ko=%.2f", best?.score ?? -.infinity, k, e, j, w)
        if let best, best.score >= w {
            return (best.split, min(best.score - whole, best.score - w + weights.margin), detail)
        }
        guard let word else { return nil }
        return (.korean(word.word), word.score - whole, detail)
    }

    /// The keys as an English front and a Korean word of two syllables or more, per key
    /// (PC카톡에서, not PCzkxhr에서): the front as `frontScore`, the word as the whole token is
    /// scored as Korean. A word that is only a particle is the particle split, and one with a
    /// syllable nobody writes is no word (mac + 뇃에서 doesn't stop macshot에서).
    ///
    /// `best` is the best cut, the reading a particle split has to beat. `split` is the best cut
    /// that may stand as a split itself (`mayStandAsWord`): an acronym or name and a word (PC카톡,
    /// TV광고) switch language at `switchCost`, as a particle does; an ordinary word and a Korean
    /// word (hello월드) are rarer and pay `wordSwitchCost`, so a name that spells like English
    /// stays whole (cartman isn't car스무).
    func englishThenKoreanWord(_ chars: [Character]) -> (best: Double, split: (word: MixedWord, score: Double)?) {
        let keys = String(chars)
        let englishOnlyCapital = DubeolsikLayout.hasEnglishOnlyCapital(keys)
        // Clean romaji (hasansowo, はさんそを) is Japanese, and keys that read as Korean throughout
        // are Korean, unless a capital no lingering Shift explains says otherwise (ThkT is 쐈).
        let mayStand = !RomajiComposer.compose(keys).isClean && (englishOnlyCapital || !readsAsKorean(keys))
        var best = -Double.infinity
        var split: (word: MixedWord, score: Double)?
        for start in 2..<(chars.count - 1) {
            let front = String(chars[..<start]), back = String(chars[start...])
            guard back.first.map(DubeolsikLayout.startsSyllable) == true,
                  let composed = HangulComposer.compose(keys: back), composed.strayJamo.isEmpty,
                  composed.syllables.count >= 2, !MixedWord.suffixes.contains(composed.text) else { continue }
            let knownKorean = isKoreanWordOrWordWithParticle(composed.text)
            guard knownKorean || readsAsKorean(back), let (w, capitals) = frontReading(front) else { continue }
            let k = koreanScore(back) * Double(back.count)
            // At the cost the cut would pay standing: Lega + 새를 at `switchCost` barred Legato + 를,
            // a better reading than the cut itself at `wordSwitchCost`.
            let cost = capitals ? weights.switchCost : weights.wordSwitchCost
            let score = (w + k - cost) / Double(chars.count)
            best = max(best, score)
            guard mayStand, !capitals || mayStandAsWord(front, englishOnlyCapital: englishOnlyCapital, knownKorean: knownKorean)
            else { continue }
            if split.map({ score > $0.score }) ?? true {
                split = (MixedWord(english: front, koreanKeys: back, korean: composed.text), score)
            }
        }
        return (best, split)
    }

    /// Whether an acronym or name may be the front of a split, not only compete with one: when
    /// a capital no lingering Shift explains is in the keys, or a known Korean word follows and
    /// its own keys spell a syllable no list or corpus has (EU as ㄸ+ㅕ: 뗘). Korean typed fast
    /// keeps its rare syllables (삐졌어 as QLwuTdj: 삐 is rare, but seen) and 쓰정책 (TMwjdcor)
    /// stays Korean. Only the front is judged: the word after may well hold a rare syllable
    /// (또공룡이 as EHrhdfyddl).
    private func mayStandAsWord(_ front: String, englishOnlyCapital: Bool, knownKorean: Bool) -> Bool {
        englishOnlyCapital || !Self.isAcronym(front) || (knownKorean && !spellsSeenKorean(front))
    }

    /// Whole Hangul of syllables seen in the corpus or a word list, however rarely (삐, not 뗘).
    private func spellsSeenKorean(_ keys: String) -> Bool {
        guard let composed = HangulComposer.compose(keys: keys), composed.strayJamo.isEmpty else { return false }
        return composed.syllables.allSatisfy(korean.knowsSyllable)
    }

    /// Whole Hangul made of syllables people use.
    func readsAsKorean(_ keys: String) -> Bool {
        guard let composed = HangulComposer.compose(keys: keys), composed.strayJamo.isEmpty else { return false }
        return composed.syllables.allSatisfy { korean.syllableLogProbability($0) > KoreanModel.unknownSyllableLogP }
    }

    /// The front as English (log-probability of the word); nil when it can't be one. `asName`:
    /// an unknown word written as a name (a capital, then lowercase) is as likely as any word to
    /// have this particle after it.
    func frontScore(_ front: String, asName: Bool = false) -> Double? { frontReading(front, asName: asName)?.score }

    /// `frontScore`, and whether the front is an acronym or a name typed with its capitals.
    func frontReading(_ front: String, asName: Bool = false) -> (score: Double, capitals: Bool)? {
        guard front.count >= 2, front.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        // Capitals that are all shifted jamo in keys that spell clean Hangul are Korean typed
        // with shift (akffkRod: 말라깽, tkrlRns: 사기꾼), not an acronym or a name.
        let korean = front.allSatisfy { !$0.isUppercase || DubeolsikLayout.isKoreanShiftKey($0) }
            && HangulComposer.compose(keys: front).map { $0.strayJamo.isEmpty } == true
        if !korean, Self.isAcronym(front) { return (weights.acronym, true) }
        // A name scores lower the rarer its last part: macOS + 문서에서, not macOSans (Sans) + 서에서.
        if !korean, let level = nameLevel(front) {
            return (weights.name - weights.perLevel * Double(max(0, level - 10)), true)
        }
        // Lowercase (or a capital at the start: a name, or the start of a sentence) needs
        // 3 letters: so + が, me + で are Japanese.
        guard front.count >= 3 else { return nil }
        let spelling = english.averageLogProbability(front) * Double(front.count)
        if let level = english.level(front), level <= EnglishModel.knownLevel {
            return (max(spelling, weights.knownBase - weights.perLevel * Double(level)), false)
        }
        // Written as a name, a capital then lowercase (Araso, Esc, Raycast), an unknown word takes
        // a core particle as often as a known one does (Araso가, Esc를): no `unknownFront` there.
        // Not before every suffix: names end in the keys of 도, 나, 이, 해 (Neleh, Kursk, Jordi,
        // Thiago) and of Japanese particles (Porto, Varga) far more often than Araso도 is typed.
        let name = asName && front.first!.isUppercase && front.dropFirst().allSatisfy(\.isLowercase)
        return (spelling - weights.unknownWord - (name ? 0 : weights.unknownFront), false)
    }

    /// GitHub, VSCode, iPhone, macOS: a capital inside, and the part from the last capital a
    /// known word (Hub, Code) or capitals (OS). Not APIdm. The SCOWL level of that last part
    /// (Code: 10, Hub: 35), 10 for capitals; nil when `front` isn't a name.
    func nameLevel(_ front: String) -> Int? {
        let chars = Array(front)
        guard chars.dropFirst().contains(where: \.isUppercase), chars.contains(where: \.isLowercase),
              let last = chars.lastIndex(where: \.isUppercase) else { return nil }
        if last == chars.count - 1 {
            // Ends in capitals (macOS): the run of them is the last part.
            var start = last
            while start > 0, chars[start - 1].isUppercase { start -= 1 }
            return chars.count - start >= 2 ? 10 : nil
        }
        // The last part starts at the last capital (Code of VSCode, Idm of APIdm).
        let part = String(chars[last...])
        guard part.count >= 3, english.isKnownWord(part) else { return nil }
        return english.level(part)
    }

    /// API, UI, PR: 2 to 6 capitals.
    static func isAcronym(_ front: String) -> Bool {
        (2...6).contains(front.count) && front.allSatisfy(\.isUppercase)
    }

    /// The whole token as Korean, per key. A capital with no shifted jamo (the S of Slack)
    /// can't be Korean.
    func koreanScore(_ keys: String) -> Double {
        guard !SplittingEngine.hasEnglishOnlyCapital(keys), let score = korean.score(keys: keys) else { return -.infinity }
        let composition = score.composition
        if composition.strayJamo.isEmpty, isKoreanWordOrWordWithParticle(composition.text) {
            return max(score.averageLogProbability, weights.koreanWordFloor)
        }
        return score.averageLogProbability
    }

    /// The whole token as kana, per key: only what keeps it from splitting, as the decision
    /// engine reads a capital as English. Capitals after the first letter aren't romaji
    /// (UIde is UI + で); one at the start may begin a sentence (Kyouha stays whole).
    func japaneseScore(_ keys: String) -> Double {
        guard !keys.dropFirst().contains(where: \.isUppercase), let score = japanese?.score(keys: keys) else { return -.infinity }
        return score.averageLogProbability + weights.japaneseOffset
    }

    /// 핸들, 소문은, 행하는: a word of the wider vocabulary, or one with a particle or ending in
    /// the form the word's last syllable takes (씨를, not 씨이 or 씨을).
    func isKoreanWordOrWordWithParticle(_ hangul: String) -> Bool {
        if korean.isVocabularyWord(hangul) { return true }
        let chars = Array(hangul)
        return chars.count > 1 && (1..<chars.count).contains { cut in
            let particle = String(chars[cut...])
            return korean.isVocabularyWord(String(chars[..<cut])) && MixedWord.suffixes.contains(particle)
                && MixedWord.finalSound(of: chars[cut - 1]).flatMap { MixedWord.particleAgrees(particle, final: $0) } != false
        }
    }
}
