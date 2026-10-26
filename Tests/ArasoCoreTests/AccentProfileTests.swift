import Foundation
import Testing
@testable import ArasoCore

@Suite struct AccentProfileTests {
    @Test func presetsAreValid() {
        let valid = AccentProfile.presets.allSatisfy { $0.isValid }
        #expect(valid)
    }

    @Test func mergeDisableEditDeleteAndCase() {
        var profiles = [AccentProfile.german,
            AccentProfile(name: "Custom", rules: [.init(key: "a", lower: "äàá", upper: "ÄÀÁ")])]
        #expect(AccentProfile.candidates(for: "a", profiles: profiles) == Array("äàá"))
        #expect(AccentProfile.candidates(for: "A", profiles: profiles) == Array("ÄÀÁ"))
        profiles[0].enabled = false
        profiles[1].rules[0].lower = "åæ"
        #expect(AccentProfile.candidates(for: "a", profiles: profiles) == Array("åæ"))
        profiles.removeLast()
        #expect(AccentHold(letter: "a", keyCode: 0, profiles: profiles) == nil)
        profiles.removeAll()
        #expect(AccentHold(letter: "A", keyCode: 0, profiles: profiles) == nil)
    }

    @Test func settingsMigrationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"japanese":true}"#.utf8))
        #expect(old.japanese)
        #expect(old.accentProfiles == [.german])
        var settings = old
        settings.accentProfiles = AccentProfile.presets
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.save(to: url)
        #expect(Settings.load(from: url) == settings)
        settings.accentProfiles = []
        try settings.save(to: url)
        #expect(Settings.load(from: url).accentProfiles.isEmpty)
        #expect(Settings.load(from: url).japanese)
    }

    @Test func validationAndCanonicalDuplicates() {
        #expect(!AccentRule(key: "ab", lower: "ä").isValid)
        #expect(!AccentRule(key: "A", lower: "ä").isValid)
        #expect(!AccentRule(key: "a", lower: "ä ö").isValid)
        #expect(!AccentRule(key: "a", lower: "\n").isValid)
        #expect(!AccentRule(key: "a", lower: "\u{202E}").isValid)
        #expect(!AccentRule(key: "a").isValid)
        #expect(AccentRule(key: "a", upper: "Á").isValid)
        let custom = AccentProfile(name: "Marks", rules: [.init(key: "e", lower: "ée\u{301}", upper: "É")])
        #expect(AccentProfile.candidates(for: "e", profiles: [custom]) == ["é"])
        #expect(!AccentProfile(name: "", rules: custom.rules).isValid)
        #expect(!AccentProfile(name: "duplicate", rules: custom.rules + custom.rules).isValid)
    }

    @Test func pagingSelectionAndSnapshot() {
        var profiles = [AccentProfile(name: "Many", rules: [.init(key: "a", lower: "àáâãäåāăąǎǟǡ", upper: "À")])]
        var hold = AccentHold(letter: "a", keyCode: 0, profiles: profiles)!
        profiles[0].rules.removeAll() // an open menu keeps the candidates it originally showed
        #expect(hold.candidates.count == 12)
        #expect(hold.page == 0..<9)
        hold.move(-1)
        #expect(hold.selected == 11 && hold.page == 9..<12)
        hold.movePage(1)
        #expect(hold.selected == 0)
        hold.movePage(-1)
        #expect(hold.selected == 9)
        let invalid = hold.select(12)
        #expect(!invalid && hold.selected == 9)
        let valid = hold.select(10)
        #expect(valid && hold.accent == "ǟ")
        hold.movePage(1)
        #expect(hold.selected == 0)
    }
}

extension AccentSessionTests {
    @Test(arguments: ["é", "ñ", "ç", "ø", "œ", "Ł", "č", "e\u{301}"])
    func customCharactersKeepLatinWord(character: String) {
        type("test")
        session.insertAccent(character.first!, client: field)
        type("word ")
        #expect(field.text == "test" + character + "word ")
        type("dkssud hello ")
        #expect(field.text.hasSuffix("안녕 hello "))
    }
}
