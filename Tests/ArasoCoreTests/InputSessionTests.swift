import Foundation
import Testing
@testable import ArasoCore

extension AppPolicies {
    /// Esc switches languages, as the tests of Esc cycling need (the default leaves Esc to the app).
    static let escSwitches = AppPolicies(overrides: [defaultKey: .init(switchKeys: [.escape, .shiftEscape])])
}

/// A text field: committed text, an optional marked (underlined) span, and a caret.
final class FakeTextField: TextClient {
    var text = ""
    var marked = NSRange(location: NSNotFound, length: 0)
    var cursor = 0
    /// Simulates apps that don't support reading back their text.
    var readable = true
    /// Every text the input method inserted, in order: a held word must go in with its boundary in one.
    var insertions: [String] = []
    /// The clause being converted, as the input method last marked it (nil: plain marked text).
    var selectedClause: NSRange?
    /// False for a field whose composition is always at the caret (fcitx5).
    var marksAnywhere = true

    func setMarkedText(_ s: String, selectedClause: NSRange, replacing range: NSRange?) {
        if let range { setMarkedText(s, replacing: range) } else { setMarkedText(s) }
        self.selectedClause = selectedClause
    }

    func setMarkedText(_ s: String) {
        selectedClause = nil
        let ns = text as NSString
        let target = marked.location != NSNotFound ? marked : NSRange(location: cursor, length: 0)
        text = ns.replacingCharacters(in: target, with: s)
        let length = (s as NSString).length
        marked = length > 0 ? NSRange(location: target.location, length: length) : NSRange(location: NSNotFound, length: 0)
        cursor = target.location + length
    }

    func setMarkedText(_ s: String, replacing range: NSRange) {
        selectedClause = nil
        let ns = text as NSString
        let target = marked.location != NSNotFound ? NSUnionRange(range, marked) : range
        text = ns.replacingCharacters(in: target, with: s)
        let length = (s as NSString).length
        marked = length > 0 ? NSRange(location: target.location, length: length) : NSRange(location: NSNotFound, length: 0)
        cursor = target.location + length
    }

    func insertText(_ s: String, replacing range: NSRange?) {
        insertions.append(s)
        selectedClause = nil
        let target = range ?? (marked.location != NSNotFound ? marked : NSRange(location: cursor, length: 0))
        text = (text as NSString).replacingCharacters(in: target, with: s)
        marked = NSRange(location: NSNotFound, length: 0)
        cursor = target.location + (s as NSString).length
    }

    func selectedRange() -> NSRange { NSRange(location: cursor, length: 0) }
    func markedRange() -> NSRange { marked }
    func text(in range: NSRange) -> String? {
        guard readable, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return (text as NSString).substring(with: range)
    }
}

