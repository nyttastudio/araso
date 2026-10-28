import Foundation
import Testing
@testable import ArasoCore

/// Deterministic converter: a few readings with fixed candidates, including a
/// first-clause candidate to exercise partial commits.
@MainActor final class FakeConverter: JapaneseConverter {
    var learned: [String] = []
    func candidates(for kana: String) -> [ConversionCandidate] {
        switch kana {
        case "きょうはいいてんきですね":
            return [.init(text: "今日はいい天気ですね", kanaCount: 12), .init(text: "今日は", kanaCount: 4),
                    .init(text: kana, kanaCount: 12)]
        case "いいてんきですね":
            return [.init(text: "いい天気ですね", kanaCount: 8), .init(text: kana, kanaCount: 8)]
        case "へんかん":
            return [.init(text: "変換", kanaCount: 4), .init(text: "返還", kanaCount: 4), .init(text: "編纂", kanaCount: 4)]
        case "しょう": // the engine puts the reading first
            return [.init(text: kana, kanaCount: 3), .init(text: "翔", kanaCount: 3), .init(text: "小", kanaCount: 3)]
        case "３がつ":
            return [.init(text: "三月", kanaCount: 3), .init(text: "３月", kanaCount: 3), .init(text: "3月", kanaCount: 3)]
        case "3じ":
            return [.init(text: "三時", kanaCount: 2), .init(text: "３時", kanaCount: 2), .init(text: "3時", kanaCount: 2),
                    .init(text: "3", kanaCount: 1)]
        case "１２３":
            return [.init(text: "一二三", kanaCount: 3), .init(text: "123", kanaCount: 3), .init(text: kana, kanaCount: 3)]
        default:
            return [.init(text: kana, kanaCount: kana.count)]
        }
    }
    func learn(_ candidate: ConversionCandidate, for kana: String) { learned.append(candidate.text) }
    func save() {}
    func moreCandidates(for kana: String) -> [ConversionCandidate] {
        kana == "しょう" ? [.init(text: "小", kanaCount: 3), .init(text: "硝", kanaCount: 3)] : []
    }
}

@MainActor @Suite struct JapaneseSessionTests {
    let field = FakeTextField()
    let converter = FakeConverter()
    let session: InputSession

