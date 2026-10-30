import ArasoCore
import Cocoa
import SwiftUI

/// The settings window runs as its own process (`Araso --settings <tab>`): the input method
/// itself is a background-only app that can't take keyboard focus for a window. It edits the
/// files in the support folder and tells the input method to read them again.
enum SettingsTab: String, CaseIterable, Identifiable {
    // The settings first, then trying them out and the app itself.
    case general, keys, apps, learning, typing, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("Languages")
        case .keys: return L("Keys")
        case .typing: return L("Try Typing")
        case .apps: return L("Apps")
        case .learning: return L("Dictionary")
        case .about: return L("About")
        }
    }

    /// One line under the pane's title: what it's for.
    var subtitle: String {
        switch self {
        case .general: return L("Which languages each word is decided between, the layouts they are typed on, and how Japanese types.")
        case .keys: return L("The keys that change a word's language, and a few more.")
        case .apps: return L("How sure a word must be to convert, and apps that work differently.")
        case .learning: return L("Keys that always come out one way.")
        case .typing: return L("Type here to see how each word is decided.")
        case .about: return L("Version, updates and files.")
        }
    }

    /// Where the sidebar draws a line: after the settings.
    static let settings: [SettingsTab] = [.general, .keys, .apps, .learning]
    static let more: [SettingsTab] = [.typing, .about]
}

enum SettingsLauncher {
    static let showTab = Notification.Name("com.nyttastudio.inputmethod.Araso.showSettings")

    /// Brings the open settings window to `tab`, or starts one.
    static func open(tab: SettingsTab) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let window = others.first {
            DistributedNotificationCenter.default().postNotificationName(showTab, object: tab.rawValue,
                                                                        userInfo: nil, deliverImmediately: true)
            window.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--settings", tab.rawValue]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { NSLog("Araso: could not open settings: %@", error.localizedDescription) }
        }
    }
}

enum AppName {
    static func of(_ bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleIdentifier
    }

    static func icon(_ bundleIdentifier: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

// MARK: - App

@MainActor
func runSettingsApp(tab: SettingsTab) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if let icon = SeamMark.appIcon() { app.applicationIconImage = icon }
    let model = SettingsModel(tab: tab)
    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
    window.title = L("Araso Settings")
    window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    // The sidebar and panes paint the whole window; the title bar is just the traffic lights.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.setContentSize(SettingsView.size)
    window.center()
    let delegate = SettingsAppDelegate()
    app.delegate = delegate
    app.mainMenu = SettingsAppDelegate.mainMenu()
    window.makeKeyAndOrderFront(nil)
    // Each time the window opens, while update checks are on.
    if model.settings.checkForUpdates { Updater.shared.check() }
    // Front even if macOS doesn't let this (background-only) bundle activate.
    window.orderFrontRegardless()
    app.activate(ignoringOtherApps: true)

    // The menu bar and the window's name (Mission Control, the Window menu) follow the language too.
    let language = model.$settings.map(\.displayLanguage).removeDuplicates().dropFirst().sink { chosen in
        MainActor.assumeIsolated {
            Localization.language = chosen // @Published sends before the model's didSet sets it
            window.title = L("Araso Settings")
            app.mainMenu = SettingsAppDelegate.mainMenu()
        }
    }
    DistributedNotificationCenter.default().addObserver(forName: SettingsLauncher.showTab, object: nil, queue: .main) { note in
        let tab = (note.object as? String).flatMap(SettingsTab.init(rawValue:))
        MainActor.assumeIsolated {
            if let tab { model.tab = tab }
            window.makeKeyAndOrderFront(nil)
        }
    }
    // The input menu may have changed things while the window was in the background, or in
    // front: choosing from the menu bar doesn't make the window inactive.
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { model.reload() }
    }
    DistributedNotificationCenter.default().addObserver(forName: SettingsNotice.changedByInputMethod, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { model.reload() }
    }
    withExtendedLifetime((delegate, window, language)) { app.run() }
    exit(0)
}

private final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit, close and the text-editing commands (the search field needs copy and paste).
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: L("Quit Araso Settings"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: L("Edit"))
        edit.submenu?.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        edit.submenu?.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(edit)
        return main
    }
}

// MARK: - Model

/// The support folder's files as the window shows them. Every change is written at once and
/// the input method is told to pick it up.
@MainActor
final class SettingsModel: ObservableObject {
    struct AppRow: Identifiable {
        let id: String
        let name: String
        /// What the app's own entry sets; nil fields follow the default.
        let entry: AppPolicy.Override
    }

    /// Read again on each switch: words learned while trying the typing pane show in Dictionary.
    @Published var tab: SettingsTab { didSet { if tab != oldValue { reload() } } }
    /// The layouts go to this process too: the Dictionary pane reads keys as the IME does.
    @Published private(set) var settings = ArasoCore.Settings.load() {
        didSet {
            LatinLayout.active = settings.latinLayout
            KoreanLayout.active = settings.koreanLayout
            LatinLayout.activeRomaji = settings.japaneseLayout
            Localization.language = settings.displayLanguage
        }
    }
    @Published private(set) var defaultPolicy = AppPolicy.standard
    @Published private(set) var apps: [AppRow] = []
    /// Japanese on under Languages or in an app of its own: its options apply then.
    var japaneseUsed: Bool { settings.japanese || apps.contains { $0.entry.japanese == true } }
    /// dictionary.json: the user's words first, then learned ones, each by keys.
    @Published private(set) var entries: [UserDictionary.Entry] = []

