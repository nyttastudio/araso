import Foundation

/// A key that switches the word being typed, or the one just committed, to its next reading.
/// A key not chosen for an app goes to that app.
public enum SwitchKey: String, Codable, CaseIterable, Sendable {
    /// Right ⌥ pressed and released on its own. Apps ignore a lone modifier, so unlike Esc it
    /// never closes a window (Chromium apps also see an Esc the input method took).
    case rightOption
    /// ⌥Space (which otherwise types a no-break space).
    case optionSpace
    /// Right ⇧ pressed and released on its own.
    case rightShift
    /// Esc. While a word is being typed or was just committed; otherwise Esc goes to the app.
    case escape
    /// ⇧Esc. Dropped when there is nothing to change, never passed to the app.
    case shiftEscape

    /// In this enum's order, so a saved file doesn't change from one save to the next.
    static func list(_ keys: Set<SwitchKey>) -> [SwitchKey] { allCases.filter(keys.contains) }
}

/// How eagerly Araso converts in a given app.
public struct AppPolicy: Codable, Equatable, Sendable {
    /// When false, Araso passes every key through (plain English typing).
    public var enabled: Bool
    /// Convert away from the typed English letters only when the engine is at least
    /// this confident. On the held-out set, raising it above 0.5 left more Korean
    /// words as letters without catching more wrong conversions, so it only pays
    /// off where a wrong conversion is expensive (terminals, editors).
    public var conversionThreshold: Double
    /// The keys that switch the word's language here; the others go to the app. (Inside a vim
    /// that reports its modes, Esc is vim's whatever this says.)
    public var switchKeys: Set<SwitchKey>
    /// Space or a symbol doesn't end the word but goes inside the underline too. Held there, it is
    /// still the word being typed: a switch key changes it, Delete deletes (the boundary first), and
    /// the next word puts it in with that character. For terminals, which can't hand a committed
    /// word back for a change. The app then never sees the Space key, so its text replacements
    /// don't fire. (Named for the Space it started with; the key stays for existing `apps.json`.)
    public var holdSpace: Bool
    /// Full-width digits and spaces after Japanese (when turned on in the settings) apply here;
    /// false keeps them half-width in this app (a terminal, a code editor).
    public var fullWidth: Bool
    /// Japanese in this app, on or off whatever the Languages tab says; nil follows it
    /// (`Settings.japanese`). Off, words are decided between Korean and English only, as with
    /// Japanese off everywhere. Only an app's entry sets it: the Languages tab is the default.
    public var japanese: Bool?

    public static let standardSwitchKeys: Set<SwitchKey> = [.rightOption, .shiftEscape]

    public init(enabled: Bool = true, conversionThreshold: Double = 0.5,
                switchKeys: Set<SwitchKey> = AppPolicy.standardSwitchKeys, holdSpace: Bool = false,
                fullWidth: Bool = true, japanese: Bool? = nil) {
        self.enabled = enabled
        self.conversionThreshold = conversionThreshold
        self.switchKeys = switchKeys
        self.holdSpace = holdSpace
        self.fullWidth = fullWidth
        self.japanese = japanese
    }

    /// Whether Japanese is on here, given the Languages tab's setting.
    public func japanese(default japaneseOn: Bool) -> Bool { japanese ?? japaneseOn }

    public static let standard = AppPolicy()
    /// The "strict" choice: convert only when quite sure (short shell commands and identifiers
    /// collide with Hangul easily).
    public static let strictThreshold = 0.97

    /// An `apps.json` entry: only the keys it names replace the default policy, so
    /// `{"conversionThreshold": 0.97}` keeps whatever the default says about the switch keys.
    public struct Override: Codable, Equatable, Sendable {
        public var enabled: Bool?
        public var conversionThreshold: Double?
        public var switchKeys: Set<SwitchKey>?
        public var holdSpace: Bool?
        public var fullWidth: Bool?
        public var japanese: Bool?
        /// 0.1.8 and earlier: true sent Esc to the app, false made it switch. Read for an entry
        /// that doesn't name `switchKeys`, as a change to the default's Esc, and kept until it does.
        var escapeToApp: Bool?

        public init(enabled: Bool? = nil, conversionThreshold: Double? = nil, switchKeys: Set<SwitchKey>? = nil,
                    holdSpace: Bool? = nil, fullWidth: Bool? = nil, japanese: Bool? = nil) {
            self.enabled = enabled
            self.conversionThreshold = conversionThreshold
            self.switchKeys = switchKeys
            self.holdSpace = holdSpace
            self.fullWidth = fullWidth
            self.japanese = japanese
        }