    init() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-ja-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        session = InputSession(engine: engine, converter: converter, japaneseEnabled: true)
    }

    func type(_ s: String) {
        // Keys the input method passes on are typed by the app, as in a real text field.
        for ch in s {
            let handled = ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    @Test func previewShowsKanaWhileTyping() {
        type("kyouhaiitenk")
        #expect(field.text == "きょうはいいてんk")
    }

    /// A Japanese phrase after an English word is shown as kana before Space too, also when its
    /// last letter is an n still pending while typing (すみませn, かんぜn: the fourth kana only
    /// with that n): the phrase is judged on its finished reading, as the commit is.
    @Test(arguments: [("sumimasen", "すみませn"), ("shinkansen", "しんかんせn"), ("inumanisentaku", "いぬまにせんたく"), ("kanzen", "かんぜn"), ("shinbun", "しんぶn"), ("ninjin", "にんじn")])
    func japanesePhraseAfterEnglishIsShownAsKana(keys: String, kana: String) {
        type("hello " + keys)
        #expect(field.text == "hello " + kana, Comment(rawValue: field.text))
    }

    /// A capital is never romaji, as in macOS's Japanese input method: ⇧P shows P while typed
    /// (not the p of a letter waiting for its vowel), and ⇧O is O, not お.
    @Test func capitalLetterIsNotRomaji() {
        type("hello P")
        #expect(field.text == "hello P")
        type(" O")
        #expect(field.text == "hello P O")
        type(" ")
        #expect(field.text == "hello P O ")
    }

    /// Return commits what was shown: letters waiting for their vowel stay letters rather than
    /// splitting an English word out of the phrase (わたしhag), and only n becomes ん.
    @Test func returnCommitsPendingLettersAsShown() {
        for (keys, shown, committed) in [("watashihag", "わたしはg", "わたしはg"), ("kyouhaiitenkides", "きょうはいいてんきでs", "きょうはいいてんきでs"),
                                         ("nagaremasen", "ながれませn", "ながれません")] {
            type(keys)
            #expect(field.text.hasSuffix(shown), "\(keys): \(field.text)")
            #expect(session.handle(.enter, client: field))
            #expect(field.text.hasSuffix(committed), "\(keys): \(field.text)")
            type(" ")
        }
    }

    @Test func spaceConvertsAndReturnCommits() {
        type("kyouhaiitenkidesune ")
        #expect(session.conversion != nil)
        #expect(field.text == "今日はいい天気ですね")
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "今日はいい天気ですね")
        #expect(session.conversion == nil)
        #expect(converter.learned == ["今日はいい天気ですね"])
    }

    /// A short word shown as kana converts on Space, though once it ends it reads as English
    /// (zio showed じお, then went in as "zio"); an English word still goes in as typed.
    @Test func spaceConvertsAShortWordShownAsKana() {
        type("zio")
        #expect(field.text == "じお")
        type(" ")
        #expect(session.conversion != nil)
        #expect(session.handle(.enter, client: field))
        type("taco ")
        #expect(field.text == "じおtaco ")
    }

    @Test func spaceCyclesCandidatesAndNumbersPick() {
        type("henkan ")
        #expect(field.text == "変換")
        type(" ")
        #expect(field.text == "返還")
        session.handle(.up, client: field)
        #expect(field.text == "変換")
        type("3")
        #expect(field.text == "編纂")
        #expect(session.conversion == nil)
    }

    @Test func firstClauseCandidateKeepsConvertingTheRest() {
        type("kyouhaiitenkidesune ")
        session.handle(.down, client: field) // 今日は (covers 4 kana)
        #expect(field.text == "今日はいいてんきですね")
        session.handle(.enter, client: field)
        #expect(field.text == "今日はいい天気ですね")
        #expect(session.conversion?.kana == "いいてんきですね")
        session.handle(.enter, client: field)
        #expect(session.conversion == nil)
        #expect(field.text == "今日はいい天気ですね")
    }

    /// The clause the candidates are for is marked as the selected one, so the app draws where
    /// ←/→ put the boundary; the kana typed before Space are plain marked text.
    @Test func conversionMarksTheSelectedClause() {
        type("kyouhaiitenkidesune")
        #expect(field.selectedClause == nil)
        type(" ")
        #expect(field.selectedClause == NSRange(location: 0, length: 10)) // 今日はいい天気ですね, all of it
        session.handle(.down, client: field) // 今日は|いいてんきですね
        #expect(field.text == "今日はいいてんきですね")
        #expect(field.selectedClause == NSRange(location: 0, length: 3))
        session.handle(.enter, client: field) // 今日は goes in; the rest is converted on its own
        #expect(field.selectedClause == NSRange(location: 0, length: 7)) // いい天気ですね
    }

    /// The homophones past the converter's list follow it in the candidate window, once each.
    @Test func candidateWindowListsEveryHomophone() {
        type("shou ")
        #expect(session.conversion?.candidates.map(\.text) == ["しょう", "翔", "小", "硝"])
    }

    /// Esc on kana cancels the phrase where Esc isn't a switch key, as in macOS's Japanese input:
    /// nothing goes in and the app doesn't get the key.
    @Test func escapeOnKanaCancelsThePhrase() {
        type("hello henkan")
        #expect(session.handle(.escape, client: field))
        #expect(field.text == "hello " && session.keys.isEmpty)
        type("dkssud ")
        #expect(field.text == "hello 안녕 ")
    }

    /// With live conversion a short reading stays kana on screen (しょう); Space shows a
    /// conversion, 翔, rather than the kana the engine put first.
    @Test func spaceOnAShortReadingShowsAConversion() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "shou" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "しょう")
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text == "翔")
    }

    /// With live conversion a switch key takes a converted phrase back to its kana first, but a
    /// phrase showing its kana anyway (きょうは, whose first candidate is the kana) switches at once.
    @Test func switchKeyOnAKanaShownLivePhraseSwitchesAtOnce() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "kyouha" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "きょうは")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "kyouha")
    }

    @Test func switchKeyOnAConvertedLivePhraseShowsTheKanaFirst() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "kyouhaiitenkidesune" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "今日はいい天気ですね")
        _ = session.handle(.cycle, client: field)
        #expect(field.text == "きょうはいいてんきですね")
        _ = session.handle(.cycle, client: field)
        #expect(!field.text.contains("きょう"))
    }

    /// Where Esc isn't a switch key, it cancels a phrase showing its kana anyway at once, as it
    /// does a converted one once that is back to its kana.
    @Test func escapeCancelsAKanaShownLivePhrase() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "kyouha" { _ = session.handle(.letter(ch), client: field) }
        #expect(session.handle(.escape, client: field))
        #expect(field.text.isEmpty && session.keys.isEmpty)
    }

    @Test func escapeReturnsToKana() {
        type("henkan ")
        session.handle(.escape, client: field)
        #expect(session.conversion == nil)
        #expect(field.text == "へんかん")
        session.handle(.delete, client: field)
        #expect(field.text == "へんか")
    }

    @Test func deleteTakesOffAWholeKana() {
        type("kannkoku")
        #expect(field.text == "かんこく")
        session.handle(.delete, client: field)
        #expect(field.text == "かんこ")
        session.handle(.delete, client: field)
        #expect(field.text == "かん")
        type("ji ")
        #expect(converter.learned.isEmpty)
        #expect(session.conversion?.kana == "かんじ")
    }

    @Test func deleteKeepsAPendingLetterSeparate() {
        type("kannkok")
        #expect(field.text == "かんこk")
        session.handle(.delete, client: field)
        #expect(field.text == "かんこ")
    }

    @Test func deleteSplitsContractedAndDoubledKana() {
        type("kyouha")
        session.handle(.delete, client: field)
        session.handle(.delete, client: field)
        #expect(field.text == "きょ")
        session.handle(.delete, client: field)
        #expect(field.text == "き")
        type("tte")
        #expect(field.text == "きって")
        session.handle(.delete, client: field)
        #expect(field.text == "きっ")
        type("ta")
        #expect(field.text == "きった")
    }

    /// Without live conversion, Delete on a conversion commits it less its last character, as
    /// macOS's Japanese input does (変換 → 変); the next Delete is the app's.
    @Test func deleteInConversionCommitsAllButTheLastCharacter() {
        type("henkan ")
        #expect(field.text == "変換")
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "変" && field.marked.location == NSNotFound)
        #expect(session.conversion == nil && session.keys.isEmpty)
        #expect(converter.learned.isEmpty)
        #expect(!session.handle(.delete, client: field))
        field.text = String(field.text.dropLast()); field.cursor = (field.text as NSString).length // the app's Delete
        type("kidesu")
        session.handle(.enter, client: field)
        #expect(field.text == "きです") // a new word after what went in
        type("kyouhaiitenkidesune ")
        session.handle(.delete, client: field)
        #expect(field.text == "きです今日はいい天気です")
    }

    @Test func deleteInConversionTakesTheNumberWithIt() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("3ji ")
        #expect(field.text == "変換3時")
        session.handle(.delete, client: field)
        #expect(field.text == "変換3" && session.conversion == nil)
    }

    /// With live conversion, Delete on a conversion goes back to typing the phrase, as macOS's
    /// does: its last clause as kana less the last one, the clauses before it as they were shown.
    @Test func deleteInLiveConversionKeepsTheClausesBefore() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "kyouhaiitenkidesune" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "今日はいい天気ですね")
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text == "今日はいいてんきですね") // the next candidate covers 今日は only
        #expect(session.handle(.delete, client: field))
        #expect(session.conversion == nil)
        #expect(field.text == "きょうはいいてんきです") // 今日は|いいてんきですね: no clause before 今日は
        _ = session.handle(.escape, client: field)
        _ = session.handle(.enter, client: field)
        field.text = ""; field.cursor = 0

        for ch in "kyouhaiitenkidesune" { _ = session.handle(.letter(ch), client: field) }
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "今日はいいてんきです")
        _ = session.handle(.delete, client: field)
        #expect(field.text == "今日はいいてんきで")
        _ = session.handle(.enter, client: field)
        #expect(field.text == "今日はいいてんきで" && field.marked.location == NSNotFound)
        #expect(converter.learned.isEmpty)
        field.text = ""; field.cursor = 0

        // Esc then shows it all as kana, as after any live conversion.
        for ch in "kyouhaiitenkidesune" { _ = session.handle(.letter(ch), client: field) }
        _ = session.handle(.delete, client: field)
        _ = session.handle(.escape, client: field)
        #expect(field.text == "きょうはいいてんきです")
    }

    /// A number taken into a live conversion goes back as typed, the phrase less a kana after it.
    @Test func deleteInLiveConversionPutsTheNumberBack() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "henkan" { _ = session.handle(.letter(ch), client: field) }
        _ = session.handle(.enter, client: field)
        if !session.handle(.printable("3"), client: field) { field.insertText("3", replacing: nil) }
        for ch in "ji" { _ = session.handle(.letter(ch), client: field) }
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text.hasPrefix("変換") && field.text.contains("時"))
        _ = session.handle(.delete, client: field)
        #expect(field.text == "変換3")
        #expect(session.conversion == nil && session.keys.isEmpty)
    }

    /// After a Delete with live conversion the end stays kana while only a letter waiting for its
    /// vowel follows (へんかn); Space then shows the first candidate, nothing being on screen.
    @Test func deleteInLiveConversionThenSpaceShowsTheFirstCandidate() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "henkan" { _ = session.handle(.letter(ch), client: field) }
        _ = session.handle(.printable(" "), client: field)
        _ = session.handle(.delete, client: field)
        #expect(field.text == "へんか")
        _ = session.handle(.letter("n"), client: field)
        #expect(field.text == "へんかn")
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text == "変換")
    }

    /// With live conversion Space shows the candidate after the one on screen (変換 → 返還), but a
    /// letter waiting for its vowel meant none of the whole reading's was (へんかn): Space then
    /// shows the first, as macOS does.
    @Test func spaceAfterAPendingLetterShowsTheFirstCandidate() {
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "henkan" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "へんかn")
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text == "変換")
        _ = session.handle(.escape, client: field)
        _ = session.handle(.escape, client: field)
        field.text = ""; field.cursor = 0
        for ch in "henkann" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "変換")
        _ = session.handle(.printable(" "), client: field)
        #expect(field.text == "返還")
    }

    @Test func lastClauseOfAConversion() {
        #expect(InputSession.dropLastClause("今日はいい天気です", reading: "きょうはいいてんきです") == ("今日はいい", 6))
        #expect(InputSession.dropLastClause("今日は箱", reading: "きょうははこ") == ("今日は", 4))
        #expect(InputSession.dropLastClause("googleで検索", reading: "googleでけんさく") == ("googleで", 7))
        #expect(InputSession.dropLastClause("変換", reading: "へんかん") == ("", 0))
        #expect(InputSession.dropLastClause("きょうは", reading: "きょうは") == ("", 0))
        #expect(InputSession.dropLastClause("今日は天気", reading: "ちがう") == ("", 0))
    }

    @Test func returnWithoutConvertingCommitsKanaOnly() {
        type("arigatou")
        #expect(field.text == "ありがとう")
        let consumed = session.handle(.enter, client: field)
        #expect(consumed) // a Japanese IME's Return only confirms the text
        #expect(field.text == "ありがとう")
    }

    @Test func previewMatchesWhatGetsCommitted() {
        // "kanji" is an English dictionary word: outside Japanese text it stays English,
        // and the preview says so before Return.
        type("kanji")
        #expect(field.text == "kanji")
        let consumed = session.handle(.enter, client: field)
        #expect(consumed) // Return only confirms, whatever the language
        #expect(field.text == "kanji")
        #expect(field.marked.location == NSNotFound)
    }

    @Test func punctuationStaysInsideJapanesePhrase() {
        type("arigatou.")
        #expect(field.text == "ありがとう。")
        type("ra-men")
        #expect(field.text == "ありがとう。らーめn") // ん waits for the next key, like any Japanese IME
    }

    /// After Japanese a symbol is full-width and underlined, as in a Japanese IME: Return only
    /// confirms it, the next letter starts a word of its own.
    @Test func symbolAfterJapaneseWaitsForReturn() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("!?")
        #expect(field.text == "変換！？")
        #expect(field.marked.location != NSNotFound)
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "変換！？")
        #expect(field.marked.location == NSNotFound)
        type("_")
        session.handle(.delete, client: field)
        #expect(field.text == "変換！？")
        type("/wo")
        #expect(field.text == "変換！？・を")
    }

    @Test func symbolAfterJapaneseConvertsWithSpace() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("_ ")
        #expect(session.conversion?.kana == "＿")
    }

    @Test func numbersAfterJapaneseStayHalfWidth() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("3.5:")
        #expect(field.text == "変換3.5:")
    }

    @Test func bracketsCloseTheWayTheyOpened() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("(hello)")
        session.handle(.enter, client: field)
        #expect(field.text == "変換（hello）")
    }

    @Test func symbolsJoinOnlyAFinishedJapaneseWord() {
        type("nihon.")
        #expect(field.text == "にほん。")
    }

    @Test func symbolsInEnglishStayHalfWidth() {
        type("foo_bar (baz) a/b ")
        #expect(field.text == "foo_bar (baz) a/b ")
    }

    /// Off by default: digits after Japanese stay half-width and go to the app.
    @Test func digitsStayHalfWidthByDefault() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("123")
        #expect(field.text == "変換123")
    }

    @Test func fullWidthDigitsAfterJapanese() {
        session.fullWidthDigits = true
        type("henkan ")
        session.handle(.enter, client: field)
        type("123")
        #expect(field.text == "変換１２３")
        #expect(field.marked.location != NSNotFound)
        type(" ")
        #expect(session.conversion?.candidates.prefix(3).map(\.text) == ["１２３", "123", "一二三"])
        type(" ")
        session.handle(.enter, client: field)
        #expect(field.text == "変換123")
    }

    /// Addresses and phone numbers: the punctuation inside a number is full-width too, and Delete
    /// takes it off one character at a time.
    @Test func fullWidthNumberPunctuation() {
        session.fullWidthDigits = true
        type("henkan ")
        session.handle(.enter, client: field)
        type("03-1234")
        #expect(field.text == "変換０３－１２３４")
        session.handle(.delete, client: field)
        session.handle(.delete, client: field)
        #expect(field.text == "変換０３－１２")
    }

    /// Inside a phrase a number joins it, and candidates that keep the digits come first.
    @Test func numberInsideAPhrase() {
        session.fullWidthDigits = true
        type("henkan ")
        session.handle(.enter, client: field)
        type("3gatsu ")
        #expect(session.conversion?.candidates.prefix(3).map(\.text) == ["３月", "3月", "三月"])
    }

    @Test func digitsAfterEnglishStayHalfWidth() {
        session.fullWidthDigits = true
        type("hello 123 ")
        #expect(field.text == "hello 123 ")
    }

    /// A switch key right after digits the app typed makes them a Japanese number, as if typed
    /// after Japanese with full-width digits on.
    @Test func switchKeyAfterDigitsMakesThemFullWidth() {
        type("hello 123")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "hello １２３")
        #expect(field.marked.location != NSNotFound)
        type(" ")
        #expect(session.conversion?.candidates.prefix(2).map(\.text) == ["１２３", "123"])
        session.handle(.enter, client: field)
        #expect(field.text == "hello １２３")
    }

    /// The same for symbols: [ at the start of a line opens a Japanese quote, and ] closes it.
    @Test func switchKeyAfterSymbolMakesItJapanese() {
        type("[")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "「")
        type("henkan]")
        #expect(field.text == "「へんかん」")
    }

    /// One digit: it becomes １, neither doubled (1１) nor lost.
    @Test func switchKeyAfterOneDigit() {
        type("hello 1")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "hello １")
        session.handle(.enter, client: field)
        #expect(field.text == "hello １")
    }

    /// An app that can't read back its text (most terminals): the digits stay as typed.
    @Test func switchKeyAfterDigitsWhereTheAppCantBeRead() {
        field.readable = false
        type("hello 1")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "hello 1")
        #expect(session.keys.isEmpty)
    }

    /// The same app with a counter: the phrase converts on its own (no 33時).
    @Test func counterWhereTheAppCantBeRead() {
        field.readable = false
        type("henkan ")
        session.handle(.enter, client: field)
        type("3ji ")
        #expect(field.text == "変換3じ")
        session.handle(.enter, client: field)
        #expect(field.text == "変換3じ")
    }

    /// Nothing typed by the app just before: the switch key stays a no-op (and after a space too).
    @Test func switchKeyAfterSpaceDoesNothing() {
        type("123 ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "123 ")
    }

    /// In Japanese text, a counter typed right after a number converts with it: 3ji is 3時, as
    /// typed, first (ji alone reads as English).
    @Test func numberBeforePhraseJoinsConversion() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("3ji ")
        #expect(session.conversion?.candidates.first?.text == "3時")
        #expect(field.text == "変換3時")
        session.handle(.enter, client: field)
        #expect(field.text == "変換3時")
    }

    /// Back to kana from such a conversion puts the number back as typed.
    @Test func numberBeforePhraseBackToKana() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("3ji ")
        session.handle(.cycle, client: field)
        #expect(field.text == "変換3じ")
        #expect(session.keys == "ji")
    }

    /// Units after a number stay English in Japanese text, and nothing changes elsewhere.
    @Test func numberBeforeOtherWordsUnchanged() {
        type("henkan ")
        session.handle(.enter, client: field)
        type("5km ")
        #expect(field.text == "変換5km ")
        let other = FakeTextField()
        for ch in "3pm 3dlf 1on1 " where !(ch.isLetter ? session.handle(.letter(ch), client: other) : session.handle(.printable(ch), client: other)) {
            other.insertText(String(ch), replacing: nil)
        }
        #expect(other.text == "3pm 3일 1on1 ")
    }

    @Test func fullWidthSpaceAfterJapanese() {
        type("henkan ")
        session.handle(.enter, client: field)
        #expect(session.handle(.shiftSpace, client: field)) // ⇧Space: the other width
        #expect(field.text == "変換　")
        session.fullWidthSpace = true
        type(" ")
        #expect(field.text == "変換　　")
        #expect(!session.handle(.shiftSpace, client: field)) // the app types the half-width one
    }

    @Test func noFullWidthWhereTheAppSaysNo() {
        let policies = AppPolicies(overrides: ["test.terminal": .init(fullWidth: false)])
        let terminal = InputSession(engine: session.engine, policies: policies, converter: converter, japaneseEnabled: true)
        terminal.activate(app: "test.terminal")
        terminal.fullWidthDigits = true
        terminal.fullWidthSpace = true
        let field = FakeTextField()
        for ch in "henkan " where !(ch.isLetter ? terminal.handle(.letter(ch), client: field) : terminal.handle(.printable(ch), client: field)) {
            field.insertText(String(ch), replacing: nil)
        }
        terminal.handle(.enter, client: field)
        for ch in "12 " where !terminal.handle(.printable(ch), client: field) { field.insertText(String(ch), replacing: nil) }
        #expect(field.text == "変換12 ")
    }

    @Test func numberHelpers() {
        #expect(InputSession.digits(of: "東京都１－２") == "12")
        #expect(InputSession.halfWidth("０３－１２３４") == "03-1234")
        #expect(RomajiComposer.compose("03-1234").text == "０３－１２３４")
        #expect(RomajiComposer.compose("ra-men").text == "らーめん")
    }

    @Test func typingOnAfterConversionCommitsIt() {
        type("henkan ")
        type("wo")
        #expect(field.text == "変換を")
        #expect(session.conversion == nil)
    }

    @Test func englishAndKoreanStillWork() {
        type("hello dkssud ")
        #expect(field.text == "hello 안녕 ")
    }

    @Test func keysRemainderAfterKana() {
        #expect(InputSession.keys("kyouhaiitenki", after: 4) == "iitenki")
        #expect(InputSession.keys("kitte", after: 2) == "te")
        #expect(InputSession.keys("konnichiha", after: 2) == "nichiha")
    }
}

