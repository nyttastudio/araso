/// An English word with a Korean particle or ending typed straight after it,
/// e.g. `githubdp` → `github에`, `APIfmf` → `API를`, `commitgotj` → `commit해서`.
public struct MixedWord: Equatable, Sendable {
    public let english: String
    public let koreanKeys: String
    public let korean: String

    public var text: String { english + korean }

    /// Particles and endings that commonly attach directly to a (loan)word.
    static let suffixes: Set<String> = Set("""
    에 에서 에게 에는 에서는 에도 에서도 의 을 를 은 는 이 가 도 로 으로 와 과 랑 이랑 하고 한테 까지 부터 만 보다
    처럼 이나 나 이야 야 이에요 예요 이다 입니다 인데 이라 이라고 라고 으로는 로는 으로도 로도 이고 이지 이랑은
    했어 했다 했어요 했는데 했고 했지 했음 해서 해야 하는 하면 하고 하기 하게 하다 해 해요 합니다 할 한 함 하자 해줘 해봐
    됐어 됐다 된 되는 되면 돼 돼요 됩니다 같은 같아 적 적인 적으로 스럽게 같이 들 들이 들을 들은 에요 이요 를요 을요
    같은건 같은거 같은게 같은걸 같은데 같다 같네 같아서 같은지 같고 같아요 인가 인지 인데요 인건 인게 인거
    이라는 라는 이란 에선 으론 로서 으로서
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Particles with a form after a final consonant and one after a vowel (책을, 사과를): the
    /// consonant form first. A final ㄹ takes the vowel form of 으로 (서울로).
    static let pairedParticles: [(consonant: String, vowel: String)] = [
        ("을", "를"), ("은", "는"), ("이", "가"), ("과", "와"), ("이랑", "랑"), ("이랑은", "랑은"),
        ("으로", "로"), ("으로는", "로는"), ("으로도", "로도"), ("으론", "론"), ("으로서", "로서"),
        ("이나", "나"), ("이야", "야"), ("이라", "라"), ("이라고", "라고"), ("이라는", "라는"), ("이란", "란"),
        ("이에요", "예요"),
    ]

    /// Whether `particle` is the form that follows a word ending as `final` describes:
    /// nil for a particle that has one form (에, 도, 의), else true or false (씨이, 쓰은 are wrong).
    static func particleAgrees(_ particle: String, final: FinalSound) -> Bool? {
        for pair in pairedParticles {
            if particle == pair.consonant {
                return final == .consonant || (final == .rieul && !pair.consonant.hasPrefix("으"))
            }
            if particle == pair.vowel {
                return final == .vowel || (final == .rieul && pair.consonant.hasPrefix("으"))
            }
        }
        return nil
    }

    enum FinalSound { case vowel, consonant, rieul }

    /// How a Hangul syllable ends; nil for anything else.
    static func finalSound(of syllable: Character) -> FinalSound? {
        guard let scalar = syllable.unicodeScalars.first, syllable.unicodeScalars.count == 1,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        switch (scalar.value - 0xAC00) % 28 {
        case 0: return .vowel
        case 8: return .rieul
        default: return .consonant
        }
    }

    /// How an acronym ends when read letter by letter: L, M, N and R (엘, 엠, 엔, 알) on a final
    /// consonant, every other letter's name on a vowel (TM은, TV는).
    static func finalSound(ofAcronym acronym: String) -> FinalSound {
        switch acronym.last?.uppercased() {
        case "L", "R": return .rieul
        case "M", "N": return .consonant
        default: return .vowel
        }
    }

    /// Particles that follow a single letter (x에, n이, a를, X축의 X): case particles only, not
    /// endings like 해/한, so short English (ago) doesn't split.
    static let singleLetterParticles: Set<String> = Set("""
    에 에서 에게 에는 에서는 에도 의 을 를 은 는 이 가 도 로 으로 와 과 랑 이랑 하고 한테 까지 부터 만 보다
    처럼 이나 나 이라 이라고 라고 이랑은 으로는 로는 같은 같이
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// A single letter and a particle: `xdp` → `x에`, `Xfmf` → `X를`. One key on its own can't
    /// make a Hangul syllable before another consonant, so the keys never read as Korean.
    public static func splitSingleLetter(_ keys: String) -> MixedWord? {
        guard keys.count >= 2, let first = keys.first, first.isASCII, first.isLetter else { return nil }
        let suffixKeys = String(keys.dropFirst())
        guard suffixKeys.first.map(DubeolsikLayout.startsSyllable) == true,
              let composed = HangulComposer.compose(keys: suffixKeys), composed.strayJamo.isEmpty,
              singleLetterParticles.contains(composed.text) else { return nil }
        // 도 and 나 are the keys eh and sk, common English endings (heh, meh, yeh, tsk): after a
        // lowercase letter they stay English. A capital (X도) was typed on purpose.
        if first.isLowercase, ["도", "나"].contains(composed.text) { return nil }
        return MixedWord(english: String(first), koreanKeys: suffixKeys, korean: composed.text)
    }

    /// Splits off the longest Korean particle/ending at the end of `keys`.
    /// Only the shape is checked here; whether the front really is English is
    /// up to the caller (see `SplittingEngine`).
    public static func split(_ keys: String) -> MixedWord? {
        let chars = Array(keys)
        // Front needs at least 2 letters; try the longest suffix first.
        guard chars.count >= 3 else { return nil }
        for start in 2..<chars.count {
            let suffixKeys = String(chars[start...])
            guard suffixKeys.first.map(DubeolsikLayout.startsSyllable) == true,
                  let composed = HangulComposer.compose(keys: suffixKeys),
                  composed.strayJamo.isEmpty,
                  suffixes.contains(composed.text) else { continue }
            return MixedWord(english: String(chars[..<start]), koreanKeys: suffixKeys, korean: composed.text)
        }
        return nil
    }
}

extension DubeolsikLayout {
    /// A Korean syllable has to start with a consonant key.
    static func startsSyllable(_ key: Character) -> Bool {
        if KoreanLayout.current.isSebeolsik { return Sebeolsik.startsSyllable(key) }
        return jamo(for: key).map(Jamo.isConsonant) ?? false
    }
}

/// Decides `mixed` for English and Korean typed as one token: English + particle (github에),
/// a single letter + particle (x에), English + Korean word (hello월드), and with Japanese on
/// English + Japanese particle (githubで). Never when the whole token is a known English word or
/// reads as ordinary Korean (every syllable is one people actually use).
public final class SplittingEngine: DecisionEngine, @unchecked Sendable {
    public let base: DecisionEngine
    public let english: EnglishModel
    public let korean: KoreanModel
    /// How sure a split is: above Strict (`AppPolicy.strictThreshold`), since each rule already
    /// asks for an English front it can stand on, so github에 splits in a terminal too.
    public static let confidence = 0.98

