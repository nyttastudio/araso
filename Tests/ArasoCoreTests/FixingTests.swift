import Foundation
import Testing
@testable import ArasoCore

/// Fixing a word typed earlier in the line: a switch key with the caret on it brings it back as
/// marked text, read the next way; ←/→ change how much is fixed; Return or any other key confirms
/// and the caret goes back to the end of the text.
@MainActor @Suite struct FixingTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-fixing-\(UUID().uuidString).json")
        session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url))
        field.insertsOverMarked = true // as a real text view does
    }

    func type(_ s: String) {
        for ch in s {
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    func korean(_ keys: String) -> String { session.engine.render(keys, as: .korean) }

    /// The caret at `offset` (UTF-16) of the text, as a click or ⌥← leaves it.
    func caret(at offset: Int) { field.cursor = offset }

    @Test func fixesAWordEarlierInTheLine() {
        type("hello world ")
        let end = field.cursor
        caret(at: 2) // inside hello
        #expect(session.handle(.cycle, client: field))
        let fixed = korean("hello")
        #expect(field.text == "\(fixed) world ")
        // The line from the word on is marked; the word is the thick clause.
        #expect(field.marked == NSRange(location: 0, length: (field.text as NSString).length))
        #expect(field.selectedClause == NSRange(location: 0, length: (fixed as NSString).length))
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "\(fixed) world ")
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == end + (fixed as NSString).length - 5) // back at the end
        #expect(session.fixing == nil)
    }

    /// The caret right after a word's space is on the next word (where ⌥← leaves it); at the end of
    /// the text, past the last word's space, it is on the last word.
    @Test func picksTheWordTheCaretTouches() {
        type("hello world ")
        caret(at: 6) // before world
        session.handle(.cycle, client: field)
        #expect(field.text == "hello \(korean("world")) ")
        session.handle(.escape, client: field) // Esc isn't a switch key here: everything goes back
        #expect(field.text == "hello world ")
        #expect(field.cursor == 12)
        caret(at: 5) // right after hello
        session.handle(.cycle, client: field)
        #expect(field.text == "\(korean("hello")) world ")
    }

    @Test func switchKeyGoesOnCyclingTheSameWord() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        #expect(field.text.hasPrefix(korean("hello")))
        session.handle(.cycle, client: field)
        #expect(field.text == "hello world ") // back to English: still hello, not world
        #expect(session.fixing != nil)
    }

    @Test func rightTakesInTheNextWord() {
        type("hello world again ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(session.handle(.right, client: field)) // keys of hello first: it is whole, so world comes in
        #expect(field.text == "\(korean("hello")) \(korean("world")) again ")
        let clause = "\(korean("hello")) \(korean("world"))"
        #expect(field.selectedClause == NSRange(location: 0, length: (clause as NSString).length))
        session.handle(.left, client: field) // world goes back to what it was
        #expect(field.text == "\(korean("hello")) world again ")
        session.handle(.right, client: field)
        session.handle(.enter, client: field)
        #expect(field.text == "\(korean("hello")) \(korean("world")) again ")
        #expect(field.cursor == (field.text as NSString).length)
        // Both were corrections: the next hello and world lean Korean.
        #expect(session.engine.correctedOnce("hello", app: nil) == .korean)
        #expect(session.engine.correctedOnce("world", app: nil) == .korean)
    }

    /// ← past a word's start cuts it: the clause is its first keys, the rest read on its own;
    /// Return settles the clause and the rest becomes the clause.
    @Test func leftCutsAWordAndReturnGoesOnWithTheRest() throws {
        type("hellofmf ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        // Back to English for the whole word, then three keys shorter: hello | fmf.
        while session.fixing?.language != .english { session.handle(.cycle, client: field) }
        for _ in 0..<3 { session.handle(.left, client: field) }
        let fixing = try #require(session.fixing)
        #expect(fixing.cut == 5)
        #expect(field.selectedClause == NSRange(location: 0, length: 5))
        #expect(field.text.hasPrefix("hello"))
        #expect(session.handle(.enter, client: field)) // hello settled
        #expect(session.fixing?.settled == "hello")
        while session.fixing?.language != .korean { session.handle(.cycle, client: field) }
        #expect(field.text == "hello를 ")
        #expect(field.selectedClause == NSRange(location: 5, length: 1))
        session.handle(.enter, client: field)
        #expect(field.text == "hello를 ")
        #expect(field.cursor == (field.text as NSString).length)
        #expect(session.engine.correctedOnce("hellofmf", app: nil) == nil) // a cut word teaches nothing
    }

    @Test func aLetterConfirmsAndTypesAtTheEnd() {
        type("hello world ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        type("abc")
        #expect(field.text.hasPrefix("\(korean("hello")) world ")) // abc is the new word, being typed at the end
        #expect(session.keys == "abc")
        #expect(field.marked.location == ("\(korean("hello")) world " as NSString).length)
        #expect(session.fixing == nil)
    }

    /// A word changed in the field since it went in isn't Araso's to fix; nor is one before a Return.
    @Test func onlyWordsStillAsTheyWentIn() {
        type("hello world ")
        field.text = "hallo world "
        caret(at: 2)
        #expect(session.handle(.cycle, client: field)) // dropped: nothing to change
        #expect(field.text == "hallo world ")
        #expect(session.fixing == nil)

        field.text = ""
        caret(at: 0)
        type("hello ")
        #expect(!session.handle(.enter, client: field))
        field.insertText("\n", replacing: nil)
        type("world ")
        caret(at: 1) // in hello, before the Return
        session.handle(.cycle, client: field)
        #expect(field.text == "hello \nworld ")
        #expect(session.fixing == nil)
    }

    /// The caret moved onto a word Araso wasn't sure of (ths, 손 at the start of a line): its
    /// readings are listed, as the switch key would go through them; not for a sure one.
    @Test func caretOnAnUnsureWordListsItsReadings() {
        type("ths hello ")
        caret(at: 1)
        #expect(session.caretMoved(client: field))
        #expect(session.readings?.texts == ["ths", "손"])
        #expect(session.readings?.selected == 1)
        caret(at: 5) // hello
        session.handle(.other, client: field) // any key puts the list away
        #expect(session.readings == nil)
        #expect(!session.caretMoved(client: field))
    }

    /// Where the composition can only be at the caret (fcitx5), a word earlier in the line stays.
    @Test func noFixingWhereMarkedTextIsOnlyAtTheCaret() {
        field.marksAnywhere = false
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        #expect(field.text == "hello world ")
        #expect(session.fixing == nil)
        #expect(!session.caretMoved(client: field))
    }

    /// A second fix after a first one changed the length of the line: the words after it moved.
    @Test func fixesAgainAfterAFixChangedTheLine() {
        type("hello world again ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        session.handle(.enter, client: field)
        let first = korean("hello") // 4 units for 5
        #expect(field.text == "\(first) world again ")
        caret(at: (first as NSString).length + 1 + 2) // inside world, where it is now
        session.handle(.cycle, client: field)
        session.handle(.enter, client: field)
        #expect(field.text == "\(first) \(korean("world")) again ")
        caret(at: (field.text as NSString).length - 2) // inside again
        session.handle(.cycle, client: field)
        session.handle(.enter, client: field)
        #expect(field.text == "\(first) \(korean("world")) \(korean("again")) ")
        #expect(field.cursor == (field.text as NSString).length)
    }

    /// Delete puts the word back as it was, rather than the app deleting at the end of the line.
    @Test func deletePutsItBack() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "hello world ")
        #expect(field.marked.location == NSNotFound)
        #expect(session.fixing == nil)
    }

    /// An app that ignored where the mark was to go: the fix is dropped, nothing written over.
    @Test func aMarkTheAppDidntPutThereDropsTheFix() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        // As if the app had kept the word and marked nothing.
        field.text = "hello world "
        field.marked = NSRange(location: NSNotFound, length: 0)
        field.cursor = 12
        #expect(!session.handle(.enter, client: field))
        #expect(field.text == "hello world ")
        #expect(session.fixing == nil)
    }

    /// Clicking a reading in the strip switches to it a press at a time, as the controller's `pick` does.
    @Test func cyclingReachesEveryReading() {
        type("hello world ")
        caret(at: 1)
        var seen: [Language] = []
        for _ in 0..<4 {
            session.handle(.cycle, client: field)
            if let language = session.fixing?.language { seen.append(language) }
        }
        #expect(seen.first == .korean)
        #expect(seen.contains(.english))
        #expect(session.readings?.languages[session.readings!.selected] == session.fixing?.language)
    }

    /// Text deleted or typed over takes the words there out of the list: the same text typed again
    /// in the same place is fixed as the new words it is, not as the old ones.
    @Test func wordsDeletedOrTypedOverAreForgotten() {
        type("hello world ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        session.handle(.enter, client: field)
        // The field emptied the way ⌘A and Delete do.
        field.text = (field.text as NSString).substring(to: 0)
        caret(at: 0)
        #expect(!session.handle(.delete, client: field))
        type("hello world again ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(field.marked == NSRange(location: 0, length: (field.text as NSString).length))
        #expect(session.fixing?.pieces.count == 3)
    }

    /// A text view that marks at the caret whatever range is named (macOS's): only with the caret at
    /// the word's start, as ⌥← leaves it.
    @Test func whereMarkedTextGoesAtTheCaret() {
        field.marksFromCaret = true
        type("hello world again ")
        caret(at: 8) // inside world
        session.handle(.cycle, client: field)
        #expect(session.fixing == nil)
        #expect(field.text == "hello world again ")
        caret(at: 6) // its start
        session.handle(.cycle, client: field)
        #expect(field.text == "hello \(korean("world")) again ")
        #expect(field.marked.location == 6)
        session.handle(.enter, client: field)
        #expect(field.text == "hello \(korean("world")) again ")
        caret(at: 0)
        #expect(!session.caretMoved(client: field)) // hello is sure: no list
    }
}
