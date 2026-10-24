import Foundation
import Testing
@testable import ArasoCore

/// Keystrokes through the real session, real engines and the real AzooKey dictionary,
/// into a fake text field: everything but InputMethodKit itself.
@MainActor @Suite struct EndToEndTests {
    let field = FakeTextField()
    let session: InputSession

    init() throws {
        let dir = FileManager.default.temporaryDirectory
        let engine = DictionaryEngine(base: SplittingEngine(base: trilingual, english: trilingual.english, japanese: trilingual.segmenter),
                                    storeURL: dir.appendingPathComponent("araso-e2e-\(UUID().uuidString).json"))
        let converter = try #require(AzooKeyConverter(memory: dir.appendingPathComponent("araso-e2e-\(UUID().uuidString)")))
        // A terminal the user set to strict, where Esc goes to the app; Esc switches elsewhere.
        let terminal = AppPolicies(overrides: ["*": .init(switchKeys: [.escape, .shiftEscape]),
                                               "test.terminal": .init(conversionThreshold: AppPolicy.strictThreshold,
                                                                      switchKeys: [.shiftEscape])])
        session = InputSession(engine: engine, policies: terminal, converter: converter, japaneseEnabled: true)
    }

    /// Types `script`: letters and printable keys as themselves, "⏎" Return, "⎋" Esc, "⌫" Delete.
    /// Keys the input method passes on are applied the way a text field would.
    func type(_ script: String) {
        for ch in script {
            switch ch {
            case "⏎":
                if !session.handle(.enter, client: field) { field.insertText("\n", replacing: nil) }
            case "⎋": _ = session.handle(.escape, client: field)
            case "⇧": _ = session.handle(.cycle, client: field) // ⇧Esc
            case "←": _ = session.handle(.left, client: field)
            case "→": _ = session.handle(.right, client: field)
            case "⌫": _ = session.handle(.delete, client: field)
            case let c where c.isLetter:
                if !session.handle(.letter(c), client: field) { field.insertText(String(c), replacing: nil) }
            default:
                if !session.handle(.printable(ch), client: field) { field.insertText(String(ch), replacing: nil) }
            }
        }
    }

    @Test func threeLanguagesInOneLine() {
        type("dkssudgktpdy hello ")
        type("kyouhaiitenkidesune ⏎")
        #expect(field.text == "안녕하세요 hello 今日はいい天気ですね")
    }

    @Test func englishInsideJapanese() {
        type("kyouhagoogledekensaku ⏎")
        #expect(field.text == "今日はgoogleで検索")
    }

    @Test(arguments: [
        ("githubde ⏎", "githubで"), ("kyouha ⏎githubwo ⏎", "今日はgithubを"), ("slackkara ⏎", "slackから"),
        ("i have 2 cats. githubde⏎", "i have 2 cats. githubで"), ("ok githubwo ⏎", "ok githubを"),
        ("jayne ", "jayne "), ("photo ", "photo "),
        ("guswo ", "현재 "), ("guswosms ", "현재는 "), ("kyouha ⏎guswo ", "今日は현재 "), // gus + を? no: 현재
    ])
    func englishWordWithAParticle(script: String, expected: String) {
        type(script)
        #expect(field.text == expected)
    }

    /// Shift held a key too long after ㄸ or ㄲ (어떤 as djEJs) in a terminal, after English too.
    @Test func lingeringShiftTypesKorean() {
        session.activate(app: "test.terminal")
        type("ok djEJs qkRNleh TkdRJvnf Hello API ")
        #expect(field.text == "ok 어떤 바뀌도 쌍꺼풀 Hello API ")
    }

    /// Shift held on from ㄲ through 깔끔, and from ㅃ through 빨, in a terminal: Korean.
    @Test func heldShiftTypesKorean() {
        session.activate(app: "test.terminal")
        type("ok RKFRMAgkek QKFfl RNAfmf ")
        #expect(field.text == "ok 깔끔하다 빨리 RNA를 ")
    }

