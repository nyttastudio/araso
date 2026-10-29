import ArasoCore
import Carbon
import Cocoa
import InputMethodKit
import os

private let log = Logger(subsystem: "com.nyttastudio.inputmethod.Araso", category: "input")

/// Adapts InputMethodKit to `InputSession`, which holds all the typing logic.
@objc(ArasoInputController)
final class InputController: IMKInputController {
    private var current: (session: InputSession, generation: Int)?
    /// When the pause key (a right modifier, `Settings.pauseKey`) went down, while no other key
    /// has been pressed with it: a tap pauses.
    private var pauseTapDown: Date?
    /// Which switch key (right ⌥ or right ⇧, in `AppPolicy.switchKeys`) went down and when,
    /// while no other key has been pressed with it: a tap switches the word's language.
    private var switchTapDown: (key: UInt16, at: Date)?
    /// A terminal was waiting for a password at the last key (`PasswordPrompt`): its keys went to
    /// the app as typed, and what was being typed went in before the first of them.
    private var passingPassword = false
    /// The underlined word's place on screen, as last asked while it was still underlined: where
    /// a learned word's mark goes once the word went in (apps place the caret unreliably then;
    /// TextEdit answered with the same column two lines up).
    private var wordRect: NSRect?
    /// The font the app reported for that word, to measure where a word just committed ends.
    private var wordFont: NSFont?

    /// This client's session, rebuilt (after committing what was being typed) when a setting changed.
    @MainActor private var session: InputSession {
        let runtime = Runtime.shared
        if let current, current.generation == runtime.generation { return current.session }
        let fresh = runtime.makeSession()
        if let old = current?.session {
            old.commit(client: client().map { old.cased(IMKClient($0 as IMKTextInput, marks: self)) })
            old.saveConverter(unless: runtime.converter, discarded: runtime.discardedConverters)
            fresh.activate(app: old.app)
        }
        current = (fresh, runtime.generation)
        return fresh
    }

    private enum KeyCode {
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let f6: UInt16 = 97
        static let f7: UInt16 = 98
        static let rightOption: UInt16 = 61
        static let leftCommand: UInt16 = 55
        static let rightCommand: UInt16 = 54
        static let rightShift: UInt16 = 60
        static let space: UInt16 = 49
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        let client = sender as? IMKTextInput
        client?.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.US")
        let app = client?.bundleIdentifier()
        MainActor.assumeIsolated {
            Runtime.shared.active = self
            session.activate(app: app)
            session.replacements = Runtime.shared.textReplacements
            if let last = Runtime.shared.lastVim { vimChanged(to: last.signal, from: last.app) }
            let policy = session.policy
            log.info("activate \(app ?? "?", privacy: .public) enabled=\(policy.enabled) threshold=\(policy.conversionThreshold) switchKeys=\(SwitchKey.allCases.filter(policy.switchKeys.contains).map(\.rawValue).joined(separator: ","), privacy: .public) holdSpace=\(policy.holdSpace) replacements=\(self.session.replacements.count)")
        }
    }

