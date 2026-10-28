import Foundation
import Testing
@testable import ArasoCore

/// An app set to hold the word (`AppPolicy.holdSpace`, for terminals): after Space or a symbol the word
/// stays underlined with that boundary until the next word starts, so a switch key still changes it and
/// Delete takes back only the boundary.
@MainActor @Suite struct HoldSpaceTests {
    let field = FakeTextField()
    let learning: DictionaryEngine
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-hold-\(UUID().uuidString).json")
        learning = DictionaryEngine(base: splitting, storeURL: url)
        session = InputSession(engine: learning, policies: AppPolicies(overrides: ["test.hold": .init(holdSpace: true)]))
        session.activate(app: "test.hold")
    }

    @discardableResult
    func type(_ s: String) -> [Bool] {
        // Keys the input method passes on are typed by the app, as in a real text field.
        s.map { ch in
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
            return handled
        }
    }

    /// The underlined text, nil when nothing is underlined.
    var marked: String? {
        guard field.marked.location != NSNotFound else { return nil }
        return (field.text as NSString).substring(with: field.marked)
    }

    /// 3-set's symbols after a Korean word (#35) are held too, and go back to the key as typed
    /// when the word is switched out of Korean.
    @Test func threeSetSymbolsAreHeldAndSwitchBack() {
        KoreanLayout.$override.withValue(.sebeolsikFinal) {
            type("ldhr2jtB")
            #expect(marked == "지냈어?")
            #expect(session.handle(.cycle, client: field))
            #expect(marked == "ldhr2jtB")
            #expect(session.handle(.cycle, client: field))
            #expect(marked == "지냈어?")
            type("?")                       // ⇧/ after it: the word goes in, then !
            #expect(field.text == "지냈어?!")
            #expect(marked == nil)
            type(" ")
            #expect(field.text == "지냈어?! ")
        }
    }

    @Test func spaceKeepsTheWordUnderlinedWithItsSpace() {
        #expect(type("dkssud ").last == true)
        #expect(field.text == "안녕 ")
        #expect(marked == "안녕 ")
    }

    /// A symbol is a boundary like Space: the word stays underlined with it, so it can still be changed.
    @Test(arguments: [".", ",", "?", "!", "-", "'", ";", ":", ")", "\"", "/"])
    func aSymbolKeepsTheWordUnderlinedWithIt(symbol: String) {
        #expect(type("dkssud" + symbol).last == true)
        #expect(field.text == "안녕" + symbol)
        #expect(marked == "안녕" + symbol)
    }

    /// A switch key changes the word; the symbol stays as typed, half-width, also for Japanese.
    @Test func aSwitchRightAfterASymbolChangesTheWordAndKeepsTheSymbol() {
        type("dkssud.")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "dkssud." && marked == "dkssud.")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "안녕." && marked == "안녕.")
    }

    @Test func deleteTakesBackOnlyTheSymbolThenAShiftEscChangesTheWord() {
        type("dkssud.")
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "안녕" && marked == "안녕")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "dkssud" && marked == "dkssud")
    }

    /// One boundary only: the next letter, Return, a second symbol, Space or a digit puts the word
    /// in with its symbol in one insertion, and the key goes where it goes with holding off.
    @Test func theNextLetterCommitsTheWordWithItsSymbolInOneInsertion() {
        type("dkssud.gktpdy")
        #expect(field.text == "안녕.하세요" && marked == "하세요")
        #expect(field.insertions == ["안녕."])
    }

    @Test func returnCommitsTheWordWithItsSymbolAndOnlyConfirms() {
        type("dkssud.")
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "안녕." && marked == nil)
        #expect(!session.handle(.enter, client: field))
    }

    @Test(arguments: [".", " ", "3", "!"])
    func aSecondBoundaryCommitsTheWordWithItsSymbolAndGoesToTheApp(next: String) {
        #expect(type("dkssud." + next).last == false)
        #expect(field.text == "안녕." + next && marked == nil)
        #expect(field.insertions == ["안녕.", next]) // the word with its symbol in one; the key typed by the app
    }

    /// A held symbol ended the word: switched to Japanese, Space commits it instead of converting.
    /// The space itself then follows the rules for a space after Japanese text, as after any word
    /// that went in as Japanese (half-width here, `fullWidthSpace` being off).
    @Test func spaceOnAHeldSymbolWordSwitchedToJapaneseCommitsWithoutConverting() {
        let (japanese, field) = Self.japaneseSession()
        for ch in "hello" { japanese.handle(.letter(ch), client: field) }
        japanese.handle(.printable("."), client: field)
        #expect(field.text == "hello.")
        japanese.handle(.cycle, client: field)
        #expect(field.text == "へっぉ.")
        #expect(!japanese.handle(.printable(" "), client: field))
        #expect(japanese.conversion == nil)
        #expect(field.text == "へっぉ." && field.marked.location == NSNotFound)
    }

    /// A holding session with Japanese on, and its field.
    static func japaneseSession(live: Bool = false) -> (InputSession, FakeTextField) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-hold-ja-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter), storeURL: url)
        let session = InputSession(engine: engine, policies: AppPolicies(overrides: ["test.hold": .init(holdSpace: true)]),
                                   converter: FakeConverter(), japaneseEnabled: true, liveConversion: live)
        session.activate(app: "test.hold")
        return (session, FakeTextField())
    }

    @Test func theNextWordCommitsTheHeldOne() {
        type("dkssud gktpdy")
        #expect(field.text == "안녕 하세요")
        #expect(marked == "하세요")
        type(" ")
        #expect(marked == "하세요 ")
    }

    @Test func deleteTakesBackOnlyTheSpace() {
        type("dkssud ")
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "안녕" && marked == "안녕")
        // Delete again: the word itself, as while typing.
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "안녀")
    }

    /// What this is for: Space pressed before looking, then Delete and ⇧Esc.
    @Test func deleteThenShiftEscChangesTheWord() {
        type("dkssud ")
        session.handle(.delete, client: field)
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "dkssud" && marked == "dkssud")
        type(" ")
        #expect(field.text == "dkssud " && marked == "dkssud ")
        type("x")
        #expect(field.text.hasPrefix("dkssud "))
        #expect(field.marked.location == ("dkssud " as NSString).length)
    }

    @Test func aSwitchRightAfterSpaceChangesTheWordAndKeepsTheSpace() {
        type("dkssud ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "dkssud " && marked == "dkssud ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "안녕 " && marked == "안녕 ")
    }

    /// Esc that isn't one of the app's switch keys finishes the word with its space and goes to the app.
    @Test func escNotASwitchKeyCommitsTheHeldWordWithItsSpace() {
        type("dkssud ")
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕 " && marked == nil)
    }

    /// What is shown after Space is what would have been committed: the whole word's decision,
    /// not the preview of its last keystroke.
    @Test(arguments: ["go", "so", "did", "hello", "dkssud", "githubdp", "rjtm", "dhsmf", "wkqtm", "gst", "APIfmf"])
    func heldWordReadsAsItWouldCommit(keys: String) {
        let plain = FakeTextField()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-hold-plain-\(UUID().uuidString).json")
        let standard = InputSession(engine: DictionaryEngine(base: splitting, storeURL: url))
        for ch in keys { standard.handle(.letter(ch), client: plain) }
        standard.handle(.printable(" "), client: plain) // the app would type the space
        type(keys + " ")
        #expect(field.text == plain.text + " ")
    }

    @Test func returnCommitsTheHeldWordWithItsSpaceAndOnlyConfirms() {
        type("dkssud ")
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "안녕 " && marked == nil)
        #expect(!session.handle(.enter, client: field))
    }

    @Test func otherKeysCommitTheHeldWordWithItsSpace() {
        type("dkssud ")
        #expect(!session.handle(.other, client: field))
        #expect(field.text == "안녕 " && marked == nil)
    }

    /// ⌘ going down puts the held word in before the shortcut: Ghostty pastes on ⌘V without showing
    /// the input method the key, and would paste over the underlined word.
    @Test func commandGoingDownCommitsTheHeldWordSoAPasteLandsAfterIt() {
        type("dkssud ")
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(field.text == "안녕 " && marked == nil)
        #expect(field.insertions == ["안녕 "])
        field.insertText("hello", replacing: nil) // the app's paste
        #expect(field.text == "안녕 hello")
    }

    @Test(arguments: [".", "!"])
    func commandGoingDownCommitsTheWordWithItsSymbol(symbol: String) {
        type("dkssud" + symbol)
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(field.text == "안녕" + symbol && marked == nil)
    }

    /// A word without a boundary goes in too (Ghostty's ⌘⌫ and ⌘V act on the text as it is); the
    /// letters after a ⌘ let go mid-word start a new word.
    @Test func commandGoingDownCommitsAWordWithoutABoundaryToo() {
        type("dkssud")
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(field.text == "안녕" && marked == nil)
        #expect(field.insertions == ["안녕"])
        type("gktpdy ")
        #expect(field.text == "안녕하세요 " && marked == "하세요 ")
    }

    /// Ghostty's ⌘V reaches the input method only as ⌘ going down, so the pasted text is read
    /// from the field: a pasted URL makes the next segment typed English.
    @Test func aURLPastedAfterCommandCounts() {
        type("dkssud ")
        session.commandPressed(client: field, heldWordOnly: false)
        field.insertText("https://x.io/", replacing: nil) // the app's paste
        type("dl ")
        #expect(field.text == "안녕 https://x.io/dl ")
    }

    /// After ⌘ the word is in the app: a switch key no longer changes it.
    @Test func aSwitchKeyAfterCommandLeavesTheWordAsItWent() {
        type("dkssud ")
        session.commandPressed(client: field, heldWordOnly: false)
        session.handle(.cycle, client: field)
        #expect(field.text == "안녕 " && marked == nil)
    }

    @Test func commandGoingDownWithNothingTypedDoesNothing() {
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(field.text == "" && field.insertions.isEmpty)
    }

    @Test func aSecondSpaceAndPunctuationGoToTheApp() {
        type("dkssud  ")
        #expect(field.text == "안녕  " && marked == nil)
        type("gktpdy .")
        #expect(field.text == "안녕  하세요 ." && marked == nil)
    }

    @Test func losingFocusCommitsTheHeldWordWithItsSpace() {
        type("dkssud ")
        session.commit(client: field)
        #expect(field.text == "안녕 " && marked == nil)
    }

    @Test func escWhileHeldIsLearnedWhenTheWordGoesIn() {
        type("hello ")
        session.handle(.cycle, client: field)
        #expect(field.text == "ㅗ디ㅣㅐ ")
        #expect(learning.pending.isEmpty)
        type("x")
        #expect(learning.pending == ["hello": .korean])
    }

    /// A held word is still the word being typed: switched to Japanese, Space converts it.
    @Test func spaceOnAHeldWordSwitchedToJapaneseConverts() {
        let (japanese, field) = Self.japaneseSession()
        for ch in "hello" { japanese.handle(.letter(ch), client: field) }
        japanese.handle(.printable(" "), client: field)
        #expect(field.text == "hello ")
        japanese.handle(.cycle, client: field)
        #expect(field.text == "へっぉ ")
        #expect(japanese.handle(.printable(" "), client: field))
        #expect(japanese.conversion != nil)
        #expect(field.text == "へっぉ")
    }

    /// Holding changes when a word goes in, never what goes in: in a Strict app (as terminals are
    /// usually set) a line comes out the same with or without it.
    @Test(arguments: ["gst ls", "cd src", "git status", "rm -rf", "ls -al", "gs ", "vi ", "tmux a",
                      "brew install", "npm run dev", "dkssud gktpdy", "rkskek ",
                      "echo \"hi.\"", "git commit -m \"fix.\"", "ls -al.", "a/b/c", "dkssud, gktpdy!", "x; y"])
    func strictAppTypesTheSameLine(keys: String) {
        func run(hold: Bool) -> String {
            let field = FakeTextField()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-hold-strict-\(UUID().uuidString).json")
            let session = InputSession(engine: DictionaryEngine(base: splitting, storeURL: url),
                                       policies: AppPolicies(overrides: ["test.strict": .init(conversionThreshold: AppPolicy.strictThreshold, holdSpace: hold)]))
            session.activate(app: "test.strict")
            for ch in keys {
                let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                        : session.handle(.printable(ch), client: field)
                if !handled { field.insertText(String(ch), replacing: nil) }
            }
            session.commit(client: field)
            return field.text
        }
        #expect(run(hold: true) == run(hold: false))
    }

    @Test func pausingCommitsTheHeldWordWithItsSpace() {
        type("dkssud ")
        session.togglePause(client: field)
        #expect(field.text == "안녕 " && marked == nil)
        // Paused, keys go to the app as typed.
        #expect(type("gk") == [false, false])
        #expect(field.text == "안녕 gk")
    }

    @Test func vimLeavingInsertModeCommitsTheHeldWordWithItsSpace() {
        type("dkssud ")
        session.vimChanged(to: .normal, client: field)
        #expect(field.text == "안녕 " && marked == nil)
    }

    /// ⇧Space on a held word is a second Space: the word goes in with its space, the app types another.
    @Test func shiftSpaceOnAHeldWordIsASecondSpace() {
        type("dkssud ")
        if !session.handle(.shiftSpace, client: field) { field.insertText(" ", replacing: nil) }
        #expect(field.text == "안녕  " && marked == nil)
    }

    @Test func aDigitCommitsTheHeldWordAndGoesToTheApp() {
        type("dkssud 3")
        #expect(field.text == "안녕 3" && marked == nil)
    }

    /// With live conversion on too, Space on a held word switched to Japanese converts, without the held space.
    @Test func spaceOnAHeldWordSwitchedToJapaneseConvertsWithLiveConversion() {
        let (live, field) = Self.japaneseSession(live: true)
        for ch in "hello" { live.handle(.letter(ch), client: field) }
        live.handle(.printable(" "), client: field)
        live.handle(.cycle, client: field)
        #expect(field.text.hasSuffix(" "))
        #expect(live.handle(.printable(" "), client: field))
        #expect(live.conversion != nil)
        #expect(!field.text.hasSuffix(" "))
    }

    @Test func otherAppsFinishTheWordOnSpace() {
        session.activate(app: "com.example.editor")
        #expect(type("dkssud ").last == false)
        #expect(field.text == "안녕 " && marked == nil)
    }
}