    /// An acronym typed straight into a Korean word splits, and the same shape typed as fast Korean doesn't.
    @Test func acronymBeforeKoreanWordSplits() {
        session.activate(app: "test.terminal")
        type("EUwjdcor TMfkrh TBvkdlf ")
        #expect(field.text == "EU정책 쓰라고 TB파일 ")
    }

    /// An acronym a lingering Shift could read as Korean (TM as 쓰) keeps a particle in its own form.
    @Test func acronymWithAgreeingParticle() {
        session.activate(app: "test.terminal")
        type("ok TMdms TLdmf TMsms ")
        #expect(field.text == "ok TM은 TL을 쓰는 ")
    }

    /// In a terminal (0.97), 어떻게 after an English word is 0.969 sure: what was shown is committed.
    @Test func spaceCommitsWhatThePreviewShows() {
        session.activate(app: "test.terminal")
        type("esc djEjgrp")
        #expect(field.text == "esc 어떻게") // still composing (marked)
        type(" todrkrgo?")
        #expect(field.text == "esc 어떻게 생각해?")
    }

    /// In a terminal, a noun the word lists have only with a particle (혜택) still converts
    /// after an English word.
    @Test func terminalKoreanNounAfterEnglish() {
        session.activate(app: "test.terminal")
        type("hello gPxor ")
        #expect(field.text == "hello 혜택 ")
    }

    /// In a terminal Esc belongs to the app (vim): the word goes in as shown and Esc goes on.
    @Test func terminalEscapeGoesToTheApp() {
        session.activate(app: "test.terminal")
        type("dkssud")
        #expect(!session.handle(.escape, client: field)) // passed to the app
        #expect(field.text == "안녕")
        #expect(session.conversion == nil)
        type(" hello ")
        #expect(!session.handle(.escape, client: field)) // no undo after commit either
        #expect(field.text == "안녕 hello ")
    }

    /// ⇧Esc switches languages there, while composing and right after a commit.
    @Test func terminalShiftEscapeSwitches() {
        session.activate(app: "test.terminal")
        // hello's clean readings are English and へっぉ (ㅗ디ㅣㅐ is skipped).
        type("hello⇧")
        #expect(field.text == "へっぉ")
        type("⇧ ")                   // back to English, then commit
        #expect(field.text == "hello ")
        type("⇧")
        #expect(field.text == "へっぉ ")
    }

    /// Converting, backing out and converting again is still one correction: not learned.
    @Test func reconvertingCountsAsOneCorrection() {
        type("hello⎋ ⎋ ⏎")
        #expect(field.text != "hello")
        type(" hello ")
        #expect(field.text.hasSuffix(" hello "))
    }

    /// Other apps keep plain Esc for switching.
    @Test func escapeSwitchesInOtherApps() {
        session.activate(app: "com.apple.TextEdit")
        type("hello⎋")
        #expect(field.text == "へっぉ")
    }

    @Test(arguments: [
        ("UIrkxdmsrjs ", "UI같은건 "), ("UIdp ", "UI에 "), ("AIrk ", "AI가 "), ("githubrkxdmsep ", "github같은데 "),
    ])
    func acronymsAndLongerEndings(script: String, expected: String) {
        type(script)
        #expect(field.text == expected)
    }

    @Test func koreanWithEnglishAndParticles() {
        type("dlrjs githubdp commitgkf rjdi.")
        #expect(field.text == "이건 github에 commit할 거야.")
    }

    @Test(arguments: [
        ("dho?", "왜?"), ("rjdi.", "거야."), ("hello.", "hello."), ("hello, world!", "hello, world!"),
        ("arigatou.", "ありがとう。"), ("ra-men", "らーめn"), ("e-mail ", "e-mail "), ("ok!", "ok!"),
    ])
    func punctuationKeepsTheWordsLanguage(script: String, expected: String) {
        type(script)
        #expect(field.text == expected)
    }

    @Test(arguments: [
        ("dkssudgktpdy. qksrkqtmqslek!", "안녕하세요. 반갑습니다!"),
        ("dlTek.", "있다."),
        ("i have 2 cats.", "i have 2 cats."),
        ("dhsmf 3tl", "오늘 3시"),
    ])
    func everydaySentences(script: String, expected: String) {
        type(script)
        #expect(field.text == expected)
    }

