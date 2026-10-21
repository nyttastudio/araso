import Foundation

public enum Language: String, Codable, Sendable {
    case english
    case korean
    /// English word + Korean particle/ending, e.g. `github에` (see `MixedWord`).
    case mixed
    /// Romaji typed as Japanese (rendered as hiragana; kanji conversion happens on Space).
    case japanese

    /// The language a sentence continues in after this word.
    public var sentenceLanguage: Language {
        switch self {
        case .english: return .english
        case .korean, .mixed: return .korean
        case .japanese: return .japanese
        }
    }

    /// What Esc switches to: english → mixed (when the keys split) → korean →
    /// japanese (when enabled) → english. Readings that can't exist for these keys
    /// are skipped (no Korean for "ra-men"), and so are garbled ones (dkssud as
    /// Japanese: dkっすd; loose consonants and ㅜ/ㅠ such as ㅁㅊ or ㅜㅜ aren't garbled) as long as a clean alternative exists — a typo can still
    /// be forced into its language when nothing reads cleanly. `splits`: whether the engine
    /// splits the keys (x에, hello월드 as well as github에); left out, the particle split decides.
    public func next(for keys: String, japanese: Bool = false, splits: Bool? = nil) -> Language {
        let order: [Language] = [.english, .mixed, .korean, .japanese]
        let available = order.filter { language in
            switch language {
            case .english: return true
            case .mixed: return splits ?? (MixedWord.split(keys) != nil)
            case .korean: return HangulComposer.compose(keys: keys) != nil
            case .japanese: return japanese
            }
        }
        let clean = available.filter { language in
            switch language {
            case .english, .mixed: return true
            case .korean: return HangulComposer.compose(keys: keys).map { $0.strayJamo.isEmpty || $0.isJamoAbbreviation } == true
            case .japanese: return RomajiComposer.compose(keys).strayLetters == 0
            }
        }
        let cycle = clean.count >= 2 ? available.filter { clean.contains($0) || $0 == self } : available
        guard let index = cycle.firstIndex(of: self) else { return cycle.first ?? .english }
        return cycle[(index + 1) % cycle.count]
    }
}

/// What the engine knows besides the token itself.
public struct DecisionContext: Sendable {
    /// Language of the previously committed word, if it is recent enough to matter.
    public var previousLanguage: Language?
    /// The token is still being typed (used for the live preview).
    public var partial: Bool
    /// The language the user corrected these keys to once (a weak dictionary entry).
    public var nudge: Language?
    /// The app typed into, for the user's dictionary entries limited to apps.
    public var app: String?

    public init(previousLanguage: Language? = nil, partial: Bool = false, nudge: Language? = nil, app: String? = nil) {
        self.previousLanguage = previousLanguage
        self.partial = partial
        self.nudge = nudge
        self.app = app
    }
}

public struct Decision: Sendable {
    public let language: Language
    /// 0.5 = coin flip, 1.0 = certain.
    public let confidence: Double
    /// What should be committed for this decision.
    public let output: String
    /// Human-readable reasoning, for the CLI and debugging.
    public let explanation: String
    /// The second most likely language, when the engine compared several.
    public var runnerUp: Language? = nil

    public init(language: Language, confidence: Double, output: String, explanation: String, runnerUp: Language? = nil) {
        self.language = language
        self.confidence = confidence
        self.output = output
        self.explanation = explanation
        self.runnerUp = runnerUp
    }
}

/// A local decider that maps raw QWERTY keystrokes of one word to a language.
/// The heuristic engine below is the default; a model-backed engine (e.g. a
/// fine-tuned on-device classifier) can implement the same protocol.
public protocol DecisionEngine: Sendable {
    func decide(_ keys: String, context: DecisionContext) -> Decision
}

extension DecisionEngine {
    /// Renders `keys` in a given language regardless of what the engine would pick.
    public func render(_ keys: String, as language: Language) -> String {
        switch language {
        case .english: return keys
        case .korean: return HangulComposer.compose(keys: keys)?.text ?? keys
        case .mixed:
            // The engine's own split (hello월드, github에); the particle split for engines without one.
            let decision = decide(keys, context: DecisionContext())
            return decision.language == .mixed ? decision.output : MixedWord.split(keys)?.text ?? keys
        case .japanese: return RomajiComposer.compose(keys).text
        }
    }
}