        /// The keys of `policy` that differ from `base`.
        init(difference policy: AppPolicy, from base: AppPolicy) {
            self.init(enabled: policy.enabled == base.enabled ? nil : policy.enabled,
                      conversionThreshold: policy.conversionThreshold == base.conversionThreshold ? nil : policy.conversionThreshold,
                      switchKeys: policy.switchKeys == base.switchKeys ? nil : policy.switchKeys,
                      holdSpace: policy.holdSpace == base.holdSpace ? nil : policy.holdSpace,
                      fullWidth: policy.fullWidth == base.fullWidth ? nil : policy.fullWidth,
                      japanese: policy.japanese == base.japanese ? nil : policy.japanese)
        }

        public func applied(to base: AppPolicy) -> AppPolicy {
            var keys = switchKeys ?? base.switchKeys
            if switchKeys == nil, let escapeToApp {
                if escapeToApp { keys.remove(.escape) } else { keys.insert(.escape) }
            }
            return AppPolicy(enabled: enabled ?? base.enabled,
                             conversionThreshold: conversionThreshold ?? base.conversionThreshold,
                             switchKeys: keys,
                             holdSpace: holdSpace ?? base.holdSpace,
                             fullWidth: fullWidth ?? base.fullWidth,
                             japanese: japanese ?? base.japanese)
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, conversionThreshold, switchKeys, holdSpace, fullWidth, japanese, escapeToApp
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A value of the wrong type ("0.97" for 0.97) is left out, as if the entry didn't
            // name it, rather than failing the whole file.
            func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
            enabled = value(.enabled)
            conversionThreshold = value(.conversionThreshold)
            // A later version's key is skipped rather than failing the whole file.
            switchKeys = (value(.switchKeys) as [String]?).map { Set($0.compactMap(SwitchKey.init(rawValue:))) }
            holdSpace = value(.holdSpace)
            fullWidth = value(.fullWidth)
            japanese = value(.japanese)
            escapeToApp = value(.escapeToApp)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(enabled, forKey: .enabled)
            try c.encodeIfPresent(conversionThreshold, forKey: .conversionThreshold)
            try c.encodeIfPresent(switchKeys.map(SwitchKey.list), forKey: .switchKeys)
            try c.encodeIfPresent(holdSpace, forKey: .holdSpace)
            try c.encodeIfPresent(fullWidth, forKey: .fullWidth)
            try c.encodeIfPresent(japanese, forKey: .japanese)
            // The 0.1.8 key stays until the entry names its own switch keys.
            if switchKeys == nil { try c.encodeIfPresent(escapeToApp, forKey: .escapeToApp) }
        }
    }
}

/// Picks the policy for an app from `~/Library/Application Support/Araso/apps.json`:
/// the `"*"` entry is the user's default, and an app's entry changes only the keys it names.
/// Keys ending in "." match as a prefix (e.g. "com.jetbrains."). No app is listed unless the
/// user lists it.
public struct AppPolicies: Sendable {
    public var overrides: [String: AppPolicy.Override]

    /// The `apps.json` key of the default policy.
    public static let defaultKey = "*"

    public init(overrides: [String: AppPolicy.Override] = [:]) {
        self.overrides = overrides
    }

    public static var storeURL: URL? {
        SupportDirectory.url?.appendingPathComponent("apps.json")
    }

