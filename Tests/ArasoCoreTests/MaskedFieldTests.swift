import Foundation
import Testing
@testable import ArasoCore

/// Masked password fields that reach the input method get the keys as typed (`MaskedField`).
@Suite struct MaskedFieldTests {
    let noCaret = NSRange(location: NSNotFound, length: 0)
    let kakao: Int32 = 501, appStore: Int32 = 502, terminal: Int32 = 503

    @Test func kakaoTalksMaskedFieldPassesKeys() {
        #expect(MaskedField.passesKeys(secureInput: true, owner: kakao, frontmost: kakao, caret: noCaret))
    }

    /// Shown as plain text, KakaoTalk's field lets Secure Event Input go: words are decided.
    @Test func thePlainFieldDecidesWords() {
        #expect(!MaskedField.passesKeys(secureInput: false, owner: nil, frontmost: kakao, caret: noCaret))
    }

    /// App Store's sheet is a PassKit extension; App Store, in front, holds Secure Event Input.
    @Test func appStoresSheetPassesKeys() {
        #expect(MaskedField.passesKeys(secureInput: true, owner: appStore, frontmost: appStore, caret: noCaret))
    }

    /// A terminal with Secure Keyboard Entry holds it but reports its caret.
    @Test func aTerminalWithSecureKeyboardEntryDecidesWords() {
        #expect(!MaskedField.passesKeys(secureInput: true, owner: terminal, frontmost: terminal,
                                        caret: NSRange(location: 42, length: 0)))
    }

    /// Held by an app behind the one being typed in: not this field's.
    @Test func secureInputHeldBehindDecidesWords() {
        #expect(!MaskedField.passesKeys(secureInput: true, owner: terminal, frontmost: kakao, caret: noCaret))
    }

    /// No owner to compare (the system didn't say): words are decided, as before.
    @Test func anUnknownOwnerDecidesWords() {
        #expect(!MaskedField.passesKeys(secureInput: true, owner: nil, frontmost: kakao, caret: noCaret))
        #expect(!MaskedField.passesKeys(secureInput: true, owner: kakao, frontmost: nil, caret: noCaret))
    }

    // MARK: Accessibility: fields that never turn Secure Event Input on (LINE's login, Qt 6)

    let secure: Set<String> = ["secure text field", "보안 텍스트 필드"]

    /// LINE's password field: no subrole, the secure role description in the app's language.
    @Test func linesPasswordFieldIsSecure() {
        #expect(MaskedField.isSecure(role: "AXTextField", subrole: nil, roleDescription: "secure text field", secureDescriptions: secure))
        #expect(MaskedField.isSecure(role: "AXTextField", subrole: nil, roleDescription: "보안 텍스트 필드", secureDescriptions: secure))
    }

    /// Its email field, beside it in the same view.
    @Test func linesEmailFieldIsNot() {
        #expect(!MaskedField.isSecure(role: "AXTextField", subrole: nil, roleDescription: "text field", secureDescriptions: secure))
    }

    /// A native secure field says so in its subrole, whatever its description.
    @Test func theSecureSubroleIsEnough() {
        #expect(MaskedField.isSecure(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: nil, secureDescriptions: []))
    }

    /// The description counts only on a text field, and an empty one never.
    @Test func otherRolesAndEmptyDescriptionsAreNot() {
        #expect(!MaskedField.isSecure(role: "AXTextArea", subrole: nil, roleDescription: "secure text field", secureDescriptions: secure))
        #expect(!MaskedField.isSecure(role: "AXTextField", subrole: nil, roleDescription: "", secureDescriptions: ["" ]))
        #expect(!MaskedField.isSecure(role: nil, subrole: nil, roleDescription: nil, secureDescriptions: secure))
    }

    @Test func descriptionsComeFromEveryLanguage() {
        let table: [String: Any] = [
            "English": ["AXSecureTextField": "secure text field", "AXTextField": "text field"],
            "ko": ["AXTextField:AXSecureTextField": "보안 텍스트 필드"],
            "LocProvenance": "x",
        ]
        #expect(MaskedField.secureDescriptions(loctable: table) == ["secure text field", "보안 텍스트 필드"])
    }

    /// This Mac's table, where there is one: English, Korean and Japanese are in it.
    @Test func thisMacsTableHasTheLanguages() throws {
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Resources/RoleDescriptions.loctable")
        guard let table = NSDictionary(contentsOf: url) as? [String: Any] else { return }
        let descriptions = MaskedField.secureDescriptions(loctable: table)
        #expect(descriptions.contains("secure text field"))
        #expect(descriptions.contains("보안 텍스트 필드"))
        #expect(descriptions.contains("セキュリティ保護されたテキストフィールド"))
    }
}
