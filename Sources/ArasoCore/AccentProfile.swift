import Foundation

/// User-editable language groups. Candidate order follows group and row order.
public struct AccentProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var rules: [AccentRule]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, rules: [AccentRule] = []) {
        self.id = id; self.name = name; self.enabled = enabled; self.rules = rules
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rules.isEmpty && rules.allSatisfy(\.isValid)
            && Set(rules.map(\.key)).count == rules.count
    }

    public static let german = AccentProfile(
        id: UUID(uuidString: "EE41CCAF-754A-47D2-8AC3-C31CD926F001")!, name: "Deutsch",
        rules: [.init(key: "a", lower: "ä", upper: "Ä"), .init(key: "o", lower: "ö", upper: "Ö"),
                .init(key: "u", lower: "ü", upper: "Ü"), .init(key: "s", lower: "ß", upper: "ẞ")])

    public static var presets: [AccentProfile] {
        [german,
         .init(name: "Français", rules: [.init(key: "a", lower: "àâ", upper: "ÀÂ"), .init(key: "c", lower: "ç", upper: "Ç"),
            .init(key: "e", lower: "éèêë", upper: "ÉÈÊË"), .init(key: "i", lower: "îï", upper: "ÎÏ"),
            .init(key: "o", lower: "ôœ", upper: "ÔŒ"), .init(key: "u", lower: "ùûü", upper: "ÙÛÜ"), .init(key: "y", lower: "ÿ", upper: "Ÿ")]),
         .init(name: "Español", rules: [.init(key: "a", lower: "á", upper: "Á"), .init(key: "e", lower: "é", upper: "É"),
            .init(key: "i", lower: "í", upper: "Í"), .init(key: "n", lower: "ñ", upper: "Ñ"),
            .init(key: "o", lower: "ó", upper: "Ó"), .init(key: "u", lower: "úü", upper: "ÚÜ")]),
         .init(name: "Português", rules: [.init(key: "a", lower: "áàâã", upper: "ÁÀÂÃ"), .init(key: "c", lower: "ç", upper: "Ç"),
            .init(key: "e", lower: "éê", upper: "ÉÊ"), .init(key: "i", lower: "í", upper: "Í"),
            .init(key: "o", lower: "óôõ", upper: "ÓÔÕ"), .init(key: "u", lower: "ú", upper: "Ú")]),
         .init(name: "Nordic", rules: [.init(key: "a", lower: "åäæ", upper: "ÅÄÆ"), .init(key: "o", lower: "öø", upper: "ÖØ")])]
    }

    public static func candidates(for letter: Character, profiles: [AccentProfile]) -> [Character] {
        guard letter.isASCII, letter.isLetter else { return [] }
        let key = String(letter).lowercased()
        var seen = Set<Character>()
        return profiles.filter(\.enabled).flatMap(\.rules).filter { $0.isValid && $0.key == key }
            .flatMap { Array(letter.isUppercase ? $0.upper : $0.lower) }
            .filter { seen.insert($0).inserted }
    }
}

public struct AccentRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    public var lower: String
    public var upper: String

    public init(id: UUID = UUID(), key: String = "", lower: String = "", upper: String = "") {
        self.id = id; self.key = key; self.lower = lower; self.upper = upper
    }

    /// One visible grapheme per candidate; no spaces, controls, or multi-letter expansions.
    public static func isCandidate(_ character: Character) -> Bool {
        !character.isWhitespace && character.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }
    }

    public var isValid: Bool {
        key.count == 1 && key.first?.isASCII == true && key.first?.isLowercase == true
            && key.first?.isLetter == true && !(lower + upper).isEmpty
            && (lower + upper).allSatisfy(Self.isCandidate)
    }
}
