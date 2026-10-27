import Foundation
import Testing
@testable import ArasoCore

/// Around an underscore (en_s2c, src_dir), segments go in as typed, unless they spell a Korean
/// word of two syllables or more: Korean file names join their parts with one (보고서_최종).
@MainActor @Suite struct IdentifierRunTests {
    let field = FakeTextField()
    let learning: DictionaryEngine
    let session: InputSession
    let japanese: InputSession
    let held: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-identifier-\(UUID().uuidString).json")
        learning = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                    storeURL: url)
        session = InputSession(engine: learning, policies: .escSwitches)
        japanese = InputSession(engine: learning, policies: .escSwitches, japaneseEnabled: true)
        held = InputSession(engine: learning, policies: AppPolicies(overrides: ["test.hold": .init(holdSpace: true)]))
        held.activate(app: "test.hold")
    }

    /// Keys through `session` (⎋: Esc, ⌫: Delete); the app types what is passed on.
    func type(_ s: String, into session: InputSession? = nil) {
        let session = session ?? self.session
        for ch in s {
            if ch == "⌫" {
                if !session.handle(.delete, client: field) {
                    field.insertText("", replacing: NSRange(location: field.cursor - 1, length: 1))
                }
                continue
            }
            let key: InputSession.Key = ch == "⎋" ? .escape : ch.isASCII && ch.isLetter ? .letter(ch) : .printable(ch)
            if !session.handle(key, client: field) { field.insertText(String(ch), replacing: nil) }
        }
    }

    @Test(arguments: ["en_s2c ", "src_dir ", "rm_rf ", "fn_call ", "sk_test ", "qa_env ", "__init__ ", "db_url "])
    func identifiersStayAsTyped(_ keys: String) {
        type(keys)
        #expect(field.text == keys)
    }

    @Test func japaneseOnToo() {
        type("en_s2c ", into: japanese)
        #expect(field.text == "en_s2c ")
    }

    @Test(arguments: [("qhrhtj_chlwhd ", "보고서_최종 "), ("ghldmlfhr_1023 ", "회의록_1023 "),
                      ("vkdlf_rjatk ", "파일_검사 "), ("user_db_dkssud ", "user_db_안녕 ")])
    func koreanWordsAroundAnUnderscore(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    @Test(arguments: [("cmd0 ", "cmd0 "), ("v2 ", "v2 "), ("rst3 clk1 ", "rst3 clk1 "), ("env6 ", "env6 "), ("db3 ", "db3 ")])
    func aWordBeforeADigitStaysAsTyped(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    @Test(arguments: [("wp1wkd ", "제1장 "), ("wn3ghl ", "주3회 "), ("vy1 ", "표1 "), ("dhqtus1 ", "옵션1 "),
                      ("3ro ", "3개 "), ("3dnjf5dlf ", "3월5일 "), ("5qns ", "5분 ")])
    func koreanAroundNumbers(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    @Test func theRunEndsAtASpace() {
        type("en_s2c en ")
        #expect(field.text == "en_s2c 두 ")
    }

    @Test func aSwitchedSegmentIsNotLearned() {
        type("src_dir⎋ ")
        type("src_dir⎋ ")
        #expect(learning.learned["dir"] == nil)
        #expect(learning.pending["dir"] == nil)
    }

    /// Delete taking back the `_` or digit that made the word a name in code makes it a word again.
    @Test func deletingTheUnderscoreMakesAWordAgain() {
        type("gk_⌫s ", into: held)
        #expect(field.text == "한 ")
    }

    @Test func deletingTheDigitLetsASwitchBeLearned() {
        type("cmd0⌫⎋ ")
        #expect(learning.pending["cmd"] == .korean)
        type("cmd0⌫⎋ ")
        #expect(learning.learned["cmd"] == .korean)
    }

    /// A Korean word around an `_` or a number is a word: a switch there is learned.
    @Test(arguments: ["dhqtus⎋1 ", "qhrhtj⎋_x "])
    func aKoreanWordThereIsLearned(_ keys: String) {
        let word = String(keys.prefix(6))
        type(keys)
        #expect(learning.pending[word] == .english)
        type(keys)
        #expect(learning.learned[word] == .english)
    }

    /// A word the user taught wins over a name in code, as a text replacement does.
    @Test func taughtWordsWin() {
        for _ in 0..<2 { learning.learn("so", as: .korean, engineChoice: .english) }
        #expect(learning.learned["so"] == .korean)
        type("so1 so_x ")
        #expect(field.text == "내1 내_x ")
    }

    @Test func textReplacementsWin() {
        session.replacements = ["ㄱㅅ": ["감사합니다"]]
        type("rt1 ")
        #expect(field.text == "ㄱㅅ1 ")
    }

    /// In a Japanese phrase an `_` stays in it, full-width.
    @Test func anUnderscoreInAJapanesePhrase() {
        type("kyouha_", into: japanese)
        #expect(field.text == "きょうは＿")
    }
}
