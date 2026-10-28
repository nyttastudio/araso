import ArasoCore
import Cocoa
import SwiftUI

/// The user's dictionary (dictionary.json) as one list: words added here, words remembered
/// after two corrections, and words corrected once (which only lean that way, for a while).
struct DictionaryPane: View {
    @ObservedObject var model: SettingsModel
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var selection = Set<UserDictionary.Entry.ID>()
    @State private var editing: EntrySheet.Target?
    @State private var confirmForgetAll = false

    enum Filter: Hashable, CaseIterable {
        case all, added, remembered, once

        func includes(_ entry: UserDictionary.Entry) -> Bool {
            switch self {
            case .all: return true
            case .added: return entry.source == .user
            case .remembered: return entry.strength == .sure
            case .once: return entry.strength == .weak
            }
        }

        var title: String {
            switch self {
            case .all: return L("All %ld")
            case .added: return L("Added %ld")
            case .remembered: return L("Remembered %ld")
            case .once: return L("Corrected once %ld")
            }
        }

        /// What the entries under this filter are, under the filter.
        var explanation: String {
            switch self {
            case .all: return L("These keys come out as written here, also with a particle after them.")
            case .added: return L("Words you added here. They always come out this way.")
            case .remembered: return L("Words you switched the same way twice. They always come out this way.")
            case .once: return L("Words you switched once. They only lean that way, and are forgotten after 30 days unless you switch or type them again.")
            }
        }
    }