    private let dictionary = DictionaryEngine(base: NoEngine())

    init(tab: SettingsTab) {
        self.tab = tab
        AppPolicies.migrateSwitchKey() // before the window shows (or saves) anything
        reload()
    }

    func reload() {
        settings = ArasoCore.Settings.load()
        dictionary.reload()
        entries = dictionary.dictionary.entries.sorted {
            ($0.source == .user ? 0 : 1, $0.keys) < ($1.source == .user ? 0 : 1, $1.keys)
        }
        let policies = AppPolicies.load()
        defaultPolicy = policies.defaultPolicy
        apps = policies.apps
            .map { AppRow(id: $0, name: AppName.of($0), entry: policies.overrides[$0] ?? AppPolicy.Override()) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func changed(kanjiReset: Bool = false) {
        SettingsNotice.post(kanjiReset: kanjiReset)
        reload()
    }

    // General

    /// Changes one setting in the file as it is now, not in the copy shown: the input menu may
    /// have changed another one since.
    func set<T>(_ key: WritableKeyPath<ArasoCore.Settings, T>, _ value: T) {
        var new = ArasoCore.Settings.load()
        new[keyPath: key] = value
        do { try new.save() } catch { NSLog("Araso: could not save settings: %@", error.localizedDescription) }
        changed()
    }

    func resetKanji() {
        if let memory = AzooKeyConverter.memoryURL {
            for item in (try? FileManager.default.contentsOfDirectory(at: memory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: item)
            }
        }
        if let learning = AppleJapaneseConverter.learningURL { try? FileManager.default.removeItem(at: learning) }
        changed(kanjiReset: true)
    }

    // Apps

    func setDefault(_ change: (inout AppPolicy) -> Void) {
        var policies = AppPolicies.load()
        var policy = policies.defaultPolicy
        change(&policy)
        policies.setDefault(policy)
        try? policies.save()
        changed()
    }

    func setEntry(for app: String, _ change: (inout AppPolicy.Override) -> Void) {
        var policies = AppPolicies.load()
        var entry = policies.overrides[app] ?? AppPolicy.Override()
        change(&entry)
        policies.setEntry(entry, for: app)
        try? policies.save()
        changed()
    }

    /// Takes apps off the list: they follow the default again.
    func remove(_ ids: Set<String>) {
        var policies = AppPolicies.load()
        for id in ids { policies.overrides[id] = nil }
        try? policies.save()
        changed()
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        var policies = AppPolicies.load()
        guard policies.overrides[id] == nil else { return }
        // Starts out following the default; the row's menus change it from there.
        policies.setEntry(AppPolicy.Override(), for: id)
        try? policies.save()
        changed()
    }

    // Dictionary

    // Each starts from dictionary.json as it is now: the input method keeps learning while the
    // window is open, and writing the window's copy back would undo that.

    /// Saves `entry`, in place of `original` when its keys or apps changed.
    func save(_ entry: UserDictionary.Entry, replacing original: UserDictionary.Entry? = nil) {
        dictionary.reload()
        if let original, original.id != entry.id { dictionary.remove(original.id) }
        dictionary.add(entry)
        changed()
    }

    func remove(_ id: UserDictionary.Entry.ID) {
        dictionary.reload()
        dictionary.remove(id)
        changed()
    }

    func pin(_ id: UserDictionary.Entry.ID) {
        dictionary.reload()
        dictionary.pin(id)
        changed()
    }

    func forgetAll() {
        dictionary.reload()
        dictionary.forgetAll()
        changed()
    }
}

/// Lets the window read and edit dictionary.json through `DictionaryEngine` without loading models.
private struct NoEngine: DecisionEngine {
    func decide(_ keys: String, context: DecisionContext) -> Decision {
        Decision(language: .english, confidence: 0.5, output: keys, explanation: "")
    }
}

// MARK: - Shared pieces

private enum Strictness {
    static func name(_ threshold: Double) -> String {
        switch threshold {
        case AppPolicy.strictThreshold: return L("Strict")
        case AppPolicy.standard.conversionThreshold: return L("Normal")
        default: return String(format: "%.2f", threshold)
        }
    }
}

private func strictnessExplanation(_ threshold: Double) -> String {
    threshold >= AppPolicy.strictThreshold
        ? L("Converts only words that are clearly Korean or Japanese, so short commands stay as typed (gst stays gst). For terminals.")
        : L("Converts a word when it reads more like Korean or Japanese than English (gst → ㅎㄴㅅ).")
}

extension Language {
    var displayName: String {
        switch self {
        case .english: return L("English")
        case .korean: return L("Korean")
        case .mixed: return L("Mixed")
        case .japanese: return L("Japanese")
        }
    }
}

/// A → 아 → あ (all read "a") one after another in place, then all of them at once, cut into
/// rows like the menu-bar icon: the top of A, the middle of 아, the bottom of あ. Reduce Motion
/// shows only the joined mark.
struct SeamMark: View {
    var height: CGFloat = 96
    /// Just the joined mark, for a picture (the app icon): no animation.
    var still = false
    /// Fixed colors for a picture; nil follows the appearance.
    var plateColor: Color? = nil
    var letterColor: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0

    init(height: CGFloat = 96, still: Bool = false, plateColor: Color? = nil, letterColor: Color? = nil) {
        self.height = height
        self.still = still
        self.plateColor = plateColor
        self.letterColor = letterColor
        _stage = State(initialValue: still ? Self.all.count : 0)
    }

    /// The app icon: the joined mark on a squircle, drawn at launch (the signed bundle can't
    /// carry one that changes, and an input method has none of its own).
    @MainActor static func appIcon() -> NSImage? {
        let ink = Color(red: 0.11, green: 0.11, blue: 0.12), paper = Color(red: 0.95, green: 0.95, blue: 0.96)
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous).fill(ink)
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
            SeamMark(height: 560, still: true, plateColor: ink, letterColor: paper)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        return renderer.nsImage
    }

    private static let all: [(String, CGFloat)] = [("A", 0.64), ("아", 0.6), ("あ", 0.6)]
    private var letters: [(String, CGFloat)] { Self.all }
    /// Letters one by one, then the joined mark (the last stage).
    private var stages: Int { letters.count + 1 }
    private var joined: Int { letters.count }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.28, style: .continuous).fill(plateColor ?? .primary)
            Group {
                if stage == joined { joinedMark } else { letter(letters[stage]) }
            }
            .id(stage)
            .transition(.asymmetric(
                insertion: .scale(scale: 1.06).combined(with: .opacity).combined(with: .modifier(active: Blur(radius: 2), identity: Blur(radius: 0))),
                removal: .scale(scale: 0.94).combined(with: .opacity).combined(with: .modifier(active: Blur(radius: 2), identity: Blur(radius: 0)))))
        }
        .frame(width: height * 1.25, height: height)
        .task(id: reduceMotion) {
            guard !reduceMotion, !still else { stage = joined; return }
            stage = 0
            while !Task.isCancelled {
                // The joined mark stays a little longer: it's where the sequence lands.
                try? await Task.sleep(for: .seconds(stage == joined ? 3.4 : 2.2))
                if Task.isCancelled { break }
                // Slow and even (sine-like ease in and out): the letters cross over each other.
                withAnimation(.timingCurve(0.37, 0, 0.63, 1, duration: 1.2)) {
                    stage = (stage + 1) % stages
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func letter(_ item: (String, CGFloat)) -> some View {
        Text(verbatim: item.0)
            .font(.system(size: height * item.1, weight: .heavy, design: .rounded))
            .foregroundStyle(letterColor ?? Color(nsColor: .windowBackgroundColor))
    }

    /// Each letter shows only in its own row of the letters' height, with a thin gap between rows.
    /// The seams are gentle waves, as in the README logo (`make-readme-logo.swift`).
    private var joinedMark: some View {
        // Letters grown so their outlines fill the rows, as in the menu-bar icon.
        let band = height * 0.62, gap = height * 0.03, grow: CGFloat = 1.32
        let row = (band - gap * CGFloat(letters.count - 1)) / CGFloat(letters.count)
        let last = letters.count - 1
        return ZStack {
            ForEach(Array(letters.enumerated()), id: \.offset) { i, item in
                let top = height / 2 - band / 2 + CGFloat(i) * (row + gap) + height * 0.01
                letter(item)
                    .scaleEffect(grow)
                    .frame(width: height * 1.25, height: height)
                    .mask { WaveRow(top: i == 0 ? nil : top, bottom: i == last ? nil : top + row) }
            }
        }
    }

    /// One row of the joined mark: the band between two wavy seams, or the edge of the plate
    /// where a side has none. Amplitude 2% of the height, a wavelength of half the width.
    private struct WaveRow: Shape {
        let top: CGFloat?, bottom: CGFloat?

        func path(in rect: CGRect) -> Path {
            let amplitude = rect.height * 0.02, wavelength = rect.width * 0.5
            func y(_ seam: CGFloat, _ x: CGFloat) -> CGFloat {
                seam + amplitude * sin(2 * .pi * (x - rect.width / 4) / wavelength)
            }
            let xs = Array(stride(from: rect.minX, through: rect.maxX, by: max(rect.width / 40, 0.5)))
            var path = Path()
            if let top {
                path.move(to: CGPoint(x: xs[0], y: y(top, xs[0])))
                for x in xs.dropFirst() { path.addLine(to: CGPoint(x: x, y: y(top, x))) }
            } else {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            if let bottom {
                for x in xs.reversed() { path.addLine(to: CGPoint(x: x, y: y(bottom, x))) }
            } else {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            path.closeSubpath()
            return path
        }
    }

    private struct Blur: ViewModifier {
        let radius: CGFloat
        func body(content: Content) -> some View { content.blur(radius: radius) }
    }
}

// MARK: - Window

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// Wide enough for the Apps pane's five menus on a row.
    static let size = NSSize(width: 980, height: 640)

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Seam.line).frame(width: 1)
            Group {
                switch model.tab {
                case .general: GeneralPane(model: model)
                case .keys: KeysPane(model: model)
                case .typing: TypingPane(model: model)
                case .apps: AppsPane(model: model)
                case .learning: DictionaryPane(model: model)
                case .about: AboutPane(model: model)
                }
            }
            // A pane wider than its room is cut at its edge; it never pushes the sidebar aside.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Built again in the chosen language: every pane reads its words through L.
        .id(model.settings.displayLanguage)
        .environment(\.locale, Localization.locale)
        .background(Seam.bg)
        .tint(Seam.blue)
        // Under the transparent title bar too; the window stays the size below.
        .ignoresSafeArea()
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The tabs as words under the mark, the settings first; the chosen one sits on a card with
/// the website's yellow dot.
private struct Sidebar: View {
    @ObservedObject var model: SettingsModel
    /// A newer release puts a badge on About, where it's installed.
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SeamMark(height: 20, still: true, plateColor: Seam.ink, letterColor: Seam.bg)
                Text(verbatim: "Araso").font(.system(size: 15, weight: .bold)).tracking(-0.2)
                    .foregroundStyle(Seam.ink)
            }
            .padding(.leading, 10).padding(.bottom, 18)
            .accessibilityHidden(true)
            ForEach(SettingsTab.settings) { item($0) }
            Rectangle().fill(Seam.line).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 10)
            ForEach(SettingsTab.more) { item($0) }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 54)
        .frame(width: 184)
        .background(Seam.bg2)
    }

    private func item(_ tab: SettingsTab) -> some View {
        let chosen = model.tab == tab
        return Button { model.tab = tab } label: {
            HStack(spacing: 9) {
                Circle().fill(chosen ? Seam.yellow : .clear).frame(width: 7, height: 7)
                Text(tab.title)
                    .font(.system(size: 14, weight: chosen ? .semibold : .medium))
                    .foregroundStyle(chosen ? Seam.ink : Seam.ink2)
                Spacer(minLength: 0)
                if tab == .about, updater.available != nil {
                    Text(L("Update"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Seam.blue, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: updater.available?.version)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(chosen ? Seam.card : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if chosen { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Seam.line) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityValue(tab == .about && updater.available != nil
                            ? L("Araso %@ is available", updater.available?.version ?? "") : "")
    }
}

private extension View {
    /// The chosen tab already shows where you are; the first one took the focus ring on open.
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmKanji = false

    private func binding(_ key: WritableKeyPath<ArasoCore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { model.set(key, $0) })
    }

    var body: some View {
        Pane(tab: .general) {
            SeamCard(title: L("Languages")) {
                // The whole input method's on/off: it is the "*" policy, which apps can override.
                SeamToggleRow(title: L("Convert words"),
                              detail: L("Off: keys go to the app as typed, as with the ABC layout. Apps can differ, under Apps."),
                              isOn: Binding(get: { model.defaultPolicy.enabled },
                                            set: { value in model.setDefault { $0.enabled = value } }))
                SeamRow(title: L("Korean · English")) {
                    Text(L("Always on")).font(.system(size: 13)).foregroundStyle(Seam.ink3)
                }
                SeamToggleRow(title: L("Japanese"),
                              detail: L("Type Japanese with romaji; Space converts to kanji."),
                              isOn: binding(\.japanese))
            }
            // The layouts together: each language reads every key through its own.
            SeamCard(title: L("Layouts")) {
                SeamRow(title: L("Hangul"),
                        detail: L("3-set types jamo on the digit and symbol keys too; a number on its own stays a number.")) {
                    Picker(L("Hangul"), selection: Binding(get: { model.settings.koreanLayout },
                                                           set: { model.set(\.koreanLayout, $0) })) {
                        Text(L("2-set")).tag(KoreanLayout.dubeolsik)
                        Text(L("3-set final")).tag(KoreanLayout.sebeolsikFinal)
                        Text(L("3-set 390")).tag(KoreanLayout.sebeolsik390)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SeamRow(title: L("English letters")) {
                    Picker(L("English letters"), selection: Binding(get: { model.settings.latinLayout },
                                                                    set: { model.set(\.latinLayout, $0) })) {
                        ForEach(LatinLayout.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SeamRow(title: L("Romaji"),
                        detail: model.japaneseUsed ? nil : L("Used with Japanese on.")) {
                    Picker(L("Romaji"), selection: Binding(get: { model.settings.japaneseLayout },
                                                           set: { model.set(\.japaneseLayout, $0) })) {
                        Text(String(format: L("Same as English (%@)"), model.settings.latinLayout.name))
                            .tag(LatinLayout?.none)
                        ForEach(LatinLayout.allCases, id: \.self) { Text(verbatim: $0.name).tag(LatinLayout?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!model.japaneseUsed)
                }
            }
            if model.japaneseUsed {
                SeamCard(title: L("Japanese input")) {
                    SeamToggleRow(title: L("Live conversion"), detail: L("Shows the top kanji candidate as you type."),
                                  isOn: binding(\.liveConversion))
                    SeamToggleRow(title: L("Full-width numbers"), detail: L("１２３ after Japanese; Space offers 123."),
                                  isOn: binding(\.fullWidthDigits))
                    SeamToggleRow(title: L("Full-width space"), detail: L("A full-width space after Japanese; ⇧Space types the other width."),
                                  isOn: binding(\.fullWidthSpace))
                    SeamRow(title: L("Kanji candidate order"),
                            detail: L("Kanji you pick come first next time.")) {
                        Button(L("Reset…")) { confirmKanji = true }
                    }
                }
            }
            SeamCard(title: L("Display")) {
                SeamRow(title: L("Language"), detail: L("Of this window, the input menu and Araso's messages.")) {
                    Picker(L("Language"), selection: Binding(get: { model.settings.displayLanguage },
                                                             set: { model.set(\.displayLanguage, $0) })) {
                        Text(L("System")).tag(String?.none)
                        // Each in its own language, so it can be found in either.
                        Text(verbatim: "English").tag(String?.some("en"))
                        Text(verbatim: "한국어").tag(String?.some("ko"))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .confirmationDialog(L("Reset the kanji candidate order?"), isPresented: $confirmKanji) {
            Button(L("Reset"), role: .destructive) { model.resetKanji() }
        } message: {
            Text(L("Kanji you picked before won't come first anymore. Remembered words stay."))
        }
    }
}

// MARK: - Keys

private struct KeysPane: View {
    @ObservedObject var model: SettingsModel
    @State private var showInfo = false
    /// Why the key just typed for the pause shortcut can't be one, under the row's description.
    @State private var pauseProblem: String?

    private func binding(_ key: WritableKeyPath<ArasoCore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { model.set(key, $0) })
    }

    /// Apps whose switch keys differ from the default.
    private var appsWithOwnKeys: Int {
        model.apps.filter { $0.entry.applied(to: model.defaultPolicy).switchKeys != model.defaultPolicy.switchKeys }.count
    }

    var body: some View {
        Pane(tab: .keys) {
            SeamCard(title: L("Language switch keys")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        RowLabel(title: L("Switch a word's language"),
                                 detail: L("Turns the word being typed, or the one just typed, into the next reading. Choose one or more."))
                        Spacer(minLength: 8)
                        Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Seam.ink2)
                            .help(L("Which key to choose"))
                            .accessibilityLabel(L("Which key to choose"))
                            // To the left, over the pane: at the window's right edge a trailing popover hung over the desktop.
                            .popover(isPresented: $showInfo, arrowEdge: .leading) {
                                SwitchKeysInfo(chosen: model.defaultPolicy.switchKeys)
                            }
                    }
                    KeycapToggles(selection: model.defaultPolicy.switchKeys, taken: model.settings.pauseKey.switchKey) { key, on in
                        model.setDefault { if on { $0.switchKeys.insert(key) } else { $0.switchKeys.remove(key) } }
                    }
                    SwitchKeysStatus(keys: model.defaultPolicy.switchKeys)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                SeamRow(title: L("Apps with their own keys"),
                        detail: appsWithOwnKeys == 0 ? L("Every app uses these keys.")
                            : appsWithOwnKeys == 1 ? L("One app uses its own keys.")
                            : L("%ld apps use their own keys.", appsWithOwnKeys)) {
                    Button(L("Set in Apps…")) { model.tab = .apps }
                }
            }
            SeamCard(title: L("Other keys")) {
                SeamToggleRow(title: L("Return only confirms"),
                              detail: L("Return on an underlined word confirms it; press it again for a new line. Japanese is always only confirmed."),
                              isOn: binding(\.returnConfirmsOnly))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 16) {
                        RowLabel(title: L("Pause"),
                                 detail: L("Keys go through as typed in that text field, for hjkl in terminal programs. Press it again to resume."))
                        Spacer(minLength: 8)
                        PauseKeyPicker(selection: model.settings.pauseKey, switchKeys: model.defaultPolicy.switchKeys,
                                       problem: $pauseProblem) {
                            model.set(\.pauseKey, $0)
                        }
                    }
                    if let pauseProblem {
                        Label(pauseProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Seam.warning)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .animation(.snappy(duration: 0.2), value: pauseProblem)
            }
        }
    }
}

/// The pause key: a right modifier tapped alone, a shortcut typed while recording, or none.
/// The recorder that replaces the pop-up keeps one width, so typing into it moves nothing.
private struct PauseKeyPicker: View {
    let selection: PauseKey
    /// The default's switch keys, which can't pause too.
    let switchKeys: Set<SwitchKey>
    @Binding var problem: String?
    let set: (PauseKey) -> Void
    @State private var monitor: Any?

    private static let width: CGFloat = 150

    var body: some View {
        Group {
            if monitor != nil {
                Recorder(problem: problem != nil) { stopRecording() }
            } else {
                Menu {
                    choice(L("Off"), .off)
                    Divider()
                    ForEach(PauseKey.Tap.allCases, id: \.self) { tap in
                        let taken = tap.switchKey.map(switchKeys.contains) ?? false
                        // A disabled item can't show a tooltip: the reason goes in its title.
                        choice(taken ? L("%@ — switches languages", PauseKey.tap(tap).title) : PauseKey.tap(tap).title, .tap(tap))
                            .disabled(taken)
                    }
                    Divider()
                    if case .shortcut = selection {
                        choice(selection.title, selection)
                    }
                    Button(L("Record Shortcut…")) { record() }
                } label: {
                    Text(selection.title)
                }
                .fixedSize()
            }
        }
        .onDisappear { stopRecording() }
    }

    /// Where a shortcut is being typed: a field with the focus ring, as macOS's own recorders.
    private struct Recorder: View {
        let problem: Bool
        let cancel: () -> Void

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            HStack(spacing: 4) {
                Text(L("Type a shortcut"))
                    .foregroundStyle(problem ? Seam.warning : Seam.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("Cancel (Esc)"))
                    .accessibilityLabel(L("Cancel"))
            }
            .padding(.leading, 8).padding(.trailing, 4)
            .frame(width: PauseKeyPicker.width, height: 22)
            .background(shape.fill(Seam.card))
            .overlay(shape.strokeBorder(problem ? Seam.warning : Seam.blue, lineWidth: 2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Type a shortcut"))
        }
    }

    private func choice(_ title: String, _ key: PauseKey) -> some View {
        Toggle(title, isOn: Binding(get: { selection == key }, set: { if $0 { problem = nil; set(key) } }))
    }

    /// The next key typed in this window becomes the shortcut; Esc alone cancels.
    private func record() {
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = KeyModifiers(event.modifierFlags)
            if event.keyCode == 53, modifiers.isEmpty {
                stopRecording()
                return nil
            }
            let shortcut = PauseKey.Shortcut(keyCode: event.keyCode, modifiers: modifiers, key: Self.keyName(event))
            switch shortcut.problem(switchKeys: switchKeys) {
            case .types?: problem = L("Add ⌘, ⌃ or ⌥: without one the key types. F-keys can go alone.")
            case .arasos?: problem = L("%@ types hiragana or katakana.", shortcut.display)
            case .switchKey?: problem = L("%@ switches a word's language. Turn that off first.", shortcut.display)
            case nil:
                problem = nil
                set(.shortcut(shortcut))
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        problem = nil
    }

    /// The key as printed on it: "P", "F5", "Space", "←".
    private static func keyName(_ event: NSEvent) -> String {
        if let index = PauseKey.Shortcut.functionKeys.firstIndex(of: event.keyCode) { return "F\(index + 1)" }
        let named: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
        if let name = named[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
    }
}

/// Under the keycaps: the keys chosen, by the names the rest of the window uses, and that the
/// others go to the app; or that none is chosen.
private struct SwitchKeysStatus: View {
    let keys: Set<SwitchKey>

    var body: some View {
        Group {
            if keys.isEmpty {
                Label(L("Nothing switches a word's language."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Seam.warning)
            } else if keys.count == SwitchKey.allCases.count {
                Text(L("All of these switch languages."))
                    .foregroundStyle(Seam.ink2)
            } else {
                Text(L("Switching: %@. The others go to the app as usual.",
                       SwitchKey.sorted(keys).map(\.displayName).joined(separator: ", ")))
                    .foregroundStyle(Seam.ink2)
            }
        }
        .font(.system(size: 12))
    }
}

/// What each key is good for, behind the info button: each as its keycap (checked when chosen),
/// on the window's card color rather than the popover's see-through material.
private struct SwitchKeysInfo: View {
    let chosen: Set<SwitchKey>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Which key to choose")).font(.system(size: 14, weight: .bold)).foregroundStyle(Seam.ink)
            // Keycap and line side by side: stacked, the popover ran past the window's top.
            ForEach(SwitchKey.allCases, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Keycap(key: key, on: chosen.contains(key))
                        .frame(width: 118, alignment: .leading)
                    Text(key.help).font(.system(size: 12)).foregroundStyle(Seam.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(Seam.line).frame(height: 1)
            Text(L("A right ⌥ or ⇧ tap with other modifiers (a Hyper key) is left to what it's bound to."))
                .font(.system(size: 12)).foregroundStyle(Seam.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 440)
        .background(Seam.card)
    }
}

/// Keys and what they come out as, for trying.
struct Example: View {
    let keys: String
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(Seam.ink3)
            Text(verbatim: output).font(.system(size: 13, weight: .semibold)).foregroundStyle(Seam.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Seam.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Pane(tab: .apps) {
            SeamCard(title: L("Default — every app")) {
                VStack(alignment: .leading, spacing: 0) {
                    ChoiceRow(title: L("Conversion"),
                              explanation: model.defaultPolicy.enabled
                                ? strictnessExplanation(model.defaultPolicy.conversionThreshold)
                                : L("Convert words is off under Languages, so nothing converts.")) {
                        Picker(L("Conversion"), selection: Binding(
                            get: { model.defaultPolicy.conversionThreshold },
                            set: { value in model.setDefault { $0.conversionThreshold = value } })) {
                            Text(L("Normal")).tag(AppPolicy.standard.conversionThreshold)
                            Text(L("Strict")).tag(AppPolicy.strictThreshold)
                        }
                        // Only matters while words are converted.
                        .disabled(!model.defaultPolicy.enabled)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SeamCard(title: L("Exceptions — only apps that differ")) {
                    if model.apps.isEmpty {
                        Text(L("None. Add an app that should work differently."))
                            .font(.system(size: 13)).foregroundStyle(Seam.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    ForEach(model.apps) { row in
                        AppRowView(row: row, defaultPolicy: model.defaultPolicy, model: model)
                    }
                    Button { model.addApp() } label: {
                        Label(L("Add App…"), systemImage: "plus")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Seam.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(L("Grey values follow the default; anything else applies to this app only."))
                    .font(.system(size: 12)).foregroundStyle(Seam.ink3)
                    .padding(.leading, 4)
            }
        }
    }
}

/// One app: its icon and full name, then each setting as a small labeled menu.
private struct AppRowView: View {
    let row: SettingsModel.AppRow
    let defaultPolicy: AppPolicy
    @ObservedObject var model: SettingsModel

    var body: some View {
        let converts = row.entry.enabled ?? defaultPolicy.enabled
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let icon = AppName.icon(row.id) {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.dashed").frame(width: 24, height: 24)
                }
                Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Seam.ink)
                    .lineLimit(1).truncationMode(.middle).help(row.id)
                Spacer()
                Button { model.remove([row.id]) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(Seam.ink3)
                    .help(L("Remove: the app follows the default again"))
                    .accessibilityLabel(L("Remove %@", row.name))
            }
            HStack(alignment: .top, spacing: 18) {
                Field(title: L("Convert words"), inherited: row.entry.enabled == nil) {
                    FieldMenu(own: row.entry.enabled.map { $0 ? L("On") : L("Off") },
                              inherited: defaultPolicy.enabled ? L("On") : L("Off"),
                              choices: [(L("On"), true), (L("Off"), false)]) { value in
                        model.setEntry(for: row.id) { $0.enabled = value }
                    }
                }
                Group {
                    Field(title: L("Conversion"), inherited: row.entry.conversionThreshold == nil) {
                        FieldMenu(own: row.entry.conversionThreshold.map(Strictness.name),
                                  inherited: Strictness.name(defaultPolicy.conversionThreshold),
                                  choices: [(L("Normal"), AppPolicy.standard.conversionThreshold), (L("Strict"), AppPolicy.strictThreshold)]) { value in
                            model.setEntry(for: row.id) { $0.conversionThreshold = value }
                        }
                    }
                    // The default is the Languages tab's Japanese: an app can have it on or off whatever that says.
                    Field(title: L("Japanese"), inherited: row.entry.japanese == nil) {
                        FieldMenu(own: row.entry.japanese.map { $0 ? L("On") : L("Off") },
                                  inherited: model.settings.japanese ? L("On") : L("Off"),
                                  choices: [(L("On"), true), (L("Off"), false)]) { value in
                            model.setEntry(for: row.id) { $0.japanese = value }
                        }
                    }
                    .help(L("Off: words here are Korean or English only, as with Japanese off. On: Japanese here even when it is off under Languages."))
                    Field(title: L("Switch keys"), inherited: row.entry.switchKeys == nil) {
                        SwitchKeysMenu(own: row.entry.switchKeys, taken: model.settings.pauseKey.switchKey,
                                       effective: row.entry.applied(to: defaultPolicy).switchKeys,
                                       inherited: defaultPolicy.switchKeys) { value in
                            model.setEntry(for: row.id) { $0.switchKeys = value }
                        }
                    }
                    // Per app only, for terminals: in "*" it would turn off text replacements everywhere.
                    Field(title: L("After Space / punctuation"), inherited: row.entry.holdSpace == nil) {
                        FieldMenu(own: row.entry.holdSpace.map(holdSpaceName),
                                  inherited: holdSpaceName(defaultPolicy.holdSpace),
                                  choices: [(holdSpaceName(false), false), (holdSpaceName(true), true)]) { value in
                            model.setEntry(for: row.id) { $0.holdSpace = value }
                        }
                    }
                    .help(L("Hold: Space or punctuation goes inside the underline, so the word can still be changed until the next word starts. For terminals."))
                }
                .disabled(!converts)
                Spacer(minLength: 0)
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// A setting's name over its menu; a menu that follows the default is drawn lighter.
    private struct Field<Menu: View>: View {
        let title: String
        let inherited: Bool
        @ViewBuilder let menu: Menu

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(Seam.ink3).lineLimit(1)
                menu.opacity(inherited ? 0.55 : 1)
            }
        }
    }
}

/// A setting with a segmented choice on its title line and what the current choice does under
/// it, across the whole row (a long explanation beside the picker would push it onto its own line).
private struct ChoiceRow<Choice: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder let choice: Choice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Seam.ink)
                Spacer(minLength: 12)
                choice.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text(explanation)
                .font(.system(size: 12)).foregroundStyle(Seam.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What Space or punctuation does to the word in an app (`AppPolicy.holdSpace`), as the Apps column shows it.
private func holdSpaceName(_ holds: Bool) -> String { holds ? L("Hold") : L("Finish") }

/// One per-app value: the app's own, or "Default · <value>" while it follows the default. The
/// difference is in the words: a borderless menu's label shows no color or weight.
private struct FieldMenu<Value>: View {
    let own: String?
    let inherited: String
    let choices: [(String, Value)]
    let set: (Value?) -> Void

    var body: some View {
        Menu {
            // Checked as the switch keys' menu is: the default while the app follows it, else its own.
            Toggle(L("Default (%@)", inherited), isOn: Binding(get: { own == nil }, set: { if $0 { set(nil) } }))
            Divider()
            ForEach(choices.indices, id: \.self) { i in
                Toggle(choices[i].0, isOn: Binding(get: { own == choices[i].0 }, set: { if $0 { set(choices[i].1) } }))
            }
        } label: {
            Text(own ?? L("Default · %@", inherited))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// An app's switch keys: "Default · <keys>" while it follows the default, else its own set,
/// changed one key at a time (the first change starts from what the app has now).
private struct SwitchKeysMenu: View {
    let own: Set<SwitchKey>?
    /// Taken by the pause key: can't be turned on.
    let taken: SwitchKey?
    let effective: Set<SwitchKey>
    let inherited: Set<SwitchKey>
    let set: (Set<SwitchKey>?) -> Void

    var body: some View {
        Menu {
            // Checked while the app follows the default; choosing it drops the app's own keys.
            Toggle(L("Default (%@)", SwitchKey.names(inherited)),
                   isOn: Binding(get: { own == nil }, set: { if $0 { set(nil) } }))
            Divider()
            ForEach(SwitchKey.allCases, id: \.self) { key in
                Toggle(key.displayName, isOn: Binding(
                    get: { (own ?? effective).contains(key) },
                    set: { on in
                        var keys = own ?? effective
                        if on { keys.insert(key) } else { keys.remove(key) }
                        set(keys)
                    }))
                    .disabled(key == taken && !(own ?? effective).contains(key))
            }
        } label: {
            // A menu's label shows only text.
            Text(own.map { $0.isEmpty ? L("None — can't switch") : SwitchKey.names($0) }
                 ?? L("Default · %@", SwitchKey.names(effective)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// In place of an empty list: what would be there, and how it fills up.
struct EmptyList: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Seam.ink3)
            Text(title).font(.headline).foregroundStyle(Seam.ink2)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(Seam.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Seam.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Seam.line))
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Pane(tab: .about) {
            HStack(spacing: 18) {
                SeamMark(height: 64, plateColor: Seam.ink, letterColor: Seam.bg)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Araso").font(.system(size: 24, weight: .heavy)).tracking(-0.6)
                        .foregroundStyle(Seam.ink)
                    HStack(spacing: 0) {
                        Text(verbatim: "흐름대로 써진다").foregroundStyle(Seam.korean)
                        Text(verbatim: " · ").foregroundStyle(Seam.ink3)
                        Text(verbatim: "流れるままに").foregroundStyle(Seam.japaneseInk)
                        Text(verbatim: " · ").foregroundStyle(Seam.ink3)
                        Text(verbatim: "Type as it flows").foregroundStyle(Seam.ink2)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    Text(L("Version %@", Updater.currentVersion))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Seam.ink3)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 4)
            SeamCard(title: L("Updates")) {
                SeamRow(title: updateTitle, detail: updateDetail) {
                    if let release = updater.available {
                        Button(L("Install %@…", release.version)) { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.state == .downloading)
                    } else {
                        Button(L("Check Now")) { updater.check() }
                            .disabled(updater.state == .checking)
                    }
                }
                if let release = updater.available, !release.notes.isEmpty || release.page != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if !release.notes.isEmpty {
                            Text(L("What's changed")).font(.system(size: 11, weight: .medium)).foregroundStyle(Seam.ink3)
                        }
                        ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                            let line = Release.headline(of: note)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.markdown(line.title)).font(.system(size: 13, weight: .medium)).foregroundStyle(Seam.ink)
                                if let detail = line.detail {
                                    Text(Self.markdown(detail))
                                        .font(.system(size: 12)).foregroundStyle(Seam.ink2)
                                        .lineLimit(2).truncationMode(.tail)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let page = release.page {
                            Link(L("Full Release Notes"), destination: page).font(.system(size: 12))
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                SeamToggleRow(title: L("Check for updates automatically"),
                              detail: L("Once a day, and each time this window opens. Only the latest version number is asked of GitHub; nothing you type is sent."),
                              isOn: Binding(get: { model.settings.checkForUpdates }, set: { model.set(\.checkForUpdates, $0) }))
            }
            SeamCard(title: L("This Mac")) {
                SeamRow(title: L("Settings and learning files"),
                        detail: L("What you type never leaves this Mac: deciding words and converting kanji both happen here.")) {
                    Button(L("Show in Finder")) {
                        if let url = SupportDirectory.url { NSWorkspace.shared.open(url) }
                    }
                }
                SeamRow(title: L("License"), detail: L("MIT, with open source notices for the data it uses.")) {
                    Button(L("Open Notices")) {
                        if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if Uninstaller.isAvailable {
                    SeamRow(title: L("Uninstall Araso"),
                            detail: L("Removes Araso from this Mac and switches to another input source. If it was installed with the installer, macOS asks for your password.")) {
                        Button(L("Uninstall…"), role: .destructive) { Uninstaller.confirmAndRun() }
                    }
                }
            }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var updateTitle: String {
        if let release = updater.available { return L("Araso %@ is available", release.version) }
        switch updater.state {
        case .checking: return L("Checking for updates…")
        case .upToDate: return L("Araso is up to date")
        default: return L("Version %@", Updater.currentVersion)
        }
    }

    private var updateDetail: String? {
        switch updater.state {
        case .downloading: return L("Downloading… Installer opens when it's done; macOS asks for your password.")
        case .failed(let message): return message
        default:
            return updater.available == nil ? nil : L("Installer opens and macOS asks for your password. Settings and learned words stay.")
        }
    }
}
