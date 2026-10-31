import Foundation
import Testing
@testable import ArasoCore

/// Digits, `-` and `_` typed into an English word stay in it (`SplittingEngine.decideJoined`): k8s,
/// mp3 and utf-8 are one word, underlined to the end and switched whole, with a Korean particle
/// after them split off (mp3를); a Korean word still ends at a digit (안녕1).
@MainActor @Suite struct JoinedWordTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("araso-joined-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                      english: trilingual.english, korean: trilingual.korean, japaneseParticles: true, storeURL: store)
        session = InputSession(engine: engine, converter: FakeConverter(), japaneseEnabled: true)
        field.insertsOverMarked = true
    }

    func type(_ s: String) {
        for ch in s {
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    @Test func digitsStayInTheWordBeingTyped() {
        type("k8s")
        #expect(field.text == "k8s")
        #expect(field.marked == NSRange(location: 0, length: 3)) // still underlined, not ㄴ after k8
        type(" ")
        #expect(field.text == "k8s ")
    }

    @Test func theSwitchKeyChangesTheWholeWord() {
        type("k8s ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "ㅏ8ㄴ ")
        type("utf-8")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "ㅏ8ㄴ ㅕㅅㄹ-8")
    }

    @Test func aKoreanParticleAfterTheDigitsSplits() {
        for (keys, text) in [("mp3fmf ", "mp3를 "), ("k8sdp ", "k8s에 "), ("utf-8dmf ", "utf-8을 "), ("gpt-4o ", "gpt-4o "),
                             ("h2o ", "h2o "), ("snake_case ", "snake_case "), ("merry-go ", "merry-go "),
                             ("mani-pedi ", "mani-pedi ")] {
            field.text = ""; field.cursor = 0
            type(keys)
            #expect(field.text == text, "\(keys)")
        }
    }

    @Test func aKoreanWordStillEndsAtADigit() {
        type("dkssud1")
        #expect(field.text == "안녕1")
        #expect(field.marked.location == NSNotFound)
    }

    @Test func aJapanesePhraseKeepsItsReading() {
        type("ra-men ")
        #expect(field.text.hasPrefix("らーめん"))
    }
}
