import ArasoBridge
import ArasoCore
@testable import ArasoService
import Foundation
import Testing

/// A text field as the Windows text service sees it: it sends a snapshot with each key, makes the
/// edits that come back in order (as `TextService::ApplyOps` does), and types a key the input method
/// passes on, as the app would.
final class FakeDocument {
    var text = ""
    var composition: NSRange?
    var cursor = 0
    var readable = true
    /// The clause the last mark drew as the one being converted.
    var clause: [Int]?

    func context() -> TextContext {
        let ns = text as NSString
        let anchor = composition?.location ?? cursor
        let start = max(0, anchor - 256)
        let end = max(composition.map(NSMaxRange) ?? cursor, cursor)
        var context = TextContext(selection: [cursor, 0], marked: composition.map { [$0.location, $0.length] },
                                  text: ns.substring(with: NSRange(location: start, length: end - start)), start: start)
        if !readable { context.unreadable = true }
        return context
    }

    func apply(_ ops: [EditOp]) {
        for op in ops {
            let target = op.replace.map { NSRange(location: $0[0], length: $0[1]) } ?? composition ?? NSRange(location: cursor, length: 0)
            text = (text as NSString).replacingCharacters(in: target, with: op.text)
            let length = (op.text as NSString).length
            if op.kind == .mark, length > 0 {
                composition = NSRange(location: target.location, length: length)
                clause = op.clause
            } else {
                composition = nil
                clause = nil
            }
            cursor = target.location + length
        }
    }

    /// The app types a key the input method didn't take.
    func appTypes(_ s: String) {
        text = (text as NSString).replacingCharacters(in: NSRange(location: cursor, length: 0), with: s)
        cursor += (s as NSString).length
    }
}

/// Keys as a US keyboard sends them.
enum Keys {
    static let letters: [Character: Int] = {
        var table: [Character: Int] = [:]
        for (row, first) in [("qwertyuiop", 0x10), ("asdfghjkl", 0x1E), ("zxcvbnm", 0x2C)] {
            for (i, ch) in row.enumerated() { table[ch] = first + i }
        }
        return table
    }()

    static let symbols: [Character: (Int, Bool)] = [
        "1": (0x02, false), "2": (0x03, false), "3": (0x04, false), "0": (0x0B, false), "!": (0x02, true),
        "-": (0x0C, false), ".": (0x34, false), ",": (0x33, false), "?": (0x35, true), "/": (0x35, false),
        ";": (0x27, false), ":": (0x27, true), " ": (0x39, false), "'": (0x28, false), "@": (0x03, true),
    ]

    static func key(_ ch: Character) -> WindowsKey {
        if let scan = letters[Character(ch.lowercased())] {
            let vk = Int(ch.uppercased().unicodeScalars.first!.value)
            return WindowsKey(vk: vk, scan: scan, shift: ch.isUppercase)
        }
        let (scan, shift) = symbols[ch]!
        let vk = ch == " " ? KeyMapper.vkSpace : 0xBE
        return WindowsKey(vk: vk, scan: scan, shift: shift)
    }

    static let rightAlt = WindowsKey(vk: KeyMapper.vkMenu, scan: 0x38, extended: true, alt: true)
    static let rightAltUp = WindowsKey(vk: KeyMapper.vkMenu, scan: 0x38, extended: true)
    static let rightCtrl = WindowsKey(vk: KeyMapper.vkControl, scan: 0x1D, extended: true, ctrl: true)
    static let rightCtrlUp = WindowsKey(vk: KeyMapper.vkControl, scan: 0x1D, extended: true)
    static let leftCtrl = WindowsKey(vk: KeyMapper.vkControl, scan: 0x1D, ctrl: true)
    static let hangul = WindowsKey(vk: KeyMapper.vkHangul, scan: 0x72)
    static let escape = WindowsKey(vk: KeyMapper.vkEscape, scan: 0x01)
    static let shiftEscape = WindowsKey(vk: KeyMapper.vkEscape, scan: 0x01, shift: true)
    static let back = WindowsKey(vk: KeyMapper.vkBack, scan: 0x0E)
    static let enter = WindowsKey(vk: KeyMapper.vkReturn, scan: 0x1C)
    static let space = key(" ")
}

