import Foundation
import Testing
@testable import ArasoCore

/// Japanese on or off per app (`AppPolicy.japanese`), whatever the Languages tab says.
@MainActor @Suite struct AppJapaneseTests {
    func session(japanese: Bool, apps: [String: AppPolicy.Override]) -> InputSession {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("araso-appja-\(UUID().uuidString).json")
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                      english: trilingual.english, korean: trilingual.korean, japaneseParticles: true, storeURL: store)
        return InputSession(engine: engine, policies: AppPolicies(overrides: apps), converter: FakeConverter(), japaneseEnabled: japanese)
    }

    func typed(_ s: String, in session: InputSession) -> String {
        let field = FakeTextField()
        for ch in s {
            let handled = ch.isLetter ? session.handle(.letter(ch), client: field) : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
        return field.text
    }

    @Test func entryReadsAndWritesJapanese() throws {
        let json = #"{"japanese": false, "conversionThreshold": 0.97}"#.data(using: .utf8)!
        let entry = try JSONDecoder().decode(AppPolicy.Override.self, from: json)
        #expect(entry.japanese == false)
        let back = try JSONDecoder().decode(AppPolicy.Override.self, from: JSONEncoder().encode(entry))
        #expect(back == entry)
        // An entry of an older version names no japanese: the app follows the Languages tab.
        let old = try JSONDecoder().decode(AppPolicy.Override.self, from: #"{"holdSpace": true}"#.data(using: .utf8)!)
        #expect(old.japanese == nil)
        #expect(AppPolicies(overrides: ["x": old]).policy(for: "x").japanese(default: true))
        #expect(!AppPolicies(overrides: ["x": old]).policy(for: "x").japanese(default: false))
    }

    @Test func setNamesJapaneseOnlyWhenTheAppDiffers() {
        var policies = AppPolicies()
        var policy = policies.policy(for: "com.apple.dt.Xcode")
        policy.japanese = false
        policies.set(policy, for: "com.apple.dt.Xcode")
        #expect(policies.overrides["com.apple.dt.Xcode"]?.japanese == false)
        #expect(!policies.turnsJapaneseOn)
        policies.set(AppPolicy(japanese: true), for: "jp.naver.line.mac")
        #expect(policies.turnsJapaneseOn)
    }

    /// Japanese on in the Languages tab, off in Xcode: there the words are Korean or English only.
    @Test func appTurnsJapaneseOff() {
        let s = session(japanese: true, apps: ["com.apple.dt.Xcode": AppPolicy.Override(japanese: false)])
        s.activate(app: "com.apple.dt.Xcode")
        #expect(!s.japaneseEnabled)
        #expect(s.converter == nil)
        let text = typed("kyouha dkssud ", in: s)
        #expect(!text.contains { ("\u{3040}"..."\u{30FF}").contains($0) }, "\(text)")
        #expect(text.contains("안녕"))
        // The same session in another app types Japanese again.
        s.activate(app: "com.apple.Safari")
        #expect(s.japaneseEnabled)
        #expect(typed("kyouha", in: s) == "きょうは")
    }

    /// Japanese off in the Languages tab, on in LINE.
    @Test func appTurnsJapaneseOn() {
        let s = session(japanese: false, apps: ["jp.naver.line.mac": AppPolicy.Override(japanese: true)])
        s.activate(app: "com.apple.Safari")
        #expect(!s.japaneseEnabled)
        #expect(!typed("kyouha ", in: s).contains("き"))
        s.activate(app: "jp.naver.line.mac")
        #expect(s.japaneseEnabled)
        #expect(typed("kyouha", in: s) == "きょうは")
    }

    /// A Japanese particle after an English word is no reading where Japanese is off.
    @Test func noJapaneseParticleWhereOff() {
        let s = session(japanese: true, apps: ["com.apple.dt.Xcode": AppPolicy.Override(japanese: false)])
        s.activate(app: "com.apple.dt.Xcode")
        let text = typed("githubde ", in: s)
        #expect(!text.contains("で"), "\(text)")
    }

    /// The cycle a switch key goes round has no Japanese where it is off.
    @Test func switchKeySkipsJapaneseWhereOff() {
        let s = session(japanese: true, apps: ["com.apple.dt.Xcode": AppPolicy.Override(japanese: false)])
        s.activate(app: "com.apple.dt.Xcode")
        let field = FakeTextField()
        for ch in "sushi" { _ = s.handle(.letter(ch), client: field) }
        for _ in 0..<3 {
            _ = s.handle(.cycle, client: field)
            #expect(!field.text.contains("す"), "\(field.text)")
        }
    }
}