    /// With Japanese on: English word + Japanese particle (githubで), decided the same way.
    public let japanese: JapaneseSegmenter?

    /// Scores English word + particle, and English + Korean word, against the whole token.
    public let particles: ParticleSplitter

    public init(base: DecisionEngine, english: EnglishModel, korean: KoreanModel = KoreanModel(),
                japanese: JapaneseSegmenter? = nil) {
        self.base = base
        self.english = english
        self.korean = korean
        self.japanese = japanese
        particles = ParticleSplitter(english: english, korean: korean, japanese: japanese?.japanese)
    }

    public func decide(_ keys: String, context: DecisionContext) -> Decision {
        // English word + particle, Korean (github에) or with Japanese on Japanese (githubで),
        // when that reading beats the whole token in one language. Before English + Korean
        // word: beautywo is beauty + を, not beau + 쇼재.
        switch particles.split(keys, japaneseOn: japanese != nil && context.japanese) {
        case .korean(let mixed)?:
            return Decision(language: .mixed, confidence: Self.confidence, output: mixed.text,
                            explanation: "split \(mixed.english)+\(mixed.korean)")
        case .japanese(let word, let particle)?:
            return Decision(language: .japanese, confidence: Self.confidence, output: word + particle,
                            explanation: "split \(word)+\(particle)")
        case nil: break
        }
        if let mixed = MixedWord.splitSingleLetter(keys), !english.isKnownWord(keys), !particles.readsAsKorean(keys) {
            return Decision(language: .mixed, confidence: Self.confidence, output: mixed.text,
                            explanation: "split \(mixed.english)+\(mixed.korean)")
        }
        return base.decide(keys, context: context)
    }

    /// A capital no lingering Shift explains (RNl, 꿀 typed fast, isn't a name).
    static func hasEnglishOnlyCapital(_ front: String) -> Bool {
        DubeolsikLayout.hasEnglishOnlyCapital(front)
    }
}