/// One text service against a runtime in a scratch settings folder.
@MainActor
final class Harness {
    let runtime: ServiceRuntime
    let document = FakeDocument()
    let client: Int
    let folder: URL
    /// What the host would draw after the last request.
    var ui: UIState?
    var lastReply = ServiceReply()

    init(settings: String? = nil, apps: String? = nil, replacements: String? = nil, app: String = "notepad.exe",
         platform: String = "windows", asset: String? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("araso-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: folder.appendingPathComponent("settings.json")) }
        if let apps { try Data(apps.utf8).write(to: folder.appendingPathComponent("apps.json")) }
        if let replacements { try Data(replacements.utf8).write(to: folder.appendingPathComponent("replacements.json")) }
        runtime = ServiceRuntime(.init(support: folder.path, version: "0.2.4", language: "ko", platform: platform, asset: asset))
        client = runtime.handle(ServiceRequest(op: .attach, app: app)).reply.client ?? -1
        _ = send(ServiceRequest(op: .focus, client: client, app: app, context: document.context()))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    func send(_ request: ServiceRequest) -> ServiceResponse {
        var request = request
        request.context = request.context ?? document.context()
        let response = runtime.handle(request)
        document.apply(response.reply.ops)
        ui = response.ui
        lastReply = response.reply
        // Edits the host started: the text service asks for them right away.
        if response.notify?.contains(client) == true {
            let pending = runtime.handle(ServiceRequest(op: .pending, client: client, context: document.context()))
            document.apply(pending.reply.ops)
            ui = pending.ui
        }
        return response
    }

    @discardableResult
    func press(_ key: WindowsKey) -> Bool {
        send(ServiceRequest(op: .key, client: client, key: key)).reply.handled
    }

    func release(_ key: WindowsKey) -> Bool {
        send(ServiceRequest(op: .keyUp, client: client, key: key)).reply.handled
    }

    /// Types `s` as the text service does: `test` first; a key not kept is typed by the app, and a
    /// kept one comes `claimed`, so the host types it if the session passes it on (or has it sent
    /// again, for the app).
    func type(_ s: String) {
        for ch in s {
            let key = Keys.key(ch)
            guard send(ServiceRequest(op: .test, client: client, key: key)).reply.handled else {
                document.appTypes(String(ch))
                continue
            }
            var request = ServiceRequest(op: .key, client: client, key: key)
            request.claimed = true
            let reply = send(request).reply
            #expect(reply.handled || reply.replay == true, "a kept key went nowhere")
            if reply.replay == true { document.appTypes(String(ch)) }
        }
    }

    /// A modifier tapped: its down only seen, its up kept when `test` says it does something.
    func tap(_ down: WindowsKey, _ up: WindowsKey) -> Bool {
        press(down)
        var test = ServiceRequest(op: .test, client: client, key: up)
        test.up = true
        guard send(test).reply.handled else { return false }
        return release(up)
    }
}

@MainActor @Suite(.serialized) struct ServiceTests {
    @Test func typesMixedSentence() throws {
        let h = try Harness()
        h.type("dkssudgktpdy hello ")
        #expect(h.document.text == "안녕하세요 hello ")
        #expect(h.document.composition == nil)
    }

    @Test func wordIsUnderlinedWhileTyped() throws {
        let h = try Harness()
        h.type("dkssud")
        #expect(h.document.text == "안녕")
        #expect(h.document.composition == NSRange(location: 0, length: 2))
        #expect(h.ui == nil) // nothing to draw: the text service needn't say where the word is
        h.press(Keys.enter)
        #expect(h.document.text == "안녕")
        #expect(h.document.composition == nil)
    }

    @Test func rightAltTapSwitchesTheWordJustCommitted() throws {
        let h = try Harness()
        h.type("hello ")
        // The lone Alt's release is taken, so the app doesn't open its menu bar.
        #expect(h.tap(Keys.rightAlt, Keys.rightAltUp))
        #expect(h.document.text == "ㅗ디ㅣㅐ ")
        // The readings it went through, listed under the word.
        #expect(h.ui?.readings?.tags.contains("KO") == true)
        #expect(h.ui?.readings?.texts.contains("ㅗ디ㅣㅐ") == true)
    }

    @Test func aCorrectionMadeTwiceIsMarkedAndListedInTheMenu() throws {
        let h = try Harness()
        for _ in 0..<2 {
            h.type("hello ")
            _ = h.tap(Keys.rightAlt, Keys.rightAltUp)
            h.type("x ")
        }
        #expect(h.ui?.learned == nil || h.ui?.learned?.learning != nil)
        h.type("hello ")
        let menu = h.send(ServiceRequest(op: .menu, client: h.client)).reply.menu ?? []
        #expect(menu.contains { $0.id == "forget:hello" })
    }

    @Test func hangulKeyIsTheRightAlt() throws {
        let h = try Harness()
        h.type("dkssud")
        #expect(h.document.text == "안녕")
        // It switches as it goes down: some keyboards send no release for it.
        #expect(h.press(Keys.hangul))
        #expect(h.document.text != "안녕")
        #expect(h.document.composition != nil)
    }

    @Test func altWithAnotherKeyIsNoTap() throws {
        let h = try Harness()
        h.type("hello ")
        h.press(Keys.rightAlt)
        h.press(Keys.key("f")) // Alt+F: the app's menu
        #expect(!h.release(Keys.rightAltUp))
        #expect(h.document.text.hasPrefix("hello "))
    }

    @Test func shiftEscapeSwitchesWhileTyping() throws {
        let h = try Harness()
        h.type("hello")
        #expect(h.press(Keys.shiftEscape))
        #expect(h.document.text != "hello")
        #expect(h.document.composition != nil)
    }

    @Test func plainEscapeGoesToTheAppByDefault() throws {
        let h = try Harness()
        h.type("dkssud")
        #expect(!h.press(Keys.escape))
        #expect(h.document.text == "안녕")
        #expect(h.document.composition == nil)
    }

    @Test func rightCtrlTapPausesTheField() throws {
        let h = try Harness()
        #expect(h.tap(Keys.rightCtrl, Keys.rightCtrlUp))
        #expect(h.ui?.paused == true)
        h.type("dkssud")
        #expect(h.document.text == "dkssud")
        _ = h.tap(Keys.rightCtrl, Keys.rightCtrlUp)
        #expect(h.ui?.paused == false)
        h.type(" dkssud")
        #expect(h.document.text == "dkssud 안녕")
    }

    /// TSF holds a text service to what `OnTestKeyDown` said: a key kept from the app goes nowhere
    /// else. So a kept key the session passes on is typed by the host or sent again, and keys the
    /// session doesn't want aren't kept.
    @Test func keptKeysAreTypedOrSentAgain() throws {
        let h = try Harness()
        func test(_ key: WindowsKey) -> Bool { h.send(ServiceRequest(op: .test, client: h.client, key: key)).reply.handled }
        func claimed(_ key: WindowsKey) -> ServiceReply {
            var request = ServiceRequest(op: .key, client: h.client, key: key)
            request.claimed = true
            return h.send(request).reply
        }
        // Space after a word: the word goes in and the host types the space after it.
        h.type("dkssud")
        #expect(test(Keys.key(" ")))
        #expect(claimed(Keys.key(" ")).handled)
        #expect(h.document.text == "안녕 ")
        // Return or a shortcut ending a word: the word goes in and the key goes back to the app.
        let ret = WindowsKey(vk: 0x0D, scan: 0x1C)
        #expect(!test(ret)) // nothing to finish: the app's
        h.type("gks")
        #expect(test(ret))
        let reply = claimed(ret)
        #expect(reply.handled || reply.replay == true)
        h.type("dkssud")
        let ctrlS = WindowsKey(vk: 0x53, scan: 0x1F, ctrl: true)
        #expect(test(ctrlS))
        #expect(claimed(ctrlS).replay == true)
        // A modifier going down is only seen; its up is kept only when it ends a tap that acts.
        var leftCtrlUp = WindowsKey(vk: KeyMapper.vkControl, scan: 0x1D)
        leftCtrlUp.ctrl = false
        #expect(!h.tap(Keys.leftCtrl, leftCtrlUp))
        // Paused: keys aren't kept at all, so the app types them itself.
        #expect(h.tap(Keys.rightCtrl, Keys.rightCtrlUp))
        #expect(!test(Keys.key("d")))
        #expect(!test(Keys.key(" ")))
    }

    @Test func hanjaKeyPausesAsItGoesDown() throws {
        let h = try Harness()
        #expect(h.press(WindowsKey(vk: KeyMapper.vkHanja, scan: 0x71)))
        #expect(h.ui?.paused == true)
    }

    @Test func pauseShortcutFromSettings() throws {
        // Ctrl+Alt+P, stored with the Mac's key code for P (35) and ⌘ for Ctrl.
        let h = try Harness(settings: #"{ "pauseKey": { "keyCode": 35, "modifiers": ["command", "option"], "key": "P" } }"#)
        #expect(h.press(WindowsKey(vk: 0x50, scan: 0x19, ctrl: true, alt: true)))
        #expect(h.ui?.paused == true)
    }

    @Test func ctrlGoingDownPutsAHeldWordIn() throws {
        let h = try Harness(apps: #"{ "notepad.exe": { "holdSpace": true } }"#)
        h.type("dkssud ")
        #expect(h.document.composition != nil) // held with its space
        h.press(Keys.leftCtrl)
        #expect(h.document.composition == nil)
        #expect(h.document.text == "안녕 ")
    }

    @Test func shortcutsGoToTheAppUnlessAWordIsInProgress() throws {
        let h = try Harness()
        let ctrlS = WindowsKey(vk: 0x53, scan: 0x1F, ctrl: true)
        #expect(!h.send(ServiceRequest(op: .test, client: h.client, key: ctrlS)).reply.handled)
        h.type("dkssud")
        // A word in progress: the key comes (and the word goes in first); the app still gets it.
        #expect(h.send(ServiceRequest(op: .test, client: h.client, key: ctrlS)).reply.handled)
        #expect(!h.press(ctrlS))
        #expect(h.document.text == "안녕")
        #expect(h.document.composition == nil)
        let altSpace = WindowsKey(vk: 0x20, scan: 0x39, alt: true)
        #expect(!h.send(ServiceRequest(op: .test, client: h.client, key: altSpace)).reply.handled)
    }

    @Test func blurCommitsAsShown() throws {
        let h = try Harness()
        h.type("dkssud")
        h.send(ServiceRequest(op: .blur, client: h.client))
        #expect(h.document.text == "안녕")
        #expect(h.document.composition == nil)
    }

    @Test func compositionEndedByTheAppKeepsItsText() throws {
        let h = try Harness()
        h.type("dkssud")
        // The app ended the composition: the text stays, and the next word starts fresh.
        h.document.composition = nil
        h.send(ServiceRequest(op: .terminated, client: h.client))
        h.type(" hello ")
        #expect(h.document.text == "안녕 hello ")
    }

    @Test func textReplacementFromItsFile() throws {
        let h = try Harness(replacements: #"{ "주소": ["서울시 중구"] }"#)
        h.type("wnth ")
        #expect(h.document.text == "서울시 중구 ")
    }

    @Test func backspaceOnAConversionCommitsAllButItsLastCharacter() throws {
        guard Resources.japaneseDictionary != nil else { return }
        let h = try Harness(settings: #"{ "japanese": true, "liveConversion": false }"#)
        h.type("henkan ")
        #expect(h.document.text == "変換")
        // Kept from the app while converting, and it ends the conversion less its last character.
        #expect(h.send(ServiceRequest(op: .test, client: h.client, key: Keys.back)).reply.handled)
        #expect(h.press(Keys.back))
        #expect(h.document.text == "変")
        #expect(h.document.composition == nil)
        #expect(h.ui?.candidates == nil)
    }

    @Test func backspaceInLiveConversionTypesThePhraseAgain() throws {
        guard Resources.japaneseDictionary != nil else { return }
        let h = try Harness(settings: #"{ "japanese": true, "liveConversion": true }"#)
        h.type("kyouhaiitenkidesune")
        #expect(h.document.text == "今日はいい天気ですね")
        h.press(Keys.back)
        #expect(h.document.text == "今日はいいてんきです")
        #expect(h.document.composition != nil)
    }

    @Test func liveConversionSpaceAfterAPendingLetterShowsTheFirstCandidate() throws {
        guard Resources.japaneseDictionary != nil else { return }
        let h = try Harness(settings: #"{ "japanese": true, "liveConversion": true }"#)
        h.type("henkan")
        #expect(h.document.text == "変化n") // live conversion's, the n waiting for its vowel
        h.press(Keys.space)
        #expect(h.document.text == "変換")
        #expect(h.ui?.candidates?.texts[h.ui?.candidates?.selected ?? -1] == "変換")
    }

    @Test func aShortcutWithPhrasesOffersThemInTheCard() throws {
        let h = try Harness(replacements: #"{ "주소": ["서울시 중구", "부산시 동구"] }"#)
        h.type("wnth")
        h.press(Keys.space)
        // The phrases, then the shortcut as typed, with the shortcut under them.
        #expect(h.ui?.candidates?.texts == ["서울시 중구", "부산시 동구", "주소"])
        #expect(h.ui?.candidates?.reading == "주소")
        var choose = ServiceRequest(op: .choose, client: h.client)
        choose.index = 1
        h.send(choose)
        #expect(h.document.text == "부산시 동구 ")
        #expect(h.document.composition == nil)
    }

    @Test func escapeTakesTheCardBackToTheShortcut() throws {
        let h = try Harness(replacements: #"{ "주소": ["서울시 중구", "부산시 동구"] }"#)
        h.type("wnth")
        h.press(Keys.space)
        h.press(Keys.escape)
        #expect(h.ui?.candidates == nil)
        #expect(h.document.text == "주소")
        #expect(h.document.composition != nil)
        h.press(Keys.space) // offered again
        #expect(h.ui?.candidates?.texts.count == 3)
    }

    @Test func clickingAReadingSwitchesToIt() throws {
        let h = try Harness()
        h.type("hello ")
        #expect(h.tap(Keys.rightAlt, Keys.rightAltUp))
        guard let readings = h.ui?.readings, let english = readings.texts.firstIndex(of: "hello") else {
            Issue.record("no readings")
            return
        }
        var pick = ServiceRequest(op: .pick, client: h.client)
        pick.index = english
        h.send(pick)
        #expect(h.document.text == "hello ")
        #expect(h.ui?.readings?.texts[h.ui?.readings?.selected ?? -1] == "hello")
    }

    @Test func maskedKeysGoThroughUnchangedWhenDisabled() throws {
        let h = try Harness(apps: #"{ "notepad.exe": { "enabled": false } }"#)
        h.type("dkssud ")
        #expect(h.document.text == "dkssud ")
    }

    @Test func menuListsTheMacItemsAndChangesTheApp() throws {
        let h = try Harness()
        let menu = h.send(ServiceRequest(op: .menu, client: h.client)).reply.menu ?? []
        let ids = menu.compactMap(\.id)
        #expect(ids.contains("pause"))
        #expect(ids.contains("app.strict"))
        #expect(ids.contains("japanese"))
        #expect(ids.contains("settings"))
        #expect(menu.contains { $0.title.contains("notepad.exe") })
        var select = ServiceRequest(op: .menuSelect, client: h.client)
        select.item = "app.strict"
        let response = h.send(select)
        #expect(response.ui?.settingsChanged == true)
        #expect(AppPolicies.load().policy(for: "notepad.exe").conversionThreshold == AppPolicy.strictThreshold)
        // Korean UI text, from the Mac app's Localizable.strings.
        #expect(menu.contains { $0.title.contains("일시정지") })
    }

    @Test func readingsForTheDictionaryEditor() throws {
        let h = try Harness()
        var request = ServiceRequest(op: .readings)
        request.keys = "dkssud"
        let choices = h.runtime.handle(request).choices ?? []
        #expect(choices.first == Choice(language: "english", text: "dkssud"))
        #expect(choices.contains(Choice(language: "korean", text: "안녕")))
    }

    @Test func recordingAPauseShortcut() throws {
        let h = try Harness()
        var request = ServiceRequest(op: .shortcut)
        request.key = WindowsKey(vk: 0x50, scan: 0x19, ctrl: true, alt: true)
        let response = h.runtime.handle(request)
        #expect(response.shortcut == PauseKey.Shortcut(keyCode: 35, modifiers: [.command, .option], key: "P"))
        #expect(response.shortcutName == "Ctrl+Alt+P")
        #expect(response.problem == nil)
        request.key = WindowsKey(vk: 0x50, scan: 0x19)
        #expect(h.runtime.handle(request).problem == "types")
        request.key = WindowsKey(vk: 0x75, scan: 0x40)
        #expect(h.runtime.handle(request).problem == "arasos")
        request.key = WindowsKey(vk: 0x74, scan: 0x3F)
        #expect(h.runtime.handle(request).shortcutName == "F5")
    }

    @Test func menuOpensTheSettingsWindow() throws {
        let h = try Harness()
        var select = ServiceRequest(op: .menuSelect, client: h.client)
        select.item = "learning"
        #expect(h.send(select).ui?.openSettings == "learning")
    }

    @Test func menuPauseCommitsTheWordFirst() throws {
        let h = try Harness()
        h.type("dkssud")
        var select = ServiceRequest(op: .menuSelect, client: h.client)
        select.item = "pause"
        h.send(select)
        #expect(h.document.composition == nil)
        h.type("rk")
        #expect(h.document.text == "안녕rk")
    }

    @Test func vimNormalModePassesKeys() throws {
        let h = try Harness(app: "windowsterminal.exe")
        var vim = ServiceRequest(op: .vim, app: "WindowsTerminal.exe")
        vim.vim = "normal"
        let response = h.runtime.handle(vim)
        #expect(response.notify == [h.client])
        h.send(ServiceRequest(op: .pending, client: h.client))
        h.type("dd")
        #expect(h.document.text == "dd")
        #expect(h.document.composition == nil)
    }

    @Test func settingsWindowChangesWriteTheFiles() throws {
        let h = try Harness()
        var change = SettingsChange()
        change.app = "Code.exe"
        change.entry = AppPolicy.Override(holdSpace: true)
        var request = ServiceRequest(op: .change)
        request.change = change
        let model = h.runtime.handle(request).settings
        #expect(model?.apps.map(\.app) == ["code.exe"])
        #expect(model?.apps.first?.policy.holdSpace == true)

        var word = SettingsChange()
        word.addWord = UserDictionary.Entry(keys: "ghostty", language: .english, source: .user)
        request.change = word
        let words = h.runtime.handle(request).settings?.words ?? []
        #expect(words.contains { $0.keys == "ghostty" && $0.status == "added" && $0.text == "ghostty" })
    }

    @Test func settingsChangeAppliesToTheNextKey() throws {
        let h = try Harness()
        h.type("dkssud")
        var change = SettingsChange()
        change.defaultPolicy = SettingsModel.PolicyInfo(AppPolicy(enabled: false))
        var request = ServiceRequest(op: .change)
        request.change = change
        _ = h.runtime.handle(request)
        // The word in progress goes in; then keys pass.
        h.type("rk")
        #expect(h.document.text == "안녕rk")
    }

    @Test func releaseFromGitHubNamesTheWindowsInstaller() throws {
        let h = try Harness()
        var request = ServiceRequest(op: .release)
        request.body = #"""
        { "tag_name": "v9.0.0", "html_url": "https://example.com/r", "body": "## 바뀐 것\n- **새 기능**: 설명\n",
          "assets": [ { "name": "Araso.pkg", "browser_download_url": "https://example.com/Araso.pkg" },
                      { "name": "Araso-Setup.exe", "browser_download_url": "https://example.com/Araso-Setup.exe" } ] }
        """#
        let release = h.runtime.handle(request).release
        #expect(release?.installer == "https://example.com/Araso-Setup.exe")
        #expect(release?.newer == true)
        #expect(release?.notes.first?.title == "새 기능")
        #expect(h.runtime.model().update?.version == "9.0.0")
        let menu = h.send(ServiceRequest(op: .menu, client: h.client)).reply.menu ?? []
        #expect(menu.contains { $0.id == "update" })
    }

    @Test func linuxNamesSuperAndUpdatesFromItsTarball() throws {
        let h = try Harness(settings: #"{"pauseKey": "rightControl"}"#, app: "gedit", platform: "linux",
                            asset: "Araso-linux-x86_64.tar.gz")
        var request = ServiceRequest(op: .shortcut)
        request.key = WindowsKey(vk: 0x50, scan: 0x19, ctrl: true, win: true)
        #expect(h.runtime.handle(request).shortcutName == "Ctrl+Super+P")
        let menu = h.send(ServiceRequest(op: .menu, client: h.client)).reply.menu ?? []
        #expect(menu.first?.title.contains("Super") == true)
        var release = ServiceRequest(op: .release)
        release.body = #"""
        { "tag_name": "v9.0.0", "html_url": "https://example.com/r", "body": "## 바뀐 것\n- **새 기능**: 설명\n",
          "assets": [ { "name": "Araso-Setup.exe", "browser_download_url": "https://example.com/Araso-Setup.exe" },
                      { "name": "Araso-linux-x86_64.tar.gz", "browser_download_url": "https://example.com/linux.tar.gz" } ] }
        """#
        #expect(h.runtime.handle(release).release?.installer == "https://example.com/linux.tar.gz")
        #expect(h.runtime.model().update?.version == "9.0.0")
    }

    @Test func tryTypingTraceOnlyInTheHostsOwnField() throws {
        let own = try Harness(app: "arasohost.exe")
        own.type("dkssud")
        #expect(own.ui?.trace?.language == "korean")
        let other = try Harness()
        other.type("dkssud")
        #expect(other.ui?.trace == nil)
    }

    @Test func japaneseConversionAndAClickInTheCandidateWindow() throws {
        guard Resources.japaneseDictionary != nil else { return }
        let h = try Harness(settings: #"{ "japanese": true }"#)
        h.type("henkan")
        #expect(h.document.text == "へんかn") // the n waits for the next key

        h.press(Keys.space)
        let candidates = h.ui?.candidates?.texts ?? []
        #expect(candidates.contains("変換"))
        #expect(h.lastReply.converting == true)
        #expect(h.document.clause != nil) // the clause the candidates are for
        guard let index = candidates.firstIndex(of: "変換") else { return }
        var choose = ServiceRequest(op: .choose, client: h.client)
        choose.index = index
        h.send(choose)
        #expect(h.document.text == "変換")
        #expect(h.document.composition == nil)
    }
}

@MainActor @Suite struct KeyMapperTests {
    @Test func lettersComeFromTheKeyNotTheLayout() {
        // AZERTY's A key sends VK_Q; the scan code is QWERTY's a.
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x51, scan: 0x1E), policy: .standard) == .letter("a"))
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x41, scan: 0x1E, shift: true), policy: .standard) == .letter("A"))
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x41, scan: 0x1E, capsLock: true), policy: .standard) == .letter("A"))
    }

    @Test func colemakTypesItsOwnLetters() {
        LatinLayout.$override.withValue(.colemak) {
            #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x45, scan: 0x12), policy: .standard) == .letter("f"))
            #expect(KeyMapper.sessionKey(WindowsKey(vk: 0xBA, scan: 0x27), policy: .standard) == .letter("o"))
        }
    }

    @Test func symbolsAndDigitsAreUSKeys() {
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x31, scan: 0x02), policy: .standard) == .printable("1"))
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x31, scan: 0x02, shift: true), policy: .standard) == .printable("!"))
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x61, scan: 0x4F), policy: .standard) == .printable("1"))
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x20, scan: 0x39, shift: true), policy: .standard) == .shiftSpace)
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x09, scan: 0x0F), policy: .standard) == .other)
    }

    @Test func modifiersAndSwitchKeys() {
        let altSpace = WindowsKey(vk: 0x20, scan: 0x39, alt: true)
        #expect(KeyMapper.sessionKey(altSpace, policy: .standard) == .other)
        #expect(KeyMapper.sessionKey(altSpace, policy: AppPolicy(switchKeys: [.optionSpace])) == .cycle)
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x56, scan: 0x2F, ctrl: true), policy: .standard) == .other)
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x4A, scan: 0x24, ctrl: true), policy: .standard) == .other)
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x75, scan: 0x40), policy: .standard) == .hiragana)
        #expect(KeyMapper.sessionKey(WindowsKey(vk: 0x76, scan: 0x41), policy: .standard) == .katakana)
        #expect(KeyMapper.sessionKey(Keys.shiftEscape, policy: AppPolicy(switchKeys: [.rightOption])) == .other)
    }

    @Test func modifierKeysByPlace() {
        #expect(KeyMapper.modifier(Keys.rightAlt) == .rightAlt)
        #expect(KeyMapper.modifier(WindowsKey(vk: 0x12, scan: 0x38)) == .leftAlt)
        #expect(KeyMapper.modifier(WindowsKey(vk: 0x10, scan: 0x36)) == .rightShift)
        #expect(KeyMapper.modifier(WindowsKey(vk: 0x10, scan: 0x2A)) == .leftShift)
        #expect(KeyMapper.modifier(Keys.rightCtrl)?.macKeyCode == PauseKey.Tap.rightCommand.keyCode)
        #expect(KeyMapper.modifier(Keys.hangul) == nil) // a key of its own
    }

    @Test func aSlowTapIsNoTap() {
        var taps = TapTracker()
        let start = Date()
        taps.down(.rightAlt, held: [.option], pauseKey: .standard, switchKeys: [.rightOption], now: start)
        #expect(taps.up(.rightAlt, pauseKey: .standard, now: start.addingTimeInterval(0.8)) == nil)
        taps.down(.rightAlt, held: [.option], pauseKey: .standard, switchKeys: [.rightOption], now: start)
        #expect(taps.up(.rightAlt, pauseKey: .standard, now: start.addingTimeInterval(0.1)) == .cycle)
        // Not chosen as a switch key: nothing.
        taps.down(.rightShift, held: [.shift], pauseKey: .standard, switchKeys: [.rightOption], now: start)
        #expect(taps.up(.rightShift, pauseKey: .standard, now: start.addingTimeInterval(0.1)) == nil)
        // A Hyper key: other modifiers held.
        taps.down(.rightAlt, held: [.option, .command, .shift], pauseKey: .standard, switchKeys: [.rightOption], now: start)
        #expect(taps.up(.rightAlt, pauseKey: .standard, now: start.addingTimeInterval(0.1)) == nil)
    }
}

@Suite struct StringsTests {
    @Test func parsesStringsFiles() {
        let table = Strings.parse("""
        /* a comment */
        "Keys" = "키";
        // another
        "Say \\"hi\\"" = "line\\nbreak";
        """)
        #expect(table["Keys"] == "키")
        #expect(table["Say \"hi\""] == "line\nbreak")
    }

    @Test func fillsArguments() {
        #expect(Strings.fill("%@ → %@ · Forget", ["a", "b"]) == "a → b · Forget")
        #expect(Strings.fill("%ld days, 100%%", ["3"]) == "3 days, 100%")
    }
}

@MainActor @Suite(.serialized) struct BridgeTests {
    @Test func requestsGoThroughTheCInterface() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("araso-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = #"{ "support": "\#(folder.path)", "version": "0.2.2", "language": "en", "ownApp": "arasohost.exe" }"#
        #expect(araso_start(config) == 0)
        let answer = try #require(araso_request(#"{ "op": "attach", "app": "notepad.exe" }"#))
        defer { araso_free(answer) }
        let response = try JSONDecoder().decode(ServiceResponse.self, from: Data(String(cString: answer).utf8))
        #expect(response.reply.client != nil)
        // What the settings window shows as the version is the one the host started the runtime with.
        let model = try #require(araso_request(#"{ "op": "settings" }"#))
        defer { araso_free(model) }
        let settings = try JSONDecoder().decode(ServiceResponse.self, from: Data(String(cString: model).utf8))
        #expect(settings.settings?.version == "0.2.2")
        let bad = try #require(araso_request("not json"))
        defer { araso_free(bad) }
        #expect(String(cString: bad).contains("bad request"))
    }
}
