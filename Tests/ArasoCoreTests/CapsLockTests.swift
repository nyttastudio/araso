import Foundation
import Testing
@testable import ArasoCore

/// Caps Lock on: letters arrive as Shift alone types them (the controller's job), words are read
/// as without Caps Lock, and English goes in in capitals, as macOS types it.
@MainActor @Suite struct CapsLockTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-caps-\(UUID().uuidString).json")
        session = InputSession(engine: DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english,
                                                                              japanese: trilingual.segmenter), storeURL: url),
                               policies: .escSwitches)
    }

    /// Keys through `session` (⎋: Esc); `caps` for each key; the app types what is passed on, in
    /// capitals with Caps Lock as macOS would.
    func type(_ s: String, caps: Bool = true) {
        for ch in s {
            let key: InputSession.Key = ch == "⎋" ? .escape : ch.isASCII && ch.isLetter ? .letter(ch) : .printable(ch)
            if !session.handle(key, client: field, capsLock: caps) {
                field.insertText(caps ? CapsLockClient.capitals(String(ch)) : String(ch), replacing: nil)
            }
        }
    }

    @Test(arguments: [("gkaus ", "하면 "), ("dkssudgktpdy ", "안녕하세요 "), ("output ", "OUTPUT "),
                      ("rst clk ", "RST CLK "), ("apifmf ", "API를 "), ("Qks ", "빤 ")])
    func readAsWithoutCapsLock(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    @Test(arguments: [("rst rd ddr tlb cpl ", "RST RD DDR TLB CPL "), ("output rd ", "OUTPUT RD "),
                      ("qusghkehlsms rp dho dmd whgdk ", "변화되는 게 왜 응 좋아 ")])
    func acronymsStayEnglish(_ keys: String, _ text: String) {
        type(keys)
        #expect(field.text == text)
    }

    /// The preview with Caps Lock is the one without it, English in capitals: no loose jamo rule
    /// keeps a Korean word from showing while it is typed.
    @Test(arguments: ["gkaus", "dkssudgktpdy", "rjatk"])
    func previewAsWithoutCapsLock(_ keys: String) {
        func shown(caps: Bool) -> [String] {
            let field = FakeTextField()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-caps-\(UUID().uuidString).json")
            let session = InputSession(engine: DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english,
                                                                                      japanese: trilingual.segmenter), storeURL: url),
                                       policies: .escSwitches)
            return keys.map { ch in
                _ = session.handle(.letter(ch), client: field, capsLock: caps)
                return field.text
            }
        }
        #expect(shown(caps: true) == shown(caps: false).map(CapsLockClient.capitals))
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

    @Test func capsLockOffKeepsTheCase() {
        type("Hello ", caps: false)
        #expect(field.text == "Hello ")
    }
}
