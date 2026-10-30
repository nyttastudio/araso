import Foundation
import Testing
@testable import ArasoCore

/// Fixing a word typed earlier in the line: a switch key with the caret on it brings it back as
/// marked text, read the next way, the words after it as they are; ←/→ change how much is fixed;
/// Return or any other key confirms and the caret goes back to the end of the text.
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
        // Only the word is marked, the thick clause; the caret is at its end.
        #expect(field.marked == NSRange(location: 0, length: (fixed as NSString).length))
        #expect(field.selectedClause == NSRange(location: 0, length: (fixed as NSString).length))
        #expect(field.cursor == (fixed as NSString).length)
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
        #expect(session.caretMoved(client: field) == NSRange(location: 0, length: 1)) // 손, as it is in the field
        #expect(session.readings?.texts == ["ths", "손"])
        #expect(session.readings?.selected == 1)
        caret(at: 5) // hello
        session.handle(.other, client: field) // any key puts the list away
        #expect(session.readings == nil)
        #expect(session.caretMoved(client: field) == nil)
    }

    /// Where the composition can only be at the caret (fcitx5), a word earlier in the line stays.
    @Test func noFixingWhereMarkedTextIsOnlyAtTheCaret() {
        field.marksAnywhere = false
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        #expect(field.text == "hello world ")
        #expect(session.fixing == nil)
        #expect(session.caretMoved(client: field) == nil)
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
        #expect(field.marked == NSRange(location: 0, length: (korean("hello") as NSString).length))
        #expect(session.fixing?.pieces.count == 3)
    }

    /// A text view that marks at the caret whatever range is named, and inserts there unless the range
    /// starts or ends at the caret (macOS's): with the caret anywhere in a word, the word alone is
    /// marked at its start, the text after it untouched; confirmed, the caret is at the end again.
    @Test func whereMarkedTextGoesAtTheCaret() {
        field.marksFromCaret = true
        field.insertsFromCaret = true
        type("hello world again ")
        caret(at: 8) // inside world
        session.handle(.cycle, client: field)
        let world = korean("world")
        #expect(field.text == "hello \(world) again ")
        #expect(field.marked == NSRange(location: 6, length: (world as NSString).length))
        #expect(field.cursor == 6 + (world as NSString).length)
        session.handle(.right, client: field) // and the range can change: again comes in
        let clause = "\(world) \(korean("again"))"
        #expect(field.text == "hello \(clause) ")
        #expect(field.marked == NSRange(location: 6, length: (clause as NSString).length))
        session.handle(.enter, client: field)
        #expect(field.text == "hello \(clause) ")
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == (field.text as NSString).length)
        caret(at: 0)
        #expect(session.caretMoved(client: field) == nil) // hello is sure: no list
    }

    /// The words after the fixed one are never written while it is fixed, only once it goes in, over
    /// themselves, to bring the caret back; a word ← gives back stays marked as it was.
    @Test func theTextAfterTheWordStaysAsItIs() {
        field.marksFromCaret = true
        field.insertsFromCaret = true
        type("hello world again ")
        caret(at: 7) // inside world
        session.handle(.cycle, client: field)
        let world = korean("world")
        let after = NSRange(location: 6 + (world as NSString).length, length: 7)
        #expect(field.text(in: after) == " again ")
        session.handle(.cycle, client: field) // back to English, and Korean again
        session.handle(.cycle, client: field)
        #expect(field.text(in: after) == " again ")
        session.handle(.right, client: field)
        session.handle(.left, client: field) // again given back: as it was, still marked
        #expect(field.text == "hello \(world) again ")
        #expect(field.marked == NSRange(location: 6, length: ("\(world) again" as NSString).length))
        session.handle(.escape, client: field)
        #expect(field.text == "hello world again ")
        #expect(field.cursor == (field.text as NSString).length)
    }

    /// The marked text takes in the next word from the field's start too: taken away and marked again
    /// at the caret, no character before it needed.
    @Test func longerClauseFromTheFieldsStart() {
        field.marksFromCaret = true
        field.insertsFromCaret = true
        type("hello world ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(session.handle(.right, client: field))
        #expect(session.fixing?.count == 2)
        let clause = "\(korean("hello")) \(korean("world"))"
        #expect(field.text == "\(clause) ")
        #expect(field.marked == NSRange(location: 0, length: (clause as NSString).length))
        session.handle(.enter, client: field)
        #expect(field.text == "\(clause) ")
        #expect(field.cursor == (field.text as NSString).length)
    }

    /// ⇧← on the word being typed cuts it, as on a word fixed later; ← alone still puts it in.
    @Test func shiftLeftCutsTheWordBeingTyped() throws {
        type("helloab")
        #expect(session.handle(.shiftLeft, client: field))
        session.handle(.shiftLeft, client: field)
        let fixing = try #require(session.fixing)
        #expect(fixing.cut == 5)
        #expect(field.selectedClause == NSRange(location: 0, length: 5))
        while session.fixing?.language != .korean { session.handle(.cycle, client: field) }
        #expect(field.text.hasPrefix(korean("hello")))
        session.handle(.enter, client: field) // hello settled; ab is the clause now
        #expect(session.fixing?.settled == korean("hello"))
        session.handle(.enter, client: field)
        #expect(field.text.hasPrefix(korean("hello")))
        #expect(field.marked.location == NSNotFound)
        #expect(session.keys.isEmpty)

        type(" world")
        #expect(!session.handle(.left, client: field)) // ← puts world in and goes to the app
        #expect(field.text.hasSuffix(" world"))
        #expect(session.fixing == nil)
    }

    /// After a switch key changed the word being typed, ← and → change how much of it is fixed, as
    /// in kanji conversion; before one, ← puts the word in.
    @Test func arrowsAfterASwitchOnTheWordBeingTyped() throws {
        type("helloab")
        session.handle(.cycle, client: field) // another reading of the word
        #expect(session.handle(.left, client: field))
        let fixing = try #require(session.fixing)
        #expect(fixing.cut == 6)
        session.handle(.left, client: field)
        #expect(session.fixing?.cut == 5)
        session.handle(.right, client: field)
        #expect(session.fixing?.cut == 6)
        session.handle(.escape, client: field) // all back, as it was before the arrows
        #expect(session.fixing == nil)
        #expect(field.marked.location == NSNotFound)
    }

    /// After a switch key changed the word just committed, ← and → make it the fix too, as for the
    /// word being typed: marked as it now reads, with its space, and ← cuts it. Return puts the fix in,
    /// learned as the word's reading.
    @Test func arrowsAfterASwitchOnTheWordJustCommitted() throws {
        type("the helloab ")
        session.handle(.cycle, client: field)
        let switched = "\(korean("helloab")) "
        #expect(field.text == "the \(switched)")
        #expect(session.handle(.left, client: field))
        let fixing = try #require(session.fixing)
        #expect(fixing.cut == 6)
        #expect(field.marked.location == 4) // the word and its space, the front part the clause
        #expect(field.text(in: field.marked)?.hasSuffix(" ") == true)
        #expect(NSMaxRange(field.marked) == (field.text as NSString).length)
        #expect(field.selectedClause?.location == 0)
        session.handle(.right, client: field) // the whole word again
        #expect(session.fixing?.cut == nil)
        session.handle(.escape, client: field) // as it was before the arrow
        #expect(field.text == "the \(switched)")
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == (field.text as NSString).length)

        type("hello ")
        session.handle(.cycle, client: field)
        #expect(session.handle(.right, client: field)) // nothing after it to take in: marked whole
        #expect(session.fixing?.cut == nil)
        session.handle(.enter, client: field)
        #expect(field.text == "the \(switched)\(korean("hello")) ")
        #expect(field.cursor == (field.text as NSString).length)
        #expect(session.engine.correctedOnce("hello", app: nil) == .korean)
    }

    /// Where marked text goes at the caret, the word just committed is taken away up to the caret,
    /// the character before it put back, and marked there; at the field's start, with no character
    /// before it, the arrow goes to the app as before.
    @Test func arrowsAfterASwitchOnTheWordJustCommittedFromTheCaret() {
        field.marksFromCaret = true
        field.insertsFromCaret = true
        type("hello ")
        session.handle(.cycle, client: field)
        #expect(!session.handle(.left, client: field))
        #expect(session.fixing == nil)

        caret(at: (field.text as NSString).length)
        type("world ")
        session.handle(.cycle, client: field)
        #expect(field.text == "\(korean("hello")) \(korean("world")) ")
        let start = (korean("hello") as NSString).length + 1
        #expect(session.handle(.left, client: field))
        #expect(session.fixing?.cut == 4)
        #expect(field.marked.location == start)
        #expect(NSMaxRange(field.marked) == (field.text as NSString).length)
        #expect(field.text.hasPrefix("\(korean("hello")) "))
        session.handle(.cycle, client: field) // the cut's front part read the next way
        session.handle(.right, client: field)
        session.handle(.enter, client: field)
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == (field.text as NSString).length)
        #expect(field.text.hasPrefix("\(korean("hello")) "))
        #expect(field.text.hasSuffix(" "))
    }

    /// Where the mark can't follow the switch key's insert at once (macOS text views), ← goes to the
    /// app, and once the caret is at the word's end (`caretMoved`) the word is marked as it reads, cut
    /// as ← cuts it; learned when the fix goes in. Another key before that only learns the switch.
    @Test func leftAfterASwitchOnTheWordJustCommittedWaitsForTheCaret() throws {
        field.marksFromCaret = true
        field.insertsFromCaret = true
        field.insertsRightAfterAnInsert = false
        type("hello world ")
        session.handle(.cycle, client: field)
        let world = korean("world")
        #expect(!session.handle(.left, client: field))
        #expect(session.fixing == nil)
        field.cursor -= 1 // the app's ←: before the space
        #expect(session.caretMoved(client: field) == nil)
        let fixing = try #require(session.fixing)
        #expect(fixing.cut == 4)
        #expect(field.marked.location == 6)
        session.handle(.right, client: field) // the whole word
        #expect(session.fixing?.cut == nil)
        #expect(field.text == "hello \(world) ")
        session.handle(.enter, client: field)
        #expect(field.text == "hello \(world) ")
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == (field.text as NSString).length)
        #expect(session.engine.correctedOnce("world", app: nil) == .korean)

        type("again ")
        session.handle(.cycle, client: field)
        #expect(!session.handle(.left, client: field))
        type("x") // before the caret move was seen
        #expect(session.fixing == nil)
        #expect(session.engine.correctedOnce("again", app: nil) == .korean)
    }

    /// The strip lists the clause's readings after ←/→ too: a cut's front part, or the words of a
    /// longer clause read together.
    @Test func readingsFollowTheClause() {
        type("hello world again ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(session.readings?.texts == ["hello", korean("hello")])
        session.handle(.right, client: field) // hello world
        #expect(session.readings?.texts == ["hello world", "\(korean("hello")) \(korean("world"))"])
        #expect(session.readings?.selected == 1)
        session.handle(.left, client: field) // hello again
        session.handle(.left, client: field) // hell|o
        #expect(session.fixing?.cut == 4)
        #expect(session.readings?.texts == ["hell", korean("hell")])
        #expect(session.readings?.selected == 1)
    }

    /// While fixing, a digit picks that reading of the clause, numbered in the strip; a digit past
    /// the list confirms and is typed.
    @Test func digitsPickAReading() {
        type("hello world ")
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(session.readings?.numbered == true)
        #expect(session.handle(.printable("1"), client: field)) // hello, English
        #expect(field.text == "hello world ")
        #expect(session.fixing?.language == .english)
        session.handle(.printable("2"), client: field)
        #expect(field.text == "\(korean("hello")) world ")
        #expect(!session.handle(.printable("7"), client: field)) // none: confirmed, and the app types it
        #expect(session.fixing == nil)
        #expect(field.text == "\(korean("hello")) world ")
    }

    /// A reading chosen with the switch key on the word being typed, then fixed with the arrows and
    /// confirmed whole, is learned as the correction it is.
    @Test func aChosenReadingFixedWholeIsLearned() {
        type("helloab")
        while session.readings?.languages[session.readings!.selected] != .korean { session.handle(.cycle, client: field) }
        session.handle(.left, client: field) // a key shorter
        session.handle(.right, client: field) // whole again
        #expect(session.fixing?.cut == nil)
        session.handle(.enter, client: field)
        #expect(session.engine.correctedOnce("helloab", app: nil) == .korean)
    }

    /// Back to Araso's own reading after choosing another, then confirmed: that is a choice too, and
    /// forgets a correction made before, as a word finished with Space does.
    @Test func choosingBackToTheOwnReadingForgetsACorrection() {
        type("hello ")
        session.handle(.cycle, client: field) // hello went in as Korean once
        type("abc ")
        #expect(session.engine.correctedOnce("hello", app: nil) == .korean)
        type("hello")
        while session.readings?.languages[session.readings!.selected] != .korean { session.handle(.cycle, client: field) }
        while session.readings?.languages[session.readings!.selected] != .english { session.handle(.cycle, client: field) }
        session.handle(.left, client: field)
        session.handle(.right, client: field)
        session.handle(.enter, client: field)
        #expect(session.engine.correctedOnce("hello", app: nil) == nil)
    }

    /// A word whose space was changed since (pasted over with another character) is fixed alone: the
    /// character after it stays as the field has it.
    @Test func aChangedBoundaryStaysAsTheFieldHasIt() {
        type("hello world again ")
        field.text = "hello_world again "
        caret(at: 0)
        session.handle(.cycle, client: field)
        #expect(session.fixing?.pieces.count == 1)
        session.handle(.enter, client: field)
        #expect(field.text == "\(korean("hello"))_world again ")
    }

    /// A mark the app didn't put there: Delete, meant to put the word back, isn't the app's either.
    @Test func deleteOnAMarkTheAppDidntPutThere() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        field.text = "hello world "
        field.marked = NSRange(location: NSNotFound, length: 0)
        field.cursor = 12
        #expect(session.handle(.delete, client: field))
        #expect(field.text == "hello world ")
        #expect(session.fixing == nil)
    }

    /// The app put the fix's marked text at the caret instead: dropping the fix takes it away again.
    @Test func aMisplacedMarkIsTakenAway() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        // As an app that marks at the caret would have it: the word as it was, the fix after it.
        let fixed = korean("hello") + " world"
        field.text = "hello world " + fixed
        field.marked = NSRange(location: 12, length: (fixed as NSString).length)
        field.cursor = NSMaxRange(field.marked)
        #expect(!session.handle(.enter, client: field)) // the app's Return, after the mark is gone
        #expect(field.text == "hello world ")
        #expect(field.marked.location == NSNotFound)
        #expect(session.fixing == nil)
    }

    /// Marked text the app reports over the word itself isn't taken away when the fix is dropped: it
    /// may be the word's own text.
    @Test func aMarkOverTheWordIsLeft() {
        type("hello world ")
        caret(at: 1)
        session.handle(.cycle, client: field)
        field.text = "hello world "
        field.marked = NSRange(location: 0, length: 3) // over hel, not where the fix put it
        field.cursor = 3
        session.handle(.enter, client: field)
        #expect(field.text.hasPrefix("hel"))
        #expect(session.fixing == nil)
    }

    /// The field's first word has no character before it to move the caret with: there it is
    /// switched where it is, the caret at its end, and the switch key goes on cycling it.
    @Test func switchInPlaceFromAnywhereInTheFirstWord() {
        field.marksFromCaret = true
        type("hello world ")
        caret(at: 2) // he|llo
        #expect(session.handle(.cycle, client: field))
        let hello = korean("hello")
        #expect(field.text == "\(hello) world ")
        #expect(field.cursor == (hello as NSString).length)
        #expect(field.marked.location == NSNotFound)
        #expect(session.readings?.texts == ["hello", hello])
        session.handle(.cycle, client: field)
        #expect(field.text == "hello world ")
        session.handle(.cycle, client: field)
        session.handle(.other, client: field) // closes it: learned
        #expect(session.engine.correctedOnce("hello", app: nil) == .korean)
    }

    /// Right after a switch key changed the word just committed, the strip is numbered and a digit
    /// picks that reading; a digit any other time goes in as typed.
    @Test func digitsPickRightAfterTheSwitchKey() {
        type("hello ")
        #expect(session.handle(.cycle, client: field))
        #expect(session.readings?.numbered == true)
        #expect(field.text == "\(korean("hello")) ")
        #expect(session.handle(.printable("1"), client: field)) // back to English, the first listed
        #expect(field.text == "hello ")
        #expect(!session.handle(.printable("9"), client: field)) // none: the app types it
        type("the 2")
        #expect(field.text.hasSuffix(" 2")) // no switch before it: the digit goes in
    }

    /// ⇧Space while fixing, where it types a full-width space (Japanese on): the fix goes in first, and
    /// the space at the end of the line, not over the marked word.
    @Test func shiftSpaceConfirmsTheFixFirst() {
        let session = InputSession(engine: self.session.engine, japaneseEnabled: true)
        func type(_ s: String) {
            for ch in s where !(ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)) {
                field.insertText(String(ch), replacing: nil)
            }
        }
        type("hello world ")
        caret(at: 0)
        #expect(session.handle(.cycle, client: field))
        let fixed = field.text(in: field.marked)!
        #expect(session.handle(.shiftSpace, client: field))
        #expect(session.fixing == nil)
        #expect(field.text == "\(fixed) world 　")
    }

    /// A line longer than one read of it: the caret still goes back to its end, not to where the
    /// first read stopped; past a line break it stays on its own line.
    @Test func theCaretGoesBackToTheEndOfALongLine() {
        type("hello world ")
        let rest = String(repeating: "x", count: 150)
        field.insertText(rest + "\nnext", replacing: nil)
        caret(at: 1)
        session.handle(.cycle, client: field)
        session.handle(.enter, client: field)
        let line = "\(korean("hello")) world \(rest)"
        #expect(field.text == line + "\nnext")
        #expect(field.cursor == (line as NSString).length)
    }

    /// A line going on past what is read of it, with no line break: its end isn't known, so no fix
    /// starts there (the caret couldn't go back to it); the word is switched where it is instead, as
    /// the field's first word is.
    @Test func noFixWhereTheLineEndIsntKnown() {
        type("hello world ")
        let rest = String(repeating: "x", count: 5000)
        field.insertText(rest, replacing: nil)
        caret(at: 8) // inside world
        session.handle(.cycle, client: field)
        #expect(session.fixing == nil)
        #expect(field.marked.location == NSNotFound)
        #expect(field.text == "hello \(korean("world")) \(rest)")
    }
}
