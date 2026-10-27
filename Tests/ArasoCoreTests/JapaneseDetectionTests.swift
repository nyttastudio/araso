import Testing
@testable import ArasoCore

let trilingual = HeuristicEngine(english: sharedEngine.english, korean: sharedEngine.korean, japanese: JapaneseModel.shared)

@Suite struct JapaneseDetectionTests {
    @Test func modelLoads() {
        #expect(JapaneseModel.shared != nil)
    }

    @Test(arguments: [
        ("konnichiha", "こんにちは"), ("watashihagakuseidesu", "わたしはがくせいです"), ("arigatougozaimasu", "ありがとうございます"),
        ("kyouhaiitenkidesune", "きょうはいいてんきですね"), ("ra-mentabetai", "らーめんたべたい"), ("sumimasen", "すみません"),
        ("yoroshikuonegaishimasu", "よろしくおねがいします"), ("daijoubu", "だいじょうぶ"),
    ])
    func japanesePhrases(keys: String, kana: String) {
        let d = trilingual.decide(keys, context: DecisionContext())
        #expect(d.language == .japanese, "\(keys): \(d.explanation)")
        #expect(d.output == kana)
    }

    @Test(arguments: ["hello", "world", "keyboard", "wanna", "gotta", "the", "people", "thanks", "commit", "same"])
    func englishStaysEnglish(word: String) {
        let d = trilingual.decide(word, context: DecisionContext())
        #expect(d.language == .english, "\(word): \(d.explanation)")
    }

    @Test(arguments: [("dkssudgktpdy", "안녕하세요"), ("gksrmf", "한글"), ("rkatkgkqslek", "감사합니다"), ("tkfkd", "사랑")])
    func koreanStaysKorean(keys: String, hangul: String) {
        let d = trilingual.decide(keys, context: DecisionContext())
        #expect(d.language == .korean, "\(keys): \(d.explanation)")
        #expect(d.output == hangul)
    }

    /// After English, keys the English list doesn't know that read as clean kana, four or more,
    /// are a Japanese phrase: the previous word pulls at them as little as at 내가 after English.
    @Test(arguments: [("inumanisentaku", "いぬまにせんたく"), ("haitatsuba", "はいたつば"), ("tahidari", "たひだり"), ("hashinde", "はしんで")])
    func japanesePhraseAfterEnglish(keys: String, kana: String) {
        let d = trilingual.decide(keys, context: DecisionContext(previousLanguage: .english))
        #expect(d.language == .japanese && d.output == kana, "\(keys): \(d.output) \(d.explanation)")
    }

    /// Shorter clean kana after English (tai, shi, karan) are names and abbreviations more often
    /// than Japanese, and a known English word (same, kite) is English there whatever its kana.
    @Test(arguments: ["tai", "shi", "karan", "same", "kite", "hello", "machine"])
    func shortOrKnownWordAfterEnglishStaysEnglish(word: String) {
        let d = trilingual.decide(word, context: DecisionContext(previousLanguage: .english))
        #expect(d.language == .english, "\(word): \(d.output) \(d.explanation)")
    }

    @Test func japaneseContextHelpsAmbiguousWords() {
        // "kami" (紙/髪/神) after Japanese reads as Japanese.
        #expect(trilingual.decide("kamiwo", context: DecisionContext(previousLanguage: .japanese)).language == .japanese)
    }

    @Test func escCycleIncludesJapaneseOnlyWhenEnabled() {
        #expect(Language.korean.next(for: "sushi", japanese: true) == .japanese)
        #expect(Language.korean.next(for: "sushi", japanese: false) == .english)
        #expect(Language.japanese.next(for: "sushi", japanese: true) == .english)
        // No Korean reading for "ra-men".
        #expect(Language.english.next(for: "ra-men", japanese: true) == .japanese)
    }

    @Test func japaneseOffByDefault() {
        #expect(sharedEngine.decide("konnichiha", context: DecisionContext()).language != .japanese)
    }
}
