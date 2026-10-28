import ArasoCore
import Cocoa

/// What every input controller shares: settings, the decision engine and the kanji converter.
/// A change bumps `generation`; each controller then commits what it was composing and
/// continues with a fresh `InputSession` built from the new state, so nothing needs a restart.
@MainActor
final class Runtime {
    static let shared = Runtime()

    private(set) var settings: Settings
    private(set) var engine: DictionaryEngine
    private(set) var converter: JapaneseConverter?
    /// Whether the engine has the Japanese model and the converter is made: Japanese is on in the
    /// Languages tab, or an app turns it on itself (`AppPolicies.turnsJapaneseOn`). Where it is on
    /// is each session's to pick, from its app's policy.
    private(set) var japaneseLoaded: Bool
    private(set) var generation = 0
    /// The controller of the text field in front, which a vim mode change is about.
    weak var active: InputController?
    /// The latest vim mode change and the app vim runs in. Vim's FocusGained can arrive before
    /// macOS activates the terminal's controller (and FocusLost after), so a controller
    /// activated in that app catches up on it.
    private(set) var lastVim: (signal: VimSignal, app: String?)?

    private init() {
        AppPolicies.migrateSwitchKey()
        settings = Settings.load()
        LatinLayout.active = settings.latinLayout
        KoreanLayout.active = settings.koreanLayout
        LatinLayout.activeRomaji = settings.japaneseLayout
        japaneseLoaded = Self.needsJapanese(settings)
        engine = Self.makeEngine(japanese: japaneseLoaded)
        converter = japaneseLoaded ? Self.makeConverter(settings) : nil
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: SettingsNotice.changed, object: nil, queue: .main) { note in
            let kanjiReset = note.object as? String == SettingsNotice.kanjiReset
            MainActor.assumeIsolated { Runtime.shared.reloadFromDisk(kanjiReset: kanjiReset) }
        }
        center.addObserver(forName: VimSignal.notification, object: nil, queue: .main) { note in
            guard let signal = (note.object as? String).flatMap(VimSignal.init(rawValue:)) else { return }
            let app = note.userInfo?[VimSignal.appKey] as? String
            MainActor.assumeIsolated {
                Runtime.shared.lastVim = (signal, app)
                Runtime.shared.active?.vimChanged(to: signal, from: app)
            }
        }
    }

    /// Order of authority: the user's dictionary (words added, or corrected the same way twice;
    /// one correction only nudges), then mixed-word splitting
    /// (github에, x에, hello월드, githubで), then the heuristic.
    private static func needsJapanese(_ settings: Settings) -> Bool {
        settings.japanese || AppPolicies.load().turnsJapaneseOn
    }

    private static func makeEngine(japanese: Bool) -> DictionaryEngine {
        let heuristic = HeuristicEngine(japanese: japanese ? JapaneseModel.shared : nil)
        let engine = DictionaryEngine(base: SplittingEngine(base: heuristic, english: heuristic.english,
                                                            japanese: heuristic.segmenter),
                                      english: heuristic.english, korean: heuristic.korean,
                                      japaneseParticles: heuristic.segmenter != nil)
        // An open settings window shows a word learned while typing at once, not on its next activation.
        engine.saved = { SettingsNotice.postFromInputMethod() }
        return engine
    }

    /// macOS's Japanese engine unless the user chose AzooKey; AzooKey also where macOS's can't be loaded.
    private static func makeConverter(_ settings: Settings) -> JapaneseConverter? {
        if settings.japaneseEngine != "azooKey", let apple = AppleJapaneseConverter() { return apple }
        return AzooKeyConverter()
    }

    func makeSession() -> InputSession {
        let session = InputSession(engine: engine, policies: AppPolicies.load(),
                                   converter: converter,
                                   japaneseEnabled: settings.japanese, liveConversion: settings.liveConversion,
                                   returnConfirmsOnly: settings.returnConfirmsOnly)
        session.replacements = textReplacements
        session.fullWidthDigits = settings.fullWidthDigits
        session.fullWidthSpace = settings.fullWidthSpace
        return session
    }

    /// The user's text replacements, read again whenever a text field becomes active, so an edit
    /// in System Settings applies without a restart.
    var textReplacements: [String: [String]] { TextReplacements.shared.entries }

    /// Saves a settings change and applies it. Starts from the file, not from memory: the
    /// settings window may have written it a moment ago.
    func update(_ change: (inout Settings) -> Void) {
        var new = Settings.load()
        change(&new)
        do { try new.save() } catch { NSLog("Araso: could not save settings: %@", error.localizedDescription) }
        if new != settings { apply(new) }
        SettingsNotice.postFromInputMethod()
    }

    /// Saves a change to one app's behavior and applies it.
    func updatePolicy(for app: String, _ change: (inout AppPolicy) -> Void) {
        var policies = AppPolicies.load()
        var policy = policies.policy(for: app)
        change(&policy)
        policies.set(policy, for: app)
        do { try policies.save() } catch { NSLog("Araso: could not save apps.json: %@", error.localizedDescription) }
        // Also loads or drops the Japanese model when this app was the only one to want it.
        apply(settings)
        SettingsNotice.postFromInputMethod()
    }

    /// Takes the app off the list: it follows the default again.
    func removePolicy(for app: String) {
        var policies = AppPolicies.load()
        policies.overrides[app] = nil
        do { try policies.save() } catch { NSLog("Araso: could not save apps.json: %@", error.localizedDescription) }
        apply(settings)
        SettingsNotice.postFromInputMethod()
    }

    /// Forgets a dictionary word the input menu listed as one it changed.
    func forget(_ keys: String) {
        engine.forget(keys)
        SettingsNotice.postFromInputMethod()
    }

    func undoLastLearned() {
        guard let keys = engine.lastLearned else { return }
        engine.forget(keys)
        SettingsNotice.postFromInputMethod()
    }

    private func apply(_ new: Settings) {
        let japanese = Self.needsJapanese(new)
        if japanese != japaneseLoaded {
            engine = Self.makeEngine(japanese: japanese)
            japaneseLoaded = japanese
        }
        if japanese, converter == nil || new.japaneseEngine != settings.japaneseEngine {
            converter?.save()
            converter = Self.makeConverter(new)
        }
        settings = new
        LatinLayout.active = new.latinLayout
        KoreanLayout.active = new.koreanLayout
        LatinLayout.activeRomaji = new.japaneseLayout
        generation += 1
    }

    /// The settings window changed files: read them again.
    private func reloadFromDisk(kanjiReset: Bool) {
        if kanjiReset {
            // Drop the converter without saving, so its memory doesn't come back.
            converter = nil
            if japaneseLoaded { converter = Self.makeConverter(settings) }
        }
        engine.reload()
        apply(Settings.load())
        generation += 1
    }
}

/// Between the settings window (its own process) and the input method: each tells the other
/// it changed the files, under its own name, so neither hears its own.
enum SettingsNotice {
    /// From the settings window: the input method reads the files again.
    static let changed = Notification.Name("com.nyttastudio.inputmethod.Araso.settingsChanged")
    /// From the input method (its input menu): an open settings window reads them again.
    static let changedByInputMethod = Notification.Name("com.nyttastudio.inputmethod.Araso.settingsChangedByInputMethod")
    static let kanjiReset = "kanjiReset"

    static func post(kanjiReset: Bool = false) {
        DistributedNotificationCenter.default().postNotificationName(
            changed, object: kanjiReset ? Self.kanjiReset : nil, userInfo: nil, deliverImmediately: true)
    }

    static func postFromInputMethod() {
        DistributedNotificationCenter.default().postNotificationName(
            changedByInputMethod, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