/// Scores the same keystrokes as English (character trigrams + word list), Korean
/// (2-set syllables) and, when enabled, Japanese (romaji → kana trigrams), each as
/// average log-probability per keystroke, nudges the previous word's language, and
/// picks the best. Confidence comes from the gap to the runner-up.
public final class HeuristicEngine: DecisionEngine, @unchecked Sendable {
    public let english: EnglishModel
    public let korean: KoreanModel
    /// Nil when Japanese is off or its model isn't available.
    public let japanese: JapaneseModel?

    /// Added to the previous word's language score: people mostly stay in one language.
    public var contextBias = 0.8
    /// Bias after Japanese text. Raising it to 1.2 recovered 1 of 2,590 held-out phrases
    /// but tripled common English words turning into kana right after Japanese (0.5% → 1.6%).
    public var japaneseContextBias = 0.8
    /// Shifts Japanese scores to the English/Korean scale (kana trigrams over ~80 symbols
    /// per ~2 keys read differently from letter trigrams). Tuned on held-out data so that
    /// English words almost never turn into kana.
    public var japaneseOffset = 0.5
    /// Shifts Korean scores (used when the syllable model changes scale).
    public var koreanOffset = 0.0
    /// Taken off the dictionary floor for rarer English words (SCOWL levels 40–50: dork,
    /// ahem), so a common Korean word with the same keys (애가, 모든) wins the tie.
    public var rareWordFloorPenalty = 0.3
    /// The previous word's pull is scaled by this when the keys are a known word of another
    /// language and not of the previous one (내가 after English, `for` after Korean): that's
    /// someone switching language, not a stray reading.
    public var switchBiasFactor = 0.25
    /// Score floors for a Korean word seen in real text (two or more syllables, one), the
    /// counterpart of the English dictionary floor: 내가, 무슨 stay Korean after English.
    /// A word only in the wider vocabulary (닥터, 했죠: too rare for Tatoeba's sentences), or a
    /// noun the lists have only with a particle (혜택), gets the long floor too, unless the keys
    /// are an English word: that list comes from subtitles, and work (재가) or ahem (모드) must
    /// stay English.
    public var koreanKnownFloor = (long: -1.4, short: -2.0)
    /// How far Japanese must lead before a known English word is turned into kana
    /// outside Japanese text.
    public var englishWordProtection = 1.0
    /// Added to the language the user corrected the keys to once (`DecisionContext.nudge`):
    /// as much as the previous word's pull, so a close call turns and a clear one doesn't.
    public var correctionBias = 0.8

    public let segmenter: JapaneseSegmenter?

    public init(english: EnglishModel = .shared, korean: KoreanModel = KoreanModel(),
                japanese: JapaneseModel? = nil) {
        self.english = english
        self.korean = korean
        self.japanese = japanese
        segmenter = japanese.map { JapaneseSegmenter(english: english, japanese: $0) }
    }