    /// Loads user overrides; a missing file means none. An entry that isn't an object is left
    /// out, and a file that isn't a JSON object is set aside as apps.json.unreadable, so the next
    /// save doesn't write over the user's entries.
    public static func load(from url: URL? = AppPolicies.storeURL) -> AppPolicies {
        guard let url, let data = try? Data(contentsOf: url) else { return AppPolicies() }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            SupportDirectory.setAside(url)
            return AppPolicies()
        }
        var overrides: [String: AppPolicy.Override] = [:]
        for (id, entry) in object {
            guard let json = try? JSONSerialization.data(withJSONObject: entry, options: .fragmentsAllowed),
                  let override = try? JSONDecoder().decode(AppPolicy.Override.self, from: json) else { continue }
            overrides[id] = override
        }
        return AppPolicies(overrides: overrides)
    }

    /// What every app uses unless its own entry says otherwise.
    public var defaultPolicy: AppPolicy {
        // The default's Japanese is the Languages tab's: a "*" entry naming it is left out.
        var policy = overrides[Self.defaultKey]?.applied(to: .standard) ?? .standard
        policy.japanese = nil
        return policy
    }

    /// The apps the user listed (the default entry excluded).
    public var apps: [String] {
        overrides.keys.filter { $0 != Self.defaultKey }.sorted()
    }

    /// Whether some app turns Japanese on itself: the Japanese model and converter are needed even
    /// with it off in the Languages tab.
    public var turnsJapaneseOn: Bool {
        overrides.contains { $0.key != Self.defaultKey && $0.value.japanese == true }
    }

    /// Whether Japanese is on somewhere, given the Languages tab's setting: there, or in an app of
    /// its own. What its options (live conversion, romaji layout, full width) and a dictionary entry
    /// for every app go by.
    public func japaneseUsed(default japaneseOn: Bool) -> Bool { japaneseOn || turnsJapaneseOn }

    public func policy(for bundleIdentifier: String?) -> AppPolicy {
        let base = defaultPolicy
        guard let id = bundleIdentifier, id != Self.defaultKey else { return base }
        return Self.lookup(id, in: overrides.filter { $0.key != Self.defaultKey })?.applied(to: base) ?? base
    }

    /// Sets the default, naming only what differs from Araso's own.
    public mutating func setDefault(_ policy: AppPolicy) {
        var policy = policy
        policy.japanese = nil // the Languages tab's
        let entry = AppPolicy.Override(difference: policy, from: .standard)
        overrides[Self.defaultKey] = entry == AppPolicy.Override() ? nil : entry
    }

    /// Sets exactly which keys the app's entry names (nil: follows the default); the app stays
    /// listed even when it names none.
    public mutating func setEntry(_ entry: AppPolicy.Override, for bundleIdentifier: String) {
        guard bundleIdentifier != Self.defaultKey else { return }
        overrides[bundleIdentifier] = entry
    }

    /// Lists the app (if it wasn't) and makes it behave as `policy`, naming only the keys that
    /// differ from the default, so the rest keeps following it. The entry stays even when
    /// nothing differs: the user added the app, only removing it takes it off the list.
    public mutating func set(_ policy: AppPolicy, for bundleIdentifier: String) {
        guard bundleIdentifier != Self.defaultKey else { return setDefault(policy) }
        overrides[bundleIdentifier] = AppPolicy.Override(difference: policy, from: defaultPolicy)
    }

    /// Writes the entries to `apps.json`. Callers load, change and save, so entries for other
    /// apps are kept as they were.
    public func save(to url: URL? = AppPolicies.storeURL) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(overrides).write(to: url, options: .atomic)
    }

    /// Builds between 0.1.8 and 0.1.9 (no release) kept one extra switch key in settings.json
    /// (`"switchKey"`), on top of Esc and ⇧Esc.
    /// Moves it into the default's `switchKeys` (unless the default names its own) and takes it
    /// out of settings.json. Running it again, or in two processes at once, changes nothing more.
    public static func migrateSwitchKey(settings: URL? = Settings.storeURL, apps: URL? = AppPolicies.storeURL) {
        guard let settings, let data = try? Data(contentsOf: settings),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let old = object["switchKey"] else { return }
        var policies = load(from: apps)
        if policies.overrides[defaultKey]?.switchKeys == nil {
            var keys: Set<SwitchKey>
            switch old as? String {
            case "off": keys = [.escape, .shiftEscape] // "Esc only"
            case let name?: keys = [SwitchKey(rawValue: name) ?? .rightOption, .shiftEscape]
            case nil: keys = AppPolicy.standardSwitchKeys
            }
            if policies.overrides[defaultKey]?.escapeToApp == true { keys.remove(.escape) }
            if keys != AppPolicy.standardSwitchKeys {
                var entry = policies.overrides[defaultKey] ?? AppPolicy.Override()
                entry.switchKeys = keys
                policies.overrides[defaultKey] = entry
                guard (try? policies.save(to: apps)) != nil else { return }
            }
        }
        object["switchKey"] = nil
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: settings, options: .atomic)
    }

    /// The exact entry, else the longest prefix that matches (com.jetbrains. over com.).
    private static func lookup<T>(_ id: String, in table: [String: T]) -> T? {
        if let exact = table[id] { return exact }
        return table.filter { $0.key.hasSuffix(".") && id.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?.value
    }
}
