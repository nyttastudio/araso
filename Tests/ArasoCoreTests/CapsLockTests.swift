import Foundation
import Testing
@testable import ArasoCore

/// Caps Lock on: letters arrive as Shift alone types them (the controller's job), words are read
/// as without Caps Lock, and English goes in in capitals, as macOS types it. Keys that are loose
/// jamo throughout (two or more) are an acronym, unless the dictionary remembers them.
@MainActor @Suite struct CapsLockTests {
    let field = FakeTextField()
    let dictionary: DictionaryEngine
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-caps-\(UUID().uuidString).json")
        dictionary = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english,
                                                            japanese: trilingual.segmenter), storeURL: url)
        session = InputSession(engine: dictionary, policies: .escSwitches)
    }

    /// Keys through `session` (⎋: Esc); `caps` for each key; the app types what is passed on, in
    /// capitals with Caps Lock as macOS would.
    func type(_ s: String, caps: Bool = true) {
        Self.type(s, caps: caps, into: session, field: field)
    }

    static func type(_ s: String, caps: Bool, into session: InputSession, field: FakeTextField) {
        for ch in s {
            let key: InputSession.Key = ch == "⎋" ? .escape : ch.isASCII && ch.isLetter ? .letter(ch) : .printable(ch)
            if !session.handle(key, client: field, capsLock: caps) {
                field.insertText(caps ? CapsLockClient.capitals(String(ch)) : String(ch), replacing: nil)
            }
        }
    }

    /// A session of its own (no dictionary entries), for comparing typing with and without Caps Lock.
    static func freshSession() -> InputSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-caps-\(UUID().uuidString).json")
        return InputSession(engine: DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english,
                                                                           japanese: trilingual.segmenter), storeURL: url),
                            policies: .escSwitches)
    }

    @Test(arguments: [("gkaus ", "하면 "), ("dkssudgktpdy ", "안녕하세요 "), ("output ", "OUTPUT "),
                      ("apifmf ", "API를 "), ("Qks ", "빤 ")])
    func readAsWithoutCapsLock(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    @Test(arguments: [("rst rd ddr ", "RST RD DDR "), ("output rd ", "OUTPUT RD "),
                      ("qusghkehlsms rp dho dmd whgdk ", "변화되는 게 왜 응 좋아 ")])
    func acronymsStayEnglish(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    /// The preview with Caps Lock is the one without it, English in capitals: the loose jamo rule
    /// leaves a word with a syllable in it alone (안녕ㄱ), and one jamo on its way to a syllable (ㅎ).
    @Test(arguments: ["gkaus", "dkssudgktpdy", "rjatk", "dkssudr", "whgdkgg"])
    func previewAsWithoutCapsLock(_ keys: String) {
        func shown(caps: Bool) -> [String] {
            let field = FakeTextField()
            let session = Self.freshSession()
            return keys.map { ch in
                _ = session.handle(.letter(ch), client: field, capsLock: caps)
                return field.text
            }
        }
        #expect(shown(caps: true) == shown(caps: false).map(CapsLockClient.capitals))
    }

    /// What Space puts in is what was shown, with Caps Lock as without it (안녕ㄱ stays 안녕ㄱ).
    @Test(arguments: ["gkaus ", "dkssudr ", "whgdkgg ", "rjatk "])
    func commitAsWithoutCapsLock(_ keys: String) {
        func committed(caps: Bool) -> String {
            let field = FakeTextField()
            Self.type(keys, caps: caps, into: Self.freshSession(), field: field)
            return field.text
        }
        #expect(committed(caps: true) == CapsLockClient.capitals(committed(caps: false)))
        #expect(!committed(caps: true).contains("DKSSUDR") && !committed(caps: true).contains("WHGDKGG"))
    }

    /// A word added by hand, or corrected the same way twice, keeps its language with Caps Lock.
    @Test(arguments: [("hello ", "hello", "ㅗ디ㅣㅐ "), ("gd ", "gd", "ㅎㅇ "), ("dz ", "dz", "ㅇㅋ ")])
    func theDictionaryWins(_ keys: String, _ entry: String, _ text: String) {
        dictionary.add(UserDictionary.Entry(keys: entry, language: .korean, source: .user))
        type(keys)
        #expect(field.text == text)
    }

    /// A limit, as the README says: chat jamo typed with Caps Lock are an acronym too.
    @Test func chatJamoAreAnAcronym() {
        type("zz ")
        #expect(field.text == "ZZ ")
    }

    @Test func withoutCapsLockLooseJamoStayAsBefore() {
        type("zz ", caps: false)
        #expect(field.text == "ㅋㅋ ")
    }

    @Test func switchingTheWordJustCommitted() {
        type("gkaus ⎋")
        #expect(field.text == "GKAUS ")
    }

    @Test func capsLockOffInsideAWordStartsANewOne() {
        type("dk")
        type("ssud ", caps: false)
        #expect(field.text == "아ㄴ녕 ")
    }

    /// The clause being converted keeps its highlight: the clause goes through with the text.
    @Test func theSelectedClauseGoesThrough() {
        final class Recorder: TextClient {
            var marked: (text: String, clause: NSRange)?
            func setMarkedText(_ text: String) {}
            func setMarkedText(_ text: String, replacing range: NSRange) {}
            func insertText(_ text: String, replacing range: NSRange?) {}
            func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
            func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
            func text(in range: NSRange) -> String? { nil }
            func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?) { marked = (text, selectedClause) }
        }
        let recorder = Recorder()
        CapsLockClient(recorder).setMarkedText("今日はtest", selectedClause: NSRange(location: 0, length: 3), replacing: nil)
        #expect(recorder.marked?.text == "今日はTEST")
        #expect(recorder.marked?.clause == NSRange(location: 0, length: 3))
    }

    /// A candidate being chosen goes in under the Caps Lock it was typed with, when Caps Lock
    /// changes before the next word.
    @Test func aCandidateGoesInAsItWasTyped() {
        @MainActor final class Converter: JapaneseConverter {
            func candidates(for kana: String) -> [ConversionCandidate] { [.init(text: "test", kanaCount: kana.count)] }
            func learn(_ candidate: ConversionCandidate, for kana: String) {}
            func save() {}
            func moreCandidates(for kana: String) -> [ConversionCandidate] { [] }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-caps-\(UUID().uuidString).json")
        let session = InputSession(engine: DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english,
                                                                                  japanese: trilingual.segmenter), storeURL: url),
                                   converter: Converter(), japaneseEnabled: true)
        Self.type("tesuto ", caps: false, into: session, field: field)
        #expect(session.conversion != nil)
        Self.type("a", caps: true, into: session, field: field)
        #expect(field.text.hasPrefix("test"))
    }

    /// On 3-set a symbol key whose jamo goes on with the word counts as a letter: Caps Lock
    /// changed on it starts a new word, as on a letter.
    @Test func sebeolsikJamoKeysStartANewWordToo() {
        let (whole, split) = KoreanLayout.$override.withValue(.sebeolsikFinal) { () -> (String, String) in
            let one = FakeTextField(), two = FakeTextField()
            Self.type("kf2 ", caps: true, into: Self.freshSession(), field: one)
            let session = Self.freshSession()
            Self.type("kf", caps: true, into: session, field: two)
            Self.type("2 ", caps: false, into: session, field: two)
            return (one.text, two.text)
        }
        #expect(whole == "갔 ")
        #expect(split != whole && split.hasPrefix("가"))
    }

    @Test func capsLockOffKeepsTheCase() {
        type("Hello ", caps: false)
        #expect(field.text == "Hello ")
    }
}
