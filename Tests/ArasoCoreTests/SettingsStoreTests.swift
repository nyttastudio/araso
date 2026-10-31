import Foundation
import Testing
@testable import ArasoCore

/// What the input menu and the settings window write: settings.json, apps.json, lexicon.json.
@Suite struct SettingsStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("araso-store-\(UUID().uuidString)")

    /// A fixed engine, so tests control what "the engine's own choice" is.
    struct Fixed: DecisionEngine {
        let language: Language
        func decide(_ keys: String, context: DecisionContext) -> Decision {
            Decision(language: language, confidence: 0.9, output: keys, explanation: "")
        }
    }

    @Test func pauseKeyIsRightCommandUnlessChanged() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "japanese": true }"#.utf8).write(to: url)
        #expect(Settings.load(from: url).pauseKey == .tap(.rightCommand))
        try Settings(pauseKey: .off).save(to: url)
        #expect(Settings.load(from: url).pauseKey == .off)
        let shortcut = PauseKey.Shortcut(keyCode: 35, modifiers: [.control, .option], key: "P")
        try Settings(pauseKey: .shortcut(shortcut)).save(to: url)
        #expect(Settings.load(from: url).pauseKey == .shortcut(shortcut))
        #expect(Settings.load(from: url).returnConfirmsOnly)
        try Settings(returnConfirmsOnly: false).save(to: url)
        #expect(!Settings.load(from: url).returnConfirmsOnly)
    }

    /// Before pauseKey, right ⌘ was turned off with rightCommandPause; that still holds, and a
    /// save moves it into pauseKey.
    @Test func rightCommandPauseOffMeansNoPauseKey() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "rightCommandPause": false }"#.utf8).write(to: url)
        #expect(Settings.load(from: url).pauseKey == .off)
        try Settings.load(from: url).save(to: url)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(saved?["rightCommandPause"] == nil)
        #expect(saved?["pauseKey"] as? String == "off")

        try Data(#"{ "pauseKey": { "keyCode": 96, "modifiers": [] , "key": "F5" } }"#.utf8).write(to: url)
        #expect(Settings.load(from: url).pauseKey == .shortcut(.init(keyCode: 96, modifiers: [], key: "F5")))
        try Data(#"{ "pauseKey": "leftCommand" }"#.utf8).write(to: url)
        #expect(Settings.load(from: url).pauseKey == .standard)
    }

    /// A shortcut that would type, or that Araso already uses, can't pause.
    @Test func pauseShortcutProblems() {
        func problem(_ keyCode: UInt16, _ modifiers: KeyModifiers, switchKeys: Set<SwitchKey> = AppPolicy.standardSwitchKeys) -> PauseKey.Shortcut.Problem? {
            PauseKey.Shortcut(keyCode: keyCode, modifiers: modifiers, key: "").problem(switchKeys: switchKeys)
        }
        #expect(problem(35, [.control, .option]) == nil) // ⌃⌥P
        #expect(problem(96, []) == nil) // F5
        #expect(problem(35, []) == .types)
        #expect(problem(35, [.shift]) == .types)
        #expect(problem(97, []) == .arasos) // F6
        #expect(problem(40, [.control]) == .arasos) // ⌃K
        #expect(problem(49, [.option]) == nil)
        #expect(problem(49, [.option], switchKeys: [.optionSpace]) == .switchKey)
        #expect(PauseKey.tap(.rightOption).switchKey == .rightOption)
        #expect(PauseKey.tap(.rightCommand).switchKey == nil)
        #expect(PauseKey.Shortcut(keyCode: 35, modifiers: [.command, .control, .option, .shift], key: "P").display == "⌃⌥⇧⌘P")
    }

    /// A hand-edited value of the wrong type costs only that key; a file that isn't JSON is set
    /// aside rather than written over by the next save.
    @Test func badValuesDontCostTheWholeFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "japanese": "true", "liveConversion": true, "fullWidthSpace": true }"#.utf8).write(to: url)
        let settings = Settings.load(from: url)
        #expect(!settings.japanese)
        #expect(settings.liveConversion && settings.fullWidthSpace)

        try Data(#"{ "japanese": true "#.utf8).write(to: url)
        #expect(Settings.load(from: url) == Settings())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let aside = url.appendingPathExtension("unreadable")
        #expect(try String(contentsOf: aside, encoding: .utf8) == #"{ "japanese": true "#)
        try Settings(liveConversion: true).save(to: url)
        #expect(try String(contentsOf: aside, encoding: .utf8) == #"{ "japanese": true "#)
    }

    @Test func badAppEntriesDontCostTheOthers() throws {
        let url = dir.appendingPathComponent("apps.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "com.mitchellh.ghostty": {"conversionThreshold": 0.97}, "com.example.Game": {"enabled": "false", "holdSpace": true}, "com.example.Odd": true }"#.utf8).write(to: url)
        let policies = AppPolicies.load(from: url)
        #expect(policies.policy(for: "com.mitchellh.ghostty").conversionThreshold == 0.97)
        #expect(policies.overrides["com.example.Game"] == AppPolicy.Override(holdSpace: true))
        #expect(policies.apps == ["com.example.Game", "com.mitchellh.ghostty"])

        try Data("{ not json".utf8).write(to: url)
        #expect(AppPolicies.load(from: url).overrides.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    /// The one extra switch key in settings.json (builds before 0.1.9) moves into the default's switch keys.
    @Test(arguments: [
        (#"{ "japanese": true }"#, nil as [SwitchKey]?),
        (#"{ "switchKey": "rightOption", "japanese": true }"#, nil), // the new default already
        (#"{ "switchKey": "optionSpace" }"#, [.optionSpace, .shiftEscape]),
        (#"{ "switchKey": "rightShift" }"#, [.rightShift, .shiftEscape]),
        (#"{ "switchKey": "off" }"#, [.escape, .shiftEscape]), // "Esc only"
    ])
    func oldSwitchKeyMovesToTheDefault(settings json: String, expected: [SwitchKey]?) throws {
        let settings = dir.appendingPathComponent("settings.json"), apps = dir.appendingPathComponent("apps.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: settings)
        AppPolicies.migrateSwitchKey(settings: settings, apps: apps)
        AppPolicies.migrateSwitchKey(settings: settings, apps: apps) // again: nothing more
        #expect(AppPolicies.load(from: apps).overrides["*"]?.switchKeys == expected.map(Set.init))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(object["switchKey"] == nil)
    }

    /// A default that names its own switch keys keeps them; "off" with Esc sent to the app leaves out Esc.
    @Test func oldSwitchKeyKeepsWhatAppsJsonSays() throws {
        let settings = dir.appendingPathComponent("settings.json"), apps = dir.appendingPathComponent("apps.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "switchKey": "off" }"#.utf8).write(to: settings)
        try Data(#"{ "*": { "switchKeys": ["rightShift"] } }"#.utf8).write(to: apps)
        AppPolicies.migrateSwitchKey(settings: settings, apps: apps)
        #expect(AppPolicies.load(from: apps).defaultPolicy.switchKeys == [.rightShift])

        try Data(#"{ "switchKey": "off" }"#.utf8).write(to: settings)
        try Data(#"{ "*": { "escapeToApp": true } }"#.utf8).write(to: apps)
        AppPolicies.migrateSwitchKey(settings: settings, apps: apps)
        #expect(AppPolicies.load(from: apps).defaultPolicy.switchKeys == [.shiftEscape])
    }

    /// apps.json from 0.1.8: `escapeToApp` changes the default's Esc for an entry that doesn't
    /// name its switch keys; a later version's key name is skipped.
    @Test func oldEscapeToAppAndUnknownKeys() throws {
        let url = dir.appendingPathComponent("apps.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"""
            { "*": { "switchKeys": ["escape", "rightOption", "capsLock"] },
              "com.microsoft.VSCode": { "escapeToApp": true },
              "com.example.Notes": { "escapeToApp": false, "switchKeys": ["shiftEscape"] },
              "com.apple.Terminal": { "escapeToApp": true, "conversionThreshold": 0.97 } }
            """#.utf8).write(to: url)
        var policies = AppPolicies.load(from: url)
        #expect(policies.defaultPolicy.switchKeys == [.escape, .rightOption])
        #expect(policies.policy(for: "com.microsoft.VSCode").switchKeys == [.rightOption])
        #expect(policies.policy(for: "com.example.Notes").switchKeys == [.shiftEscape])
        // Saved again untouched, the old key keeps meaning what it meant.
        try policies.save(to: url)
        policies = AppPolicies.load(from: url)
        #expect(policies.policy(for: "com.apple.Terminal").switchKeys == [.rightOption])
        #expect(policies.policy(for: "com.apple.Terminal").conversionThreshold == 0.97)
    }

    @Test func settingsSaveKeepsUnknownKeys() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "japanese": false, "future": 3 }"#.utf8).write(to: url)
        try Settings(japanese: true, liveConversion: true).save(to: url)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["future"] as? Int == 3)
        #expect(Settings.load(from: url) == Settings(japanese: true, liveConversion: true))
    }

    @Test func displayLanguageFollowsTheSystemAgainWhenCleared() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(Settings.load(from: url).displayLanguage == nil)
        try Settings(displayLanguage: "en").save(to: url)
        #expect(Settings.load(from: url).displayLanguage == "en")
        try Settings().save(to: url)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["displayLanguage"] == nil)
    }

    @Test func appEntryNamesOnlyWhatDiffersFromTheDefault() throws {
        var policies = AppPolicies()
        policies.setDefault(AppPolicy(switchKeys: [.escape]))
        #expect(policies.overrides["*"] == AppPolicy.Override(switchKeys: [.escape]))

        var ghostty = policies.policy(for: "com.mitchellh.ghostty")
        ghostty.conversionThreshold = AppPolicy.strictThreshold
        policies.set(ghostty, for: "com.mitchellh.ghostty")
        #expect(policies.overrides["com.mitchellh.ghostty"] == AppPolicy.Override(conversionThreshold: 0.97))

        // Set back to the default's values, the app stays listed (the user added it).
        policies.set(policies.defaultPolicy, for: "com.mitchellh.ghostty")
        #expect(policies.overrides["com.mitchellh.ghostty"] == AppPolicy.Override())
        #expect(policies.apps == ["com.mitchellh.ghostty"])

        // A default back at Araso's own leaves no "*" entry.
        policies.setDefault(.standard)
        #expect(policies.overrides["*"] == nil)

        var game = policies.policy(for: "com.example.Game")
        game.enabled = false
        policies.set(game, for: "com.example.Game")
        let url = dir.appendingPathComponent("apps.json")
        try policies.save(to: url)
        #expect(AppPolicies.load(from: url).policy(for: "com.example.Game").enabled == false)
        #expect(AppPolicies.load(from: url).apps == ["com.example.Game", "com.mitchellh.ghostty"])
    }

    @Test func forgetAndUndoLearnedWords() {
        let url = dir.appendingPathComponent("lexicon.json")
        let learning = DictionaryEngine(base: Fixed(language: .english), storeURL: url)
        learning.learn("dlrjs", as: .korean)
        #expect(learning.pending == ["dlrjs": .korean])
        #expect(learning.lastLearned == nil)
        learning.learn("dlrjs", as: .korean)
        #expect(learning.learned == ["dlrjs": .korean])
        #expect(learning.lastLearned == "dlrjs")

        learning.forget("dlrjs")
        #expect(learning.learned.isEmpty && learning.pending.isEmpty)
        #expect(learning.lastLearned == nil)

        learning.learn("gks", as: .korean)
        learning.learn("rk", as: .korean)
        learning.learn("rk", as: .korean)
        // Another process (the settings window) edits the file; reload picks it up.
        let other = DictionaryEngine(base: Fixed(language: .english), storeURL: url)
        other.forget("gks")
        learning.reload()
        #expect(learning.pending.isEmpty)
        #expect(learning.learned == ["rk": .korean])

        learning.forgetAll()
        #expect(DictionaryEngine(base: Fixed(language: .english), storeURL: url).learned.isEmpty)
    }
}
