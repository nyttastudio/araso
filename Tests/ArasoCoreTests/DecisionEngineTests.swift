import Foundation
import Testing
@testable import ArasoCore

let sharedEngine = HeuristicEngine()

@Suite struct DecisionEngineTests {
    let converter = TextConverter(engine: sharedEngine)

    @Test(arguments: [
        "hello", "world", "the", "keyboard", "language", "switch", "input", "method",
        "files", "running", "commit", "github", "please", "thanks", "Apple", "API", "is", "a",
        "computer", "people", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
    ])
    func englishWordsStayEnglish(word: String) {
        let d = sharedEngine.decide(word, context: DecisionContext())
        #expect(d.language == .english, "\(word) → \(d.output) \(d.explanation)")
    }

    @Test(arguments: [
        ("dkssudgktpdy", "안녕하세요"), ("gksrmf", "한글"), ("rkatkgkqslek", "감사합니다"),
        ("dhsmf", "오늘"), ("skfTl", "날씨"), ("whgdk", "좋아"), ("dlTek", "있다"),
        ("tkfkd", "사랑"), ("zjavbxj", "컴퓨터"), ("vmfhrmfoa", "프로그램"), ("wjdakf", "정말"),
        ("rhakdnj", "고마워"), ("wkf", "잘"), ("ajrdj", "먹어"), ("zzz", "ㅋㅋㅋ"),
        ("dlrjs", "이건"), ("djEjg", "어떻"), ("tlrks", "시간"), ("rmfjsep", "그런데"),
    ])
    func koreanKeystrokesBecomeHangul(keys: String, expected: String) {
        let d = sharedEngine.decide(keys, context: DecisionContext())
        #expect(d.language == .korean, "\(keys) → \(d.output) \(d.explanation)")
        #expect(d.output == expected)
    }

    // Shift held a key too long after a double consonant (어떤's ㄸ, 바뀌's ㄲ) capitalizes the
    // next key, which has no shifted jamo. That is Korean typed fast, not English.
    @Test(arguments: [
        ("djEJs", "어떤"), ("qkRNl", "바뀌"), ("qkRNleh", "바뀌도"), ("RNfdmf", "꿀을"),
        ("EKfktj", "따라서"), ("TkdRjvnf", "쌍꺼풀"), ("TKdRJvnf", "쌍꺼풀"),
        // Reported on the PR (HyeonWooLee).
        ("djEJfRkdy", "어떨까요"), ("gkfRK", "할까"), ("wlsWK", "진짜"), ("TMfkrh", "쓰라고"),
        ("qkRNjTdj", "바꿨어"), ("ahtjflWHrdl", "모서리쪽이"), ("RKwl", "까지"),
        // ㅒ/ㅖ on a consonant, Shift still down for the consonant after (예를 as dPFmf).
        ("dPFmf", "예를"), ("rOSp", "걔네"), ("rPFks", "계란"), ("dPDhl", "예외"),
        // ㅆ or ㄲ as a final consonant, so a consonant key comes next (있어 as dlTDj).
        ("dlTDj", "있어"), ("dlTSp", "있네"), ("qkRDp", "밖에"),
    ])
    func lingeringShiftAfterKoreanShiftKeyStaysKorean(keys: String, expected: String) {
        let d = sharedEngine.decide(keys, context: DecisionContext())
        #expect(d.language == .korean, "\(keys) → \(d.output) \(d.explanation)")
        #expect(d.output == expected)
    }

    // Shift held down on purpose from a double consonant over the keys after it, which it doesn't
    // change, and let go before the word ends (빨리 as QKFfl, 깔끔하다 as RKFRmagkek).
    @Test(arguments: [
        ("QKFfl", "빨리"), ("RKFRmagkek", "깔끔하다"), ("wkaRKSaks", "잠깐만"), ("QNSDLdi", "뿐이야"),
        ("dlTDJdy", "있어요"), ("goTSMSep", "했는데"),
    ])
    func heldShiftAfterKoreanShiftKeyStaysKorean(keys: String, expected: String) {
        let d = sharedEngine.decide(keys, context: DecisionContext())
        #expect(d.language == .korean, "\(keys) → \(d.output) \(d.explanation)")
        #expect(d.output == expected)
    }

    // A capital that no lingering Shift explains is still only ever English, after a Korean
    // word too. A Shift lingers between lowercase keys, so an acronym typed in capitals
    // throughout (TM, RN, TL) keeps the rule even when it starts on a Korean shift key, and so
    // does a consonant key after a double consonant that begins a syllable (TFxla, PCqkd) or after
    // ㅒ/ㅖ with no consonant before it (OAuth). tvOS is a lingering Shift by shape (ㅖ on ㅍ, then
    // ㄴ) and stays English by its scores.
    @Test(arguments: ["Hello", "API", "TV", "OK", "QA", "WE", "QUICK", "TEst", "iPhone", "GitHub", "dHello",
                      "TM", "EU", "RN", "TL", "THe", "WHat", "THis", "QUery", "tvOS", "PCqkd", "OAuth", "TFxla"])
    func capitalsOutsideKoreanShiftKeysStayEnglish(word: String) {
        for previous in [nil, Language.english, .korean] {
            let d = sharedEngine.decide(word, context: DecisionContext(previousLanguage: previous))
            #expect(d.language == .english, "\(word) after \(String(describing: previous)) → \(d.output) \(d.explanation)")
            #expect(d.output == word)
        }
    }

