import SeamtypeCore
import Carbon
import Cocoa
import InputMethodKit
import os

private let log = Logger(subsystem: "com.aimdevlee.inputmethod.Seamtype", category: "input")

/// The candidate window shared by all controllers (one is visible at a time).
@MainActor var candidatesWindow: IMKCandidates?
/// What the candidate window was last given: its list and the line it highlights.
@MainActor private var candidatesShown: (texts: [String], selected: Int)?

/// Adapts InputMethodKit to `InputSession`, which holds all the typing logic.
@objc(SeamtypeInputController)
final class InputController: IMKInputController {
    private var current: (session: InputSession, generation: Int)?
    /// When the pause key (a right modifier, `Settings.pauseKey`) went down, while no other key
    /// has been pressed with it: a tap pauses.
    private var pauseTapDown: Date?
    /// Which switch key (right ⌥ or right ⇧, in `AppPolicy.switchKeys`) went down and when,
    /// while no other key has been pressed with it: a tap switches the word's language.
    private var switchTapDown: (key: UInt16, at: Date)?

    /// This client's session, rebuilt (after committing what was being typed) when a setting changed.
    @MainActor private var session: InputSession {
        let runtime = Runtime.shared
        if let current, current.generation == runtime.generation { return current.session }
        let fresh = runtime.makeSession()
        if let old = current?.session {
            old.commit(client: client().map { IMKClient($0 as IMKTextInput) })
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

    /// Vim changed mode (`Seamtype --vim`). Taken only when vim runs in this controller's app,
    /// so a signal that arrives while focus moves between apps changes nothing elsewhere; a
    /// signal without its app is taken where Esc goes to the app (isn't a switch key).
    @MainActor func vimChanged(to signal: VimSignal, from app: String?) {
        let session = session
        guard app.map({ $0 == session.app }) ?? !session.policy.switchKeys.contains(.escape) else { return }
        session.vimChanged(to: signal, client: client().map { IMKClient($0 as IMKTextInput) })
        log.debug("vim \(signal.rawValue, privacy: .public)")
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            session.commit(client: textInput(sender).map(IMKClient.init))
            candidatesWindow?.hide()
            Runtime.shared.converter?.save()
        }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            session.commitForNewContext(client: textInput(sender).map(IMKClient.init))
            candidatesWindow?.hide()
        }
    }

