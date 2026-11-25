import Foundation

/// A masked password field that still reaches the input method (KakaoTalk's login, App Store's
/// password sheet, LINE's login). Asked to show marked text while handling a key, KakaoTalk's
/// types that key itself (lowercase when ⇧ was already down) and drops what the input method
/// inserts; App Store's loses keys; LINE's (Qt) takes the composed Hangul as the password. Its
/// keys go to the app as typed, as when paused.
public enum MaskedField {
    /// Whether the focused field is one: Secure Event Input is on, held by the frontmost app,
    /// and the field reports no caret.
    /// - The frontmost app, not the client's: App Store's sheet is a PassKit extension while
    ///   App Store holds Secure Event Input. An app behind the one being typed in doesn't count.
    /// - A terminal with Secure Keyboard Entry holds it too, but reports its caret.
    /// - `owner` is `kCGSSessionSecureInputPID`, `frontmost` the frontmost app's process.
    public static func passesKeys(secureInput: Bool, owner: Int32?, frontmost: Int32?, caret: NSRange) -> Bool {
        guard secureInput, caret.location == NSNotFound, let owner else { return false }
        return owner == frontmost
    }

    /// Whether the focused element, as Accessibility describes it, is a secure text field. For
    /// fields that never turn Secure Event Input on and answer the input method as any field
    /// does, text and caret included: LINE's login (Qt 6) reports no subrole, only the role
    /// description of `AXTextField` + `AXSecureTextField`, in the app's language
    /// (`secureDescriptions` holds every language's).
    public static func isSecure(role: String?, subrole: String?, roleDescription: String?,
                                secureDescriptions: Set<String>) -> Bool {
        if subrole == secureSubrole { return true }
        guard role == "AXTextField", let roleDescription, !roleDescription.isEmpty else { return false }
        return secureDescriptions.contains(roleDescription)
    }

    public static let secureSubrole = "AXSecureTextField"

    /// The role descriptions a secure text field has in every language, from HIServices'
    /// `RoleDescriptions.loctable` (language → key → text): the keys `AXTextField:AXSecureTextField`
    /// and `AXSecureTextField`.
    public static func secureDescriptions(loctable: [String: Any]) -> Set<String> {
        var descriptions: Set<String> = []
        for case let table as [String: Any] in loctable.values {
            for key in ["AXTextField:\(secureSubrole)", secureSubrole] {
                if let text = table[key] as? String, !text.isEmpty { descriptions.insert(text) }
            }
        }
        return descriptions
    }
}
