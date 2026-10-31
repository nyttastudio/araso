/// Turns a sequence of 2-set keystrokes into Hangul, the same way a standard
/// 두벌식 automaton does (compound vowels, compound finals, final-consonant
/// migration to the next syllable).
public enum HangulComposer {
    public enum Unit: Equatable, Sendable {
        case syllable(Character)
        /// A jamo that never became part of a complete syllable.
        case jamo(Character)

        public var character: Character {
            switch self {
            case .syllable(let c), .jamo(let c): return c
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let units: [Unit]
        public var text: String { String(units.map(\.character)) }
        public var syllables: [Character] {
            units.compactMap { if case .syllable(let c) = $0 { return c } else { return nil } }
        }
        public var strayJamo: [Character] {
            units.compactMap { if case .jamo(let c) = $0 { return c } else { return nil } }
        }
        /// Jamo that can't be Korean even mid-word: stray jamo other than a consonant just
        /// typed to start the next syllable (하느님ㅇ is 하느님의 on its way, 해ㅐ is not Korean).
        public var isBroken: Bool { strayJamo.count > (endsWithPendingConsonant ? 1 : 0) }
        /// True when the last unit is a lone consonant, i.e. the user has just
        /// started the next syllable. Normal while typing, suspicious at a word end.
        public var endsWithPendingConsonant: Bool {
            if case .jamo(let c) = units.last { return Jamo.isConsonant(c) }
            return false
        }
    }

    /// Returns nil if any key is not a letter on the 2-set layout. On 3-set (`KoreanLayout`) the
    /// keys are composed as that layout types them.
    public static func compose(keys: String) -> Result? {
        if KoreanLayout.current.isSebeolsik { return Sebeolsik.compose(keys: keys) }
        var jamos: [Character] = []
        for key in keys {
            guard let j = DubeolsikLayout.jamo(for: key) else { return nil }
            jamos.append(j)
        }
        return compose(jamos: jamos)
    }

    /// The keys composed, or where digits or symbols are inside (k8s, utf-8) each run of letters
    /// composed on its own; nil when a run doesn't compose (or there are no letters).
    public static func composeEachRun(_ keys: String) -> [Result]? {
        if let whole = compose(keys: keys) { return [whole] }
        guard !KoreanLayout.current.isSebeolsik else { return nil }
        let runs = keys.split(whereSeparator: { !$0.isLetter })
        guard !runs.isEmpty else { return nil }
        var results: [Result] = []
        for run in runs {
            guard let result = compose(keys: String(run)) else { return nil }
            results.append(result)
        }
        return results
    }

    /// Keys with digits or symbols inside (k8s, utf-8, an English word that kept them): each run of
    /// letters composed on its own, the rest as typed (ㅏ8ㄴ, ㅕㅅㄹ-8).
    public static func composeRuns(_ keys: String) -> String {
        var text = "", run = ""
        func flush() {
            if !run.isEmpty { text += compose(keys: run)?.text ?? run }
            run = ""
        }
        for key in keys {
            if key.isLetter { run.append(key) } else { flush(); text.append(key) }
        }
        flush()
        return text
    }

    public static func compose(jamos: [Character]) -> Result {
        var units: [Unit] = []
        var cho: Character?
        var jung: Character?
        var jong: Character?

        func flush() {
            if let c = cho, let v = jung {
                units.append(.syllable(Jamo.syllable(cho: c, jung: v, jong: jong)))
            } else {
                if let c = cho { units.append(.jamo(c)) }
                if let v = jung { units.append(.jamo(v)) }
            }
            cho = nil; jung = nil; jong = nil
        }

        for j in jamos {
            if Jamo.isVowel(j) {
                if let v = jung {
                    if let final = jong {
                        // 받침 moves to become the next syllable's initial: 갑+ㅏ → 가바, 값+ㅏ → 갑사
                        if let (stay, move) = Jamo.finalSplits[final] {
                            jong = stay
                            flush()
                            cho = move
                        } else {
                            jong = nil
                            flush()
                            cho = final
                        }
                        jung = j
                    } else if let combined = Jamo.vowelCombos[String([v, j])] {
                        jung = combined
                    } else {
                        flush()
                        jung = j
                    }
                } else {
                    jung = j
                }
            } else {
                if jung == nil || cho == nil {
                    // Nothing to attach to (or a bare vowel): start a new syllable.
                    if cho != nil || jung != nil { flush() }
                    cho = j
                } else if let final = jong {
                    if let combined = Jamo.finalCombos[String([final, j])] {
                        jong = combined
                    } else {
                        flush()
                        cho = j
                    }
                } else if Jamo.jongIndex[j] != nil {
                    jong = j
                } else {
                    // ㄸ ㅃ ㅉ cannot be finals.
                    flush()
                    cho = j
                }
            }
        }
        flush()
        return Result(units: units)
    }
}
