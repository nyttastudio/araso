import Foundation

/// User settings from `~/Library/Application Support/Araso/settings.json`:
///
///     { "japanese": true, "liveConversion": true }
///
/// A missing file or key means the default, and so does a value of the wrong type; unknown keys
/// are ignored (and kept on save). A file that isn't JSON is set aside as settings.json.unreadable.
public struct Settings: Codable, Equatable, Sendable {
    /// Detect romaji Japanese and convert it (kana preview, Space for kanji).
    public var japanese: Bool = false
    /// With Japanese on: show (and commit) the top kanji candidate while typing, like macOS
    /// Live Conversion. Space opens the other candidates, Esc shows the kana.
    public var liveConversion: Bool = false
    /// The key that pauses Araso in the text field (keys go through as typed) and resumes it.
    /// Builds before 0.1.15 had only right ⌘, turned off with `"rightCommandPause": false`.
    public var pauseKey: PauseKey = .standard
    /// Return on an underlined word only confirms it, like a Japanese IME; off, the app gets the
    /// Return too (a Japanese phrase is still only confirmed).
    public var returnConfirmsOnly: Bool = true
    /// Once a day, ask GitHub for the latest release's version (nothing else is sent), and offer
    /// it in the input menu and About when it is newer.
    public var checkForUpdates: Bool = true
    /// Kanji conversion: "apple", macOS's own Japanese engine (AzooKey where it can't be loaded),
    /// or "azooKey".
    public var japaneseEngine: String = "apple"
    /// With Japanese on: digits after Japanese text are part of it, full-width (１２３); Space offers 123.
    public var fullWidthDigits: Bool = false
    /// With Japanese on: a space after Japanese text is full-width (⇧Space types the other width).
    public var fullWidthSpace: Bool = false
    /// The layout English and romaji are typed on: "qwerty", "colemak" or "colemakDH". Korean
    /// 2-set stays on its keys either way (`LatinLayout`).
    public var latinLayout: LatinLayout = .qwerty
    /// The layout Korean is typed on: "dubeolsik", "sebeolsikFinal" or "sebeolsik390" (`KoreanLayout`).
    public var koreanLayout: KoreanLayout = .dubeolsik
    /// The layout romaji is typed on, when not English's (`latinLayout`): absent follows it.
    public var japaneseLayout: LatinLayout?
    /// The language of the settings window, the input menu and the rest of the UI: "en" or "ko";
    /// absent follows the system's.
    public var displayLanguage: String?

    public init(japanese: Bool = false, liveConversion: Bool = false, pauseKey: PauseKey = .standard,
                returnConfirmsOnly: Bool = true, checkForUpdates: Bool = true, japaneseEngine: String = "apple",
                fullWidthDigits: Bool = false, fullWidthSpace: Bool = false, latinLayout: LatinLayout = .qwerty,
                koreanLayout: KoreanLayout = .dubeolsik, japaneseLayout: LatinLayout? = nil,
                displayLanguage: String? = nil) {
        self.displayLanguage = displayLanguage
        self.latinLayout = latinLayout
        self.koreanLayout = koreanLayout
        self.japaneseLayout = japaneseLayout
        self.fullWidthDigits = fullWidthDigits
        self.fullWidthSpace = fullWidthSpace
        self.japanese = japanese
        self.liveConversion = liveConversion
        self.pauseKey = pauseKey
        self.returnConfirmsOnly = returnConfirmsOnly
        self.checkForUpdates = checkForUpdates
        self.japaneseEngine = japaneseEngine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One value of the wrong type ("true" for true) is that key's default, not the whole file's.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        japanese = value(.japanese, false)
        liveConversion = value(.liveConversion, false)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let rightCommandPause = ((try? legacy?.decodeIfPresent(Bool.self, forKey: .rightCommandPause)) ?? nil) ?? true
        pauseKey = value(.pauseKey, rightCommandPause ? .standard : .off)
        returnConfirmsOnly = value(.returnConfirmsOnly, true)
        checkForUpdates = value(.checkForUpdates, true)
        japaneseEngine = value(.japaneseEngine, "apple")
        fullWidthDigits = value(.fullWidthDigits, false)
        fullWidthSpace = value(.fullWidthSpace, false)
        latinLayout = value(.latinLayout, .qwerty)
        koreanLayout = value(.koreanLayout, .dubeolsik)
        japaneseLayout = value(.japaneseLayout, nil as LatinLayout?)
        displayLanguage = value(.displayLanguage, nil as String?)
    }

    private enum LegacyKeys: String, CodingKey { case rightCommandPause }

    public static var storeURL: URL? {
        SupportDirectory.url?.appendingPathComponent("settings.json")
    }

    public static func load(from url: URL? = Settings.storeURL) -> Settings {
        guard let url, let data = try? Data(contentsOf: url) else { return Settings() }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            SupportDirectory.setAside(url)
            return Settings()
        }
        return settings
    }

    /// Writes these values over the file's, keeping any keys this version doesn't know.
    public func save(to url: URL? = Settings.storeURL) throws {
        guard let url else { return }
        var object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        object.merge(mine) { _, new in new }
        object[LegacyKeys.rightCommandPause.rawValue] = nil // now in pauseKey
        if japaneseLayout == nil { object[CodingKeys.japaneseLayout.stringValue] = nil } // follows English again
        if displayLanguage == nil { object[CodingKeys.displayLanguage.stringValue] = nil } // follows the system again
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