@MainActor @Suite struct InputSessionTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-session-\(UUID().uuidString).json")
        session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url), policies: .escSwitches)
    }

    @discardableResult
    func type(_ s: String) -> [Bool] {
        // Keys the input method passes on are typed by the app, as in a real text field.
        s.map { ch in
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
            return handled
        }
    }

    @Test func typesMixedSentence() {
        type("dkssudgktpdy hello ")
        #expect(field.text == "안녕하세요 hello ")
    }

    @Test func escAfterCommitFlipsTheWordAndLearnsIt() {
        type("hello ")
        #expect(field.text == "hello ")
        #expect(session.handle(.escape, client: field))
        #expect(field.text == "ㅗ디ㅣㅐ ")
        #expect(field.cursor == ("ㅗ디ㅣㅐ " as NSString).length)
        // Esc again flips back.
        #expect(session.handle(.escape, client: field))
        #expect(field.text == "hello ")
        // Flipping back to the engine's own choice clears the learned override.
        type("hello ")
        #expect(field.text == "hello hello ")
    }

    /// A switch key lists the word's readings, the one now shown selected, while it is being
    /// typed and right after it went in; the next key puts the list away.
    @Test func switchKeyListsTheReadings() {
        type("dkssud")
        #expect(session.readings == nil)
        session.handle(.escape, client: field)
        #expect(session.readings == InputSession.Readings(texts: ["dkssud", "안녕"], languages: [.english, .korean], selected: 0, own: 1))
        type(" ")
        #expect(session.readings == nil)
        session.handle(.escape, client: field)
        #expect(field.text == "안녕 ")
        // dkssud went in as English once: that reading is marked as corrected once.
        #expect(session.readings == InputSession.Readings(texts: ["dkssud", "안녕"], languages: [.english, .korean], selected: 1, own: 1, once: 0))
        type("a")
        #expect(session.readings == nil)
        type(" githubdp")
        session.handle(.escape, client: field)
        #expect(session.readings?.texts == ["githubdp", "github에"]) // a garbled reading isn't listed
    }

    /// A word the dictionary decided is listed once it went in, newest first and without the
    /// particle after it, and its reading is marked in the switch key's list; a word the engine
    /// decided, or one the user switched, isn't. Forgetting it takes it off the list.
    @Test func wordsTheDictionaryDecidedAreListed() {
        session.engine.add(.init(keys: "ghostty", language: .english, source: .user))
        session.engine.add(.init(keys: "chrao", language: .korean, source: .user))
        type("dkssud ghostty ")
        #expect(session.engine.recentlyApplied == [.init(keys: "ghostty", text: "ghostty", language: .english)])
        type("chraofh ") // 촉매로
        #expect(session.engine.recentlyApplied.map(\.keys) == ["chrao", "ghostty"])
        #expect(session.engine.recentlyApplied.first?.text == "촉매")
        type("ghosttydp ")
        #expect(field.text.hasSuffix("ghostty에 "))
        #expect(session.engine.recentlyApplied.map(\.keys) == ["ghostty", "chrao"])
        type("chrao")
        session.handle(.escape, client: field)
        #expect(session.readings?.remembered == session.readings?.languages.firstIndex(of: .korean))
        type(" ")
        #expect(session.engine.recentlyApplied.map(\.keys) == ["ghostty", "chrao"]) // switched: not the dictionary's
        session.engine.forget("ghostty")
        #expect(session.engine.recentlyApplied.map(\.keys) == ["chrao"])
    }

    /// The switch key's list tells a reading corrected once from one learned for good.
    @Test func readingsTellOnceFromForGood() {
        type("rjtm ")
        session.handle(.escape, client: field) // once
        let flipped = session.readings!.languages[session.readings!.selected]
        type("x rjtm")
        session.handle(.escape, client: field)
        #expect(session.readings?.once == session.readings?.languages.firstIndex(of: flipped))
        #expect(session.readings?.own != session.readings?.once)
        #expect(session.readings?.remembered == nil)
        type(" x rjtm") // that went in as the correction again: learned for good
        session.handle(.escape, client: field)
        #expect(session.readings?.remembered == session.readings?.languages.firstIndex(of: flipped))
        #expect(session.readings?.own != session.readings?.remembered) // Araso's own stays marked
        #expect(session.readings?.once == nil)
    }

    /// One Esc changes only that word (a habitual Esc shouldn't stick); the same
    /// correction a second time is remembered.
    @Test func flippedChoiceIsRememberedTheSecondTime() {
        type("rjtm ")
        let first = field.text
        session.handle(.escape, client: field)
        let flipped = field.text
        #expect(flipped != first)
        type("rjtm ")
        #expect(field.text == flipped + first)
        session.handle(.escape, client: field)
        #expect(field.text == flipped + flipped)
        type("rjtm ")
        #expect(field.text == flipped + flipped + flipped)
    }

    /// The key that makes a correction stick says so (the input method shows it), once: the
    /// first correction and the word typed afterwards don't.
    @Test func secondCorrectionReportsTheLearnedWord() {
        type("rjtm ")
        session.handle(.escape, client: field)
        let flipped = String(field.text.dropLast())
        type("r")
        #expect(session.learned == InputSession.Learned(text: flipped, language: .english, learning: .once)) // once: a nudge
        type("jtm ")
        session.handle(.escape, client: field)
        type("a") // the flip window closes: learned for good
        #expect(session.learned == InputSession.Learned(text: flipped, language: .english))
        type("b")
        #expect(session.learned == nil)
    }

    /// Switching a remembered word back to Araso's own reading forgets it in one go, and says so.
    @Test func backToTheOwnReadingForgetsTheWord() {
        type("rjtm ")
        let own = String(field.text.dropLast())
        session.handle(.escape, client: field)
        type("rjtm ")
        session.handle(.escape, client: field)
        type("x rjtm ") // remembered: goes in as the correction
        session.handle(.escape, client: field)
        #expect(field.text.hasSuffix(own + " "))
        type("a")
        #expect(session.learned?.text == own)
        #expect(session.learned?.learning == .forgot)
        type(" rjtm ")
        #expect(field.text.hasSuffix(own + " "))
        // Nothing is remembered; Araso's reading is marked as its own.
        type("rjtm")
        session.handle(.escape, client: field)
        #expect(session.readings.map { $0.texts[$0.own!] } == own)
        #expect(session.readings?.remembered == nil)
    }

    @Test func flipOnlyAppliesToTheWordBeforeTheCaret() {
        type("dkssud ")
        field.cursor = 0 // user clicked elsewhere
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕 ")
    }

    @Test func escPassesThroughWhenTextCannotBeVerified() {
        field.readable = false
        type("dkssud ")
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕 ")
    }

    @Test func anyOtherKeyEndsTheFlipWindow() {
        type("dkssud ")
        #expect(!session.handle(.other, client: field))
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕 ")
    }

    /// The app's own Delete: the character before the caret.
    func appDelete() {
        if !session.handle(.delete, client: field) {
            field.insertText("", replacing: NSRange(location: field.cursor - 1, length: 1))
        }
    }

    /// Space before looking, then Delete and Esc: the word still changes.
    @Test func deleteAfterCommitKeepsTheWordChangeable() {
        type("dkssud ")
        appDelete()
        #expect(field.text == "안녕")
        #expect(session.handle(.escape, client: field))
        #expect(field.text == "dkssud" && field.cursor == 6)
        type(" ")
        #expect(field.text == "dkssud ")
    }

    @Test func deleteAfterPunctuationKeepsTheWordChangeable() {
        type("hello.")
        appDelete()
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "ㅗ디ㅣㅐ")
    }

    /// Only the boundary: a second Delete takes a letter of the word and ends the chance.
    @Test func secondDeleteEndsTheFlipWindow() {
        type("dkssud ")
        appDelete()
        appDelete()
        #expect(field.text == "안")
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안")
    }

    /// ⇧Esc is Araso's key: when there is nothing to change it is dropped, not sent to the
    /// app as an Esc (Claude Code clears its draft on Esc).
    @Test func shiftEscWithNothingToChangeNeverReachesTheApp() {
        #expect(session.handle(.cycle, client: field))
        field.readable = false
        type("dkssud ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "안녕 ")
        #expect(!session.handle(.escape, client: field)) // plain Esc still goes on
    }

    @Test func escWhileComposingFlipsThePreview() {
        type("dkssud")
        #expect(field.text == "안녕")
        session.handle(.escape, client: field)
        #expect(field.text == "dkssud")
        type(" ")
        #expect(field.text == "dkssud ")
    }

    /// A consonant that joins the syllable before as its final is the next one's first on its
    /// way: 소개 + ㅎ shows 소갷, not throg, while 소개하는 is typed.
    @Test func previewKeepsKoreanThroughAPendingFinal() {
        var shown: [String] = []
        for ch in "throgksms" {
            type(String(ch))
            shown.append(field.text)
        }
        #expect(shown.dropFirst(3).allSatisfy { $0.unicodeScalars.allSatisfy { !$0.isASCII } }, "\(shown)")
        #expect(shown.last == "소개하는")
    }

    @Test func deleteRemovesKeystrokes() {
        type("dkssud")
        session.handle(.delete, client: field)
        #expect(field.text == "안녀")
    }

    /// As the system's 2-set input: the syllable being typed goes jamo by jamo, earlier ones whole.
    @Test func deleteKoreanLikeTheSystem() {
        type("gksrnr")
        #expect(field.text == "한국")
        for expected in ["한구", "한ㄱ", "한", ""] {
            session.handle(.delete, client: field)
            #expect(field.text == expected)
        }
        type("dkssudgktpdy")
        for expected in ["안녕하세ㅇ", "안녕하세", "안녕하", "안녕"] {
            session.handle(.delete, client: field)
            #expect(field.text == expected)
        }
        type("gk")
        #expect(field.text == "안녕하")
        session.handle(.delete, client: field)
        #expect(field.text == "안녕ㅎ")
    }

    /// After a Delete the syllable being typed stays apart from the ones before, as in the system
    /// input: 세요 → 세ㅇ → 세유 (not 셍, 셍ㅠ).
    @Test func retypingAfterDeleteKeepsSyllablesApart() {
        type("dkssudgktpdy")
        session.handle(.delete, client: field)
        type("b ")
        #expect(field.text == "안녕하세유 ")
    }

    @Test func deleteKeepsTheLanguageShown() {
        type("gksrnr")
        session.handle(.delete, client: field)
        session.handle(.delete, client: field)
        #expect(field.text == "한ㄱ")
        type(" ")
        #expect(field.text == "한ㄱ ")
    }

    @Test func deleteEnglishKeyByKey() {
        type("hello")
        session.handle(.delete, client: field)
        #expect(field.text == "hell")
    }
}