    @Test(arguments: [
        ("honwoyomu ⏎", "本を読む"),
        ("ko-hi-wononde ⏎", "コーヒーを飲んで"),
        ("watashihagakuseidesu ⏎", "私は学生です"),
    ])
    func japaneseConversions(script: String, expected: String) {
        type(script)
        #expect(field.text == expected)
    }

    @Test func escapeAfterAClauseNeverLosesText() {
        type("kyouhagoogledekensaku ")
        // Commit just the first clause, then back out of the rest.
        while let c = session.conversion, c.current.kanaCount == c.kana.count { type(" ") }
        type("⏎")
        let committed = field.text
        type("⎋")
        type("⏎")
        #expect(field.text.count >= committed.count)
        #expect(field.text.hasSuffix("けんさく") || field.text.hasSuffix("検索") || field.text.contains("google"))
    }

    /// ←/→ move the first clause's end; Return commits it and converts the rest.
    @Test func clauseByClauseWithArrows() {
        type("kyouhaiitenkidesune ")
        #expect(session.conversion?.current.kanaCount == 12)
        type("←←←←←←←←") // 12 → 4: きょうは
        #expect(session.conversion?.current.kanaCount == 4)
        #expect(field.text == "今日はいいてんきですね")
        type("⏎")
        #expect(field.text.hasPrefix("今日は"))
        #expect(session.conversion?.kana == "いいてんきですね")
        type("⏎")
        #expect(field.text == "今日はいい天気ですね")
        #expect(session.conversion == nil)
    }

    @Test func clauseEndsStayWithinBounds() {
        type("kyouha ")
        type("→")
        #expect(session.conversion?.current.kanaCount == 4) // already the whole reading
        type("←←←←←←")
        #expect(session.conversion?.current.kanaCount == 1)
        type("⎋")
        #expect(session.conversion == nil)
    }

    /// A clause boundary never splits an English word inside the phrase.
    @Test func clauseBoundarySkipsEnglishLetters() {
        type("kyouhagoogledekensaku ")
        #expect(session.conversion?.kana == "きょうはgoogleでけんさく")
        #expect(session.conversion?.current.kanaCount == 15)
        type("←←←←←") // 15 → 10: きょうはgoogle
        #expect(session.conversion?.current.kanaCount == 10)
        type("←")      // not 9 (googl|e) but 4: きょうは
        #expect(session.conversion?.current.kanaCount == 4)
    }

    @Test func numbersAfterJapaneseKeepTheirDecimalPoint() {
        type("kyouha ⏎")
        type("3.5")
        #expect(field.text == "今日は3.5")
        type("desu.")
        #expect(field.text.hasSuffix("です。"))
    }

    @Test func katakanaAndHiraganaShortcuts() {
        type("ko-hi-")
        _ = session.handle(.katakana, client: field)
        #expect(field.text == "コーヒー")
        type(" ")                                   // flip to the other form
        #expect(field.text == "こーひー")
        type("⏎")
        #expect(field.text == "こーひー")
        // ⌃K on an English word is the app's shortcut, not ours.
        type(" hello")
        #expect(!session.handle(.katakana, client: field))
        #expect(field.text == "こーひー hello")
    }

    @Test func pickASecondCandidate() {
        type("kanjiwo")      // かんじを (Japanese context not needed: "kanjiwo" isn't English)
        type(" ")
        let first = field.text
        type(" ")
        #expect(field.text != first) // another candidate is shown
        type("⏎")
        #expect(session.conversion == nil)
        #expect(field.text.hasSuffix("を"))
    }

    @Test func fixAWrongGuessWithEscape() {
        type("ozzy ")
        #expect(field.text == "ozzy ")
        type("⎋")                    // ozzy → its Korean reading
        #expect(field.text != "ozzy ")
        type("⎋⎋")                   // → Japanese → back to English
        #expect(field.text == "ozzy ")
    }
}
