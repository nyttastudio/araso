import ArasoCore
import Cocoa
import InputMethodKit
import Carbon

// Registration and a settings window do not establish that the input server can accept work.
// This command only checks the installed server; it must not create a server of its own.
if CommandLine.arguments.contains("--check-server") {
    let ready = InputServerHealth.check()
    print(ready ? "input server ready" : "input server did not respond (this is not a typing test)")
    exit(ready ? 0 : 1)
}

// `Araso --vim insert|normal|off [--app <bundle id>]`: vim tells the input method which mode
// it is in, and in which app (see README, "vim"), so normal-mode keys go straight through without
// guessing. Runs before anything else loads: it is started on every mode change.
if let flag = CommandLine.arguments.firstIndex(of: "--vim") {
    let args = CommandLine.arguments
    let mode = args.dropFirst(flag + 1).first ?? ""
    guard VimSignal(rawValue: mode) != nil else {
        print("usage: Araso --vim insert|normal|off [--app <bundle id>]")
        exit(2)
    }
    let app = args.firstIndex(of: "--app").flatMap { args.dropFirst($0 + 1).first }.flatMap { $0.isEmpty ? nil : $0 }
    DistributedNotificationCenter.default().postNotificationName(
        VimSignal.notification, object: mode, userInfo: app.map { [VimSignal.appKey: $0] }, deliverImmediately: true)
    exit(0)
}

// `Araso --settings [general|keys|accents|apps|typing|learning|about]`: the settings window, started from the input menu.
if let flag = CommandLine.arguments.firstIndex(of: "--settings") {
    let next = CommandLine.arguments.dropFirst(flag + 1).first
    MainActor.assumeIsolated { runSettingsApp(tab: next.flatMap(SettingsTab.init(rawValue:)) ?? .general) }
}

// `Araso --register`: register this bundle as an input method and enable its input source,
// for the user running it (the installer package runs it as the logged-in user). Recent macOS
// may still want the user to add it in System Settings → Keyboard → Input Sources.
if CommandLine.arguments.contains("--register") {
    let status = MainActor.assumeIsolated { Registration.run() }
    print(status == noErr ? "registered \(Bundle.main.bundlePath)" : "could not register (\(status))")
    exit(status == noErr ? 0 : 1)
}

// `Araso --registered`: exit 0 if macOS lists the input source (for the pkg's postinstall).
if CommandLine.arguments.contains("--registered") {
    exit(MainActor.assumeIsolated { Registration.isListed() } ? 0 : 1)
}

// `Araso --uninstall [--delete-data]`: what About's Uninstall… does, for the install scripts.
if CommandLine.arguments.contains("--uninstall") {
    MainActor.assumeIsolated {
        do {
            try Uninstaller.run(deleteData: CommandLine.arguments.contains("--delete-data"))
            print("uninstalled Araso")
            exit(0)
        } catch Uninstaller.Failure.cancelled {
            print("uninstall cancelled")
            exit(1)
        } catch {
            print("could not uninstall Araso: \(error.localizedDescription)")
            exit(1)
        }
    }
}

// `Araso --selftest`: load every model from the bundle and exit (used by build-app.sh).
if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated {
        var ok = true
        // A fresh engine: the user's learned words must not decide the self-test.
        let fresh = SplittingEngine(base: HeuristicEngine(), english: .shared)
        let english = fresh.decide("hello", context: DecisionContext()).language == .english
        let korean = fresh.decide("dkssud", context: DecisionContext()).output == "안녕"
        let lists = EnglishModel.shared.wordCount > 100_000 && KoreanModel().isKnownWord("나는")
        print("english/korean: \(english && korean && lists ? "ok" : "FAILED")")
        ok = ok && english && korean && lists
        // Must come from the bundle, not the source-tree fallback used in development.
        let resources = [Resources.kanaModel, Resources.textModel, Resources.englishWords, Resources.koreanWords,
                         Resources.koreanSyllables, Resources.koreanVocabulary, Resources.japaneseDictionary]
        let bundled = resources.allSatisfy { $0?.path.hasPrefix(Bundle.main.bundlePath) == true }
        print("resources in bundle: \(bundled ? "ok" : "FAILED")")
        ok = ok && bundled
        // A throwaway memory folder: the self-test must not create or touch the user's.
        let memory = FileManager.default.temporaryDirectory.appendingPathComponent("araso-selftest-\(UUID().uuidString)")
        if let model = JapaneseModel.shared, let converter = AzooKeyConverter(memory: memory) {
            let kana = model.score(keys: "konnichiha") != nil
            let kanji = converter.candidates(for: "へんかん").contains { $0.text == "変換" }
            print("japanese model: \(kana ? "ok" : "FAILED"), dictionary: \(kanji ? "ok" : "FAILED")")
            ok = ok && kana && kanji
        } else {
            print("japanese resources: FAILED (not found in \(Bundle.main.resourceURL?.path ?? "?"))")
            ok = false
        }
        try? FileManager.default.removeItem(at: memory)
        // macOS's engine is private API: report it, but AzooKey stands in when it's missing.
        let apple = AppleJapaneseConverter(learning: nil)?.candidates(for: "たか").contains { $0.text == "髙" } ?? false
        print("macOS japanese engine: \(apple ? "ok" : "unavailable (AzooKey is used)")")
        exit(ok ? 0 : 1)
    }
}

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "com.nyttastudio.inputmethod.Araso_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    fatalError("Araso: could not start IMKServer '\(connectionName)'. Run from the installed .app bundle.")
}

// Build the language models (and load the Japanese dictionary) before the first keystroke.
MainActor.assumeIsolated {
    _ = Runtime.shared.engine.decide("warmup", context: DecisionContext())
    _ = Runtime.shared.converter?.candidates(for: "あ")
    Updater.shared.startDailyChecks()
}

let healthObserver = InputServerHealth.respond()
withExtendedLifetime((server, healthObserver)) {
    NSApplication.shared.run()
}
