import Foundation
import Testing
@testable import ArasoCore

/// Norwegian on (`Settings.norwegian`): the Latin side is English + Norwegian (bokmål), typed on
/// the Norwegian layout, QWERTY's letters with ø, æ, å on the ; ' [ keys. Korean 2-set stays on
/// its keys. Off, nothing changes.
@MainActor @Suite struct NorwegianTests {
    let norwegian = HeuristicEngine(english: .norwegianModel)

    @Test func norwegianLayoutPutsLettersOnTheSymbolKeys() {
        let n = LatinLayout.norwegian
        #expect(n.character(onSeat: ";") == "ø")
        #expect(n.character(onSeat: "'") == "æ")
        #expect(n.character(onSeat: "[") == "å")
        #expect(n.character(onSeat: ":") == "Ø")
        #expect(n.character(onSeat: "e") == "e")
        #expect(n.seat(of: "ø") == ";")
        #expect(n.seat(of: "Å") == "{")
        #expect(n.character(keyCode: 41, shift: false, capsLock: false) == "ø") // the ; key
        #expect(n.character(keyCode: 39, shift: true, capsLock: false) == "Æ")  // the ' key
        #expect(n.character(keyCode: 33, shift: false, capsLock: true) == "Å")  // the [ key
        #expect(n.isLetterSeat("ø") && n.isLetterSeat("å") && n.isLetterSeat("æ"))
        for seat in "qwertyuiop[asdfghjkl;'zxcvbnmQWERTYUIOP{ASDFGHJKL:\"ZXCVBNM" {
            #expect(n.seat(of: n.character(onSeat: seat)) == seat)
        }
    }

    /// The other layouts type the two keys the Norwegian one adds as themselves.
    @Test func otherLayoutsKeepTheSymbolKeys() {
        for layout in [LatinLayout.qwerty, .colemak, .colemakDH] {
            #expect(layout.character(onSeat: "'") == "'")
            #expect(layout.character(onSeat: "[") == "[")
            #expect(layout.character(keyCode: 39, shift: true, capsLock: false) == "\"")
            #expect(layout.character(keyCode: 33, shift: false, capsLock: false) == "[")
            #expect(!layout.isLetterSeat("'") && !layout.isLetterSeat("["))
        }
        #expect(LatinLayout.qwerty.character(keyCode: 41, shift: false, capsLock: false) == ";")
    }

    @Test(arguments: [
        "jeg", "ikke", "takk", "hyggelig", "selvfølgelig", "kjøpe", "blå", "øl", "på", "så",
        "norsk", "leilighet", "bilder", "fotograf", "visning", "eiendom", "sjø", "fjord", "været",
        "hello", "github", "the", "please",
    ])
    func norwegianAndEnglishWordsStayLatin(word: String) {
        LatinLayout.$override.withValue(.norwegian) {
            for previous in [nil, Language.english, .korean] {
                let d = norwegian.decide(word, context: DecisionContext(previousLanguage: previous))
                #expect(d.language == .english, "\(word) after \(String(describing: previous)) → \(d.output) \(d.explanation)")
                #expect(d.output == word)
            }
        }
    }

    @Test(arguments: [("dkssudgktpdy", "안녕하세요"), ("rkatkgkqslek", "감사합니다"), ("dhsmf", "오늘"), ("tkfkd", "사랑"),
                      ("nn", "ㅜㅜ"), ("rt", "ㄱㅅ")])
    func koreanStaysOnItsKeys(keys: String, text: String) {
        LatinLayout.$override.withValue(.norwegian) {
            let d = norwegian.decide(keys, context: DecisionContext())
            #expect(d.language == .korean && d.output == text, "\(keys) → \(d.output) \(d.explanation)")
        }
    }

    /// A word with æ, ø or å can't be Korean at all: those keys have no jamo.
    @Test func extraLettersNeverReadAsKorean() {
        LatinLayout.$override.withValue(.norwegian) {
            #expect(HangulComposer.compose(keys: "blå") == nil)
            #expect(HangulComposer.compose(keys: "kjøpe") == nil)
            #expect(Language.korean.next(for: "blå") == .english)
            #expect(norwegian.english.isKnownWord("kjøpe"))
            #expect(norwegian.english.isKnownWord("kjøpte")) // kjøp + te through the stem
            #expect(norwegian.english.averageLogProbability("kjøpe") > -3)
        }
    }

    /// A Norwegian word with a Korean particle after it splits like an English one: kjøp에.
    @Test func norwegianWordPlusKoreanParticle() {
        LatinLayout.$override.withValue(.norwegian) {
            let engine = SplittingEngine(base: norwegian, english: norwegian.english)
            let d = engine.decide("kjøpdp", context: DecisionContext())
            #expect(d.language == .mixed && d.output == "kjøp에", "\(d.output) \(d.explanation)")
        }
    }

    /// Off (the default), the English model is the one it always was.
    @Test func offLeavesEnglishAlone() {
        #expect(!Settings().norwegian)
        #expect(EnglishModel.shared === EnglishModel.english)
        #expect(!EnglishModel.english.norwegian)
        #expect(!EnglishModel.english.isKnownWord("kjøpe"))
        #expect(!EnglishModel.english.isKnownWord("ikke"))
        #expect(EnglishModel.english.wordCount < EnglishModel.norwegianModel.wordCount)
        EnglishModel.$override.withValue(.norwegianModel) {
            #expect(EnglishModel.shared === EnglishModel.norwegianModel)
        }
    }

    @Test func settingSavesAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-norwegian-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Settings(latinLayout: .norwegian, norwegian: true).save(to: url)
        let loaded = Settings.load(from: url)
        #expect(loaded.norwegian && loaded.latinLayout == .norwegian)
    }

    /// A whole session with Norwegian on: Korean, Norwegian with æøå, and English in one line.
    @Test func typesKoreanNorwegianAndEnglish() {
        EnglishModel.$override.withValue(.norwegianModel) {
            LatinLayout.$override.withValue(.norwegian) {
                let field = FakeTextField()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-norwegian-\(UUID().uuidString).json")
                let session = InputSession(engine: DictionaryEngine(base: SplittingEngine(base: norwegian, english: norwegian.english),
                                                                    english: norwegian.english, storeURL: url))
                // As the input controller sends them: the ; ' [ keys arrive as the letters ø æ å.
                for ch in "dkssud jeg kjøpte en blå bil hello " {
                    let handled = ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)
                    if !handled { field.insertText(String(ch), replacing: nil) }
                }
                #expect(field.text == "안녕 jeg kjøpte en blå bil hello ")
            }
        }
    }
}
