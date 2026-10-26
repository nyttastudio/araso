import Foundation
import Testing
@testable import ArasoCore

@Suite struct AccentHoldTests {
    @Test(arguments: Array(zip(Array("aousAOUS"), Array("äöüßÄÖÜẞ"))))
    func mapping(pair: (Character, Character)) {
        var hold = AccentHold(letter: pair.0, keyCode: 0)!
        #expect(hold.accent == pair.1)
        hold.repeatKey()
        #expect(hold.isVisible)
        let released = hold.release()
        #expect(!released)
        #expect(!hold.isDown)
        #expect(hold.isVisible) // releasing keeps the menu available for selection
    }

    @Test func quickReleaseAndLateRepeat() {
        var hold = AccentHold(letter: "a", keyCode: 0)!
        let firstRelease = hold.release()
        #expect(firstRelease)
        hold.repeatKey()
        #expect(!hold.isVisible)
        let released = hold.release()
        #expect(!released)
    }

    /// A missing key-up followed by idle time has no way to open the panel: no timer.
    @Test(arguments: Array("aousAOUS"))
    func missingKeyUpDoesNotOpenMenu(letter: Character) {
        let hold = AccentHold(letter: letter, keyCode: 0)!
        #expect(!hold.isVisible)
    }

    @Test func continuousRepeatOpensAndReleaseKeepsMenu() {
        var hold = AccentHold(letter: "a", keyCode: 0)!
        hold.repeatKey()
        #expect(hold.isVisible)
        hold.repeatKey()
        let released = hold.release()
        #expect(!released && hold.isVisible)
    }

    @Test(arguments: Array("eqxzä1 "))
    func unsupported(letter: Character) {
        #expect(AccentHold(letter: letter, keyCode: 0) == nil)
    }
}

@MainActor @Suite struct AccentSessionTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        session = InputSession(engine: DictionaryEngine(base: sharedEngine,
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("accent-\(UUID()).json")))
    }

    func type(_ text: String) {
        for ch in text {
            if !session.handle(ch.isLetter ? .letter(ch) : .printable(ch), client: field) {
                field.insertText(String(ch), replacing: nil)
            }
        }
    }

    @Test(arguments: Array("äöüßÄÖÜẞ"))
    func standalone(accent: Character) {
        session.insertAccent(accent, client: field)
        session.commit(client: field)
        #expect(field.text == String(accent))
        #expect(session.keys.isEmpty)
    }

    @Test func germanWordAndFollowingKoreanEnglish() {
        type("M")
        session.insertAccent("ü", client: field)
        type("nchen ")
        type("dkssud hello ")
        #expect(field.text == "München 안녕 hello ")
    }

    @Test func multipleAccentsAndDeletion() {
        type("gr")
        session.insertAccent("ö", client: field)
        session.insertAccent("ß", client: field)
        type("er")
        #expect(field.text == "größer")
        _ = session.handle(.delete, client: field)
        _ = session.handle(.delete, client: field)
        _ = session.handle(.delete, client: field)
        #expect(field.text == "grö")
        session.commit(client: field)
        #expect(field.text == "grö")
    }

    @Test func pausedAndVimPassThrough() {
        session.togglePause(client: field)
        session.insertAccent("ä", client: field)
        #expect(field.text.isEmpty)
        session.togglePause(client: field)
        session.vimChanged(to: .normal, client: field)
        session.insertAccent("ö", client: field)
        #expect(field.text.isEmpty)
    }

    @Test func holdBoundaryIsPreserved() {
        let held = InputSession(engine: session.engine,
            policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(holdSpace: true)]))
        for ch in "hello" { _ = held.handle(.letter(ch), client: field) }
        _ = held.handle(.printable(" "), client: field)
        held.insertAccent("Ä", client: field)
        held.commit(client: field)
        #expect(field.text == "hello Ä")
    }
}

extension AccentSessionTests {
    @Test func originalIsImmediateAndChoiceReplacesRawLetter() {
        type("Mu")
        #expect(field.text == "Mu")
        let chosen = session.replaceLastLetterWithAccent("ü", original: "u", expectedKeys: "Mu", client: field)
        #expect(chosen && field.text == "Mü")
        type("nchen ")
        #expect(field.text == "München ")
    }

    @Test func koreanPreviewDoesNotNeedSyntheticDelete() {
        type("a")
        #expect(!field.text.isEmpty)
        let chosen = session.replaceLastLetterWithAccent("ä", original: "a", expectedKeys: "a", client: field)
        #expect(chosen && field.text == "ä")
        session.commit(client: field)
        #expect(field.text == "ä")
    }

    @Test func staleChoiceCannotReplaceAnotherWord() {
        type("a hello")
        let before = field.text
        let chosen = session.replaceLastLetterWithAccent("ä", original: "a", expectedKeys: "a", client: field)
        #expect(!chosen && field.text == before)
    }

    @Test func heldBoundaryIsCommittedBeforeAccentLetter() {
        let held = InputSession(engine: session.engine,
            policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(holdSpace: true)]))
        for ch in "hello" { _ = held.handle(.letter(ch), client: field) }
        _ = held.handle(.printable(" "), client: field)
        _ = held.handle(.letter("a"), client: field)
        let chosen = held.replaceLastLetterWithAccent("ä", original: "a", expectedKeys: "a", client: field)
        #expect(chosen && field.text == "hello ä")
    }
}

extension AccentSessionTests {
    @Test(arguments: LatinLayout.allCases, KoreanLayout.allCases)
    func accentWordsOnCurrentLayouts(latin: LatinLayout, korean: KoreanLayout) {
        LatinLayout.$override.withValue(latin) {
            KoreanLayout.$override.withValue(korean) {
                let original = latin.character(keyCode: latin == .qwerty ? 31 : 41, shift: false, capsLock: false)!
                #expect(original == "o") // Colemak's o is on the QWERTY semicolon key.
                type("sch" + String(original))
                let snapshot = session.keys
                let chosen = session.replaceLastLetterWithAccent("ö", original: original, expectedKeys: snapshot, client: field)
                #expect(chosen)
                type("n ")
                #expect(field.text == "schön ")
            }
        }
    }

    @Test func staleChoiceCannotChangeCommittedOrPausedText() {
        type("a")
        session.togglePause(client: field)
        let before = field.text
        let chosen = session.replaceLastLetterWithAccent("ä", original: "a", expectedKeys: "a", client: field)
        #expect(!chosen && field.text == before)
    }

    @Test func invalidCandidateCannotRemoveTheOriginalLetter() {
        type("a")
        let before = field.text
        let chosen = session.replaceLastLetterWithAccent("\n", original: "a", expectedKeys: "a", client: field)
        #expect(!chosen && field.text == before && session.keys == "a")
    }
}

extension JapaneseSessionTests {
    @Test func latinAccentThenJapaneseConversion() {
        type("Mu")
        let chosen = session.replaceLastLetterWithAccent("ü", original: "u", expectedKeys: session.keys, client: field)
        #expect(chosen)
        type("nchen henkan ")
        #expect(session.conversion != nil)
        session.handle(.enter, client: field)
        #expect(field.text == "München 変換")
    }

    @Test func accentChoiceCannotOverwriteKanjiCandidates() {
        type("henkan ")
        let before = field.text
        let chosen = session.replaceLastLetterWithAccent("ä", original: "a", expectedKeys: session.keys, client: field)
        #expect(!chosen && session.conversion != nil && field.text == before)
    }
}
