import Foundation
import Testing
@testable import ArasoCore

/// A word fixed as Japanese earlier in the line converts to kanji as one being typed does: Space
/// opens the candidates in the clause's place, and the words after it stay as they are.
@MainActor @Suite struct FixingKanjiTests {
    let field = FakeTextField()
    let converter = FakeConverter()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-fixing-kanji-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                      storeURL: url)
        session = InputSession(engine: engine, converter: converter, japaneseEnabled: true)
        field.insertsOverMarked = true // as a real text view does
    }

    func type(_ s: String) {
        for ch in s {
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    /// "made it " with the caret on made, the fix switched on to its kana, まで.
    func fixMadeAsKana() {
        type("made it ")
        #expect(field.text == "made it ")
        field.cursor = 1
        #expect(session.handle(.cycle, client: field))
        for _ in 0..<3 where session.fixing?.language != .japanese { session.handle(.cycle, client: field) }
        #expect(session.fixing?.language == .japanese)
        #expect(field.text == "まで it ")
    }

    @Test func spaceOpensTheCandidatesInPlace() {
        fixMadeAsKana()
        #expect(session.handle(.printable(" "), client: field))
        // The kana is on screen already: Space shows the next candidate, as for a word being typed.
        #expect(session.conversion?.current.text == "迄")
        #expect(session.readings == nil)
        #expect(field.text == "迄 it ")
        #expect(field.marked == NSRange(location: 0, length: 1))
        #expect(field.selectedClause == NSRange(location: 0, length: 1))
        #expect(session.handle(.printable(" "), client: field)) // round the candidates
        #expect(field.text == "まで it ")
        #expect(session.handle(.up, client: field))
        #expect(field.text == "迄 it ")
    }

    @Test func returnPicksTheCandidateAndGoesBackToTheLineEnd() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        #expect(session.handle(.enter, client: field))
        #expect(session.fixing == nil)
        #expect(session.conversion == nil)
        #expect(field.text == "迄 it ")
        #expect(field.marked.location == NSNotFound)
        #expect(field.cursor == ("迄 it " as NSString).length)
        #expect(converter.learned == ["迄"])
    }

    @Test func aDigitPicksFromTheCandidates() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        #expect(session.handle(.printable("1"), client: field))
        #expect(field.text == "まで it ")
        #expect(session.fixing == nil)
        #expect(converter.learned == ["まで"])
    }

    /// ← makes the clause shorter, as in kanji conversion; Return picks it and the rest of the
    /// reading is converted next, the fix confirmed after the last clause.
    @Test func aShorterClauseIsPickedThenTheRest() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        #expect(session.handle(.left, client: field))
        #expect(session.conversion?.current.text == "ま")
        #expect(field.selectedClause == NSRange(location: 0, length: 1))
        #expect(session.handle(.enter, client: field))
        #expect(session.fixing != nil)
        #expect(session.conversion?.kana == "で")
        #expect(field.selectedClause == NSRange(location: 1, length: 1)) // the rest is the clause now
        #expect(session.handle(.enter, client: field))
        #expect(session.fixing == nil)
        #expect(field.text == "まで it ")
        #expect(field.cursor == ("まで it " as NSString).length)
        #expect(converter.learned == ["ま", "で"])
    }

    /// Esc goes back to the kana, still fixing; then the fix goes on as before (Return confirms it).
    @Test func escapeGoesBackToTheKana() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        #expect(session.handle(.escape, client: field))
        #expect(session.conversion == nil)
        #expect(session.fixing != nil)
        #expect(field.text == "まで it ")
        #expect(field.marked == NSRange(location: 0, length: 2))
        session.handle(.enter, client: field)
        #expect(field.text == "まで it ")
        #expect(converter.learned.isEmpty)
    }

    /// A letter while the candidates are up: the fix goes in as shown, the letter at the line's end.
    @Test func typingOnConfirmsAsShown() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        type("x")
        #expect(session.fixing == nil)
        #expect(field.text.hasPrefix("迄 it "))
        #expect(converter.learned == ["迄"])
    }

    /// ⌘ going down while the candidates are up: the fix goes in as shown, the caret at the line's end.
    @Test func commandConfirmsAsShown() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        #expect(session.commandPressed(client: field, heldWordOnly: false))
        #expect(session.fixing == nil)
        #expect(session.conversion == nil)
        #expect(field.text == "迄 it ")
        #expect(field.cursor == ("迄 it " as NSString).length)
        #expect(converter.learned == ["迄"])
    }

    /// A mark the app moved: nothing goes in where the word was, and nothing is learned.
    @Test func aMisplacedMarkLearnsNothing() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        field.marked = NSRange(location: 3, length: 1)
        session.commit(client: field)
        #expect(session.fixing == nil)
        #expect(session.conversion == nil)
        #expect(converter.learned.isEmpty)
    }

    /// A click in the candidate window picks there, the rest of the line kept.
    @Test func aClickedCandidateGoesInWhereTheWordIs() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        session.choose(0, client: field)
        #expect(field.text == "まで it ")
        #expect(session.fixing == nil)
        #expect(field.cursor == ("まで it " as NSString).length)
    }

    /// The word converted is remembered as it went in: fixing it again finds it.
    @Test func theKanjiWordCanBeFixedAgain() {
        fixMadeAsKana()
        session.handle(.printable(" "), client: field)
        session.handle(.enter, client: field)
        field.cursor = 0
        #expect(session.handle(.cycle, client: field))
        #expect(session.fixing != nil)
        #expect(!field.text.hasPrefix("迄"))
        #expect(field.text.hasSuffix(" it "))
    }

    /// Space on a fix that isn't Japanese still confirms it, the space typed at the line's end.
    @Test func spaceOnAnotherReadingConfirms() {
        type("made it ")
        field.cursor = 1
        session.handle(.cycle, client: field)
        #expect(session.fixing != nil)
        guard session.fixing?.language != .japanese else { return }
        let fixed = field.text(in: field.marked)!
        #expect(!session.handle(.printable(" "), client: field))
        #expect(session.fixing == nil)
        #expect(session.conversion == nil)
        #expect(field.text.hasPrefix("\(fixed) it "))
    }
}
