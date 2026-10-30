import Foundation
import Testing
@testable import ArasoCore

/// Live conversion with the real engines and the real AzooKey dictionary.
@MainActor @Suite struct LiveConversionTests {
    let field = FakeTextField()
    let session: InputSession

    init() throws {
        let dir = FileManager.default.temporaryDirectory
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                    storeURL: dir.appendingPathComponent("araso-live-\(UUID().uuidString).json"))
        let converter = try #require(AzooKeyConverter(memory: dir.appendingPathComponent("araso-live-\(UUID().uuidString)")))
        session = InputSession(engine: engine, policies: .escSwitches, converter: converter, japaneseEnabled: true, liveConversion: true)
    }

    /// Letters and printable keys as themselves, "⏎" Return, "⎋" Esc.
    func type(_ script: String) {
        for ch in script {
            switch ch {
            case "⏎":
                if !session.handle(.enter, client: field) { field.insertText("\n", replacing: nil) }
            case "⎋": _ = session.handle(.escape, client: field)
            case let c where c.isLetter:
                if !session.handle(.letter(c), client: field) { field.insertText(String(c), replacing: nil) }
            default:
                if !session.handle(.printable(ch), client: field) { field.insertText(String(ch), replacing: nil) }
            }
        }
    }

    @Test func kanjiWhileTypingAndReturnCommitsThem() {
        type("kyouhaiitenkidesune")
        #expect(field.text == "今日はいい天気ですね") // still marked
        type("⏎")
        #expect(field.text == "今日はいい天気ですね")
        #expect(session.keys.isEmpty && session.conversion == nil)
    }

    /// Kanji Return confirmed come back when a switch key cycles back to Japanese, not their kana.
    @Test func switchKeyBackToJapaneseAfterReturnKeepsTheKanji() {
        type("kyouhaiitenkidesune⏎")
        let kanji = field.text
        var seen: [String] = []
        for _ in 0..<4 {
            _ = session.handle(.cycle, client: field)
            seen.append(field.text)
            if field.text == kanji { break }
        }
        #expect(seen.first != kanji)
        #expect(seen.last == kanji, "\(seen)")
    }

    @Test func lettersWaitingForAVowelStayVisible() {
        type("kyouhaiitenkides")
        #expect(field.text.hasPrefix("今日は"), "\(field.text)")
        #expect(field.text.hasSuffix("s"), "\(field.text)")
    }

    /// A short word shown as kanji converts on Space, though once it ends it reads as English
    /// (zi went in as "zi " after 地 was on screen); an English word still goes in as typed.
    @Test func spaceConvertsAShortWordShownAsKanji() {
        type("zi")
        let live = field.text
        #expect(live != "zi")
        type(" ")
        #expect(session.conversion != nil)
        #expect(field.text != live)
        type("⏎hi ")
        #expect(field.text.hasSuffix("hi "))
    }

    /// Letters with no kana yet (ths: three waiting for vowels) were Japanese on screen, though
    /// they show as typed, and Space converted them; the word goes in as the engine reads it.
    @Test func spaceDoesntConvertLettersWithNoKana() {
        type("the ths")
        type(" ")
        #expect(session.conversion == nil)
        type("wkfgo ")
        #expect(field.text == "the 손 잘해 ")
    }

    @Test func spaceShowsTheNextCandidate() {
        type("kyouhaiitenkidesune")
        let live = field.text
        type(" ")
        #expect(session.conversion != nil)
        #expect(field.text != live)
        type("⏎")
        #expect(session.conversion == nil)
        #expect(field.text.hasSuffix("ですね"))
    }

    @Test func escapeShowsKanaThenSwitchesLanguage() {
        type("kyouhaiitenkidesune⎋")
        #expect(field.text == "きょうはいいてんきですね")
        type("⎋")
        #expect(!field.text.contains("きょう"))
        type("⎋⎋⎋")
    }

    /// Where Esc isn't a switch key, it still shows the kana first; the next one cancels the
    /// phrase, as in macOS's Japanese input, and doesn't reach the app.
    @Test func escapeShowsKanaThenCancelsWhereItIsNoSwitchKey() throws {
        let dir = FileManager.default.temporaryDirectory
        let converter = try #require(AzooKeyConverter(memory: dir.appendingPathComponent("araso-live-\(UUID().uuidString)")))
        let session = InputSession(engine: session.engine, converter: converter, japaneseEnabled: true, liveConversion: true)
        for ch in "kyouhaiitenkidesune" { _ = session.handle(.letter(ch), client: field) }
        #expect(session.handle(.escape, client: field))
        #expect(field.text == "きょうはいいてんきですね")
        #expect(session.handle(.escape, client: field))
        #expect(field.text.isEmpty && session.keys.isEmpty)
    }

    @Test func kanaCommitAfterEscape() {
        type("kyouhaiitenkidesune⎋⏎")
        #expect(field.text == "きょうはいいてんきですね")
    }

    @Test func otherLanguagesAreUnchanged() {
        type("dkssudgktpdy hello ")
        #expect(field.text == "안녕하세요 hello ")
    }

    /// The candidate on screen goes in with the letters still waiting for their vowel after it,
    /// and a short reading kept as kana on screen stays kana (うふぉs, not うフォs).
    @Test func returnCommitsPendingLettersAsShown() {
        type("kyouhaiitenkides")
        #expect(field.text == "今日はいい天気でs")
        type("⏎")
        #expect(field.text == "今日はいい天気でs")
        type(" ufos")
        #expect(field.text == "今日はいい天気でs うふぉs")
        type("⏎")
        #expect(field.text == "今日はいい天気でs うふぉs")
    }

    @Test func englishInsidePhraseAndPunctuation() {
        type("kyouhagoogledekensaku⏎")
        #expect(field.text == "今日はgoogleで検索")
        type(" arigatou.⏎")
        #expect(field.text.hasSuffix("。"), "\(field.text)")
    }
}