    // The rule, not the scores: an English-only capital is as sure after a Korean word as anywhere
    // (PCqkd had fallen to 0.70 when every capital after a Korean shift key was a lingering Shift).
    @Test(arguments: ["PCqkd", "OAuth", "TFxla", "PDF", "WWDC"])
    func englishOnlyCapitalIsCertainAfterKorean(word: String) {
        let d = sharedEngine.decide(word, context: DecisionContext(previousLanguage: .korean))
        #expect(d.language == .english)
        #expect(d.confidence >= 0.99, "\(word) → \(d.confidence) \(d.explanation)")
    }

    @Test func mixedSentence() {
        #expect(converter.convert("dkssudgktpdy, hello world!").output == "안녕하세요, hello world!")
        #expect(converter.convert("dlrjs github dp commit gkf rjdi").output == "이건 github 에 commit 할 거야")
        #expect(converter.convert("tmvmfls API qkfvy wnsql").output == "스프린 API 발표 준비")
    }

    @Test func contextResolvesShortCollisions() {
        // "go" is English, but also 해 — the previous word tips it.
        #expect(converter.convert("let's go").output == "let's go")
        #expect(converter.convert("dlrj go").output == "이거 해")
    }

    /// A Korean word that Tatoeba's sentences lack (닥터, 했죠), or have only with a particle
    /// (혜택 from 혜택을), is as sure after English as a Strict app needs. An English word whose
    /// keys spell a listed one (work: 재가, ahem: 모드) stays English.
    @Test(arguments: [("gPxor", "혜택"), ("ekrxj", "닥터"), ("goTwy", "했죠"), ("whwl", "조지")])
    func vocabularyWordsAfterEnglish(keys: String, expected: String) {
        let d = sharedEngine.decide(keys, context: DecisionContext(previousLanguage: .english))
        #expect(d.language == .korean && d.output == expected, "\(keys) → \(d.output) \(d.explanation)")
        #expect(d.confidence >= AppPolicy.strictThreshold, "\(keys) \(d.explanation)")
    }

    /// A noun too rare for the syllable counts (촉 is seen twice) is Korean once the subtitles
    /// list it, even with no previous word to lean on.
    @Test func rareNounFromTheFullList() {
        let d = sharedEngine.decide("chrao", context: DecisionContext())
        #expect(d.language == .korean && d.output == "촉매", "\(d.output) \(d.explanation)")
    }

    @Test(arguments: ["work", "ahem", "claus"])
    func englishWordsSpellingVocabularyStayEnglish(word: String) {
        for previous in [nil, Language.korean] {
            let d = sharedEngine.decide(word, context: DecisionContext(previousLanguage: previous))
            #expect(d.language == .english, "\(word) after \(String(describing: previous)) → \(d.output) \(d.explanation)")
        }
    }

    /// SCOWL lists its words' inflections, so a guessed one counts only for a stem the list
    /// ranks above its rarest level: thru (50, 35 as a `commonWords` slang word) + s and ahem
    /// (50) + s are no words, and their keys are 소견 and 모든. travelling and maths, from
    /// commoner stems the list lacks the form of, still are.
    @Test(arguments: [("thrus", "소견"), ("ahems", "모든")])
    func noGuessedInflectionOfARareStem(keys: String, expected: String) {
        #expect(!EnglishModel.shared.isKnownWord(keys))
        let d = sharedEngine.decide(keys, context: DecisionContext())
        #expect(d.language == .korean && d.output == expected, "\(keys) → \(d.output) \(d.explanation)")
    }

    @Test(arguments: ["travelling", "cancelled", "maths", "onwards"])
    func guessedInflectionOfACommonStemIsAWord(word: String) {
        #expect(EnglishModel.shared.isKnownWord(word))
    }

    @Test func learningOverridesBase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let learning = DictionaryEngine(base: sharedEngine, storeURL: url)
        #expect(learning.decide("hello", context: DecisionContext()).language == .english)
        learning.learn("hello", as: .korean)
        #expect(learning.decide("hello", context: DecisionContext()).language == .english) // once: not yet
        learning.learn("hello", as: .korean)
        #expect(learning.decide("hello", context: DecisionContext()).output == "ㅗ디ㅣㅐ")
        // Persisted and reloaded.
        let reloaded = DictionaryEngine(base: sharedEngine, storeURL: url)
        #expect(reloaded.decide("hello", context: DecisionContext()).language == .korean)
        // Learning the base choice removes the override.
        reloaded.learn("hello", as: .english)
        #expect(reloaded.decide("hello", context: DecisionContext()).language == .english)
    }

    /// A lexicon.json it can't read (hand-edited, another version) is set aside, not overwritten.
    @Test func unreadableLexiconIsKeptAside() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-test-\(UUID().uuidString).json")
        let aside = url.appendingPathExtension("unreadable")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: aside) }
        try Data(#"{"de": "japanese"}"#.utf8).write(to: url)
        let learning = DictionaryEngine(base: sharedEngine, storeURL: url)
        #expect(learning.learned.isEmpty && learning.pending.isEmpty)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        // A different correction than before starts over.
        learning.learn("rjtm", as: .english, engineChoice: .korean)
        learning.learn("rjtm", as: .mixed, engineChoice: .korean)
        #expect(learning.learned.isEmpty && learning.pending == ["rjtm": .mixed])
    }

    @Test func partialPreviewDoesNotPunishPendingConsonant() {
        // "dkss" = 안 + next ㄴ while typing 안녕
        let partial = sharedEngine.decide("dkss", context: DecisionContext(partial: true))
        #expect(partial.language == .korean, "\(partial.explanation)")
    }
}
