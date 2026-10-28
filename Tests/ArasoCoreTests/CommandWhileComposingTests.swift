import Foundation
import Testing
@testable import ArasoCore

/// ⌘ going down while a word is being typed, in an ordinary app (no `holdSpace`). An app may act on
/// the shortcut without showing the input method the key (Ghostty's ⌘V, ⌘⌫), so what it finds in its
/// text at that moment is what it acts on. A bare ⌘ with nothing being typed changes nothing.
@MainActor @Suite struct CommandWhileComposingTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-cmd-\(UUID().uuidString).json")
        session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url), policies: AppPolicies())
        session.activate(app: "test.plain")
    }

    @discardableResult
    func type(_ s: String) -> [Bool] {
        s.map { ch in
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
            return handled
        }
    }

    var marked: String? {
        guard field.marked.location != NSNotFound else { return nil }
        return (field.text as NSString).substring(with: field.marked)
    }

    /// The app pastes on its own (never shows the input method the ⌘V): the paste must land after
    /// the word being typed, not over it.
    @Test func pasteOnCommandLandsAfterTheWordBeingTyped() {
        type("hello ")
        type("dkssud")
        #expect(marked == "안녕")
        session.commandPressed(client: field, heldWordOnly: false)
        field.insertText("world", replacing: nil) // the app's paste: replaces marked text if any
        #expect(field.text == "hello 안녕world")
    }

    /// The app deletes on its own (Ghostty's ⌘⌫ is a line delete), acting on its text as it is: the
    /// word being typed has to be in by then, or the delete skips it and takes the text before it.
    @Test func theWordIsInBeforeTheAppDeletesOnCommand() {
        type("hello ")
        type("dkssud")
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(marked == nil)
        #expect(field.text == "hello 안녕")
    }

    /// With nothing being typed, ⌘ changes nothing: the word just committed can still be flipped.
    @Test func commandWithNothingTypedLeavesTheFlipWindowOpen() {
        type("dkssud ")
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(session.handle(.cycle, client: field))
        #expect(field.text != "안녕 ")
    }

    /// The caller redraws the strip only when ⌘ put a word in: a ⌘ that changed nothing says so,
    /// or the capsule saying a word was learned would start over on every ⌘S.
    @Test func commandSaysWhetherItPutAWordIn() {
        #expect(!session.commandPressed(client: field, heldWordOnly: false))
        type("dkssud")
        #expect(session.commandPressed(client: field, heldWordOnly: false))
        #expect(!session.commandPressed(client: field, heldWordOnly: false))
    }

    /// The price of committing on ⌘: pressed and let go mid-word, it ends the word there, and the
    /// next letters start a new word.
    @Test func commandMidWordEndsTheWordThere() {
        type("dkss")
        session.commandPressed(client: field, heldWordOnly: false)
        #expect(marked == nil)
        #expect(field.insertions == ["안ㄴ"])
        type("ud ")
        #expect(field.text.hasPrefix("안ㄴ"))
    }
}