/// nn is ㅜㅜ in Korean chat and ん in Japanese: the preview shows what Space commits (it showed
/// ん and went in as ㅜㅜ), the sentence decides which, and the switch key reaches both.
@MainActor @Suite struct ChatJamoTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-cj-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        session = InputSession(engine: engine, policies: .escSwitches, japaneseEnabled: true)
    }

    func type(_ s: String) {
        for ch in s {
            switch ch {
            case "⎋": _ = session.handle(.escape, client: field)
            case let c where c.isLetter: _ = session.handle(.letter(c), client: field)
            default: if !session.handle(.printable(ch), client: field) { field.insertText(String(ch), replacing: nil) }
            }
        }
    }

    @Test func showsWhatSpaceCommits() {
        type("nn")
        #expect(field.text == "ㅜㅜ")
        type(" ")
        #expect(field.text == "ㅜㅜ ")
        type("sugoi nn")
        #expect(field.text.hasSuffix("すごい ん"))
        type(" ")
        #expect(field.text.hasSuffix("すごい ん "))
    }

    /// A doubled consonant with nothing after its っ isn't Japanese on its way: ff showed っf
    /// and went in as ff, ss showed っs and went in as っs. って (tte) is still Japanese.
    @Test(arguments: [("ff", "ff"), ("ww", "ww"), ("ss", "ss"), ("xxx", "xxx"), ("zz", "ㅋㅋ"), ("ttedokoni", "ってどこに")])
    func doubledConsonantShowsWhatItCommits(keys: String, word: String) {
        type(keys)
        #expect(field.text == word)
        type(" ")
        #expect(field.text == word + " ")
    }

    @Test func switchKeyReachesTheChatReading() {
        type("nn⎋⎋⎋")
        #expect(field.text == "ㅜㅜ")
        type(" ⎋")
        #expect(field.text == "ん ")
        type("⎋⎋")
        #expect(field.text == "ㅜㅜ ")
    }
}

