import Foundation
import Testing
@testable import ArasoCore

/// ⌘ going down while a word is being typed, in an ordinary app (no `holdSpace`). An app may act on
/// the shortcut without showing the input method the key (Ghostty's ⌘V, ⌘⌫), so what it finds in its
/// text at that moment is what it acts on.
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
        session.commandPressed(client: field)
        field.insertText("world", replacing: nil) // the app's paste: replaces marked text if any
        #expect(field.text == "hello 안녕world")
    }

    /// The app deletes a word backward on its own: the word being typed goes, not the one before it.
    @Test func wordDeleteOnCommandTakesTheWordBeingTypedNotThePreviousOne() {
        type("hello ")
        type("dkssud")
        session.commandPressed(client: field)
        // The app's own word-delete acts on its committed text; an underlined word isn't text to it yet.
        let committed = field.marked.location == NSNotFound ? field.text
            : (field.text as NSString).substring(to: field.marked.location)
        var words = committed.split(separator: " ", omittingEmptySubsequences: false)
        if words.last == "" { words.removeLast() }
        words.removeLast()
        let after = words.isEmpty ? "" : words.joined(separator: " ") + " "
        #expect(after == "hello ", "the typed word 안녕 should have gone, not hello")
    }
}
