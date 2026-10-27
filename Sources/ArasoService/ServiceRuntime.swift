import ArasoCore
import Foundation

/// The Windows input method's state, in the host process: what `Runtime` and the input
/// controllers are on macOS. One `InputSession` per text service client (an app's UI thread with
/// Araso active), the shared engine, converter and settings, and the language bar menu.
///
/// The text service sends each key with a snapshot of the field (`TextContext`); the session runs
/// against a `SnapshotClient` of it, and the edits it made go back to be made in the app.
@MainActor
public final class ServiceRuntime {
    public struct Configuration: Codable, Sendable {
        /// The data files (english_words.txt…, the kanji dictionary in `Dictionary`, `ko.lproj`).
        public var resources: String?
        /// The settings folder; nil: Foundation's application support folder + `Araso`.
        public var support: String?
        /// This copy's version (for updates and About).
        public var version: String
        /// Windows' UI language (`ko-KR`): Korean UI text when it starts with `ko`.
        public var language: String
        /// The host's own exe name: its settings window's Try Typing field reports how words were decided.
        public var ownApp: String
        /// Load the kanji converter (the input method's host). The settings window only edits files.
        public var converter: Bool
        /// `windows` or `linux` (the fcitx5 addon): how keys are named, the platform's own UI text
        /// (`Windows.strings`, `Linux.strings`).
        public var platform: String
        /// The release asset this copy updates from; nil: Windows' installer.
        public var asset: String?

        public init(resources: String? = nil, support: String? = nil, version: String = "0",
                    language: String = "en", ownApp: String = "arasohost.exe", converter: Bool = true,
                    platform: String = "windows", asset: String? = nil) {
            self.resources = resources
            self.support = support
            self.version = version
            self.language = language
            self.ownApp = ownApp
            self.converter = converter
            self.platform = platform
            self.asset = asset
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            resources = try c.decodeIfPresent(String.self, forKey: .resources)
            support = try c.decodeIfPresent(String.self, forKey: .support)
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
            language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
            ownApp = try c.decodeIfPresent(String.self, forKey: .ownApp) ?? "arasohost.exe"
            converter = try c.decodeIfPresent(Bool.self, forKey: .converter) ?? true
            platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "windows"
            asset = try c.decodeIfPresent(String.self, forKey: .asset)
        }
    }

    /// One text service: an app thread with Araso active.
    final class Client {
        var session: InputSession
        var generation: Int
        var app: String?
        var taps = TapTracker()
        /// Edits the host started (a click in the candidate window, a menu item), made the next
        /// time the text service asks with a fresh snapshot.
        var pending: [(InputSession, SnapshotClient) -> Void] = []
    
        init(session: InputSession, generation: Int) {
            self.session = session
            self.generation = generation
        }
    }