/// A word learned as Japanese types as Japanese only while Japanese is on.
@MainActor @Suite struct LearnedJapaneseTests {
    @Test(arguments: [(true, "すし "), (false, "sushi ")])
    func followsTheJapaneseSetting(japanese: Bool, typed: String) {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-lj-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: japanese ? SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter)
                                                   : splitting, storeURL: lex)
        engine.learn("sushi", as: .japanese, engineChoice: .english)
        engine.learn("sushi", as: .japanese, engineChoice: .english)
        let session = InputSession(engine: engine, japaneseEnabled: japanese)
        let field = FakeTextField()
        for ch in "sushi " {
            if !(ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)) {
                field.insertText(String(ch), replacing: nil)
            }
        }
        #expect(field.text == typed)
    }

    /// A word that goes in through its conversion or its kana forms was typed again, as one
    /// that goes in with Return: a weak correction to it stays, a switch away from a remembered
    /// one noted since was a slip, and a word the dictionary decided is listed.
    @Test(arguments: [false, true])
    func convertedWordIsTypedAgain(katakana: Bool) {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-lj-\(UUID().uuidString).json")
        let base = SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter)
        let corrected = Date(timeIntervalSince1970: 1_790_000_000)
        let typed = corrected.addingTimeInterval(20 * 86_400)
        let before = DictionaryEngine(base: base, storeURL: lex, today: { corrected })
        before.learn("kyouha", as: .japanese, engineChoice: .english) // once: weak
        before.learn("sugoi", as: .japanese, engineChoice: .english)
        before.learn("sugoi", as: .japanese, engineChoice: .english)  // twice: remembered
        before.learn("sugoi", as: .korean, engineChoice: .japanese)   // a switch away, noted
        #expect(before.dictionary.languageEntry(for: "sugoi")?.next == .korean)
        let engine = DictionaryEngine(base: base, storeURL: lex, today: { typed })
        let session = InputSession(engine: engine, converter: FakeConverter(), japaneseEnabled: true)
        let field = FakeTextField()
        for word in ["kyouha", "sugoi"] {
            for ch in word { _ = session.handle(.letter(ch), client: field) }
            _ = session.handle(katakana ? .katakana : .printable(" "), client: field)
            #expect(session.conversion != nil)
            _ = session.handle(.enter, client: field)
        }
        #expect(field.text == (katakana ? "キョウハスゴイ" : "きょうはすごい"))
        #expect(engine.dictionary.languageEntry(for: "kyouha")?.last == UserDictionary.day(typed))
        #expect(engine.dictionary.languageEntry(for: "sugoi")?.next == nil)
        #expect(engine.recentlyApplied.map(\.keys) == ["sugoi"])
    }

    /// A word switched to Japanese and put in its kana forms learns the switch, as with Space.
    @Test func kanaFormsLearnTheSwitch() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-lj-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        let session = InputSession(engine: engine, converter: FakeConverter(), japaneseEnabled: true)
        let field = FakeTextField()
        for ch in "sushi" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "sushi")
        for _ in 0..<4 where field.text != "すし" { _ = session.handle(.cycle, client: field) }
        #expect(field.text == "すし")
        _ = session.handle(.katakana, client: field)
        _ = session.handle(.enter, client: field)
        #expect(field.text == "スシ")
        #expect(engine.correctedOnce("sushi", app: nil) == .japanese)
    }
}