    public func decide(_ keys: String, context: DecisionContext) -> Decision {
        // Shift on a key that has no shifted jamo (e.g. "Hello", "API") is only ever English,
        // unless it lingers from a Korean shift key onto the next key (djEJs 어떤, dPFmf 예를) or
        // is held from one over whole Hangul (RKFRMAgkek 깔끔하다): then the scores decide.
        if DubeolsikLayout.hasEnglishOnlyCapital(keys) {
            return Decision(language: .english, confidence: 0.99, output: keys, explanation: "uppercase outside QWERTOP")
        }

        var e = english.averageLogProbability(keys.filter(\.isLetter))
        // Also while typing: the preview must show what Space/Return will commit.
        let known = english.isKnownWord(keys)
        if known {
            // Short dictionary words collide with real Korean (go=해, so=내, do=애),
            // so they get a weaker boost and leave room for context to decide.
            var floor: Double = keys.count >= 4 ? -1.4 : (keys.count == 3 ? -2.0 : -2.6)
            // to, so, go, do: everyday English just above a one-syllable Korean word (새, 내,
            // 해, 애), so they stay English unless the previous word was Korean.
            if keys.count == 2, english.isCommonWord(keys) { floor = koreanKnownFloor.short + 0.1 }
            if (english.level(keys) ?? 0) > EnglishModel.extraLevel { floor -= rareWordFloorPenalty }
            e = max(e, floor)
        }
        if keys.contains(where: { !$0.isLetter }) { e -= 3 } // "ra-men", "kan'i" aren't English

        var k = korean.score(keys: keys, partial: context.partial)
        let knownKorean = k.map {
            $0.composition.strayJamo.isEmpty && (korean.isKnownWord($0.composition.text)
                || (!known && (korean.isVocabularyWord($0.composition.text) || korean.isRareVocabularyWord($0.composition.text)
                    || korean.isKnownStem($0.composition.text))))
        } ?? false
        if let score = k, knownKorean {
            let floor = score.composition.syllables.count >= 2 ? koreanKnownFloor.long : koreanKnownFloor.short
            k = KoreanModel.Score(averageLogProbability: max(score.averageLogProbability, floor), composition: score.composition)
        }
        // A dictionary English word may already be complete, and so are chat jamo (ㅜㅜ): score
        // the Japanese reading as finished too, so the preview shows what Space will commit
        // ("to" stays to, not と; nn shows ㅜㅜ, not ん that Space turned into ㅜㅜ). So is a
        // doubled consonant with nothing after its っ (ff, ww): no Japanese word is only っ, so
        // it isn't one on its way (ff showed っf and went in as ff); って (tte) still is.
        let chat = k?.composition.isChat == true
        let sokuonFirst = RomajiComposer.compose(keys, partial: true).isOnlySokuon
        // A capital is never romaji: Japanese IMEs type ⇧ letters as themselves (⇧O is O, not お).
        let j = keys.contains(where: \.isUppercase) ? nil
            : japanese?.score(keys: keys, partial: context.partial && !known && !chat && !sokuonFirst)
        // English words inside a Japanese phrase (googlede…) score as segmented Japanese,
        // not as kana with stray letters.
        var segmented: (segments: [JapaneseSegmenter.Segment], score: Double)?
        if let j, j.composition.strayLetters > 0, let segmenter {
            segmented = segmenter.scoredSegments(keys)
        }
        let japaneseScore = j.map { j in
            max(j.averageLogProbability, (segmented?.score).map { $0 / Double(keys.count) } ?? -.infinity)
        }

        var scores: [(Language, Double)] = [(.english, e)]
        if let k { scores.append((.korean, k.averageLogProbability + koreanOffset)) }
        if let japaneseScore { scores.append((.japanese, japaneseScore + japaneseOffset)) }
        if let previous = context.previousLanguage?.sentenceLanguage, let i = scores.firstIndex(where: { $0.0 == previous }) {
            var bias = previous == .japanese ? japaneseContextBias : contextBias
            let knownIn: [Language: Bool] = [.english: known, .korean: knownKorean, .japanese: false]
            if knownIn[previous] == false, knownIn.contains(where: { $0.key != previous && $0.value }) {
                bias *= switchBiasFactor
            }
            scores[i].1 += bias
        }
        if let nudge = context.nudge, nudge != .mixed, let i = scores.firstIndex(where: { $0.0 == nudge }) {
            scores[i].1 += correctionBias
        }
        scores.sort { $0.1 > $1.1 }

        // A dictionary English word only becomes kana on a clear win, unless we're already
        // in Japanese text or the user corrected it to Japanese once (where "same", "sake", "kite" are Japanese words).
        if known, scores[0].0 == .japanese, context.previousLanguage?.sentenceLanguage != .japanese, context.nudge != .japanese,
           let englishIndex = scores.firstIndex(where: { $0.0 == .english }),
           scores[0].1 - scores[englishIndex].1 < englishWordProtection {
            scores.swapAt(0, englishIndex)
        }

        let (language, best) = scores[0]
        let runnerUp = scores.count > 1 ? scores[1] : nil
        let margin = best - (runnerUp?.1 ?? best - 5)
        let confidence = 1 / (1 + exp(-margin * 2))
        let output: String
        switch language {
        case .korean: output = k?.composition.text ?? keys
        case .japanese: output = segmented.map { JapaneseSegmenter.text($0.segments) } ?? j?.composition.text ?? keys
        default: output = keys
        }
        let detail = scores.map { String(format: "%@=%.2f", String($0.0.rawValue.prefix(2)), $0.1) }.joined(separator: " ")
        return Decision(language: language, confidence: confidence, output: output,
                        explanation: detail + (known ? " (dict)" : "") + String(format: " margin=%+.2f", margin),
                        runnerUp: runnerUp?.0)
    }
}