    /// Vim changed mode (`Araso --vim`). Taken only when vim runs in this controller's app,
    /// so a signal that arrives while focus moves between apps changes nothing elsewhere; a
    /// signal without its app is taken where Esc goes to the app (isn't a switch key).
    @MainActor func vimChanged(to signal: VimSignal, from app: String?) {
        let session = session
        guard app.map({ $0 == session.app }) ?? !session.policy.switchKeys.contains(.escape) else { return }
        session.vimChanged(to: signal, client: client().map { textClient($0 as IMKTextInput) })
        log.debug("vim \(signal.rawValue, privacy: .public)")
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            session.commit(client: textInput(sender).map(textClient))
            StripHUD.hide(force: true)
            Runtime.shared.converter?.save()
        }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            session.commitForNewContext(client: textInput(sender).map(textClient))
            StripHUD.hide(force: true)
        }
    }

    /// The client to insert into: the sender, or this controller's own client when IMK passes
    /// none (so text being composed is never dropped on a focus change).
    private func textInput(_ sender: Any?) -> IMKTextInput? {
        (sender as? IMKTextInput) ?? client()
    }

    /// The session's view of a client; this controller gives it the system's clause underlines.
    /// The field as the session writes to it: through `cased`, so a word typed with Caps Lock
    /// goes in in capitals wherever the session is handed the field.
    @MainActor private func textClient(_ input: IMKTextInput) -> TextClient { session.cased(IMKClient(input, marks: self)) }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    /// Routes key and modifier events to the session and updates the reading strip. Returns true
    /// for a consumed key; modifier events and keys in masked fields remain available to the app.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if let event, event.type == .flagsChanged {
            // Which modifier key and which modifiers are down: no typed text.
            log.debug("flagsChanged key=\(event.keyCode) flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, format: .hex) client=\(sender is IMKTextInput)")
        }
        guard let event, let input = sender as? IMKTextInput else { return false }
        if event.type == .flagsChanged {
            MainActor.assumeIsolated {
                // ⌘ going down: the word being typed goes in before the shortcut, since an app may
                // act on the shortcut without showing it to the input method (Ghostty pastes on ⌘V
                // and deletes on ⌘⌫ itself).
                if event.keyCode == KeyCode.leftCommand || event.keyCode == KeyCode.rightCommand,
                   event.modifierFlags.contains(.command) {
                    if session.commandPressed(client: textClient(input), heldWordOnly: false) {
                        syncStrip(input) // a conversion's candidates went in with it: the strip goes too
                    }
                }
                pauseTapChanged(event, client: input)
                switchTapChanged(event, client: input)
            }
            return false
        }
        guard event.type == .keyDown else {
            log.debug("handle: not a key event from a text client")
            return false
        }
        pauseTapDown = nil // a modifier with a key is a shortcut, not a tap
        switchTapDown = nil // ⌥ or ⇧ with a key types a character, not a tap
        if maskedField(input) {
            // A masked password field: the keys go to the app as typed, as when paused.
            log.debug("handle masked passed app=\(input.bundleIdentifier() ?? "?", privacy: .public)")
            return false
        }
        if PasswordPrompt.isWaiting() {
            // A terminal waiting for a password (`PasswordPrompt`): the keys go to the app as typed.
            if !passingPassword {
                passingPassword = true
                log.info("password prompt: keys pass as typed app=\(input.bundleIdentifier() ?? "?", privacy: .public)")
                MainActor.assumeIsolated {
                    // The prompt can start while a word is composing (another tab's sudo): it goes
                    // in first, as when pausing, or the app's own insert replaces it. The word
                    // just committed can't be switched past the keys after it either, and what
                    // comes after the prompt starts a new context (the session doesn't see them).
                    let client = textClient(input)
                    if !session.commandPressed(client: client, heldWordOnly: false) { session.commitForNewContext(client: client) }
                    StripHUD.hide(force: true)
                }
            }
            log.debug("handle password prompt passed app=\(input.bundleIdentifier() ?? "?", privacy: .public)")
            return false
        }
        if passingPassword {
            passingPassword = false
            log.info("password prompt ended app=\(input.bundleIdentifier() ?? "?", privacy: .public)")
        }
        return MainActor.assumeIsolated {
            if case .shortcut(let shortcut) = Runtime.shared.settings.pauseKey,
               shortcut.matches(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags)) {
                togglePause(client: input)
                return true
            }
            let key = key(for: event)
            noteWordRect(input)
            // The raw field: this `handle` notes Caps Lock for the word first, then applies `cased`.
            let handled = session.handle(key, client: IMKClient(input, marks: self), capsLock: event.modifierFlags.contains(.capsLock))
            if let dropped = session.fixingDropped {
                session.fixingDropped = nil
                // Positions only, never text.
                log.notice("fix dropped: marked \(NSStringFromRange(dropped.marked), privacy: .public) wanted \(NSStringFromRange(dropped.wanted), privacy: .public) app=\(self.session.app ?? "?", privacy: .public)")
            }
            syncStrip(input)
            if !handled, key != .shiftLeft, key != .shiftRight, [KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down].contains(event.keyCode) {
                // The app moves the caret after this returns: then a word Araso wasn't sure of, if
                // the caret is on one, lists its readings under it (`caretMoved`).
                DispatchQueue.main.async { [weak self] in
                    guard let self, let word = self.session.caretMoved(client: self.textClient(input)) else { return }
                    self.wordRect = self.placeOf(word, in: input)
                    self.syncStrip(input)
                }
            }
            // The settings window's typing test shows how each word was decided; only there.
            if session.app == Bundle.main.bundleIdentifier, let trace = session.lastTrace {
                TypingTrace(trace).post()
            }
            // The kind of key only, never which character: typed text stays out of the log.
            log.debug("handle \(String(describing: key).prefix(while: { $0 != "(" }), privacy: .public) handled=\(handled) app=\(self.session.app ?? "?", privacy: .public)")
            return handled
        }
    }

    /// A masked password field has the focus (`MaskedField`). The system is asked only while
    /// Secure Event Input is on.
    private func maskedField(_ client: IMKTextInput) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        let owner = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? NSNumber
        return MaskedField.passesKeys(secureInput: true, owner: owner?.int32Value,
                                      frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                      caret: client.selectedRange())
    }

    /// The pause key, a right modifier, pressed and released on its own within a moment: pause
    /// or resume Araso in this text field. The app still gets the modifier's events, as a lone
    /// modifier does nothing.
    @MainActor private func pauseTapChanged(_ event: NSEvent, client: IMKTextInput) {
        guard case .tap(let tap) = Runtime.shared.settings.pauseKey else { return }
        guard event.keyCode == tap.keyCode else {
            pauseTapDown = nil // another modifier joined in
            return
        }
        let flag = NSEvent.ModifierFlags(tap)
        if event.modifierFlags.contains(flag) {
            // Only on its own, as for a switch key: a Hyper key's tap is bound to something else.
            let others = event.modifierFlags.intersection([.command, .control, .option, .shift]).subtracting(flag)
            pauseTapDown = others.isEmpty ? Date() : nil
            return
        }
        guard let down = pauseTapDown, Date().timeIntervalSince(down) < 0.5 else { return }
        pauseTapDown = nil
        togglePause(client: client)
    }

    /// A switch key (right ⌥ or right ⇧) pressed and released on its own, within a moment:
    /// switch the word being typed, or the one just committed, to its next reading (as Esc
    /// does). The app still gets the modifier's events, and a lone modifier does nothing there,
    /// so nothing leaks the way an Esc can (Chromium apps see an Esc the input method took and
    /// close their window).
    @MainActor private func switchTapChanged(_ event: NSEvent, client: IMKTextInput) {
        let flag: NSEvent.ModifierFlags
        if case .tap(let tap) = Runtime.shared.settings.pauseKey, tap.keyCode == event.keyCode {
            switchTapDown = nil // the pause key wins where an app chose the same key
            return
        }
        switch event.keyCode {
        case KeyCode.rightOption where session.policy.switchKeys.contains(.rightOption): flag = .option
        case KeyCode.rightShift where session.policy.switchKeys.contains(.rightShift): flag = .shift
        default:
            switchTapDown = nil // another modifier joined in, or one that isn't a switch key here
            return
        }
        if event.modifierFlags.contains(flag) {
            // Only on its own: a key remapped as a Hyper key (Karabiner) reports ⌃⌥⇧⌘ at once,
            // and its tap belongs to whatever the user bound it to.
            let others = event.modifierFlags.intersection([.command, .control, .option, .shift]).subtracting(flag)
            switchTapDown = others.isEmpty ? (event.keyCode, Date()) : nil
            return
        }
        guard let down = switchTapDown, down.key == event.keyCode,
              Date().timeIntervalSince(down.at) < 0.5 else { return }
        switchTapDown = nil
        guard !session.inVimNormalMode else { return } // vim's own keys
        // While a terminal waits for a password, the keys pass as typed: a tap before the first of
        // them would change the word, or the one just committed, in front of the prompt.
        guard !PasswordPrompt.isWaiting() else { return }
        noteWordRect(client)
        let handled = session.handle(.cycle, client: textClient(client))
        syncStrip(client)
        log.debug("handle switchTap handled=\(handled) app=\(self.session.app ?? "?", privacy: .public)")
    }

    /// The strip under the word: the candidates while a clause is converted, else the readings a
    /// switch key just went through, put away on any other key unless it made a correction stick:
    /// then the strip says so for a moment. One panel shows them all, so this is the one place
    /// that decides which.
    @MainActor private func syncStrip(_ client: IMKTextInput) {
        if let conversion = session.conversion {
            StripHUD.show(conversion, clause: caretRect(client)) { [weak self] index in
                guard let self, let input: IMKTextInput = self.client() else { return }
                self.session.choose(index, client: self.textClient(input))
                self.syncStrip(input)
            }
        } else if let readings = session.readings {
            let marked = client.markedRange()
            let typing = marked.location != NSNotFound && marked.length > 0
            StripHUD.show(readings, word: typing ? caretRect(client) : wordRect ?? caretRect(client)) { [weak self] language in
                self?.pick(language)
            }
        } else if let learned = session.learned {
            StripHUD.settle(learned, word: learnedRect(learned) ?? caretRect(client))
        } else {
            StripHUD.hide()
        }
    }

    /// A reading clicked in the strip: switched to as the switch key would, a press at a time,
    /// once round the readings at most (they can change as the word does).
    @MainActor private func pick(_ language: Language) {
        guard let input: IMKTextInput = client() else { return }
        for _ in 0..<4 {
            guard let readings = session.readings, readings.languages[readings.selected] != language else { break }
            noteWordRect(input)
            _ = session.handle(.cycle, client: textClient(input))
        }
        syncStrip(input)
    }

    /// Asks where the word being typed is while it is underlined; kept from before a key that
    /// commits it, for the mark that may follow.
    /// The start is the marked text's index 0, through `attributes(forCharacterIndex:)`, the call
    /// the readings list is placed by: `firstRect(forCharacterRange:)` came back as garbage
    /// (1.6e-314) through IMK. TextEdit answers a zero rect for the index just past the word, so
    /// the end is its last letter's place plus one letter's average width.
    @MainActor private func noteWordRect(_ client: IMKTextInput) {
        let marked = client.markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        var start = NSRect.zero, end = NSRect.zero, last = NSRect.zero
        let attributes = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &start)
        guard Self.plausible(start) else { return }
        wordFont = (attributes?[NSAttributedString.Key.font] ?? attributes?[NSAttributedString.Key.font.rawValue]) as? NSFont
        _ = client.attributes(forCharacterIndex: marked.length, lineHeightRectangle: &end)
        if marked.length > 1 { _ = client.attributes(forCharacterIndex: marked.length - 1, lineHeightRectangle: &last) }
        // Positions only, never text.
        log.debug("word start \(start.debugDescription, privacy: .public) last \(last.debugDescription, privacy: .public) end \(end.debugDescription, privacy: .public)")
        func onLine(_ rect: NSRect) -> Bool { Self.plausible(rect) && rect.minX > start.minX && abs(rect.midY - start.midY) < 1 }
        let endX: CGFloat
        if onLine(end) {
            endX = end.minX
        } else if onLine(last) {
            endX = last.minX + (last.minX - start.minX) / CGFloat(marked.length - 1)
        } else {
            endX = start.minX + CGFloat(marked.length) * start.height * 0.55 // about a letter's width
        }
        wordRect = NSRect(x: start.minX, y: start.minY, width: endX - start.minX, height: start.height)
    }

    /// Where a word of the field is on screen while nothing is marked, for the list under it.
    /// `attributes(forCharacterIndex:)` answers only for index 0 then (the start of the text), so
    /// this is `firstRect`'s.
    @MainActor private func placeOf(_ word: NSRange, in client: IMKTextInput) -> NSRect? {
        let rect = Self.firstRect(word, in: client)
        // Positions only, never text.
        log.debug("hint word \(rect.debugDescription, privacy: .public)")
        return Self.plausible(rect) ? rect : nil
    }

    /// `firstRect(forCharacterRange:)` as a line-height rect, its origin at the line's bottom: through
    /// IMK it comes with the origin at the top (TextEdit and Notes, for the same marked text as
    /// `attributes(forCharacterIndex:)`'s, 2026-10-29), which put the list over the line itself.
    static func firstRect(_ range: NSRange, in client: IMKTextInput) -> NSRect {
        var actual = NSRange(location: NSNotFound, length: 0)
        var rect = client.firstRect(forCharacterRange: range, actualRange: &actual)
        rect.origin.y -= rect.height
        return rect
    }

    /// The committed word's place for the line under it: from where it started to just before the
    /// caret after it, its own width in the app's font. The end the app reports while it was typed
    /// is only an estimate (TextEdit gives none), and ran past the word into the caret. The
    /// estimate stays when the font is unknown or the measure is far off (a zoomed text view).
    @MainActor private func learnedRect(_ learned: InputSession.Learned) -> NSRect? {
        guard var rect = wordRect else { return nil }
        if let font = wordFont {
            let measured = ceil((learned.text as NSString).size(withAttributes: [.font: font]).width)
            if measured > 0, (rect.width * 0.5...rect.width * 1.5).contains(measured) { rect.size.width = measured }
        }
        return rect
    }

    /// A rect a text client gave that can be a place on screen: finite, line-sized, on a screen.
    static func plausible(_ rect: NSRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, (4...400).contains(rect.height),
              rect.width >= 0, rect.width < 10_000 else { return false }
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(rect.origin) }
    }

    /// Pauses or resumes this text field, and says so under the caret.
    @MainActor private func togglePause(client: IMKTextInput?) {
        session.togglePause(client: client.map(textClient))
        StripHUD.hide(force: true)
        PauseHUD.show(paused: session.paused, caret: client.map(caretRect) ?? .zero)
        log.info("paused=\(self.session.paused) app=\(self.session.app ?? "?", privacy: .public)")
    }

    /// The caret's line in screen coordinates, or `.zero` when the app doesn't say: where the
    /// underlined word starts while one is being typed, else the caret itself. Index 0 is the
    /// marked text's first letter only while there is marked text; after a commit it is the
    /// start of the text (a word's mark landed at the start of the line).
    private func caretRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        let selected = client.selectedRange(), marked = client.markedRange()
        // No marked text is NSNotFound in some apps and an empty range in others (TextEdit).
        if marked.location == NSNotFound || marked.length == 0, selected.location != NSNotFound {
            rect = Self.firstRect(NSRange(location: selected.location, length: 0), in: client)
            if Self.plausible(rect) { return rect }
        }
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    /// Maps a key-down event to a session key, preserving shifted arrows and configured switch
    /// keys. Letters use the chosen layout and Shift alone; other shortcuts become `.other`.
    @MainActor private func key(for event: NSEvent) -> InputSession.Key {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers == .option, !event.modifierFlags.contains(.shift), event.keyCode == KeyCode.space,
           session.policy.switchKeys.contains(.optionSpace) {
            return .cycle // ⌥Space chosen as a switch key
        }
        if modifiers == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": return .katakana
            case "j": return .hiragana
            default: return .other
            }
        }
        if !modifiers.isEmpty { return .other }
        if event.keyCode == KeyCode.escape, event.modifierFlags.contains(.shift) {
            // Not chosen: the app's ⇧Esc, after the word goes in as shown.
            return session.policy.switchKeys.contains(.shiftEscape) ? .cycle : .other
        }
        switch event.keyCode {
        case KeyCode.f7: return .katakana
        case KeyCode.f6: return .hiragana
        case KeyCode.delete: return .delete
        case KeyCode.escape: return .escape
        case KeyCode.returnKey, KeyCode.keypadEnter: return .enter
        case KeyCode.left: return event.modifierFlags.contains(.shift) ? .shiftLeft : .left
        case KeyCode.right: return event.modifierFlags.contains(.shift) ? .shiftRight : .right
        case KeyCode.down: return .down
        case KeyCode.up: return .up
        default: break
        }
        // On another English layout the letter comes from the key, not from whatever layout macOS
        // hands the input method: the setting decides. Colemak's ; (on the p key, 2-set's ㅔ) is
        // part of a word too, as is any key romaji's layout has a letter on.
        let layout = LatinLayout.current
        // Caps Lock is left out: the session reads letters as Shift alone types them (`capsLock:`).
        if layout != .qwerty || LatinLayout.romaji != .qwerty, let ch = layout.character(keyCode: event.keyCode,
                                                        shift: event.modifierFlags.contains(.shift),
                                                        capsLock: false),
           ch.isLetter || layout.isLetterSeat(ch) {
            return .letter(ch)
        }
        guard let chars = event.characters, chars.unicodeScalars.count == 1,
              let ch = chars.first, let value = chars.unicodeScalars.first?.value else { return .other }
        if ch.isASCII && ch.isLetter {
            // With Caps Lock on, macOS types capitals, Shift or not: the letter Shift alone gives.
            guard event.modifierFlags.contains(.capsLock) else { return .letter(ch) }
            return .letter(Character(event.modifierFlags.contains(.shift) ? ch.uppercased() : ch.lowercased()))
        }
        if ch == " ", event.modifierFlags.contains(.shift) { return .shiftSpace }
        if (0x20..<0x7F).contains(value) { return .printable(ch) }
        return .other
    }

    // MARK: - Input menu

    /// Araso's part of the input menu, built each time it opens.
    override func menu() -> NSMenu! {
        nonisolated(unsafe) var built: NSMenu?
        MainActor.assumeIsolated { built = buildMenu() }
        return built
    }

    @MainActor private func buildMenu() -> NSMenu {
        do {
            let runtime = Runtime.shared
            let menu = NSMenu()
            /// `enabled: false` leaves the action out: the input menu shows a copy of these items and
            /// enables every one with an action, so only an item without one comes out greyed.
            func add(_ title: String, _ action: Selector?, on: Bool = false, enabled: Bool = true,
                     indent: Int = 0, value: Any? = nil) {
                // The input menu ignores indentationLevel, so the levels are em spaces in the title.
                let item = NSMenuItem(title: String(repeating: "\u{2003}", count: indent) + title,
                                      action: enabled ? action : nil, keyEquivalent: "")
                item.target = self
                item.state = on ? .on : .off
                item.isEnabled = enabled && action != nil
                item.representedObject = value
                menu.addItem(item)
            }
            // A temporary state of this text field first, then the app's saved settings: word
            // conversion and, under it, what only matters while it is on. The names are the
            // settings window's, so a choice reads the same in both.
            add(runtime.settings.pauseKey == .off ? L("Pause in This Text Field")
                    : L("Pause in This Text Field (%@)", runtime.settings.pauseKey.label),
                // A session from before a settings change is replaced, unpaused, on the next key.
                #selector(togglePause(_:)), on: current.map { $0.generation == runtime.generation && $0.session.paused } ?? false)
            menu.addItem(.separator())
            if let app = current?.session.app ?? client()?.bundleIdentifier() {
                let policies = AppPolicies.load()
                let policy = policies.policy(for: app)
                let listed = policies.overrides[app] != nil
                add(listed ? L("%@ — App Settings", AppName.of(app)) : L("%@ — Default Settings", AppName.of(app)), nil)
                add(L("Convert Words"), #selector(toggleDisabled(_:)), on: policy.enabled, indent: 1, value: app)
                // Greyed while words aren't converted: they only matter while they are.
                add(L("Conversion: Normal"), #selector(setNormal(_:)),
                    on: policy.conversionThreshold < AppPolicy.strictThreshold, enabled: policy.enabled, indent: 2, value: app)
                add(L("Conversion: Strict"), #selector(setStrict(_:)),
                    on: policy.conversionThreshold >= AppPolicy.strictThreshold, enabled: policy.enabled, indent: 2, value: app)
                add(L("Esc Switches Language"), #selector(toggleEscapeSwitches(_:)), on: policy.switchKeys.contains(.escape),
                    enabled: policy.enabled, indent: 2, value: app)
                add(L("Hold the Word After Space or Punctuation"), #selector(toggleHoldSpace(_:)), on: policy.holdSpace,
                    enabled: policy.enabled, indent: 2, value: app)
                // On or off here whatever the Languages tab says; the item under them is that tab's.
                add(L("Japanese Input in This App"), #selector(toggleAppJapanese(_:)),
                    on: policy.japanese(default: runtime.settings.japanese), enabled: policy.enabled, indent: 2, value: app)
                if listed {
                    add(L("Use Default Settings in This App"), #selector(removeAppEntry(_:)), indent: 1, value: app)
                }
                menu.addItem(.separator())
            }

            add(L("Japanese Input"), #selector(toggleJapanese(_:)), on: runtime.settings.japanese)
            add(L("Live Conversion"), #selector(toggleLiveConversion(_:)), on: runtime.settings.liveConversion,
                enabled: runtime.japaneseLoaded, indent: 1) // also where only an app has Japanese on

            menu.addItem(.separator())
            if let keys = runtime.engine.lastLearned {
                add(L("Undo Last Learned (%@)", keys), #selector(undoLastLearned(_:)))
            }
            // What the dictionary decided lately, to tell whether a word went in because of it
            // and forget it on the spot.
            let applied = runtime.engine.recentlyApplied
            if !applied.isEmpty {
                add(L("Changed by the Dictionary"), nil)
                for word in applied {
                    add(L("%@ → %@ · Forget", word.text, word.language.displayName), #selector(forgetApplied(_:)),
                        indent: 1, value: word.keys)
                }
            }
            Updater.shared.refresh()
            if let release = Updater.shared.available {
                add(L("Update to Araso %@…", release.version), #selector(openUpdate(_:)))
            }
            add(L("Try Typing…"), #selector(openTyping(_:)))
            add(L("Dictionary…"), #selector(openLearned(_:)))
            add(L("Araso Settings…"), #selector(openSettings(_:)))
            return menu
        }
    }

    /// IMK hands menu actions a dictionary holding the item (or, on some versions, the item).
    private func menuItem(_ sender: Any?) -> NSMenuItem? {
        (sender as? [String: Any])?[kIMKCommandMenuItemName] as? NSMenuItem ?? sender as? NSMenuItem
    }

    private func appOf(_ sender: Any?) -> String? {
        if let app = menuItem(sender)?.representedObject as? String { return app }
        return MainActor.assumeIsolated { current?.session.app }
    }

    @objc func toggleJapanese(_ sender: Any?) {
        MainActor.assumeIsolated { Runtime.shared.update { $0.japanese.toggle() } }
    }

    @objc func toggleLiveConversion(_ sender: Any?) {
        MainActor.assumeIsolated { Runtime.shared.update { $0.liveConversion.toggle() } }
    }

    @objc func setStrict(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated { Runtime.shared.updatePolicy(for: app) { $0.conversionThreshold = AppPolicy.strictThreshold } }
    }

    @objc func setNormal(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated { Runtime.shared.updatePolicy(for: app) { $0.conversionThreshold = AppPolicy.standard.conversionThreshold } }
    }

    @objc func toggleEscapeSwitches(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated {
            Runtime.shared.updatePolicy(for: app) {
                if $0.switchKeys.remove(.escape) == nil { $0.switchKeys.insert(.escape) }
            }
        }
    }

    @objc func toggleHoldSpace(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated {
            Runtime.shared.updatePolicy(for: app) { $0.holdSpace.toggle() }
        }
    }

    @objc func toggleAppJapanese(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated {
            let japaneseOn = Runtime.shared.settings.japanese
            // Back to what the Languages tab says: the app follows it again.
            Runtime.shared.updatePolicy(for: app) { $0.japanese = $0.japanese(default: japaneseOn) == japaneseOn ? !japaneseOn : nil }
        }
    }

    @objc func togglePause(_ sender: Any?) {
        MainActor.assumeIsolated { togglePause(client: client() as IMKTextInput?) }
    }

    @objc func toggleDisabled(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated { Runtime.shared.updatePolicy(for: app) { $0.enabled.toggle() } }
    }

    @objc func removeAppEntry(_ sender: Any?) {
        guard let app = appOf(sender) else { return }
        MainActor.assumeIsolated { Runtime.shared.removePolicy(for: app) }
    }

    @objc func forgetApplied(_ sender: Any?) {
        guard let keys = menuItem(sender)?.representedObject as? String else { return }
        MainActor.assumeIsolated { Runtime.shared.forget(keys) }
    }

    @objc func undoLastLearned(_ sender: Any?) {
        MainActor.assumeIsolated { Runtime.shared.undoLastLearned() }
    }

    @objc func openLearned(_ sender: Any?) { SettingsLauncher.open(tab: .learning) }
    @objc func openTyping(_ sender: Any?) { SettingsLauncher.open(tab: .typing) }
    @objc func openSettings(_ sender: Any?) { SettingsLauncher.open(tab: .general) }
    @objc func openUpdate(_ sender: Any?) { SettingsLauncher.open(tab: .about) }
}

/// `TextClient` over the IMK client proxy.
private final class IMKClient: TextClient {
    private let input: IMKTextInput
    /// Where the system's marked-text styles come from (`mark(forStyle:at:)`).
    private weak var marks: IMKInputController?
    private static let noRange = NSRange(location: NSNotFound, length: 0)

    init(_ input: IMKTextInput, marks: IMKInputController) {
        self.input = input
        self.marks = marks
    }

    func setMarkedText(_ text: String) {
        let length = (text as NSString).length
        input.setMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: Self.noRange)
    }

    func setMarkedText(_ text: String, replacing range: NSRange) {
        let length = (text as NSString).length
        input.setMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: range)
    }

    /// The selected clause gets the system's selected-converted style (a thick underline) and the
    /// rest of the reading its converted style, each its own clause segment, so the app draws the
    /// boundary ←/→ moves as macOS's Japanese input does.
    func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?) {
        let marked = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: marked.length)
        let selected = NSIntersectionRange(selectedClause, whole)
        if let marks {
            func style(_ style: Int, _ range: NSRange, segment: Int) {
                guard range.length > 0 else { return }
                var attributes = (marks.mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any]) ?? [:]
                attributes[.markedClauseSegment] = segment
                marked.addAttributes(attributes, range: range)
            }
            style(kTSMHiliteConvertedText, whole, segment: 1)
            style(kTSMHiliteSelectedConvertedText, selected, segment: 0)
        }
        input.setMarkedText(marked, selectionRange: NSRange(location: whole.length, length: 0),
                            replacementRange: range ?? Self.noRange)
    }

    func insertText(_ text: String, replacing range: NSRange?) {
        input.insertText(text, replacementRange: range ?? Self.noRange)
    }

    func selectedRange() -> NSRange { input.selectedRange() }
    func markedRange() -> NSRange { input.markedRange() }

    func text(in range: NSRange) -> String? {
        input.attributedSubstring(from: range)?.string
    }

    /// The settings window's text view marked at the caret, not where the range named started.
    var marksFromCaret: Bool { true }
}

extension NSEvent.ModifierFlags {
    init(_ tap: PauseKey.Tap) {
        switch tap {
        case .rightCommand: self = .command
        case .rightOption: self = .option
        case .rightShift: self = .shift
        case .rightControl: self = .control
        }
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}