/// A Strict app with Japanese on: a consonant at the end, still waiting for its vowel while
/// typed, kept a Korean word under the threshold on screen, and Space then committed it as
/// Korean (qud showed qud and went in as 병).
@MainActor @Suite struct StrictJapaneseTests {
    @Test(arguments: [("qud", "병"), ("eho", "돼"), ("ajanf", "머물")])
    func koreanWordShowsWhatItCommits(keys: String, word: String) {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-sj-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        let session = InputSession(engine: engine, policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(conversionThreshold: AppPolicy.strictThreshold)]),
                                   converter: FakeConverter(), japaneseEnabled: true)
        let field = FakeTextField()
        for ch in keys { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == word)
        #expect(session.handle(.enter, client: field))
        #expect(field.text == word)
    }

    /// A short token the threshold keeps English still converts when its kana are on screen.
    @Test func spaceConvertsAShortTokenShownAsKana() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-sj-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        let session = InputSession(engine: engine, policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(conversionThreshold: AppPolicy.strictThreshold)]),
                                   converter: FakeConverter(), japaneseEnabled: true)
        let field = FakeTextField()
        for ch in "ka" { _ = session.handle(.letter(ch), client: field) }
        #expect(field.text == "か")
        #expect(session.handle(.printable(" "), client: field))
        #expect(session.conversion != nil)
    }
}

