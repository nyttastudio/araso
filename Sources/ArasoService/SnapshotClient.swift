import ArasoCore
import Foundation

/// `TextClient` over what the text service sent of the field (`TextContext`): the session's
/// questions are answered from it, and each edit is applied to it, so later questions in the same
/// key see the edit, and recorded for the text service to make in the app.
///
/// Each recorded edit names the range it replaces, resolved here (the composition joins a range
/// given for marked text, as in a Mac text field), so the text service only replaces ranges.
public final class SnapshotClient: TextClient {
    /// The known part of the field, from `start`.
    private var units: [UInt16]
    private var start: Int
    private var marked: NSRange
    private var selection: NSRange
    private let readable: Bool
    public let marksAnywhere: Bool
    public let marksFromCaret: Bool
    public private(set) var ops: [EditOp] = []

    private static let none = NSRange(location: NSNotFound, length: 0)

    /// Copies the field snapshot, honoring its readability and caret-only composition flags.
    /// A nil context, a selection without exactly two elements, or a negative location creates a
    /// detached client; a negative selection length is treated as zero.
    public init(_ context: TextContext?) {
        guard let context, context.selection.count == 2, context.selection[0] >= 0 else {
            units = []
            start = 0
            marked = Self.none
            selection = Self.none
            readable = false
            marksAnywhere = false
            marksFromCaret = false
            return
        }
        units = Array(context.text.utf16)
        start = context.start
        selection = NSRange(location: context.selection[0], length: max(0, context.selection[1]))
        if let m = context.marked, m.count == 2, m[0] >= 0, m[1] > 0 {
            marked = NSRange(location: m[0], length: m[1])
        } else {
            marked = Self.none
        }
        readable = !(context.unreadable ?? false)
        marksAnywhere = !(context.marksAtCaret ?? false)
        marksFromCaret = context.marksFromCaret ?? false
    }

    /// No field at all (a commit after the app took the composition away): edits are recorded
    /// with no range, and questions answered as a field that says nothing.
    public static func detached() -> SnapshotClient { SnapshotClient(nil) }

    private var knowsPositions: Bool { selection.location != NSNotFound }

    // MARK: TextClient

    public func setMarkedText(_ text: String) {
        let target = marked.location != NSNotFound ? marked : selection
        mark(text, target, clause: nil)
    }

    public func setMarkedText(_ text: String, replacing range: NSRange) {
        let target = marked.location != NSNotFound ? NSUnionRange(range, marked) : range
        mark(text, target, clause: nil)
    }

    public func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?) {
        let target: NSRange
        if let range {
            target = marked.location != NSNotFound ? NSUnionRange(range, marked) : range
        } else {
            target = marked.location != NSNotFound ? marked : selection
        }
        mark(text, target, clause: selectedClause)
    }

    public func insertText(_ text: String, replacing range: NSRange?) {
        let target = range ?? (marked.location != NSNotFound ? marked : selection)
        let resolved = replace(target, with: text)
        marked = Self.none
        if knowsPositions, resolved { selection = NSRange(location: target.location + utf16Count(text), length: 0) }
        ops.append(EditOp(kind: .insert, text: text, replace: resolved ? [target.location, target.length] : nil))
    }

    public func selectedRange() -> NSRange { selection }
    public func markedRange() -> NSRange { marked }

    public func text(in range: NSRange) -> String? {
        guard readable, range.location != NSNotFound, range.location >= start,
              NSMaxRange(range) <= start + units.count else { return nil }
        let slice = Array(units[(range.location - start)..<(NSMaxRange(range) - start)])
        return String(decoding: slice, as: UTF16.self)
    }

    /// Puts `text` in place of what the last edit inserted (a text replacement's phrase for its
    /// shortcut), in the copy and in the recorded edit.
    func replaceLastInsert(with text: String) {
        guard let last = ops.last, last.kind == .insert else { return }
        ops[ops.count - 1].text = text
        guard let range = last.replace else { return }
        let inserted = NSRange(location: range[0], length: utf16Count(last.text))
        if replace(inserted, with: text) { selection = NSRange(location: range[0] + utf16Count(text), length: 0) }
    }

    // MARK: Applying

    private func mark(_ text: String, _ target: NSRange, clause: NSRange?) {
        let resolved = replace(target, with: text)
        let length = utf16Count(text)
        if knowsPositions, resolved {
            marked = length > 0 ? NSRange(location: target.location, length: length) : Self.none
            selection = NSRange(location: target.location + length, length: 0)
        }
        ops.append(EditOp(kind: .mark, text: text, replace: resolved ? [target.location, target.length] : nil,
                          clause: clause.map { [$0.location, $0.length] }))
    }

    /// Replaces `range` in the copy; false when the range isn't a place in it (positions unknown).
    @discardableResult
    private func replace(_ range: NSRange, with text: String) -> Bool {
        guard knowsPositions, range.location != NSNotFound else { return false }
        let new = Array(text.utf16)
        let lower = range.location - start, upper = NSMaxRange(range) - start
        if lower >= 0, upper <= units.count, lower <= upper {
            units.replaceSubrange(lower..<upper, with: new)
        } else if lower > units.count {
            // Past what was sent (it never is): what lies between isn't known, so start afresh there.
            units = new
            start = range.location
        } else {
            // Starts before what was sent: what was sent from the range on is replaced.
            let cut = max(0, min(units.count, upper))
            units = new + units[cut...]
            start = range.location
        }
        return true
    }

    private func utf16Count(_ text: String) -> Int { text.utf16.count }
}