@MainActor @Suite struct MixedWordSessionTests {
    let field = FakeTextField()

    func type(_ session: InputSession, _ s: String) {
        for ch in s {
            let handled = ch.isASCII && ch.isLetter ? session.handle(.letter(ch), client: field)
                                                    : session.handle(.printable(ch), client: field)
            if !handled { field.insertText(String(ch), replacing: nil) }
        }
    }

    func session(japanese: Bool = false) -> InputSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-mixed-\(UUID().uuidString).json")
        let base = japanese ? SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter) : splitting
        return InputSession(engine: DictionaryEngine(base: base, storeURL: url), policies: .escSwitches, japaneseEnabled: japanese)
    }

    /// The English + Korean word split is what gets typed, not only what the engine decides.
    @Test func typesEnglishThenKoreanWord() {
        type(session(), "hellodnjfem githubtjqj ")
        #expect(field.text == "hello월드 github서버 ")
    }

    /// Return on an underlined word only confirms it; with nothing underlined it is the app's.
    @Test func returnConfirmsThenGoesToTheApp() {
        let session = session()
        type(session, "dkssud")
        #expect(session.handle(.enter, client: field))
        #expect(field.text == "안녕" && field.marked.location == NSNotFound)
        #expect(!session.handle(.enter, client: field))
    }

    /// By default Esc isn't a switch key: the word goes in as shown and the app gets the Esc,
    /// also right after a commit. The chosen keys (`.cycle`) still switch.
    @Test func escGoesToTheAppUnlessChosen() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-esc-\(UUID().uuidString).json")
        let session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url))
        #expect(session.policy.switchKeys == [.rightOption, .shiftEscape])
        type(session, "dkssud")
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕" && field.marked.location == NSNotFound)
        type(session, " ")
        #expect(!session.handle(.escape, client: field))
        #expect(field.text == "안녕 ")
        #expect(session.handle(.cycle, client: field)) // nothing to change: dropped
        type(session, "dkssud ")
        #expect(session.handle(.cycle, client: field))
        #expect(field.text == "안녕 dkssud ")
    }

    /// With the setting off, Return confirms the word and the app gets it too.
    @Test func returnGoesOnWhenItDoesntOnlyConfirm() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-return-\(UUID().uuidString).json")
        let session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url), returnConfirmsOnly: false)
        type(session, "dkssud")
        #expect(!session.handle(.enter, client: field))
        #expect(field.text == "안녕" && field.marked.location == NSNotFound)
    }

    /// A single letter with a particle (a variable name, an axis) is typed as such.
    /// Esc cycles back to the engine's own split (x에, hello월드), which the particle split alone
    /// doesn't find, and skips the garbled readings while it is there (ㅌ에, ㅗ디ㅣㅐ월드).
    @Test(arguments: [("xdp", "x에"), ("hellodnjfem", "hello월드")])
    func escCyclesBackToTheEnginesSplit(keys: String, split: String) {
        let s = session(japanese: true)
        type(s, keys)
        #expect(field.text == split)
        var seen: [String] = []
        for _ in 0..<4 { _ = s.handle(.escape, client: field); seen.append(field.text) }
        #expect(seen == [keys, split, keys, split])
    }

    @Test func typesSingleLetterWithParticle() {
        type(session(), "xdp ndl Xfmf Xeh ")
        #expect(field.text == "x에 n이 X를 X도 ")
    }

    /// Short English ending in the keys of 도 or 나 stays English.
    @Test func keepsShortEnglishEndingInEhOrSk() {
        type(session(), "heh meh tsk ")
        #expect(field.text == "heh meh tsk ")
    }

    /// Korean then romaji with no space: the Korean goes in, the rest is a Japanese word.
    @Test func typesKoreanThenJapaneseWord() {
        type(session(japanese: true), "qusruddlfurrireki dlfurrireki ")
        #expect(field.text == "변경이력りれき 이력りれき ")
    }

    /// A Japanese word with a Korean particle: the word as Japanese, the particle as Korean.
    @Test func typesJapaneseWordThenParticle() {
        type(session(japanese: true), "duwjsgl rirekifmf rirekidptj ")
        #expect(field.text == "여전히 りれき를 りれき에서 ")
    }

    /// A Japanese phrase with a Korean word straight after it.
    @Test func typesJapaneseThenKoreanWord() {
        type(session(japanese: true), "kyouhaehtlfkrdms ")
        #expect(field.text == "きょうは도시락은 ")
    }

    /// An English word and a particle whose keys also all make kana (redde is れっで).
    @Test(arguments: [("redde", "redで"), ("bugga", "bugが"), ("loginde", "loginで"), ("filede", "fileで"),
                      ("linuxni", "linuxに"), ("vimmade", "vimまで"), ("homede", "homeで")])
    func typesEnglishWordSpelledInKanaWithParticle(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Japanese that an English word and a particle could also spell isn't split (kit + と).
    /// Kyouha reads as English on its own, as before.
    @Test(arguments: [("kitto", "きっと"), ("densha", "でんしゃ"), ("sitede", "してで"), ("kyouha", "きょうは"),
                      ("Kyouha", "Kyouha"), ("nomede", "のめで")])
    func keepsJapaneseThatSpellsEnglishWithParticle(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Acronyms and names typed with their capitals take a Japanese particle too.
    @Test(arguments: [("APIde", "APIで"), ("PRwo", "PRを"), ("GitHubyori", "GitHubより"), ("VSCodede", "VSCodeで"),
                      ("YouTubeha", "YouTubeは"), ("VSCode", "VSCode")])
    func typesCapitalizedWordWithParticle(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Which particle: the reading that scores best as word + particle (figma + で, not fig + まで).
    @Test(arguments: [("figmade", "figmaで"), ("Dockermade", "Dockerまで"), ("AWSmade", "AWSまで")])
    func picksTheParticleByTheWord(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// A Japanese particle beats an English + Korean word split (beau + 쇼재), and an English
    /// word with a particle never goes in mid-word before Korean (lin + で + 그무).
    @Test(arguments: [("beautywo", "beautyを"), ("buddyto", "buddyと"), ("linderman", "linderman")])
    func japaneseParticleBeforeKoreanSplits(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Everyday English with a Korean particle whose keys also spell Hangul nobody writes
    /// (래그에서, 미내에), two words run together, and an acronym of shifted-jamo keys (ㅖㄲ).
    @Test(arguments: [("formdptj", "form에서"), ("alsodp", "also에"), ("macshotdptj", "macshot에서"), ("PRdp", "PR에"),
                      ("Slackdptj", "Slack에서")])
    func typesEnglishWordWithKoreanParticle(keys: String, expected: String) {
        type(session(), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Korean words that an English word and a particle could also spell stay Korean: the
    /// Korean reading is a word (핸들, 소문, 했는), or its capitals are shifted jamo (사기꾼).
    @Test(arguments: [("gosemf", "핸들"), ("gosemfdmf", "핸들을"), ("thansdms", "소문은"), ("thansdp", "소문에"),
                      ("goTsms", "했는"), ("godgks", "행한"), ("godgksms", "행하는"), ("duckgkaus", "여차하면"),
                      ("Thesms", "쏟는"), ("tkrlRnsdms", "사기꾼은"), ("akffkRoddl", "말라깽이")])
    func keepsKoreanThatSpellsEnglishWithParticle(keys: String, expected: String) {
        type(session(japanese: true), keys + " ")
        #expect(field.text == expected + " ")
    }

    /// Korean then English with no space: 오늘은 then google에서.
    @Test func typesKoreanThenEnglishWord() {
        type(session(japanese: true), "dhsmfdmsgoogledptj dlrjtdmsgithubdp ")
        #expect(field.text == "오늘은google에서 이것은github에 ")
    }

    @Test func plainKoreanStaysWhole() {
        type(session(japanese: true), "dkssudgktpdy qusruddlfur rhkswjadmfh ")
        #expect(field.text == "안녕하세요 변경이력 관점으로 ")
        // A consonant just typed for the next syllable isn't broken Hangul (하느님ㅇ, then lad…).
        field.text = ""; field.cursor = 0
        type(session(japanese: true), "gksmsladml tlsqnsladms godirpTspdy ")
        #expect(field.text == "하느님의 신부님은 해야겠네요 ")
    }
}