@MainActor @Suite struct TextReplacementTests {
    let field = FakeTextField()
    let converter = FakeConverter()
    let session: InputSession

    init() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-tr-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        session = InputSession(engine: engine, policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(conversionThreshold: AppPolicy.strictThreshold)]),
                               converter: converter, japaneseEnabled: true)
        session.replacements = ["ㅈㅅ": ["죄송합니다"], "주소": ["서울시"], "よろ": ["よろしくお願いします"], "go": ["gone"]]
    }

    func type(_ s: String) {
        for ch in s {
            let handled = ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    /// The shortcut goes in as typed, even in a Strict app, so the app can replace it on Space.
    @Test func koreanShortcutWinsTheDecision() {
        type("wt wnth ")
        #expect(field.text == "ㅈㅅ 주소 ")
    }

    @Test func japaneseShortcutIsTheFirstCandidate() {
        type("yoro ")
        #expect(session.conversion?.candidates.first?.text == "よろしくお願いします")
        session.handle(.enter, client: field)
        #expect(field.text == "よろしくお願いします")
    }

    /// gu reads as 혀, but gu- is on its way to the shortcut ぐー.
    @Test func japaneseShortcutWithASymbol() {
        session.replacements["ぐー"] = ["グーグル"]
        type("gu- ")
        #expect(session.conversion?.candidates.first?.text == "グーグル")
    }

    /// A shortcut entered more than once offers every phrase, in order, before the converter's own.
    @Test func everyPhraseOfAShortcutIsACandidate() {
        session.replacements["よろ"] = ["よろしくお願いします", "よろしく", "夜露死苦"]
        type("yoro ")
        #expect(session.conversion?.candidates.prefix(3).map(\.text) == ["よろしくお願いします", "よろしく", "夜露死苦"])
        #expect(session.conversion?.candidates.filter { $0.text == "よろしく" }.count == 1)
    }

    /// Live conversion shows conversions only, never a completion of what was typed.
    @Test func liveConversionSkipsCompletions() {
        let live = InputSession(engine: session.engine, converter: PredictingConverter(), japaneseEnabled: true, liveConversion: true)
        let field = FakeTextField()
        for ch in "arigatou" where !live.handle(.letter(ch), client: field) { field.insertText(String(ch), replacing: nil) }
        #expect(field.text == "ありがとう")
    }

    @Test func englishShortcutsAreLeftToTheEngine() {
        type("kyouha go")
        #expect(session.lastTrace?.decision.explanation != "text replacement shortcut")
    }

    /// A Korean shortcut entered more than once offers its phrases on Space as a Japanese one
    /// does, then the shortcut as typed; the chosen one goes in with the space.
    @Test func koreanShortcutWithSeveralPhrasesOffersThem() {
        session.replacements["ㅈㅅ"] = ["죄송합니다", "잠시만요"]
        type("wt ")
        #expect(session.conversion?.candidates.map(\.text) == ["죄송합니다", "잠시만요", "ㅈㅅ"])
        #expect(field.text == "죄송합니다")
        type(" ")
        #expect(field.text == "잠시만요")
        _ = session.handle(.enter, client: field)
        #expect(field.text == "잠시만요 " && session.conversion == nil)
    }

    /// So does an English one the engine reads as English; typing on takes the phrase and its space.
    @Test func englishShortcutWithSeveralPhrasesOffersThem() {
        session.replacements["go"] = ["gone", "going"]
        type("go ")
        #expect(session.conversion?.candidates.map(\.text) == ["gone", "going", "go"])
        type("x")
        #expect(field.text == "gone x")
    }

    /// A digit picks a phrase on the page; Esc goes back to the shortcut, and Space offers them again.
    @Test func phrasesByDigitAndBackWithEscape() {
        session.replacements["ㅈㅅ"] = ["죄송합니다", "잠시만요"]
        type("wt ")
        _ = session.handle(.escape, client: field)
        #expect(session.conversion == nil && field.text == "ㅈㅅ" && session.keys == "wt")
        type(" 2")
        #expect(field.text == "잠시만요 ")
    }

    /// Without Japanese input a Korean shortcut's phrases are offered all the same.
    @Test func phrasesWithoutJapanese() {
        let session = InputSession(engine: session.engine)
        let field = FakeTextField()
        session.replacements = ["ㅈㅅ": ["죄송합니다", "잠시만요"]]
        for ch in "wt" { _ = session.handle(.letter(ch), client: field) }
        #expect(session.handle(.printable(" "), client: field))
        #expect(session.conversion?.candidates.count == 3)
        session.choose(1, client: field)
        #expect(field.text == "잠시만요 ")
    }

    /// A shortcut whose phrases are offered was typed as a word: one its dictionary entry
    /// decided is listed, as when it goes in.
    @Test func offeredShortcutIsListed() {
        session.replacements["ㅈㅅ"] = ["죄송합니다", "잠시만요"]
        session.engine.add(.init(keys: "wt", language: .korean, source: .user))
        type("wt ")
        #expect(session.conversion?.candidates.count == 3)
        #expect(session.engine.recentlyApplied == [.init(keys: "wt", text: "ㅈㅅ", language: .korean)])
    }
}

/// A converter whose first candidate for ゆーちゅ is a completion.
@MainActor final class PredictingConverter: JapaneseConverter {
    func candidates(for kana: String) -> [ConversionCandidate] {
        [.init(text: "YouTube", kanaCount: kana.count, isPrediction: true), .init(text: kana, kanaCount: kana.count)]
    }
    func learn(_ candidate: ConversionCandidate, for kana: String) {}
    func save() {}
}

/// With three readings the list's pill stays on a remembered one until another reading is chosen
/// twice; switching back to Araso's own forgets it at once. Araso's own is marked throughout.
@MainActor @Suite struct ThreeReadingsTests {
    let field = FakeTextField()
    let engine: DictionaryEngine
    let session: InputSession

    init() {
        let lex = FileManager.default.temporaryDirectory.appendingPathComponent("araso-three-\(UUID().uuidString).json")
        engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: lex)
        session = InputSession(engine: engine, converter: FakeConverter(), japaneseEnabled: true)
    }

    /// Types tori, switches until `target` is shown, and commits it; returns the list as first
    /// shown: each reading with its marks (● remembered, ○ corrected once, ✦ Araso's own).
    @discardableResult
    func type(_ target: String) -> [String] {
        for ch in "tori" { _ = session.handle(.letter(ch), client: field) }
        _ = session.handle(.cycle, client: field)
        let first = session.readings!
        while let r = session.readings, r.texts[r.selected] != target { _ = session.handle(.cycle, client: field) }
        for ch in " x " where !session.handle(ch == "x" ? .letter(ch) : .printable(ch), client: field) {
            field.insertText(String(ch), replacing: nil)
        }
        return first.texts.indices.map {
            first.texts[$0] + ($0 == first.remembered ? "●" : "") + ($0 == first.once ? "○" : "") + ($0 == first.own ? "✦" : "")
        }
    }

    @Test func pillStaysOnTheRememberedReading() {
        engine.learn("tori", as: .english, engineChoice: .japanese)
        engine.learn("tori", as: .english, engineChoice: .japanese)
        #expect(type("새갸") == ["tori●", "새갸", "とり✦"])
        #expect(type("새갸") == ["tori●", "새갸○", "とり✦"])
        #expect(type("とり") == ["tori", "새갸●", "とり✦"])
        #expect(type("とり") == ["tori", "새갸", "とり✦"]) // back to Araso's own: forgotten
    }

    @Test func typingTheRememberedReadingDropsTheSwitch() {
        engine.learn("tori", as: .english, engineChoice: .japanese)
        engine.learn("tori", as: .english, engineChoice: .japanese)
        type("새갸")
        type("tori")
        #expect(type("tori") == ["tori●", "새갸", "とり✦"])
    }
}
