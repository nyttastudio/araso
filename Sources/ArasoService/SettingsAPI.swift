import ArasoCore
import Foundation

/// What the Windows settings window shows, read from the same files the Mac app writes.
public struct SettingsModel: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var app: String
        /// Only what the entry names; the rest follows the default.
        public var entry: AppPolicy.Override
        /// The policy the app ends up with.
        public var policy: PolicyInfo
    }

    /// `AppPolicy` as plain values.
    public struct PolicyInfo: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var conversionThreshold: Double
        public var switchKeys: [SwitchKey]
        public var holdSpace: Bool
        public var fullWidth: Bool

        init(_ policy: AppPolicy) {
            enabled = policy.enabled
            conversionThreshold = policy.conversionThreshold
            switchKeys = SwitchKey.allCases.filter(policy.switchKeys.contains)
            holdSpace = policy.holdSpace
            fullWidth = policy.fullWidth
        }

        var policy: AppPolicy {
            AppPolicy(enabled: enabled, conversionThreshold: conversionThreshold, switchKeys: Set(switchKeys),
                      holdSpace: holdSpace, fullWidth: fullWidth)
        }
    }

    public struct Word: Codable, Equatable, Sendable {
        public var id: String
        public var keys: String
        /// `english`, `korean`, `mixed`, `japanese`, or nil for the user's own text.
        public var language: String?
        /// What the keys come out as.
        public var text: String
        /// `added`, `remembered` or `once`.
        public var status: String
        public var apps: [String]?
        /// Days until a word corrected once is forgotten.
        public var daysLeft: Int?
    }

    public var settings: Settings
    public var defaultPolicy: PolicyInfo
    public var apps: [App]
    public var words: [Word]
    public var version: String
    /// A newer release the last check found.
    public var update: ReleaseInfo?
    /// When the last update check ran (seconds since 1970), 0 when never.
    public var checked: Double
    /// Strict's threshold, so the window doesn't hard-code it.
    public var strictThreshold: Double
}

/// A change from the settings window. One of the fields is set.
public struct SettingsChange: Codable, Equatable, Sendable {
    public var settings: Settings?
    public var defaultPolicy: SettingsModel.PolicyInfo?
    /// With `entry`: sets exactly what the app's entry names (an app is added this way, with `{}`).
    public var app: String?
    public var entry: AppPolicy.Override?
    public var removeApp: String?
    public var addWord: UserDictionary.Entry?
    /// The id of the word to replace (an edit), when `addWord` changes one.
    public var replacing: String?
    public var removeWord: String?
    public var keepWord: String?
    public var forgetLearned: Bool?
    public var resetKanji: Bool?
    /// The updater's last check, from the host.
    public var checked: Double?

    public init() {}
}

/// A release as the window and the updater need it.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    public var installer: String
    public var page: String?
    /// The notes' first section, each item split into its bold title and the rest.
    public var notes: [Note]
    public var newer: Bool

    public struct Note: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String?
    }

    init(_ release: Release, current: String) {
        version = release.version
        installer = release.package.absoluteString
        page = release.page?.absoluteString
        notes = release.notes.map { Release.headline(of: $0) }.map { Note(title: $0.title, detail: $0.detail) }
        newer = Release.isNewer(release.version, than: current)
    }
}

/// What the last update check found and when, shared by the host and the settings window
/// (`update.json` in the settings folder; the Mac app keeps the same in its user defaults).
public enum UpdateStore {
    /// The release asset Windows installs (Linux's is named by the addon: `Configuration.asset`).
    public static let asset = "Araso-Setup.exe"

    struct Stored: Codable {
        var checked: Double
        var body: String?
    }

    static var url: URL? { SupportDirectory.url?.appendingPathComponent("update.json") }

    static func read() -> Stored? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// Keeps GitHub's answer (nil: the check failed, only its time is kept with the last answer).
    static func write(body: String?, checked: Double) {
        guard let url else { return }
        let stored = Stored(checked: checked, body: body ?? read()?.body)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }

    /// The newer release the last check found, if any.
    static func available(current: String, asset: String = asset) -> ReleaseInfo? {
        guard let body = read()?.body, let release = Release(gitHubJSON: Data(body.utf8), asset: asset) else { return nil }
        let info = ReleaseInfo(release, current: current)
        return info.newer ? info : nil
    }
}

/// `replacements.json` in the settings folder: Windows has no system list of text replacements, so
/// Araso keeps its own, in the shape of macOS's (`{ "주소": ["서울시 …"], "よろ": ["よろしく"] }`).
/// Read again when the file changes.
public final class TextReplacementFile: @unchecked Sendable {
    private var cached: (stamp: Date, entries: [String: [String]])?

    public init() {}

    static var url: URL? { SupportDirectory.url?.appendingPathComponent("replacements.json") }

    public var entries: [String: [String]] {
        guard let url = Self.url,
              let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return [:] }
        if let cached, cached.stamp == stamp { return cached.entries }
        var entries: [String: [String]] = [:]
        if let data = try? Data(contentsOf: url),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (shortcut, value) in object where !shortcut.isEmpty {
                if let phrase = value as? String { entries[shortcut] = [phrase] }
                if let phrases = value as? [String], !phrases.isEmpty { entries[shortcut] = phrases }
            }
        }
        cached = (stamp, entries)
        return entries
    }
}