    /// The client to insert into: the sender, or this controller's own client when IMK passes
    /// none (so text being composed is never dropped on a focus change).
    private func textInput(_ sender: Any?) -> IMKTextInput? {
        (sender as? IMKTextInput) ?? client()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if let event, event.type == .flagsChanged {
            // Which modifier key and which modifiers are down: no typed text.
            log.debug("flagsChanged key=\(event.keyCode) flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, format: .hex) client=\(sender is IMKTextInput)")
        }
        guard let event, let input = sender as? IMKTextInput else { return false }
        if event.type == .flagsChanged {
            MainActor.assumeIsolated {
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
            log.debug("handle password prompt passed app=\(input.bundleIdentifier() ?? "?", privacy: .public)")
            return false
        }
        return MainActor.assumeIsolated {
            if case .shortcut(let shortcut) = Runtime.shared.settings.pauseKey,
               shortcut.matches(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags)) {
                togglePause(client: input)
                return true
            }
            let key = key(for: event)
            let handled = session.handle(key, client: IMKClient(input))
            syncCandidates()
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
    /// or resume Seamtype in this text field. The app still gets the modifier's events, as a lone
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
        let handled = session.handle(.cycle, client: IMKClient(client))
        syncCandidates()
        log.debug("handle switchTap handled=\(handled) app=\(self.session.app ?? "?", privacy: .public)")
    }

    /// Pauses or resumes this text field, and says so under the caret.
    @MainActor private func togglePause(client: IMKTextInput?) {
        session.togglePause(client: client.map(IMKClient.init))
        PauseHUD.show(paused: session.paused, caret: client.map(caretRect) ?? .zero)
        log.info("paused=\(self.session.paused) app=\(self.session.app ?? "?", privacy: .public)")
    }

    /// The caret's line in screen coordinates, or `.zero` when the app doesn't say.
    private func caretRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

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
        case KeyCode.left: return .left
        case KeyCode.right: return .right
        case KeyCode.down: return .down
        case KeyCode.up: return .up
        default: break
        }
        guard let chars = event.characters, chars.unicodeScalars.count == 1,
              let ch = chars.first, let value = chars.unicodeScalars.first?.value else { return .other }
        if ch.isASCII && ch.isLetter { return .letter(ch) }
        if ch == " ", event.modifierFlags.contains(.shift) { return .shiftSpace }
        if (0x20..<0x7F).contains(value) { return .printable(ch) }
        return .other
    }

    // MARK: - Candidate window

    @MainActor private func syncCandidates() {
        guard let conversion = session.conversion else {
            candidatesWindow?.hide()
            return
        }
        if candidatesWindow == nil {
            candidatesWindow = IMKCandidates(server: server(), panelType: kIMKSingleColumnScrollingCandidatePanel)
        }
        guard let window = candidatesWindow else { return }
        // The highlight is moved a line at a time: candidateIdentifier(atLineNumber:) returns 0
        // for every line (macOS 27), so selectCandidate(withIdentifier:) never moved it.
        let texts = conversion.candidates.map(\.text)
        var line = 0
        if let shown = candidatesShown, shown.texts == texts, window.isVisible() {
            line = shown.selected
        } else {
            // A new list in the open window (a first clause made shorter): the panel kept its
            // height with the rows gone, so it is hidden first and sized afresh.
            if window.isVisible() { window.hide() }
            window.update() // reloads the list and highlights the first line
            window.show(kIMKLocateCandidatesBelowHint)
        }
        for _ in line..<max(line, conversion.selected) { window.moveDown(nil) }
        for _ in conversion.selected..<max(conversion.selected, line) { window.moveUp(nil) }
        candidatesShown = (texts, conversion.selected)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated { session.conversion?.candidates.map(\.text) ?? [] }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        MainActor.assumeIsolated {
            guard let conversion = session.conversion, let text = candidateString?.string,
                  let index = conversion.candidates.firstIndex(where: { $0.text == text }),
                  let input: IMKTextInput = client() else { return }
            session.choose(index, client: IMKClient(input))
            syncCandidates()
        }
    }

    // MARK: - Input menu

    /// Seamtype's part of the input menu, built each time it opens.
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
                if listed {
                    add(L("Use Default Settings in This App"), #selector(removeAppEntry(_:)), indent: 1, value: app)
                }
                menu.addItem(.separator())
            }

            add(L("Japanese Input"), #selector(toggleJapanese(_:)), on: runtime.settings.japanese)
            add(L("Live Conversion"), #selector(toggleLiveConversion(_:)), on: runtime.settings.liveConversion,
                enabled: runtime.settings.japanese, indent: 1)

            menu.addItem(.separator())
            if let keys = runtime.engine.lastLearned {
                add(L("Undo Last Learned (%@)", keys), #selector(undoLastLearned(_:)))
            }
            Updater.shared.refresh()
            if let release = Updater.shared.available {
                add(L("Update to Seamtype %@…", release.version), #selector(openUpdate(_:)))
            }
            add(L("Try Typing…"), #selector(openTyping(_:)))
            add(L("Dictionary…"), #selector(openLearned(_:)))
            add(L("Seamtype Settings…"), #selector(openSettings(_:)))
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
    private static let noRange = NSRange(location: NSNotFound, length: 0)

    init(_ input: IMKTextInput) { self.input = input }

    func setMarkedText(_ text: String) {
        let length = (text as NSString).length
        input.setMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: Self.noRange)
    }

    func setMarkedText(_ text: String, replacing range: NSRange) {
        let length = (text as NSString).length
        input.setMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: range)
    }

    func insertText(_ text: String, replacing range: NSRange?) {
        input.insertText(text, replacementRange: range ?? Self.noRange)
    }

    func selectedRange() -> NSRange { input.selectedRange() }
    func markedRange() -> NSRange { input.markedRange() }

    func text(in range: NSRange) -> String? {
        input.attributedSubstring(from: range)?.string
    }
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
