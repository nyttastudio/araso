import Foundation

/// The field as a word typed with Caps Lock on sees it. Its letters reach the session in the case
/// Shift alone gives (GKAUS is 하면: Caps Lock doesn't change what is decided), and the English
/// that goes in is in capitals, as macOS types it with Caps Lock, Shift or not. Text read back is
/// lowercased, so a word just committed still matches what the session inserted (unless Shift
/// gave it a capital: then it can't be switched after the commit).
final class CapsLockClient: TextClient {
    let base: TextClient

    init(_ base: TextClient) { self.base = base }

    func setMarkedText(_ text: String) { base.setMarkedText(Self.capitals(text)) }
    func setMarkedText(_ text: String, replacing range: NSRange) { base.setMarkedText(Self.capitals(text), replacing: range) }
    func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?) {
        base.setMarkedText(Self.capitals(text), selectedClause: selectedClause, replacing: range)
    }
    func insertText(_ text: String, replacing range: NSRange?) { base.insertText(Self.capitals(text), replacing: range) }
    func selectedRange() -> NSRange { base.selectedRange() }
    func markedRange() -> NSRange { base.markedRange() }
    func text(in range: NSRange) -> String? { base.text(in: range).map(Self.lowercase) }

    /// ASCII letters in capitals; Hangul, kana and everything else as they are.
    static func capitals(_ text: String) -> String {
        String(text.map { $0.isASCII && $0.isLetter ? Character($0.uppercased()) : $0 })
    }

    static func lowercase(_ text: String) -> String {
        String(text.map { $0.isASCII && $0.isLetter ? Character($0.lowercased()) : $0 })
    }
}
