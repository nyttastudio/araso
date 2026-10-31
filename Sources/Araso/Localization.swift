import Foundation

/// The language UI text is shown in: `Settings.displayLanguage` when set, else the system's.
enum Localization {
    /// "en", "ko", or nil for the system's. Set from the settings before the UI is built.
    nonisolated(unsafe) static var language: String? {
        didSet { if language != oldValue { bundle = language.flatMap(bundle(for:)) } }
    }

    nonisolated(unsafe) private static var bundle: Bundle?

    private static func bundle(for language: String) -> Bundle? {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    static func string(_ key: String) -> String {
        if language == "en" { return key } // English is the keys themselves
        guard let bundle else { return NSLocalizedString(key, comment: "") }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The locale SwiftUI's own words (Cancel in a dialog) follow.
    static var locale: Locale { language.map(Locale.init(identifier:)) ?? .current }
}

/// The user's language for `key`: English is the key itself, Korean comes from
/// Resources/ko.lproj/Localizable.strings.
func L(_ key: String) -> String {
    Localization.string(key)
}

/// `L` with `%@`/`%d` arguments filled in.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: arguments)
}