    private var shown: [UserDictionary.Entry] {
        model.entries.filter { entry in
            filter.includes(entry) && (search.isEmpty || entry.keys.localizedCaseInsensitiveContains(search)
                || EntryText.of(entry).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(tab: .learning)
            HStack(spacing: 12) {
                Picker(L("List"), selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { filter in
                        Text(String(format: filter.title, model.entries.filter(filter.includes).count)).tag(filter)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                // Narrow, and + alone: the filter's English titles take most of the row.
                ComposingSearchField(placeholder: L("Search"), text: $search).frame(width: 140)
                Button { editing = .new(keys: "") } label: { Image(systemName: "plus") }
                    .help(L("Add…"))
                    .accessibilityLabel(L("Add…"))
            }
            Text(filter.explanation)
                .font(.system(size: 12)).foregroundStyle(Seam.ink2)
            if shown.isEmpty {
                EmptyList(symbol: search.isEmpty ? "text.book.closed" : "magnifyingglass",
                          title: search.isEmpty ? L("No words yet") : L("No matches"),
                          detail: search.isEmpty ? L("Add a word with +, or switch a word that came out wrong with the language switch key: corrected the same way twice, it's remembered here.") : nil)
            } else {
                table
            }
            HStack {
                Spacer()
                Button(L("Forget Learned Words…"), role: .destructive) { confirmForgetAll = true }
                    .disabled(!model.entries.contains { $0.source == .learned })
            }
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
        .background(Seam.bg)
        .sheet(item: $editing) { EntrySheet(model: model, target: $0) }
        .confirmationDialog(L("Forget every learned word?"), isPresented: $confirmForgetAll) {
            Button(L("Forget All"), role: .destructive) { model.forgetAll() }
        } message: {
            Text(L("Words you added stay. This can't be undone."))
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Keys")).frame(width: Column.keys, alignment: .leading)
                Text(L("Result")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Status")).frame(width: Column.source, alignment: .leading)
                Text(L("Apps")).frame(width: Column.apps, alignment: .leading)
                Text(L("Expires")).frame(width: Column.expires, alignment: .leading)
                Color.clear.frame(width: Column.actions, height: 1)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Seam.ink3)
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
            Rectangle().fill(Seam.line).frame(height: 1)
            List(selection: $selection) {
                ForEach(shown) { entry in
                    // The sheet chooses a reading: an entry of the user's own text isn't one, and
                    // saving it there would turn the text into a reading. It can only be removed.
                    EntryRow(entry: entry, model: model) { if entry.language != nil { editing = .edit(entry) } }
                        .tag(entry.id)
                        .contextMenu { actions(entry) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .onDeleteCommand { selection.forEach(model.remove); selection = [] }
        }
        .background(Seam.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Seam.line))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The row's commands, in its ⋯ menu and its context menu alike.
    @ViewBuilder private func actions(_ entry: UserDictionary.Entry) -> some View {
        if entry.language != nil { Button(L("Edit…")) { editing = .edit(entry) } }
        if entry.source == .learned { Button(L("Keep for Good")) { model.pin(entry.id) } }
        Button(L("Remove"), role: .destructive) { model.remove(entry.id) }
    }
}

private enum Column {
    static let keys: CGFloat = 100
    static let source: CGFloat = 112
    static let apps: CGFloat = 110
    static let expires: CGFloat = 70
    static let actions: CGFloat = 28
}

private struct EntryRow: View {
    let entry: UserDictionary.Entry
    @ObservedObject var model: SettingsModel
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: entry.keys).font(.system(size: 13, design: .monospaced)).foregroundStyle(Seam.ink2)
                .lineLimit(1).truncationMode(.middle).help(entry.keys)
                .frame(width: Column.keys, alignment: .leading)
            HStack(spacing: 6) {
                Text(verbatim: EntryText.of(entry)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Seam.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(EntryText.kind(entry)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(entry.language?.ink ?? Seam.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SourceBadge(entry: entry).frame(width: Column.source, alignment: .leading)
            Text(EntryText.apps(entry)).font(.system(size: 12)).foregroundStyle(Seam.ink2).lineLimit(1)
                .frame(width: Column.apps, alignment: .leading)
            Text(EntryText.expires(entry)).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(entry.strength == .weak ? Seam.ink2 : Seam.ink3).lineLimit(1)
                .frame(width: Column.expires, alignment: .leading)
            Menu {
                if entry.language != nil { Button(L("Edit…"), action: edit) }
                if entry.source == .learned { Button(L("Keep for Good")) { model.pin(entry.id) } }
                Button(L("Remove"), role: .destructive) { model.remove(entry.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Seam.ink3)
            .help(L("Edit, keep for good or remove"))
            .accessibilityLabel(L("Actions for %@", entry.keys))
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

/// How an entry reads in the list: its kind first (Korean, My text), then what it writes.
enum EntryText {
    static func kind(_ entry: UserDictionary.Entry) -> String {
        entry.language?.displayName ?? L("My text")
    }

    static func of(_ entry: UserDictionary.Entry) -> String {
        if let language = entry.language { return UserDictionary.reading(entry.keys, as: language) }
        return entry.text ?? ""
    }

    /// When a word corrected once is forgotten; a dash for the rest, which stay.
    static func expires(_ entry: UserDictionary.Entry) -> String {
        guard let days = UserDictionary.daysLeft(entry, today: Date()) else { return "—" }
        return L("%ld days", days)
    }

    static func apps(_ entry: UserDictionary.Entry) -> String {
        guard let apps = entry.apps else { return L("Every app") }
        return apps.map { $0.hasSuffix(".") ? $0 + "*" : AppName.of($0) }.joined(separator: ", ")
    }
}

/// Added and remembered words stay (blue and ink); a word corrected once is on its way (yellow).
private struct SourceBadge: View {
    let entry: UserDictionary.Entry

    var body: some View {
        switch (entry.source, entry.strength) {
        case (.user, _): Badge(title: L("Added"), fill: Seam.bg2, ink: Seam.ink)
        case (_, .weak?): Badge(title: L("Corrected once"), fill: Seam.japanese.opacity(0.22), ink: Seam.japaneseInk)
        default: Badge(title: L("Remembered"), fill: Seam.korean.opacity(0.14), ink: Seam.korean)
        }
    }
}

/// Adds a word to the dictionary, or changes one: the keys as typed, the reading they come
/// out as, and the app they're for.
struct EntrySheet: View {
    enum Target: Identifiable {
        case new(keys: String)
        case edit(UserDictionary.Entry)

        var id: String {
            switch self {
            case .new(let keys): return "new:" + keys
            case .edit(let entry): return entry.id
            }
        }
    }

    @ObservedObject var model: SettingsModel
    let target: Target
    @State private var keys: String
    @State private var language: Language
    @State private var app: String?
    @Environment(\.dismiss) private var dismiss

    init(model: SettingsModel, target: Target) {
        self.model = model
        self.target = target
        switch target {
        case .new(let keys):
            _keys = State(initialValue: keys)
            _language = State(initialValue: .english)
            _app = State(initialValue: nil)
        case .edit(let entry):
            _keys = State(initialValue: entry.keys)
            _language = State(initialValue: entry.language ?? .english)
            _app = State(initialValue: entry.apps?.first)
        }
    }

    private var original: UserDictionary.Entry? {
        if case .edit(let entry) = target { return entry }
        return nil
    }

    /// The readings the keys have: Korean when they make Hangul, Japanese when it's on where the
    /// entry applies (its app, or some app for an entry for every app) and they make kana.
    private var choices: [Language] {
        var choices: [Language] = [.english]
        if !keys.isEmpty, HangulComposer.compose(keys: keys) != nil { choices.append(.korean) }
        if japaneseHere || language == .japanese, !keys.isEmpty,
           RomajiComposer.compose(keys).strayLetters == 0 { choices.append(.japanese) }
        return choices
    }

    /// Japanese is on where the entry applies: its app, or some app for an entry for every app.
    private var japaneseHere: Bool {
        let policies = AppPolicies.load()
        return app.map { policies.policy(for: $0).japanese(default: model.settings.japanese) }
            ?? policies.japaneseUsed(default: model.settings.japanese)
    }

    /// Apps set in apps.json and the ones running, by name.
    private var apps: [(id: String, name: String)] {
        var ids = Set(model.apps.map(\.id))
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            // Not this settings window: it runs as Araso, an app no one types in.
            if let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier { ids.insert(id) }
        }
        if let app { ids.insert(app) }
        return ids.map { ($0, AppName.of($0)) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? L("Add to Dictionary") : L("Change Word")).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                KeyField(keys: $keys).frame(height: 30)
                Text(L("Type the keys as you would on the English layout. They go in as typed, not through an input method."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker(L("Comes out as"), selection: $language) {
                ForEach(choices, id: \.self) { choice in
                    HStack(spacing: 8) {
                        Text(choice.displayName).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(verbatim: keys.isEmpty ? "–" : UserDictionary.reading(keys, as: choice))
                        if choice == language, app == nil, !keys.isEmpty {
                            Text(L("— also with a particle: %@", Self.withParticle(keys, as: choice)))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            Picker(L("App"), selection: $app) {
                Text(L("Every app")).tag(String?.none)
                Divider()
                ForEach(apps, id: \.id) { app in Text(app.name).tag(String?.some(app.id)) }
            }
            .fixedSize()
            HStack {
                if let original {
                    Button(L("Remove"), role: .destructive) {
                        model.remove(original.id)
                        dismiss()
                    }
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? L("Add") : L("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(keys.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: keys) { _ in
            if !choices.contains(language) { language = .english }
        }
        // A new entry moved to an app without Japanese doesn't keep a Japanese reading; an entry
        // being edited keeps the one it has.
        .onChange(of: app) { _ in
            if original == nil, language == .japanese, !japaneseHere { language = .english }
        }
    }

    private func save() {
        guard !keys.isEmpty else { return }
        model.save(UserDictionary.Entry(keys: keys, language: language, source: .user, apps: app.map { [$0] }),
                   replacing: original)
        dismiss()
    }

    /// The word with a particle after it, as the dictionary splits it: 촉매에, ghostty에, ほげで.
    static func withParticle(_ keys: String, as language: Language) -> String {
        let word = UserDictionary.reading(keys, as: language)
        return word + (language == .japanese ? "で" : "에")
    }
}

/// A search field that filters while a word is still being composed: SwiftUI's `TextField`
/// passes on its text only once the input method commits it, and Araso keeps the word
/// underlined until Space, Return or a focus change. Its field editor moves the caret with
/// every change to the composed word, so the text is read on each selection change.
private struct ComposingSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        weak var field: NSSearchField?
        private var observer: NSObjectProtocol?

        init(text: Binding<String>) {
            self.text = text
            super.init()
            observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                                              object: nil, queue: .main) { [weak self] note in
                guard let self, let editor = note.object as? NSTextView,
                      let field = self.field, field.currentEditor() === editor else { return }
                self.update(editor.string)
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            update(field.currentEditor()?.string ?? field.stringValue)
        }

        private func update(_ value: String) {
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}

/// Takes the keys themselves, not text: it isn't a text view, so no input method sees them.
/// Letters, `-` and `'` (⇧ for capitals), Delete to take one off.
private struct KeyField: NSViewRepresentable {
    @Binding var keys: String

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.keys = keys
        view.onChange = { keys = $0 }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        if view.keys != keys { view.keys = keys }
        view.onChange = { keys = $0 }
    }
}

final class KeyCaptureView: NSView {
    var keys = "" { didSet { label.stringValue = keys.isEmpty ? "" : keys; placeholder.isHidden = !keys.isEmpty } }
    var onChange: ((String) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: L("Type the keys"))

    /// US-layout key codes, so the letters are the keys whatever the input source.
    static let qwerty: [UInt16: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k",
        37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u",
        9: "v", 13: "w", 7: "x", 16: "y", 6: "z", 27: "-", 39: "'",
    ]

    /// The key's letter: what it types when that is a letter, `-` or `'` (an English layout, as
    /// Araso's), else by its key code (a Korean layout types jamo).
    static func key(_ event: NSEvent) -> Character? {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1, let ch = typed.first,
           ch.isASCII, ch.isLetter || ch == "-" || ch == "'" {
            return ch
        }
        return qwerty[event.keyCode]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        for field in [label, placeholder] {
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        label.lineBreakMode = .byTruncatingHead
        placeholder.textColor = .placeholderTextColor
        setAccessibilityRole(.textField)
        setAccessibilityLabel(L("Keys"))
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; updateColors(); return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; updateColors(); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func viewDidChangeEffectiveAppearance() { updateColors() }
    override func accessibilityValue() -> Any? { keys }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            guard !keys.isEmpty else { return NSSound.beep() }
            keys.removeLast()
        case 48: // Tab
            flags.contains(.shift) ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            return
        default:
            guard var key = Self.key(event), keys.count < 40 else { return super.keyDown(with: event) }
            if flags.contains(.shift) { key = Character(key.uppercased()) }
            keys.append(key)
        }
        onChange?(keys)
    }
}