    public private(set) var settings: Settings
    public private(set) var engine: DictionaryEngine
    private var converter: JapaneseConverter?
    public private(set) var generation = 0
    private var clients: [Int: Client] = [:]
    private var nextClient = 1
    /// The client of the text field in front, which a vim mode change is about.
    private var active: Int?
    /// The latest vim mode change and the app vim runs in (see Runtime on macOS).
    private var lastVim: (signal: VimSignal, app: String?)?
    private let configuration: Configuration
    /// How keys are named, and the release asset this copy updates from.
    private let platform: KeyMapper.Platform
    private let asset: String
    private let replacements = TextReplacementFile()
    /// The files changed from the menu: an open settings window reads them again.
    private var changedFiles = false

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        if let support = configuration.support { SupportDirectory.override = URL(fileURLWithPath: support, isDirectory: true) }
        if let resources = configuration.resources { Resources.directory = URL(fileURLWithPath: resources, isDirectory: true) }
        let linux = configuration.platform == "linux"
        platform = linux ? .linux : .windows
        asset = configuration.asset ?? UpdateStore.asset
        Strings.load(language: configuration.language, platform: linux ? "Linux" : "Windows",
                     from: [configuration.resources.map { URL(fileURLWithPath: $0, isDirectory: true) },
                            Self.packageRoot.appendingPathComponent("Resources"),
                            Self.packageRoot.appendingPathComponent(linux ? "linux/Resources" : "windows/Resources")].compactMap { $0 })
        AppPolicies.migrateSwitchKey()
        settings = Settings.load()
        LatinLayout.active = settings.latinLayout
        KoreanLayout.active = settings.koreanLayout
        LatinLayout.activeRomaji = settings.japaneseLayout
        engine = Self.makeEngine(japanese: settings.japanese)
        converter = settings.japanese && configuration.converter ? Self.makeConverter(settings) : nil
    }

    /// The source tree (Sources/ArasoService/ServiceRuntime.swift), for UI text in development.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Builds the models (and loads the kanji dictionary) before the first key.
    /// Loads what the first words would: the models and the converter, and whatever a session
    /// reaches only when typed through (the first Korean word took over a second, past the text
    /// service's wait).
    public func warmUp() {
        _ = engine.decide("warmup", context: DecisionContext())
        _ = converter?.candidates(for: "あ")
        let session = makeSession()
        let field = SnapshotClient.detached()
        for word in ["dkssud", "hello", "kyouha"] {
            for ch in word { _ = session.handle(.letter(ch), client: field) }
            session.commit(client: field)
        }
    }

    private static func makeEngine(japanese: Bool) -> DictionaryEngine {
        let heuristic = HeuristicEngine(japanese: japanese ? JapaneseModel.shared : nil)
        return DictionaryEngine(base: SplittingEngine(base: heuristic, english: heuristic.english,
                                                      japanese: heuristic.segmenter),
                                english: heuristic.english, korean: heuristic.korean,
                                japaneseParticles: heuristic.segmenter != nil)
    }

    /// AzooKey: macOS's engine doesn't exist on Windows.
    private static func makeConverter(_ settings: Settings) -> JapaneseConverter? {
        if settings.japaneseEngine != "azooKey", let apple = AppleJapaneseConverter() { return apple }
        return AzooKeyConverter()
    }

    private func makeSession() -> InputSession {
        let session = InputSession(engine: engine, policies: AppPolicies.load(),
                                   converter: settings.japanese ? converter : nil,
                                   japaneseEnabled: settings.japanese, liveConversion: settings.liveConversion,
                                   returnConfirmsOnly: settings.returnConfirmsOnly)
        session.replacements = replacements.entries
        session.fullWidthDigits = settings.fullWidthDigits
        session.fullWidthSpace = settings.fullWidthSpace
        return session
    }

    // MARK: - Requests

    /// Answers one request from the text service (or the settings window).
    public func handle(_ request: ServiceRequest) -> ServiceResponse {
        changedFiles = false
        var response: ServiceResponse
        switch request.op {
        case .attach:
            let id = nextClient
            nextClient += 1
            let client = Client(session: makeSession(), generation: generation)
            client.app = request.app
            client.session.activate(app: request.app)
            clients[id] = client
            active = id
            response = ServiceResponse()
            response.reply.client = id
        case .detach:
            if let id = request.client, let client = clients.removeValue(forKey: id) {
                client.session.commit(client: nil)
                converter?.save()
            }
            response = ServiceResponse()
        case .settings:
            response = ServiceResponse()
            response.settings = model()
        case .change:
            response = ServiceResponse()
            if let change = request.change { apply(change) }
            response.settings = model()
        case .reload:
            reloadFromDisk(kanjiReset: request.kanjiReset ?? false)
            response = ServiceResponse()
        case .release:
            response = ServiceResponse()
            let now = Date().timeIntervalSince1970
            if let body = request.body, let release = Release(gitHubJSON: Data(body.utf8), asset: asset) {
                UpdateStore.write(body: body, checked: now)
                response.release = ReleaseInfo(release, current: configuration.version)
            } else {
                UpdateStore.write(body: nil, checked: now)
                response.error = "no release"
            }
        case .decide:
            response = ServiceResponse()
            if let keys = request.keys, !keys.isEmpty {
                let decision = engine.decide(keys, context: DecisionContext(app: request.app))
                response.decision = TraceInfo(keys: keys, previous: nil, language: decision.language.rawValue,
                                              confidence: decision.confidence, output: decision.output,
                                              explanation: decision.explanation, partial: false)
            }
        case .readings:
            response = ServiceResponse()
            let keys = request.keys ?? ""
            let languages: [Language] = keys.isEmpty ? [] : Language.english.cycle(for: keys, japanese: settings.japanese)
            response.choices = languages.map { Choice(language: $0.rawValue, text: UserDictionary.reading(keys, as: $0)) }
        case .shortcut:
            response = ServiceResponse()
            guard let key = request.key, KeyMapper.modifier(key) == nil, let code = KeyMapper.macKeyCode(key),
                  let name = KeyMapper.keyName(key) else { break }
            let shortcut = PauseKey.Shortcut(keyCode: code, modifiers: KeyMapper.modifiers(key), key: name)
            response.shortcut = shortcut
            response.shortcutName = KeyMapper.shortcutName(shortcut, on: platform)
            switch shortcut.problem(switchKeys: AppPolicies.load().defaultPolicy.switchKeys) {
            case .types?: response.problem = "types"
            case .arasos?: response.problem = "arasos"
            case .switchKey?: response.problem = "switchKey"
            case nil: break
            }
        case .vim:
            response = ServiceResponse()
            guard let signal = request.vim.flatMap(VimSignal.init(rawValue:)) else { break }
            lastVim = (signal, request.app)
            if let id = active, clients[id] != nil {
                queue(id) { [weak self] session, field in self?.vimChanged(signal, from: request.app, session, field) }
            }
        default:
            guard let id = request.client, let client = clients[id] else {
                response = ServiceResponse()
                response.error = "unknown client"
                return response
            }
            response = handle(request, client: client, id: id)
        }
        if changedFiles { response.ui = response.ui ?? UIState(); response.ui?.settingsChanged = true }
        let waiting = clients.filter { !$0.value.pending.isEmpty }.map(\.key).sorted()
        if !waiting.isEmpty { response.notify = waiting }
        return response
    }

    private func handle(_ request: ServiceRequest, client: Client, id: Int) -> ServiceResponse {
        let field = request.op == .terminated ? SnapshotClient.detached() : SnapshotClient(request.context)
        var reply = ServiceReply()
        var ui = UIState()
        let session = session(client, field)
        switch request.op {
        case .focus:
            active = id
            client.app = request.app ?? client.app
            // What the last field had goes in there (`blur`); a word still on hand without a
            // composition in this field was lost with that field.
            if field.markedRange().location == NSNotFound { session.commit(client: SnapshotClient.detached()) }
            session.activate(app: client.app)
            session.replacements = replacements.entries
            if let last = lastVim { vimChanged(last.signal, from: last.app, session, field) }
        case .blur:
            session.commit(client: field)
            converter?.save()
        case .terminated:
            // The app ended the composition (a click elsewhere): the text stays as shown.
            session.commitForNewContext(client: field)
        case .key:
            guard let key = request.key else { break }
            // A password field: the keys go in as typed, as when paused (MaskedField on macOS).
            if request.context?.masked != true {
                reply.handled = handleKey(key, client: client, session: session, field: field, ui: &ui)
            }
            if !reply.handled, request.claimed == true, KeyMapper.modifier(key) == nil {
                // Kept from the app, so it can't type it: typed here, after the word, or sent again.
                if let text = KeyMapper.typed(key, policy: session.policy) {
                    field.insertText(text, replacing: nil)
                    reply.handled = true
                } else {
                    reply.replay = true
                }
            }
        case .test:
            guard let key = request.key else { break }
            reply.handled = request.up == true ? tapActs(key, client: client, session: session)
                                               : takes(key, client: client, session: session)
        case .keyUp:
            guard let key = request.key, let modifier = KeyMapper.modifier(key) else { break }
            switch client.taps.up(modifier, pauseKey: settings.pauseKey) {
            case .pause?:
                togglePause(session, field, ui: &ui)
                reply.handled = true
            case .cycle?:
                guard !session.inVimNormalMode else { break } // vim's own keys
                _ = session.handle(.cycle, client: field)
                // A lone Alt going up opens the app's menu bar: taken, so the app doesn't see it.
                reply.handled = true
            case nil:
                break
            }
        case .pending:
            let work = client.pending
            client.pending.removeAll()
            for item in work { item(session, field) }
        case .place:
            break // only the host uses where things are
        case .menu:
            reply.menu = menu(client: client, session: session)
        case .menuSelect:
            if let item = request.item { select(item, client: client, id: id, ui: &ui) }
        case .choose:
            if let index = request.index {
                queue(id) { session, field in session.choose(index, client: field) }
            }
        case .pick:
            // As macOS's strip does: the switch key pressed until that reading is on screen, once
            // round the readings at most (they can change as the word does).
            if let index = request.index, let readings = session.readings, readings.languages.indices.contains(index),
               index != readings.selected {
                let language = readings.languages[index]
                queue(id) { session, field in
                    for _ in 0..<4 {
                        guard let readings = session.readings, readings.languages[readings.selected] != language else { break }
                        _ = session.handle(.cycle, client: field)
                    }
                }
            }
        default:
            break
        }
        // A composition the app ended is already text: nothing to put in.
        reply.ops = request.op == .terminated ? [] : field.ops
        reply.converting = session.conversion != nil
        fill(&ui, client: client, session: session, field: field)
        return ServiceResponse(reply: reply, ui: ui.isEmpty ? nil : ui)
    }

    /// This client's session, rebuilt (after committing what was being typed) when a setting changed.
    private func session(_ client: Client, _ field: SnapshotClient) -> InputSession {
        guard client.generation != generation else { return client.session }
        let fresh = makeSession()
        client.session.commit(client: field)
        fresh.activate(app: client.session.app ?? client.app)
        client.session = fresh
        client.generation = generation
        return fresh
    }

    private func queue(_ id: Int, _ work: @escaping (InputSession, SnapshotClient) -> Void) {
        clients[id]?.pending.append(work)
    }

    /// Whether the host has edits waiting for this client (the text service then asks for them).
    public func hasPending(_ id: Int) -> Bool { !(clients[id]?.pending.isEmpty ?? true) }

    /// The client of the text field in front (a click in the candidate window is about it).
    public var activeClient: Int? { active }

    private func handleKey(_ key: WindowsKey, client: Client, session: InputSession, field: SnapshotClient,
                           ui: inout UIState) -> Bool {
        if let modifier = KeyMapper.modifier(key) {
            // Ctrl going down: a held word goes in before the shortcut, since an app may act on it
            // without showing it to the input method.
            if modifier.isCommand { session.commandPressed(client: field) }
            client.taps.down(modifier, held: KeyMapper.modifiers(key), pauseKey: settings.pauseKey,
                             switchKeys: session.policy.switchKeys)
            return false
        }
        if KeyMapper.isLock(key) { return false }
        client.taps.otherKey()
        // 한/영 and 한자 (right Alt and right Ctrl on Korean keyboards) act as they go down.
        if key.vk == KeyMapper.vkHangul {
            guard session.policy.switchKeys.contains(.rightOption), !session.inVimNormalMode else { return false }
            _ = session.handle(.cycle, client: field)
            return true
        }
        if key.vk == KeyMapper.vkHanja {
            guard settings.pauseKey == .tap(.rightCommand) else { return false }
            togglePause(session, field, ui: &ui)
            return true
        }
        if case .shortcut(let shortcut) = settings.pauseKey, let code = KeyMapper.macKeyCode(key),
           shortcut.matches(keyCode: code, modifiers: KeyMapper.modifiers(key)) {
            togglePause(session, field, ui: &ui)
            return true
        }
        let sessionKey = KeyMapper.sessionKey(key, policy: session.policy)
        let handled = session.handle(sessionKey, client: field)
        if !handled { replaceShortcut(after: sessionKey, field: field, session: session) }
        // The settings window's Try Typing shows how each word was decided; only there.
        if session.app == configuration.ownApp, let trace = session.lastTrace {
            ui.trace = TraceInfo(keys: trace.keys, previous: trace.previous?.rawValue,
                                 language: trace.decision.language.rawValue, confidence: trace.decision.confidence,
                                 output: trace.decision.output, explanation: trace.decision.explanation,
                                 partial: trace.partial)
        }
        return handled
    }

    /// Whether the text service keeps a key from the app (`test`). Letters, digits, Space and
    /// symbols are kept unless keys pass straight through (paused, vim's normal mode); any other key
    /// only when the session has a word to finish or a switch to make. A key that isn't kept goes to
    /// the app untouched (a shortcut's accelerator sees it) and the session only hears of it, as on
    /// macOS. Asked more than once for one key, it answers the same.
    private func takes(_ key: WindowsKey, client: Client, session: InputSession) -> Bool {
        if KeyMapper.modifier(key) != nil || KeyMapper.isLock(key) { return false }
        client.taps.otherKey() // a modifier held with it is a shortcut, kept or not
        if key.vk == KeyMapper.vkHangul {
            return session.policy.switchKeys.contains(.rightOption) && !session.inVimNormalMode
        }
        if key.vk == KeyMapper.vkHanja { return settings.pauseKey == .tap(.rightCommand) }
        if case .shortcut(let shortcut) = settings.pauseKey, let code = KeyMapper.macKeyCode(key),
           shortcut.matches(keyCode: code, modifiers: KeyMapper.modifiers(key)) { return true }
        let sessionKey = KeyMapper.sessionKey(key, policy: session.policy)
        if sessionKey == .cycle { return true }
        if session.paused || session.inVimNormalMode { return false }
        switch sessionKey {
        case .letter, .printable, .shiftSpace:
            return true
        case .escape where session.policy.switchKeys.contains(.escape):
            return true // it may switch the word just committed
        default:
            if !session.keys.isEmpty || session.conversion != nil { return true }
            _ = session.handle(sessionKey, client: SnapshotClient.detached())
            return false
        }
    }

    /// Whether a modifier going up ends a tap that does something (`test` with `up`): then the text
    /// service keeps it and sends `keyUp`. One that doesn't is done with here, since it won't come.
    private func tapActs(_ key: WindowsKey, client: Client, session: InputSession) -> Bool {
        guard let modifier = KeyMapper.modifier(key) else { return false }
        var taps = client.taps
        switch taps.up(modifier, pauseKey: settings.pauseKey) {
        case .pause?: return true
        case .cycle? where !session.inVimNormalMode: return true
        default: break
        }
        client.taps = taps
        return false
    }

    /// Windows apps don't replace text (macOS's do, on Space or punctuation after a shortcut), so
    /// a word that went in as a shortcut is replaced here, as it goes in, when Space or a symbol
    /// ended it and goes to the app after it.
    private func replaceShortcut(after key: InputSession.Key, field: SnapshotClient, session: InputSession) {
        guard case .printable(let ch) = key, ch == " " || (ch.isPunctuation || ch.isSymbol),
              let last = field.ops.last, last.kind == .insert, !last.text.isEmpty,
              let phrase = session.replacements[last.text]?.first, phrase != last.text else { return }
        field.replaceLastInsert(with: phrase)
    }

    private func togglePause(_ session: InputSession, _ field: SnapshotClient, ui: inout UIState) {
        session.togglePause(client: field)
        ui.paused = session.paused
    }

    /// Vim changed mode. Taken only when vim runs in this client's app, so a signal that arrives
    /// while focus moves between apps changes nothing elsewhere; a signal without its app is taken
    /// where Esc goes to the app.
    private func vimChanged(_ signal: VimSignal, from app: String?, _ session: InputSession, _ field: SnapshotClient) {
        guard app.map({ $0.lowercased() == session.app?.lowercased() }) ?? !session.policy.switchKeys.contains(.escape) else { return }
        session.vimChanged(to: signal, client: field)
    }

    /// What the host draws after this request.
    private func fill(_ ui: inout UIState, client: Client, session: InputSession, field: SnapshotClient) {
        if let conversion = session.conversion {
            ui.candidates = UIState.Candidates(texts: conversion.candidates.map(\.text), selected: conversion.selected,
                                               reading: conversion.kana)
        }
        if let readings = session.readings {
            ui.readings = UIState.Readings(texts: readings.texts, tags: readings.languages.map(\.tag),
                                           selected: readings.selected, remembered: readings.remembered,
                                           once: readings.once)
        }
        if let learned = session.learned {
            let learning: String
            switch learned.learning {
            case .once: learning = "once"
            case .forGood: learning = "forGood"
            case .forgot: learning = "forgot"
            }
            ui.learned = UIState.Learned(text: learned.text, tag: learned.language.tag, learning: learning)
        }
        ui.composing = field.markedRange().location != NSNotFound
    }

    // MARK: - Menu

    /// The language bar menu: the Mac input menu's items, with the same names.
    private func menu(client: Client, session: InputSession) -> [MenuItem] {
        var items: [MenuItem] = []
        func add(_ id: String?, _ title: String, on: Bool = false, enabled: Bool = true, indent: Int = 0) {
            items.append(MenuItem(id: enabled ? id : nil, title: String(repeating: "    ", count: indent) + title,
                                  checked: on, enabled: enabled && id != nil))
        }
        let pause: String
        switch settings.pauseKey {
        case .off: pause = L("Pause in This Text Field")
        case .tap(let tap): pause = L("Pause in This Text Field (%@)", L("right %@", KeyMapper.tapName(tap, on: platform)))
        case .shortcut(let shortcut): pause = L("Pause in This Text Field (%@)", KeyMapper.shortcutName(shortcut, on: platform))
        }
        add("pause", pause, on: session.paused)
        items.append(.line)
        if let app = session.app ?? client.app {
            let policies = AppPolicies.load()
            let policy = policies.policy(for: app)
            let listed = policies.overrides[app] != nil
            add(nil, listed ? L("%@ — App Settings", app) : L("%@ — Default Settings", app))
            add("app.enabled", L("Convert Words"), on: policy.enabled, indent: 1)
            add("app.normal", L("Conversion: Normal"), on: policy.conversionThreshold < AppPolicy.strictThreshold,
                enabled: policy.enabled, indent: 2)
            add("app.strict", L("Conversion: Strict"), on: policy.conversionThreshold >= AppPolicy.strictThreshold,
                enabled: policy.enabled, indent: 2)
            add("app.escape", L("Esc Switches Language"), on: policy.switchKeys.contains(.escape),
                enabled: policy.enabled, indent: 2)
            add("app.hold", L("Hold the Word After Space or Punctuation"), on: policy.holdSpace,
                enabled: policy.enabled, indent: 2)
            if listed { add("app.remove", L("Use Default Settings in This App"), indent: 1) }
            items.append(.line)
        }
        add("japanese", L("Japanese Input"), on: settings.japanese)
        add("live", L("Live Conversion"), on: settings.liveConversion, enabled: settings.japanese, indent: 1)
        items.append(.line)
        if let keys = engine.lastLearned { add("undo", L("Undo Last Learned (%@)", keys)) }
        // What the dictionary decided lately, to tell whether a word went in because of it and forget it.
        let applied = engine.recentlyApplied
        if !applied.isEmpty {
            add(nil, L("Changed by the Dictionary"))
            for word in applied {
                add("forget:" + word.keys, L("%@ → %@ · Forget", word.text, Self.languageName(word.language)), indent: 1)
            }
        }
        if settings.checkForUpdates, let release = UpdateStore.available(current: configuration.version, asset: asset) {
            add("update", L("Update to Araso %@…", release.version))
        }
        add("typing", L("Try Typing…"))
        add("learning", L("Dictionary…"))
        add("settings", L("Araso Settings…"))
        return items
    }

    static func languageName(_ language: Language) -> String {
        switch language {
        case .english: return L("English")
        case .korean: return L("Korean")
        case .mixed: return L("Mixed")
        case .japanese: return L("Japanese")
        }
    }

    private func select(_ item: String, client: Client, id: Int, ui: inout UIState) {
        let app = client.session.app ?? client.app
        switch item {
        case "pause":
            // The edit (the word in progress goes in) happens with the next snapshot.
            queue(id) { session, field in session.togglePause(client: field) }
            ui.paused = !client.session.paused
        case "app.enabled": updatePolicy(app) { $0.enabled.toggle() }
        case "app.normal": updatePolicy(app) { $0.conversionThreshold = AppPolicy.standard.conversionThreshold }
        case "app.strict": updatePolicy(app) { $0.conversionThreshold = AppPolicy.strictThreshold }
        case "app.escape": updatePolicy(app) { if $0.switchKeys.remove(.escape) == nil { $0.switchKeys.insert(.escape) } }
        case "app.hold": updatePolicy(app) { $0.holdSpace.toggle() }
        case "app.remove":
            guard let app else { break }
            var policies = AppPolicies.load()
            policies.overrides[app] = nil
            try? policies.save()
            generation += 1
            changedFiles = true
        case "japanese": update { $0.japanese.toggle() }
        case "live": update { $0.liveConversion.toggle() }
        case "undo":
            if let keys = engine.lastLearned { engine.forget(keys); changedFiles = true }
        case "update": ui.openSettings = "about"
        case "typing": ui.openSettings = "typing"
        case "learning": ui.openSettings = "learning"
        case "settings": ui.openSettings = "general"
        default:
            if item.hasPrefix("forget:") {
                engine.forget(String(item.dropFirst("forget:".count)))
                changedFiles = true
            }
        }
    }

    // MARK: - Settings

    /// Saves a settings change and applies it. Starts from the file: the settings window may have
    /// written it a moment ago.
    private func update(_ change: (inout Settings) -> Void) {
        var new = Settings.load()
        change(&new)
        try? new.save()
        if new != settings { apply(new) }
        changedFiles = true
    }

    private func updatePolicy(_ app: String?, _ change: (inout AppPolicy) -> Void) {
        guard let app else { return }
        var policies = AppPolicies.load()
        var policy = policies.policy(for: app)
        change(&policy)
        policies.set(policy, for: app)
        try? policies.save()
        generation += 1
        changedFiles = true
    }

    private func apply(_ new: Settings) {
        if new.japanese != settings.japanese {
            engine = Self.makeEngine(japanese: new.japanese)
        }
        if new.japanese, configuration.converter, converter == nil || new.japaneseEngine != settings.japaneseEngine {
            converter?.save()
            converter = Self.makeConverter(new)
        }
        settings = new
        LatinLayout.active = new.latinLayout
        KoreanLayout.active = new.koreanLayout
        LatinLayout.activeRomaji = new.japaneseLayout
        generation += 1
    }

    /// The settings window changed files: read them again.
    public func reloadFromDisk(kanjiReset: Bool) {
        if kanjiReset {
            // Drop the converter without saving, so its memory doesn't come back.
            converter = nil
            if settings.japanese, configuration.converter { converter = Self.makeConverter(settings) }
        }
        engine.reload()
        apply(Settings.load())
        generation += 1
    }

    /// What the settings window shows.
    public func model() -> SettingsModel {
        let policies = AppPolicies.load()
        let base = policies.defaultPolicy
        let apps = policies.apps.map { app in
            SettingsModel.App(app: app, entry: policies.overrides[app] ?? AppPolicy.Override(),
                              policy: SettingsModel.PolicyInfo(policies.policy(for: app)))
        }
        let today = Date()
        let words = engine.dictionary.entries.map { entry -> SettingsModel.Word in
            let status: String
            switch (entry.source, entry.strength) {
            case (.user, _): status = "added"
            case (_, .weak?): status = "once"
            default: status = "remembered"
            }
            let text = entry.language.map { UserDictionary.reading(entry.keys, as: $0) } ?? entry.text ?? ""
            return SettingsModel.Word(id: entry.id, keys: entry.keys, language: entry.language?.rawValue, text: text,
                                      status: status, apps: entry.apps,
                                      daysLeft: UserDictionary.daysLeft(entry, today: today))
        }
        return SettingsModel(settings: Settings.load(), defaultPolicy: SettingsModel.PolicyInfo(base), apps: apps,
                             words: words, version: configuration.version,
                             update: UpdateStore.available(current: configuration.version, asset: asset),
                             checked: UpdateStore.read()?.checked ?? 0, strictThreshold: AppPolicy.strictThreshold)
    }

    /// A change from the settings window, written to the files (the window's process; the
    /// input method's host reads them again on `reload`).
    public func apply(_ change: SettingsChange) {
        if let new = change.settings {
            try? new.save()
            apply(new)
        }
        if let info = change.defaultPolicy {
            var policies = AppPolicies.load()
            policies.setDefault(info.policy)
            try? policies.save()
            generation += 1
        }
        if let app = change.app?.trimmingCharacters(in: .whitespaces).lowercased(), !app.isEmpty, let entry = change.entry {
            var policies = AppPolicies.load()
            policies.setEntry(entry, for: app)
            try? policies.save()
            generation += 1
        }
        if let app = change.removeApp {
            var policies = AppPolicies.load()
            policies.overrides[app] = nil
            try? policies.save()
            generation += 1
        }
        if var entry = change.addWord {
            if let old = change.replacing, old != entry.id { engine.remove(old) }
            entry.apps = entry.apps.map { $0.map { $0.lowercased() } }
            engine.add(entry)
        }
        if let id = change.removeWord { engine.remove(id) }
        if let id = change.keepWord { engine.pin(id) }
        if change.forgetLearned == true { engine.forgetAll() }
        if change.resetKanji == true {
            if let memory = AzooKeyConverter.memoryURL {
                for item in (try? FileManager.default.contentsOfDirectory(at: memory, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: item)
                }
            }
            if let learning = AppleJapaneseConverter.learningURL { try? FileManager.default.removeItem(at: learning) }
            reloadFromDisk(kanjiReset: true)
        }
        if let checked = change.checked { UpdateStore.write(body: nil, checked: checked) }
    }
}
