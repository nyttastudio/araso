import Foundation

/// The text field the input method is typing into. Ranges are UTF-16, like NSString.
public protocol TextClient: AnyObject {
    func setMarkedText(_ text: String)
    /// Marked text in place of `range`, text the app already has (the marked text, if any, goes too).
    func setMarkedText(_ text: String, replacing range: NSRange)
    /// `range == nil` replaces the marked text (or the selection if nothing is marked).
    func insertText(_ text: String, replacing range: NSRange?)
    func selectedRange() -> NSRange
    func markedRange() -> NSRange
    func text(in range: NSRange) -> String?
    /// Marked text being converted to kanji: `selectedClause` (UTF-16, within `text`) is the clause
    /// the candidates are for, drawn thick as Japanese IMEs do; the rest of the reading is thin.
    /// `range` as in `setMarkedText(_:replacing:)`.
    func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?)
}

public extension TextClient {
    /// A client that draws no clauses shows the plain marked text.
    func setMarkedText(_ text: String, selectedClause: NSRange, replacing range: NSRange?) {
        if let range { setMarkedText(text, replacing: range) } else { setMarkedText(text) }
    }
}

/// Per-client typing state: the word being composed, the language of the previous
/// word, the last committed word (so Esc right after a commit can change it), and
/// an in-progress kana→kanji conversion.
///
/// While a word is being composed:
///   letters        extend it; the underlined preview shows the likely language
///   switch key     cycle it: english → english+particle (github에) → korean → japanese
///                  (the app's `switchKeys`: Esc, or `.cycle` for ⇧Esc and the others). Where
///                  Esc isn't one, or inside a vim that reports its modes, Esc commits and goes
///                  to the app
///   Delete         remove the last kana of a Japanese phrase; in Korean the last jamo of the
///                  syllable being typed, then whole syllables (as the system's 2-set does);
///                  else the last keystroke. The word keeps its language until the next letter.
///                  With live conversion the last clause goes back to kana (今日はいい天気 →
///                  今日はいいてん) until a letter completes a kana, as in macOS's.
///   Space          English/Korean: commit, then a space. Japanese: convert to kanji
///                  (`AppPolicy.holdSpace`: the space goes inside the underline instead, and the
///                  word stays the word being typed until the next one starts; a symbol is held
///                  the same way, and Space on a word held with a symbol commits it)
///                  (with `fullWidthSpace`, a space after Japanese text is full-width; ⇧Space
///                  types the other width)
///   0–9            with `fullWidthDigits`, after Japanese text or inside a phrase they are part
///                  of it, full-width (１２３, ０３－１２３４); Space offers the half-width form
///                  Otherwise the app types them; a switch key right after digits or symbols it
///                  typed makes them Japanese (123 → １２３, [ → 「), and in Japanese text a romaji
///                  word straight after a number is a counter, converted with it (3ji → 3時)
///   symbols        , . ? ! - ' inside a Japanese phrase are part of it (、。？！ー); otherwise
///                  a symbol commits the word, then types the key (`holdSpace`: held like Space)
///   Return         commit the word as shown, and nothing else (the next Return is the app's);
///                  with `returnConfirmsOnly` off the app gets it too, except after Japanese
///   anything else  commit and let the app handle the key
///   ⌘ going down   the word goes in (a held one with its boundary) before the shortcut (`commandPressed`;
///                  Windows's Ctrl only a held word, `heldWordOnly`)
/// While converting to kanji (candidate window open):
///   Space / ↓      next candidate          ↑      previous candidate
///   1–9            commit that candidate   Return commit the selected candidate
///   Esc            back to kana            letters/punctuation  commit, then keep typing
///   Delete         as macOS's Japanese input: without live conversion, commit what is shown less
///                  its last character (変換 → 変); with it, back to typing the phrase, its last
///                  clause as kana less one (今日はいい天気 → 今日はいいてん)
///   A candidate that covers only the start of the reading commits that part and
///   continues converting the rest.
/// Right after a word was committed with space/punctuation:
///   switch keys    cycle that committed word the same way (`AppPolicy.switchKeys`: Esc, or
///                  `.cycle` for the others).
///   Delete         the app deletes the space or punctuation; the word can still be changed.
/// A `.cycle` with nothing to change is dropped, never passed to the app.
///                  The same correction made twice is learned for good.
@MainActor
public final class InputSession {
    public enum Key: Equatable {
        case letter(Character)
        case delete
        case escape
        /// A switch key other than Esc (⇧Esc, a right ⌥ tap…), sent only where it is chosen.
        case cycle
        /// Space, digit or punctuation typed by the input method.
        case printable(Character)
        /// ⇧Space: a space of the other width (full-width where Space types a half-width one).
        case shiftSpace
        case enter
        case up
        case down
        /// ←/→: while converting, shorten or lengthen the first clause; otherwise like `other`.
        case left
        case right
        /// ⌃K / F7 and ⌃J / F6: the Japanese reading as katakana / hiragana.
        case katakana
        case hiragana
        /// Tab, shortcuts…: commit and let the app handle the key.
        case other

        /// The character a letter or printable key types.
        var character: Character? {
            switch self {
            case .letter(let ch), .printable(let ch): return ch
            default: return nil
            }
        }
    }

    /// A kana→kanji conversion in progress, or the phrases of a Korean or English text
    /// replacement shortcut offered the same way (`language`).
    public struct Conversion: Equatable {
        /// The reading still being converted (the shortcut, for phrases).
        public let kana: String
        /// The romaji that produced `kana`, so Esc can go back to editing it.
        public let keys: String
        public let candidates: [ConversionCandidate]
        public var selected: Int
        /// The user chose Japanese for these keys with Esc (going back to kana keeps that).
        var userForced = false
        /// Digits the app had already typed just before the phrase, taken into the reading
        /// (3ji → 3じ → 3時); not part of `keys`.
        var numberPrefix = ""
        /// Japanese for kana→kanji; Korean or English for a shortcut's phrases (ㅈㅅ entered more
        /// than once), which go in with the space that offered them and teach the converter nothing.
        var language = Language.japanese

        public var current: ConversionCandidate { candidates[selected] }
        /// How many candidates the window shows at a time, numbered 1 to 9 for the digit keys.
        public static let pageSize = 9
        /// What the user sees: the selected candidate, then any reading it doesn't cover.
        public var display: String { current.text + String(kana.dropFirst(current.kanaCount)) }
        /// The selected candidate's place in `display`: the clause being converted (今日は in
        /// 今日は|いいてんき).
        public var selectedClause: NSRange { NSRange(location: 0, length: (current.text as NSString).length) }
    }

    /// The readings a switch key goes through for the word it just changed, in order, and the
    /// one now shown: what the input method lists under the caret.
    public struct Readings: Equatable {
        public let texts: [String]
        /// Each reading's language, for its tag in the list.
        public let languages: [Language]
        public let selected: Int
        /// Araso's own reading, as if the keys had never been corrected, whatever the dictionary
        /// says: the one switching back to forgets a remembered word.
        public var own: Int? = nil
        /// The reading the dictionary remembers, learned for good or added by hand: the keys go in
        /// as it when left alone, over Araso's own.
        public var remembered: Int? = nil
        /// The reading the keys were corrected to once: the engine leans to it, and choosing it
        /// again learns it for good.
        public var once: Int? = nil
    }

    /// A correction the dictionary just took: the first one (the engine leans that way from now
    /// on), the second, the word learned for good, or a switch back to Araso's own reading that
    /// forgot it. The input method shows it by the word.
    public struct Learned: Equatable {
        public let text: String
        public let language: Language
        public var learning: DictionaryEngine.Learning = .forGood
    }

    private struct Committed {
        let keys: String
        /// What Araso chose before any Esc.
        let decided: Language
        /// What it went in as (Esc after the commit changes `language`).
        let committedAs: Language
        let language: Language
        /// Exactly what was inserted: the word plus its boundary character.
        let text: String
        let boundary: String
        let location: Int
        let previous: Language?
        /// A segment of a URL or path: a switch there isn't a correction to learn.
        var learns = true
        /// The key as typed when `boundary` is 3-set's symbol for it (B for ?): what the boundary
        /// goes back to when the word is switched out of Korean (지냈어? → ldhr2jtB).
        var typedBoundary: String?

        /// The same word after Delete took back its boundary character.
        var withoutBoundary: Committed {
            Committed(keys: keys, decided: decided, committedAs: committedAs, language: language,
                      text: String(text.dropLast(boundary.count)), boundary: "", location: location,
                      previous: previous, learns: learns)
        }

        /// The boundary as it goes in after the word in `language`.
        func boundary(in language: Language) -> String {
            language == .korean ? boundary : typedBoundary ?? boundary
        }
    }

    public let engine: DictionaryEngine
    public let converter: JapaneseConverter?
    public var japaneseEnabled: Bool
    public private(set) var keys = ""
    public private(set) var app: String?
    public private(set) var policy = AppPolicy.standard
    public private(set) var conversion: Conversion?
    /// Set by a switch key that changed a word (being typed or just committed), cleared by the
    /// next key: the readings to list while the user picks one.
    public private(set) var readings: Readings?
    /// Set by the key that made a correction stick (`Learned`), cleared by the next one.
    public private(set) var learned: Learned?
    private let policies: AppPolicies
    private var forced: Language?
    /// Whether `forced` is the user's choice (Esc) rather than "back to kana" after converting
    /// a phrase the engine read as Japanese anyway: only the user's choices are corrections.
    private var forcedByUser = false
    /// The language the engine itself showed last, before any Esc: what a commit compares
    /// against, so a forced reading is never mistaken for the engine's own choice.
    private var enginePreview: Language?
    /// The last `decide` kept a short token (3 keys or fewer, like a command) English only
    /// because the app is set to Strict. Longer words keep the hysteresis: applied to them it
    /// left 8% of Korean words English, against 5% this way, for the same English kept.
    private var keptEnglishByStrict = false
    /// "henkan" came back from conversion as "henkan'" (the final n stays ん); dropped again
    /// if the word leaves Japanese, so English doesn't get an apostrophe nobody typed.
    private var addedNMarker = false
    private var previousLanguage: Language? {
        didSet { if previousLanguage == nil { openBrackets.removeAll() } } // a new context
    }
    private var lastCommit: Committed?
    /// The boundary (Space or a symbol) the word was ended with in an app set to hold it
    /// (`AppPolicy.holdSpace`): the word stays composed, shown with that character, until the next
    /// word starts or another key finishes it. A switch key still cycles it and Delete takes back
    /// only the boundary. Terminals can't give a finished word back (Ghostty reports its mouse
    /// selection as the caret), so this keeps the word on hand.
    private var heldBoundary: Character? {
        didSet { if heldBoundary == nil { heldTyped = nil } }
    }
    /// The key as typed when `heldBoundary` is 3-set's symbol for it (B for ?): the boundary once
    /// the word is switched out of Korean, as `Committed.typedBoundary` is.
    private var heldTyped: Character?
    /// The held boundary as it goes in after the word in `language`.
    private func heldBoundary(in language: Language?) -> Character? {
        language == .korean ? heldBoundary : heldTyped ?? heldBoundary
    }
    /// The mode vim last reported (`vimChanged`), nil when no vim is reporting. In normal mode
    /// every key goes straight through; while vim reports at all, Esc is vim's.
    private var vimMode: VimSignal?
    /// The user paused Araso in this text field (the pause key): keys go through as typed
    /// until the next tap or another text field.
    public private(set) var paused = false
    /// Caps Lock was on when the word being typed (or the one just committed) started: the field
    /// is seen through `CapsLockClient` (`cased`), English going in in capitals.
    public private(set) var capsWord = false
    /// Language of the current preview, so in-phrase symbols know where they belong.
    private var previewLanguage: Language?
    /// The last key passed to the app was a digit (so "." there is a decimal point).
    private var afterDigit = false
    /// On 3-set, the keys since the last Korean word are symbols typed straight after it (지냈어?,
    /// 그래...): 3-set's symbols go on there (⇧/ is !), as they do right after the word itself.
    private var afterKoreanSymbol = false
    /// The word being typed starts after a space or straight after Hangul: on 3-set its 0s may
    /// be ㅋㅋ there, not in 1,000 or 10:00.
    private var startsAfterHangul = true
    /// Digits and symbols the app just typed for us, one after another, and where they start:
    /// a switch key right after them makes them Japanese (123 → １２３, [ → 「), and a Japanese
    /// phrase typed right after digits converts with them (3ji → 3時).
    private var passedRun: (text: String, location: Int)?
    /// The word being typed started right after a number, in Japanese text: a counter (3ji → 3時).
    private var afterNumberInJapanese = false
    /// The text gone in since the last Space, Tab or Return (`runKnown`), or since the caret moved
    /// or the field changed, when the text before the caret is read the first time it matters.
    private var runText = ""
    private var runKnown = false
    /// The word being typed is a segment of a URL or path (`hasURLMarker`): it goes in as typed.
    private var inURLRun = false
    /// Live conversion: a Japanese phrase is shown as its top kanji candidate while it is typed,
    /// and committed that way.
    public let liveConversion: Bool
    /// Return on an underlined word only confirms it (`Settings.returnConfirmsOnly`).
    public let returnConfirmsOnly: Bool
    /// The language shown when Delete was pressed, held until the next letter: a shorter word
    /// may read differently (한국 → 한구, not 한rn), but it shouldn't change under the user.
    private var pinned: Language?
    /// Where the Korean syllable being typed starts once Delete was used in the word: the system's
    /// 2-set input has committed everything before it, so those syllables delete whole and new
    /// jamo don't join them (세요 → 세ㅇ, not 셍). Nil until then: the word composes as one.
    private var syllableStart: Int?
    /// Digits after Japanese text, and inside a Japanese phrase, are part of it and full-width
    /// (`Settings.fullWidthDigits`), as addresses in Japan often need.
    public var fullWidthDigits = false
    /// A space after Japanese text is full-width (`Settings.fullWidthSpace`).
    public var fullWidthSpace = false
    private var digitsFullWidth: Bool { japaneseEnabled && fullWidthDigits && policy.fullWidth }
    /// Esc showed the current phrase's kana instead (the next Esc switches language as usual).
    private var liveSuppressed = false
    private var liveCache: (kana: String, candidate: ConversionCandidate?)?
    /// What live conversion keeps on screen after Delete, as macOS's does: the clauses before the
    /// last as they were shown (`prefix`, a conversion of the first `prefixLength` kana of
    /// `reading`), the rest as kana. Only while the reading stays `reading`: a letter that
    /// completes a kana converts the whole phrase again.
    private var liveKept: (prefix: String, prefixLength: Int, reading: String)?

    public init(engine: DictionaryEngine, policies: AppPolicies = AppPolicies(),
                converter: JapaneseConverter? = nil, japaneseEnabled: Bool = false, liveConversion: Bool = false,
                returnConfirmsOnly: Bool = true) {
        self.engine = engine
        self.policies = policies
        policy = policies.defaultPolicy
        self.converter = converter
        self.japaneseEnabled = japaneseEnabled
        self.liveConversion = liveConversion
        self.returnConfirmsOnly = returnConfirmsOnly
        if japaneseEnabled, let model = JapaneseModel.shared {
            segmenter = JapaneseSegmenter(english: EnglishModel.shared, japanese: model)
        }
    }

    /// A new text field became active: pick its app's policy and forget the sentence context.
    public func activate(app bundleIdentifier: String?) {
        closeFlipWindow()
        // Coming back to the same terminal leaves vim in whatever mode it was.
        if bundleIdentifier != app { vimMode = nil }
        app = bundleIdentifier
        policy = policies.policy(for: bundleIdentifier)
        previousLanguage = nil
        passedRun = nil
        paused = false
        resetRun()
    }

    /// Pauses or resumes Araso in this text field; what was being typed goes in first.
    public func togglePause(client: TextClient?) {
        if !paused { commit(client: client) }
        paused.toggle()
        previousLanguage = nil
        resetRun()
    }

    /// Vim's mode, from `Araso --vim` (the caller checks it came from this app).
    public func vimChanged(to signal: VimSignal, client: TextClient?) {
        if signal == .normal, vimMode != .normal {
            commit(client: client)
            previousLanguage = nil
            resetRun()
        }
        vimMode = signal == .off ? nil : signal
    }

    /// Whether keys currently go straight to vim (normal, visual or command-line mode).
    public var inVimNormalMode: Bool { vimMode == .normal }

    /// `handle` for a key typed with Caps Lock on or off. The letter comes in the case Shift alone
    /// gives it (the controller's job), so a word reads the same either way (GKAUS is 하면); what
    /// the word puts in the field goes through `cased`. Caps Lock changing inside a word commits
    /// what came before, and a new word starts.
    public func handle(_ key: Key, client: TextClient, capsLock: Bool) -> Bool {
        if capsLock != capsWord, startsOrExtendsWord(key, client) {
            // What came before goes in as it was shown, a candidate being chosen too, under the old
            // state; then the new word takes the new one.
            if !keys.isEmpty || conversion != nil { commit(client: cased(client)) }
            if keys.isEmpty, conversion == nil { capsWord = capsLock }
        }
        return handle(key, client: cased(client))
    }

    /// A letter, or a 3-set digit or symbol key whose jamo goes on with the word (`handle` makes
    /// it a letter).
    private func startsOrExtendsWord(_ key: Key, _ client: TextClient) -> Bool {
        switch key {
        case .letter: return true
        case .printable(let ch): return printableContinuesWord(ch, client)
        default: return false
        }
    }

    /// On 3-set a digit or symbol key with a jamo goes on with the word where the jamo fits
    /// (갔 is kf2, 밥 starts on ;); elsewhere it is the symbol. Not in a URL or path, though the
    /// word itself doesn't make one: 밝 is ;f@, not an address.
    private func printableContinuesWord(_ ch: Character, _ client: TextClient) -> Bool {
        heldBoundary == nil && (keys.isEmpty || !inURLRun)
            && KoreanLayout.current.continuesWord(keys, with: ch, afterDigit: afterDigit, knows: Self.koreanModel.knowsSyllableIncludingRare)
            && !Self.hasURLMarker(run(client))
    }

    /// The field as the word being typed sees it: through `CapsLockClient` when Caps Lock was on.
    public func cased(_ client: TextClient) -> TextClient {
        capsWord ? CapsLockClient(client) : client
    }

    /// Returns true when the key was consumed.
    public func handle(_ key: Key, client: TextClient) -> Bool {
        readings = nil
        learned = nil
        let inKoreanSymbols = afterKoreanSymbol
        afterKoreanSymbol = false
        guard policy.enabled, !paused else { return false }
        if vimMode == .normal {
            // Vim's normal mode: every key is a command. ⇧Esc is the way out if vim's last word
            // was lost (Vim not seeing the terminal's focus change): it only says "decide words".
            if key == .cycle { vimMode = nil; return true }
            previousLanguage = nil
            resetRun()
            return false
        }
        if key == .shiftSpace {
            // With nothing being typed, the other width: full-width unless Space already types that.
            guard keys.isEmpty, conversion == nil, japaneseEnabled, policy.fullWidth else {
                return handle(.printable(" "), client: client)
            }
            closeFlipWindow()
            if fullWidthSpace && previousLanguage == .japanese { noteRun(" "); return false } // the app types " "
            client.insertText("　", replacing: nil)
            noteRun("　")
            return true
        }
        if conversion != nil { return handleConverting(key, client: client) }
        if case .printable(let ch) = key, printableContinuesWord(ch, client) {
            return handle(.letter(ch), client: client)
        }
        // On 3-set a key with a digit or symbol there (⇧B ?, ⇧/ !, ⇧L 3, [ () types it right after
        // a Korean word and after the symbols that follow one; anywhere else it is QWERTY's (Bob),
        // also after Hangul with stray jamo (kgb, 그ㅜ), which isn't a word.
        if let typed = key.character, let symbol = Sebeolsik.symbol(for: typed), KoreanLayout.current.isSebeolsik,
           !inURLRun, keys.isEmpty ? inKoreanSymbols
               : heldBoundary.map { $0 != " " && currentLanguage() == .korean } ?? (currentLanguage() == .korean && readsAsKoreanWord()) {
            if heldBoundary != nil { commit(client: client) } // the held word and its symbol go in, then this one
            typeKoreanSymbol(symbol, typed: typed, client)
            return true
        }

        if case .printable = key, keys.isEmpty {} else { afterDigit = false }
        switch key {
        case .letter, .printable, .escape, .cycle: break
        default: passedRun = nil
        }
        let pending = lastCommit
        lastCommit = nil
        // Esc switches languages where it is a switch key (and no reporting vim owns it); the
        // other switch keys arrive as `.cycle` only where they are chosen.
        let switchesLanguage = key == .cycle || (key == .escape && policy.switchKeys.contains(.escape) && vimMode == nil)
        if switchesLanguage, keys.isEmpty, let pending {
            if let changed = cycle(pending, client: client) {
                lastCommit = changed
                readings = readings(of: changed.keys, as: changed.language, decided: changed.decided, rendered: committedReading)
                return true
            }
        }
        // Delete right after the commit: the app takes back the space or punctuation, and the
        // word itself can still be changed (Space before looking, then Delete and Esc).
        if key == .delete, keys.isEmpty, let pending, !pending.boundary.isEmpty {
            lastCommit = pending.withoutBoundary
            noteDeleted()
            return false
        }
        if let pending { finalize(pending) }
        if switchesLanguage, keys.isEmpty, let run = passedRunBeforeCaret(client) {
            passedRun = nil
            startSymbol(run.text, client, replacing: run.range)
            return true
        }

        switch key {
        case .letter(let ch):
            if heldBoundary != nil { commit(client: client) } // the held word goes in with its boundary; a new word starts
            // A symbol on its own is confirmed by the next word, which is judged by itself.
            if !keys.isEmpty, keys.allSatisfy({ RomajiComposer.symbols[$0] != nil }),
               !(KoreanLayout.current.isSebeolsik && keys.allSatisfy({ Sebeolsik.jamo(for: $0) != nil })) {
                commit(client: client) // (3-set's ; is ㅂ, a word on its way)
            }
            if keys.isEmpty { // a new word
                lastRecorded = nil
                liveSuppressed = false
                liveKept = nil
                let cursor = client.selectedRange()
                afterNumberInJapanese = japaneseEnabled && previousLanguage == .japanese
                    && passedRun?.text.last?.isNumber == true && cursor.location != NSNotFound
                    && passedRunRange(endingAt: cursor.location, client) != nil
                let before = run(client)
                inURLRun = Self.hasURLMarker(before)
                startsAfterHangul = before.last.map(Self.isHangul) ?? true
            }
            addedNMarker = false
            pinned = nil
            keys.append(ch)
            updatePreview(client)
            return true

        case .delete:
            if heldBoundary != nil {
                // Only the boundary comes back; the word is still there to be changed.
                heldBoundary = nil
                updatePreview(client)
                return true
            }
            guard !keys.isEmpty else { noteDeleted(); return false }
            let shown = forced ?? pinned ?? previewLanguage
            if forced == nil { pinned = shown }
            switch shown {
            case .japanese where isLive: deleteLive(deleteKana)
            case .japanese: deleteKana()
            case .korean: deleteJamoOrSyllable()
            default: keys.removeLast()
            }
            addedNMarker = false
            if keys.isEmpty { forced = nil; forcedByUser = false; pinned = nil; syllableStart = nil }
            updatePreview(client)
            return true

        case .escape, .cycle:
            // A chosen ⇧Esc is Araso's own: with nothing to change it goes nowhere, rather than
            // reaching the app as an Esc (in a terminal, Claude Code's "cancel the draft").
            guard !keys.isEmpty else { return key == .cycle }
            // A live-converted phrase goes back to its kana first, also with an Esc that isn't a
            // switch key, as in macOS's live conversion (not inside vim: Esc is vim's there). Only
            // with a conversion on screen: a phrase showing its kana anyway (たけ, whose first
            // candidate is the kana) switches or cancels at once, not after a press that changes nothing.
            if isLive, (forced ?? previewLanguage) == .japanese, switchesLanguage || vimMode == nil,
               japaneseDisplay() != japaneseReading(partial: true) {
                liveSuppressed = true
                updatePreview(client)
                return true
            }
            // Kana on screen: the app's Esc cancels the phrase, as in macOS's Japanese input,
            // rather than committing it and closing a window in the app.
            if !switchesLanguage, vimMode == nil, (forced ?? previewLanguage) == .japanese {
                cancelComposition(client)
                return true
            }
            guard switchesLanguage else {
                // The app's Esc: the word goes in as shown, then the app gets the key.
                commit(client: client)
                return false
            }
            // Cycle from what the user sees.
            let shown = forced ?? pinned ?? previewLanguage ?? decide(partial: true).language
            let next = shown.next(for: keys, japanese: japaneseEnabled, splits: engineSplits(keys))
            forced = next
            pinned = nil
            forcedByUser = true
            if next != .japanese { dropNMarker() }
            updatePreview(client)
            readings = readings(of: keys, as: next, decided: committedLanguage()) { _, language in self.rendering(as: language) }
            return true

        case .printable(let ch):
            if let held = heldBoundary {
                // A held word is still the word being typed: Space on it in Japanese (after a switch)
                // converts, as it would have before; the held space was never a Japanese one. A held
                // symbol ended the word for good: Space then commits it, no conversion.
                if ch == " ", held == " ", currentLanguage() == .japanese, converter != nil {
                    heldBoundary = nil
                    startConversion(client)
                    return true
                }
                commit(client: client) // the held word goes in with its boundary; the key follows as after any commit
            }
            if keys.isEmpty {
                defer { afterDigit = ch.isNumber }
                // Inside a URL or path symbols stay half-width, whatever came before: ほ@gmail.com.
                if Self.hasURLMarker(run(client) + String(ch)) {
                    passedRun = nil
                    noteRun(String(ch))
                    return false
                }
                if previousLanguage == .japanese {
                    if ch == " ", fullWidthSpace, japaneseEnabled, policy.fullWidth {
                        client.insertText("　", replacing: nil)
                        return true
                    }
                    // A number after Japanese text starts a Japanese word: １２３, ３がつ → ３月.
                    if ch.isASCII, ch.isNumber, digitsFullWidth {
                        startSymbol(String(ch), client)
                        return true
                    }
                }
                // After Japanese text a symbol is Japanese too (、。？！「」・…), underlined until Return
                // or the next word confirms it, as in a Japanese IME; Space shows its other forms.
                // Not inside a number (3.5, 10:30), but a bracket closes the way it was opened.
                if RomajiComposer.symbols[ch] != nil, (previousLanguage == .japanese && !afterDigit) || closesFullWidth(ch) {
                    startSymbol(String(ch), client)
                    return true
                }
                notePassed(ch, client)
                noteRun(String(ch))
                afterKoreanSymbol = inKoreanSymbols && ch != " "
                return false
            }
            // A symbol that makes the run a URL or path (ho@, www.) ends the word, half-width.
            let endsInURL = inURLRun || Self.hasURLMarker(run(client) + keys + String(ch))
            if japaneseEnabled, !endsInURL, belongsToJapanesePhrase(ch) {
                keys.append(ch)
                // Digits don't read as anything: the phrase stays Japanese, as it was shown.
                if ch.isNumber, forced == nil { forced = .japanese; forcedByUser = false }
                updatePreview(client)
                return true
            }
            if ch == " ", currentLanguage() == .japanese, converter != nil {
                startConversion(client)
                return true
            }
            if !endsInURL, closesFullWidth(ch) { // 日本語（English）
                commit(client: client)
                startSymbol(String(ch), client)
                return true
            }
            if policy.holdSpace, ch == " " || Self.isBoundarySymbol(ch) {
                // The word stays underlined with its boundary, shown as it would be committed (the
                // whole word's decision, not the last keystroke's preview), so a switch key still
                // changes it and Delete takes back the boundary. The next word commits both (see `heldBoundary`).
                let language = currentLanguage()
                if language != .japanese {
                    if forced == nil { pinned = language }
                    heldBoundary = ch
                    updatePreview(client)
                    afterKoreanSymbol = KoreanLayout.current.isSebeolsik && language.sentenceLanguage == .korean
                        && ch != " " && !inURLRun
                    return true
                }
            }
            if ch == " ", !endsInURL, offerPhrases(client) { return true }
            let marked = client.markedRange()
            let location = marked.location != NSNotFound ? marked.location : client.selectedRange().location
            let previous = previousLanguage
            passedRun = nil
            let word = finishWord()
            // Only the word goes in; the app types the space or punctuation itself, as with the
            // system's Korean input. Handing over "word + space" for the space key made terminals
            // (Ghostty, which sends the key with its text) add a stray character.
            client.insertText(word.text, replacing: nil)
            lastCommit = Committed(keys: word.keys, decided: word.decided, committedAs: word.language,
                                   language: word.language, text: word.text + String(ch), boundary: String(ch),
                                   location: location, previous: previous, learns: !inURLRun)
            noteRun(word.text + String(ch))
            afterKoreanSymbol = KoreanLayout.current.isSebeolsik && word.language.sentenceLanguage == .korean
                && ch != " " && !inURLRun
            return false

        case .enter:
            defer { noteRun("\n") }
            guard !keys.isEmpty else { return false }
            // Like a Japanese IME, Return on an underlined word only confirms it; the next Return
            // is the app's. Passed on (the setting off), terminals and web chats may still drop a
            // Return that ended a composition. A Japanese phrase is only confirmed either way.
            let japanese = currentLanguage() == .japanese
            commit(client: client)
            return returnConfirmsOnly || japanese

        case .katakana, .hiragana:
            // Only for a Japanese phrase; otherwise ⌃K/⌃J stay the app's shortcuts.
            if heldBoundary != nil { commit(client: client); return false } // a held word is done: the shortcut is the app's
            guard !keys.isEmpty, japaneseEnabled, forced == .japanese || previewLanguage == .japanese else {
                commit(client: client)
                return false
            }
            wordEnds(as: .japanese, engineChoice: committedLanguage())
            showKanaForms(key == .katakana, client: client)
            return true

        case .up, .down, .left, .right, .other:
            commit(client: client)
            previousLanguage = nil
            resetRun()
            return false

        case .shiftSpace: // handled above
            return false
        }
    }

    /// The ⌘ key went down (Ctrl on Windows). The word being typed goes in now, a held word with
    /// its boundary, before the shortcut: an app that acts on the shortcut itself never shows the
    /// input method the key (Ghostty's ⌘V and ⌘⌫ are its own keybindings), so it pasted over the
    /// underlined word, and its ⌘⌫ (a line delete there) skipped that word for the text before it
    /// (the underlined word wasn't text to it yet). The price is a ⌘ pressed and let go mid-word:
    /// the letters after it start a new word. With nothing being typed a ⌘ changes nothing, as
    /// before: the flip window stays open for the switch key. With `heldWordOnly` a word without a boundary keeps composing: on Windows the
    /// shortcut reaches the text service as a key and `.other` puts the word in first, so there
    /// is nothing to fix and a Ctrl let go on its own (AltGr sends a virtual left Ctrl) would only
    /// split the word. As after any shortcut, what comes next isn't known (the paste never
    /// reaches the input method either), so the run is read again from the field. Returns whether
    /// a word went in: the caller redraws the strip only then, or a ⌘ that changed nothing would
    /// start the learned capsule over.
    @discardableResult
    public func commandPressed(client: TextClient, heldWordOnly: Bool) -> Bool {
        if heldWordOnly, heldBoundary == nil { return false }
        guard !keys.isEmpty || conversion != nil else { return false }
        readings = nil // as on any key: the strip is synced right after this
        learned = nil
        commit(client: client)
        previousLanguage = nil
        resetRun()
        return true
    }

    /// Commits whatever is in progress as-is (focus change, shortcut, deactivation).
    public func commit(client: TextClient?) {
        closeFlipWindow()
        if let conversion, conversion.language != .japanese { return commitPhrase(client: client) }
        if let conversion {
            client?.insertText(conversion.display, replacing: nil)
            noteRun(conversion.display)
            noteBrackets(in: conversion.display)
            converter?.learn(conversion.current, for: conversion.kana)
            self.conversion = nil
            keys = ""
            previousLanguage = .japanese
            return
        }
        guard !keys.isEmpty else { heldBoundary = nil; return }
        let held = (boundary: heldBoundary, typed: heldTyped) // a held word goes in with its space or symbol
        heldBoundary = nil
        let word = finishWord()
        let boundary = (word.language == .korean ? held.boundary : held.typed ?? held.boundary).map(String.init) ?? ""
        client?.insertText(word.text + boundary, replacing: nil)
        noteRun(word.text + boundary)
    }

    /// The keys make whole syllables, or jamo on their own (ㅎㅎ, and ㅋㅋ on 0).
    private func readsAsKoreanWord() -> Bool {
        HangulComposer.compose(keys: keys).map { $0.strayJamo.isEmpty || $0.isJamoAbbreviation } == true
    }

    /// 3-set's `symbol` for the key `typed`, after a Korean word: the word goes in with it, and a
    /// switch key right after takes both back to the keys as typed (지냈어? → ldhr2jtB). After the
    /// symbols that follow the word, it goes in alone.
    private func typeKoreanSymbol(_ symbol: Character, typed: Character, _ client: TextClient) {
        afterKoreanSymbol = true
        afterDigit = symbol.isNumber // ⇧L⇧H is 30, and 0 after it a digit too
        passedRun = nil
        if policy.holdSpace, !keys.isEmpty, Self.isBoundarySymbol(symbol) {
            // Held as a symbol QWERTY types would be (see `heldBoundary`), so a switch key still
            // changes it where the app can't give a committed word back (Ghostty).
            if forced == nil { pinned = .korean }
            heldBoundary = symbol
            heldTyped = typed
            updatePreview(client)
            return
        }
        if keys.isEmpty {
            client.insertText(String(symbol), replacing: nil)
            noteRun(String(symbol))
            return
        }
        let marked = client.markedRange()
        let location = marked.location != NSNotFound ? marked.location : client.selectedRange().location
        let previous = previousLanguage
        let word = finishWord()
        let text = word.text + String(symbol)
        // Not left for the app to type as with QWERTY's symbols: its key types something else.
        client.insertText(text, replacing: nil)
        lastCommit = Committed(keys: word.keys, decided: word.decided, committedAs: word.language,
                               language: word.language, text: text, boundary: String(symbol),
                               location: location, previous: previous, typedBoundary: String(typed))
        noteRun(text)
    }

    /// Drops the word being typed: nothing goes in, as when Delete takes its last key.
    private func cancelComposition(_ client: TextClient) {
        keys = ""
        heldBoundary = nil
        forced = nil
        forcedByUser = false
        pinned = nil
        syllableStart = nil
        addedNMarker = false
        liveSuppressed = false
        liveKept = nil
        updatePreview(client)
    }

    /// Commits what's in progress after the caret was moved elsewhere (a click; the app asks):
    /// the next word doesn't continue the previous sentence.
    public func commitForNewContext(client: TextClient?) {
        commit(client: client)
        previousLanguage = nil
        resetRun()
    }

    /// Commits candidate `index` of the open conversion (e.g. clicked in the candidate window).
    public func choose(_ index: Int, client: TextClient) {
        guard let conversion, conversion.candidates.indices.contains(index) else { return }
        self.conversion?.selected = index
        commitCandidate(client: client)
    }

    // MARK: - URLs and paths

    /// Whether a run of text without spaces is a URL or path from here on: `://`, `www.`, `~/`,
    /// `./` or `../` at its start, a path that starts with `/` and has another, `@` after
    /// something (an email; `@홍길동` is a mention) or `localhost:`. A lone `.` or `/` isn't one:
    /// L.A.로, TV/라디오 and 남/여 are Korean.
    static func hasURLMarker(_ run: String) -> Bool {
        run.contains("://") || run.contains("localhost:")
            || ["www.", "~/", "./", "../"].contains(where: run.hasPrefix)
            || (run.hasPrefix("/") && run.dropFirst().contains("/"))
            || run.dropFirst().contains("@")
    }

    /// The run of text before the word being typed: what went in since the last space, with
    /// what the field had before the caret when that isn't known (a pasted URL, a click).
    private func run(_ client: TextClient) -> String {
        guard !runKnown else { return runText }
        runKnown = true
        let marked = client.markedRange(), cursor = client.selectedRange()
        // Up to the word being typed, if there is one on screen.
        let end = marked.location != NSNotFound ? marked.location : cursor.length == 0 ? cursor.location : NSNotFound
        guard end != NSNotFound else { return runText }
        let start = max(0, end - Self.runLookBehind)
        guard let before = client.text(in: NSRange(location: start, length: end - start)) else { return runText }
        let field = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        if field.hasSuffix(runText) { runText = field }
        return runText
    }

    /// How far back the field is read for the run (UTF-16 units).
    private static let runLookBehind = 256

    /// Keeps the run up to date with text going in; Space, Tab and Return end it. A URL or path
    /// counts as English for the next word.
    private func noteRun(_ text: String) {
        for ch in text {
            if ch.isWhitespace {
                if Self.hasURLMarker(runText) { previousLanguage = .english }
                runText = ""
                runKnown = true
            } else {
                runText.append(ch)
            }
        }
    }

    /// The app deleted the character before the caret, nothing being typed.
    private func noteDeleted() {
        if runText.isEmpty { runKnown = false } else { runText.removeLast() }
    }

    /// The caret moved or the field changed: what is before the caret is read again when needed.
    private func resetRun() {
        runText = ""
        runKnown = false
    }

    // MARK: - Japanese conversion

    /// A symbol typed as its own Japanese word, shown full-width (or as the 「」・ a Japanese IME types).
    /// With `range`, it takes the place of what the app typed there, in one step: an empty
    /// insertText to delete it first is dropped on the way to the app (1 became 1１). Nor can the
    /// result be checked: the app answers markedRange before it has applied the change.
    private func startSymbol(_ symbol: String, _ client: TextClient, replacing range: NSRange? = nil) {
        lastRecorded = nil
        liveSuppressed = false
        liveKept = nil
        keys = symbol
        forced = .japanese
        forcedByUser = false
        guard let range else { return updatePreview(client) }
        previewLanguage = .japanese
        client.setMarkedText(japaneseDisplay(), replacing: range)
    }

    /// Keeps `passedRun` up to date with a key the app is about to type.
    private func notePassed(_ ch: Character, _ client: TextClient) {
        let cursor = client.selectedRange()
        guard japaneseEnabled, policy.fullWidth, ch.isASCII, ch.isNumber || RomajiComposer.symbols[ch] != nil,
              cursor.location != NSNotFound, cursor.length == 0 else {
            passedRun = nil
            return
        }
        if let run = passedRun, run.location + (run.text as NSString).length == cursor.location {
            passedRun = (run.text + String(ch), run.location)
        } else {
            passedRun = (String(ch), cursor.location)
        }
    }

    /// The range of `passedRun` when it is still in the text, unchanged, ending at `end`.
    private func passedRunRange(endingAt end: Int, _ client: TextClient) -> NSRange? {
        guard let run = passedRun else { return nil }
        let range = NSRange(location: run.location, length: (run.text as NSString).length)
        guard NSMaxRange(range) == end, client.text(in: range) == run.text else { return nil }
        return range
    }

    /// The digits and symbols just typed, and where they are, when the caret is right after them.
    private func passedRunBeforeCaret(_ client: TextClient) -> (text: String, range: NSRange)? {
        let cursor = client.selectedRange()
        guard japaneseEnabled, conversion == nil, let run = passedRun, cursor.location != NSNotFound, cursor.length == 0,
              let range = passedRunRange(endingAt: cursor.location, client) else { return nil }
        return (run.text, range)
    }

    /// Full-width openers not closed yet in this sentence, so ) ] } close them full-width
    /// after an English word too.
    private var openBrackets: [Character] = []
    private static let closing: [Character: Character] = [")": "（", "]": "「", "}": "｛"]
    private static let pairs: [Character: Character] = ["）": "（", "」": "「", "｝": "｛", "』": "『", "】": "【"]

    private func closesFullWidth(_ ch: Character) -> Bool {
        guard let opener = Self.closing[ch] else { return false }
        return openBrackets.last == opener
    }

    /// Keeps `openBrackets` up to date with text going in.
    private func noteBrackets(in text: String) {
        for ch in text {
            if Self.pairs.values.contains(ch) {
                openBrackets.append(ch)
            } else if let opener = Self.pairs[ch], openBrackets.last == opener {
                openBrackets.removeLast()
            }
        }
    }

    /// Whether a symbol typed after the current word continues a Japanese phrase.
    /// Sentence punctuation (、。？！) never changes the word's language: it joins only a
    /// word already read as Japanese ("hello." and "dho?" = 왜? stay what they were).
    /// The in-word marks ー and ' may also turn an English-looking start into Japanese
    /// ("ra" → "ra-" → らー), but never take a word away from Korean.
    private func belongsToJapanesePhrase(_ ch: Character) -> Bool {
        if ch.isASCII, ch.isNumber {
            guard digitsFullWidth else { return false }
            return forced == .japanese || (forced == nil && previewLanguage == .japanese
                                           && ["", "n"].contains(RomajiComposer.compose(keys, partial: true).pending.lowercased()))
        }
        guard JapaneseModel.inPhraseSymbols.contains(ch) else { return false }
        if forced == .japanese { return true }
        // On the way to a Japanese text replacement shortcut with a symbol in it: gu- is ぐー,
        // even though gu alone read as 혀.
        if japaneseEnabled, forced == nil, case let kana = RomajiComposer.compose(keys + String(ch), partial: true),
           kana.isClean, replacements.keys.contains(where: { $0.hasPrefix(kana.text) }) {
            return true
        }
        // A letter still waiting for its vowel says the word may not be Japanese after all
        // (baz) is baz), not ばz）); a final n is ん (nihon. is にほん。).
        if previewLanguage == .japanese {
            return ch == "-" || ch == "'" || ["", "n"].contains(RomajiComposer.compose(keys, partial: true).pending.lowercased())
        }
        // An English word before the mark keeps it English (to-do, co-op); ra-men isn't one.
        guard forced == nil, ch == "-" || ch == "'", previewLanguage == .english,
              !EnglishModel.shared.isKnownWord(keys),
              RomajiComposer.compose(keys, partial: true).strayLetters == 0 else { return false }
        let context = DecisionContext(previousLanguage: previousLanguage, partial: true, app: app)
        return engine.decide(keys + String(ch), context: context).language == .japanese
    }

    /// The user's text replacements (shortcut → phrases, System Settings → Keyboard; a shortcut
    /// may be there more than once). A word whose reading is a shortcut shows that way, so the app
    /// replaces it on Space as it would with the system's input; a Japanese one also offers every
    /// phrase as the first candidates.
    public var replacements: [String: [String]] = [:]

    /// The Korean or Japanese reading of the keys that is a text replacement shortcut (주소, ㅈㅅ,
    /// よろ), unless the user taught Araso otherwise for these keys. English shortcuts are left
    /// to the engine: "go" may be one, and still be ご in a Japanese sentence.
    private func shortcutReading(partial: Bool) -> (language: Language, text: String)? {
        guard !replacements.isEmpty, !keys.isEmpty, engine.learned[keys] == nil else { return nil }
        if let hangul = hangul(), replacements[hangul] != nil { return (.korean, hangul) }
        if japaneseEnabled {
            let kana = RomajiComposer.compose(keys, partial: partial)
            if kana.isClean, replacements[kana.text] != nil { return (.japanese, kana.text) }
        }
        return nil
    }

    /// Splits English words out of a Japanese phrase (google in kyouhagoogledekensaku).
    public var segmenter: JapaneseSegmenter?

    /// Kana for the keys, with any English words inside the phrase kept as typed.
    private func japaneseReading(partial: Bool) -> String {
        // An English word with a particle (redde → redで) even when every key also makes kana,
        // as the engine split it; a reading the user picked by hand stays kana (れっで).
        if !(forced == .japanese && forcedByUser), let (word, particle) = segmenter?.englishWithParticle(keys) {
            return word + particle
        }
        if !partial {
            // Letters still waiting for their vowel when the phrase ends go in as shown
            // (watashihag → わたしはg, not わたしhag); only n becomes ん.
            let typed = RomajiComposer.compose(keys, partial: true)
            if typed.strayLetters == 0, !typed.pending.isEmpty { return RomajiComposer.compose(keys, partial: false).text }
            if let segments = segmenter?.segment(keys) { return JapaneseSegmenter.text(segments) }
        }
        // While typing, a consonant at the end is just waiting for its vowel (watashihag → わたしはg),
        // not a stray letter to split an English word ("hag") out of.
        if partial, RomajiComposer.compose(keys, partial: true).strayLetters > 0, let segments = segmenter?.segment(keys) {
            // While typing, the last segment may still be growing; keep its pending letters visible.
            return JapaneseSegmenter.text(segments.dropLast()) + {
                if case .japanese(let k, _) = segments.last! { return RomajiComposer.compose(k, partial: true).text }
                return JapaneseSegmenter.text([segments.last!])
            }()
        }
        return RomajiComposer.compose(keys, partial: partial).text
    }

    // MARK: - Live conversion

    private var isLive: Bool { liveConversion && !liveSuppressed && converter != nil }

    /// The top candidate covering all of `kana` (cached: the preview asks on every key).
    private func liveCandidate(for kana: String) -> ConversionCandidate? {
        if let cached = liveCache, cached.kana == kana { return cached.candidate }
        var candidate = conversionCandidates(for: kana).first { $0.kanaCount == kana.count && !$0.isPrediction }
        // A short reading only turns into kanji (私, 今日), not into katakana mid-word
        // (と → ト, こんに → コンに): those flicker while the phrase is still being typed.
        if kana.count <= 3, let c = candidate, !c.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            candidate = nil
        }
        liveCache = (kana, candidate)
        return candidate
    }

    /// The Japanese phrase as shown while typing: kana, or with live conversion the top
    /// candidate followed by letters still waiting for their vowel (今日はいい天気でs).
    private func japaneseDisplay() -> String {
        let reading = japaneseReading(partial: true)
        guard isLive, let (kana, pending) = liveReading() else { return reading }
        if let kept = keptOnScreen(kana) { return kept + pending }
        guard !kana.isEmpty, let candidate = liveCandidate(for: kana) else { return reading }
        return candidate.text + pending
    }

    /// The phrase's reading without the letters still waiting for their vowel, and those letters.
    private func liveReading() -> (kana: String, pending: String)? {
        let reading = japaneseReading(partial: true)
        let pending = RomajiComposer.compose(keys, partial: true).pending
        guard reading.hasSuffix(pending) else { return nil }
        return (String(reading.dropLast(pending.count)), pending)
    }

    /// What Delete left of a live-converted `kana` on screen (`liveKept`), if that is still it.
    private func keptOnScreen(_ kana: String) -> String? {
        guard let kept = liveKept, kept.reading == kana else { return nil }
        return kept.prefix + kana.dropFirst(kept.prefixLength)
    }

    /// Delete with live conversion, as macOS's: the last clause on screen goes back to kana, less
    /// its last kana (今日はいい天気 → 今日はいいてん, 漢字k → かんじ), the clauses before it stay
    /// as they were shown, and further Deletes take kana off the end. `deleteKeys` takes the kana
    /// off the keys; `shown` is a conversion on screen instead of live conversion's.
    private func deleteLive(shown: (text: String, kana: String)? = nil, _ deleteKeys: () -> Void) {
        guard let (typed, _) = liveReading() else { return deleteKeys() }
        let kana = shown?.kana ?? typed
        var (prefix, length): (String, Int)
        if let shown {
            (prefix, length) = (shown.text, kana.count)
        } else if let kept = liveKept, kept.reading == kana {
            (prefix, length) = (kept.prefix, kept.prefixLength)
        } else if !kana.isEmpty, let candidate = liveCandidate(for: kana) {
            (prefix, length) = (candidate.text, kana.count)
        } else {
            (prefix, length) = ("", 0)
        }
        deleteKeys()
        let after = liveReading()?.kana ?? ""
        // Nothing shown as kana after the conversion: this Delete reaches its last clause.
        if length >= kana.count || after.count < length {
            repeat {
                (prefix, length) = Self.dropLastClause(prefix, reading: String(kana.prefix(length)))
            } while after.count < length
        }
        liveKept = after.isEmpty ? nil : (prefix, length, after)
    }

    /// The clauses before the last of `text`, a conversion of `reading`, and how much of the
    /// reading they cover. The last clause is the last run of kanji (or katakana, or anything not
    /// typed as it shows) with the kana after it: 天気です in 今日はいい天気です. ("", 0) when
    /// there is nothing before it, or the text can't be matched to the reading.
    static func dropLastClause(_ text: String, reading: String) -> (String, Int) {
        let chars = Array(text)
        /// Kana and letters show as typed; anything else converted some of the reading.
        func literal(_ c: Character) -> Bool {
            c.isASCII || c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
        }
        guard var start = chars.lastIndex(where: { !literal($0) }) else { return ("", 0) }
        while start > 0, !literal(chars[start - 1]) { start -= 1 }
        let prefix = Array(chars[..<start])
        let kana = Array(reading)
        // How much of the reading the prefix covers, its conversions as short as they can be
        // (今日 is きょう in きょうははこ, so 箱 is はこ); the last clause keeps at least one kana.
        func covered(_ p: Int, _ r: Int) -> Int? {
            guard p < prefix.count else { return r < kana.count ? r : nil }
            if literal(prefix[p]) {
                return r < kana.count && kana[r] == prefix[p] ? covered(p + 1, r + 1) : nil
            }
            var end = p
            while end < prefix.count, !literal(prefix[end]) { end += 1 }
            for r2 in stride(from: r + 1, through: kana.count, by: 1) {
                if let found = covered(end, r2) { return found }
            }
            return nil
        }
        guard !prefix.isEmpty, let length = covered(0, 0) else { return ("", 0) }
        return (String(prefix), length)
    }

    /// What a Japanese phrase commits as without the candidate window: the kana, or with
    /// live conversion the candidate that was on screen (which the converter learns).
    private func committedJapanese() -> String {
        let reading = japaneseReading(partial: false)
        // Letters still waiting for their vowel follow the candidate, as japaneseDisplay shows
        // them (今日はいい天気でs, not a candidate for the whole reading with the s in it).
        let pending = RomajiComposer.compose(keys, partial: true).pending
        let kana = reading.hasSuffix(pending) ? String(reading.dropLast(pending.count)) : reading
        let letters = String(reading.dropFirst(kana.count))
        // What Delete left on screen goes in as shown; nothing was chosen to learn.
        if isLive, let kept = keptOnScreen(kana) { return kept + letters }
        guard isLive, let converter, !kana.isEmpty, let candidate = liveCandidate(for: kana) else { return reading }
        converter.learn(candidate, for: kana)
        return candidate.text + letters
    }

    private func startConversion(_ client: TextClient) {
        var kana = japaneseReading(partial: false)
        guard converter != nil, !kana.isEmpty else { return }
        // After a Delete live conversion shows the end as kana (へんかn), not a candidate: Space
        // shows the first one (変換), as macOS does.
        let kept = isLive ? liveReading().flatMap { keptOnScreen($0.kana) } : nil
        // Nor is one on screen with a letter waiting for its vowel: 変化n was へんか's, so Space on
        // henkan shows へんかん's first, 変換, as macOS does, not the one after it.
        let pendingShown = isLive && !(liveReading()?.pending.isEmpty ?? true)
        let userForced = forced == .japanese && forcedByUser
        wordEnds(as: .japanese, engineChoice: committedLanguage())
        // A number the app typed just before the phrase is part of it: 3ji is 3時, not 3 and 時
        // picked out of 地, 字, 自…
        let marked = client.markedRange()
        var prefixRange: NSRange?
        if marked.location != NSNotFound, let run = passedRun, run.text.last?.isNumber == true,
           run.text.allSatisfy({ Self.numberCharacters.contains($0) }),
           let range = passedRunRange(endingAt: marked.location, client) {
            prefixRange = NSRange(location: range.location, length: range.length + marked.length)
            kana = run.text + kana
        }
        let numberPrefix = prefixRange == nil ? "" : passedRun!.text
        passedRun = nil
        var candidates = conversionCandidates(for: kana)
        if !numberPrefix.isEmpty {
            // The number as it was typed (3時) before other widths and spellings (３時, 三時).
            candidates = candidates.filter { $0.text.hasPrefix(numberPrefix) } + candidates.filter { !$0.text.hasPrefix(numberPrefix) }
        }
        // Live conversion showed the phrase without the number, so no candidate is on screen yet.
        let live = isLive && numberPrefix.isEmpty && kept == nil && !pendingShown ? liveCandidate(for: kana) : nil
        if let phrases = replacements[kana], !phrases.isEmpty {
            // Text replacements come first, or right after the live candidate already on screen.
            let at = live.flatMap { candidates.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let added = phrases.map { ConversionCandidate(text: $0, kanaCount: kana.count) }
            candidates = Array(candidates[..<at]).filter { !phrases.contains($0.text) } + added
                + candidates[at...].filter { !phrases.contains($0.text) }
        }
        // Every other homophone the engine has follows, for the candidate window (しょう → 硝).
        let listed = Set(candidates.map(\.text))
        candidates += (converter?.moreCandidates(for: kana) ?? []).filter { !listed.contains($0.text) }
        guard !candidates.isEmpty else {
            commit(client: client)
            return
        }
        // With live conversion the top candidate is already on screen: Space shows the next one.
        var selected = 0
        if let live, let i = candidates.firstIndex(of: live), candidates.count > 1 {
            selected = (i + 1) % candidates.count
        } else if liveConversion, numberPrefix.isEmpty, candidates.count > 1, candidates[0].text == kana {
            // The kana is on screen (a short reading kept as kana, or brought back with Esc) and the
            // engine put it first (しょう): Space shows a conversion, 翔, as macOS does, not the kana again.
            selected = 1
        }
        liveSuppressed = false
        liveKept = nil
        conversion = Conversion(kana: kana, keys: keys, candidates: candidates, selected: selected, userForced: userForced,
                                numberPrefix: numberPrefix)
        keys = ""
        forced = nil
        forcedByUser = false
        pinned = nil
        syllableStart = nil
        enginePreview = nil
        previousLanguage = .japanese
        showConversion(client, replacing: prefixRange) // with a prefix: the number, then the phrase
    }

    /// Space on a Korean or English text replacement shortcut entered more than once (ㅈㅅ for two
    /// phrases): the phrases are offered as a Japanese shortcut's are, oldest first, then the
    /// shortcut as typed. The app would replace it with one phrase only (AppKit keeps one per
    /// shortcut); with a single phrase it still does. False when the word isn't such a shortcut.
    private func offerPhrases(_ client: TextClient) -> Bool {
        let language = currentLanguage()
        guard language == .korean || language == .english else { return false }
        dropNMarker()
        let shortcut = language == .korean ? hangul() ?? engine.render(keys, as: language) : engine.render(keys, as: language)
        guard let phrases = replacements[shortcut]?.filter({ $0 != shortcut }), phrases.count > 1 else { return false }
        let userForced = forced == language && forcedByUser
        wordEnds(as: language, engineChoice: committedLanguage())
        let candidates = (phrases + [shortcut]).map { ConversionCandidate(text: $0, kanaCount: shortcut.count) }
        conversion = Conversion(kana: shortcut, keys: keys, candidates: candidates, selected: 0, userForced: userForced,
                                language: language)
        passedRun = nil
        keys = ""
        forced = nil
        forcedByUser = false
        pinned = nil
        syllableStart = nil
        addedNMarker = false
        previewLanguage = nil
        enginePreview = nil
        showConversion(client)
        return true
    }

    /// The chosen phrase of a Korean or English shortcut, with the space that offered it.
    private func commitPhrase(client: TextClient?) {
        guard let conversion else { return }
        let text = conversion.current.text + " "
        client?.insertText(text, replacing: nil)
        noteRun(text)
        noteBrackets(in: conversion.current.text)
        previousLanguage = conversion.language.sentenceLanguage
        self.conversion = nil
    }

    /// Shows the reading as katakana (or hiragana) as the selected "candidate": Return
    /// commits it, Space flips to the other form, typing on commits it and continues.
    private func showKanaForms(_ katakanaFirst: Bool, kana: String? = nil, keys romaji: String? = nil, client: TextClient) {
        let kana = kana ?? japaneseReading(partial: false)
        let forms = [ConversionCandidate(text: RomajiComposer.katakana(kana), kanaCount: kana.count),
                     ConversionCandidate(text: kana, kanaCount: kana.count)]
        conversion = Conversion(kana: kana, keys: romaji ?? keys, candidates: katakanaFirst ? forms : forms.reversed(), selected: 0)
        keys = ""
        forced = nil
        forcedByUser = false
        pinned = nil
        syllableStart = nil
        enginePreview = nil
        previousLanguage = .japanese
        showConversion(client)
    }

    /// The conversion as the marked text, its selected clause marked as such.
    private func showConversion(_ client: TextClient, replacing range: NSRange? = nil) {
        guard let conversion else { return }
        client.setMarkedText(conversion.display, selectedClause: conversion.selectedClause, replacing: range)
    }

    /// The conversion with its first clause `step` kana shorter or longer (今日は|いいてんき):
    /// candidates for exactly that much of the reading, the rest shown as kana. A boundary
    /// never falls inside an English word (google). Nil when it can't move further.
    private func resizeFirstClause(_ conversion: Conversion, by step: Int) -> Conversion? {
        guard converter != nil else { return nil }
        let reading = Array(conversion.kana)
        var length = conversion.current.kanaCount + step
        while (1..<reading.count).contains(length),
              reading[length - 1].isASCII, reading[length - 1].isLetter, reading[length].isASCII, reading[length].isLetter {
            length += step
        }
        guard (1...reading.count).contains(length), length != conversion.current.kanaCount else { return nil }
        let clause = String(reading[..<length])
        let candidates = conversionCandidates(for: clause).filter { $0.kanaCount == clause.count }
        guard !candidates.isEmpty else { return nil }
        return Conversion(kana: conversion.kana, keys: conversion.keys, candidates: candidates, selected: 0,
                          userForced: conversion.userForced, numberPrefix: conversion.numberPrefix)
    }

    private func handleConverting(_ key: Key, client: TextClient) -> Bool {
        guard var conversion else { return false }
        switch key {
        case .printable(" "), .down, .shiftSpace:
            conversion.selected = (conversion.selected + 1) % conversion.candidates.count
            self.conversion = conversion
            showConversion(client)
            return true

        case .up:
            conversion.selected = (conversion.selected + conversion.candidates.count - 1) % conversion.candidates.count
            self.conversion = conversion
            showConversion(client)
            return true

        case .left, .right:
            if conversion.language == .japanese, let resized = resizeFirstClause(conversion, by: key == .left ? -1 : 1) {
                self.conversion = resized
                showConversion(client)
            }
            return true

        case .printable(let ch) where ch.isNumber:
            // The digits number the page on show.
            let start = conversion.selected / Conversion.pageSize * Conversion.pageSize
            if let n = ch.wholeNumberValue, n >= 1, start + n - 1 < conversion.candidates.count {
                choose(start + n - 1, client: client)
                return true
            }
            commit(client: client)
            return handle(key, client: client)

        case .enter:
            commitCandidate(client: client)
            return true

        case .katakana, .hiragana:
            guard conversion.language == .japanese else {
                commit(client: client) // a shortcut's phrase: ⌃K/⌃J stay the app's shortcuts
                return false
            }
            self.conversion = nil
            showKanaForms(key == .katakana, kana: conversion.kana, keys: conversion.keys, client: client)
            return true

        case .escape, .cycle, .delete:
            self.conversion = nil
            guard conversion.language == .japanese else {
                // Back to the shortcut as typed; Space offers its phrases again.
                keys = conversion.keys
                forced = conversion.userForced ? conversion.language : nil
                forcedByUser = conversion.userForced
                updatePreview(client)
                return true
            }
            // Delete with live conversion off: the conversion on screen goes in less its last
            // character (変換 → 変), as in macOS's Japanese input.
            if key == .delete, !liveConversion {
                let text = String(conversion.display.dropLast())
                client.insertText(text, replacing: nil)
                noteRun(text)
                noteBrackets(in: text)
                previousLanguage = .japanese
                return true
            }
            // "Back to kana" means kana, also with live conversion; Delete goes on with it.
            liveSuppressed = key != .delete
            // A number taken in from before the phrase goes back as it was typed.
            if !conversion.numberPrefix.isEmpty {
                client.insertText(conversion.numberPrefix, replacing: nil)
                noteRun(conversion.numberPrefix)
            }
            let kana = String(conversion.kana.dropFirst(conversion.numberPrefix.count))
            // Back to editing the romaji — when it still spells the reading. After part of a
            // phrase with English in it was committed it may not; keep the kana rather than lose it.
            guard JapaneseSegmenter.reading(of: conversion.keys, segmenter: segmenter) == kana else {
                let text = key == .delete ? String(kana.dropLast()) : kana
                client.insertText(text, replacing: nil)
                noteRun(text)
                previousLanguage = .japanese
                return true
            }
            keys = conversion.keys
            syllableStart = nil
            if key == .delete {
                // With live conversion, as macOS's: typing the phrase again, its last clause back
                // to kana less the last one (今日はいい天気 → 今日はいいてん), the clauses before it as shown.
                forced = .japanese
                forcedByUser = conversion.userForced
                let shown = conversion.numberPrefix.isEmpty ? conversion.display : ""
                deleteLive(shown: (shown, kana), deleteKana)
                if keys.isEmpty { forced = nil; forcedByUser = false }
                updatePreview(client)
                return true
            }
            // A final "n" was shown as ん; keep it ("henkan" → "henkan'") instead of
            // letting it wait for a vowel again.
            if keys.hasSuffix("n"), !keys.hasSuffix("nn") { keys += "'"; addedNMarker = true }
            forced = .japanese
            forcedByUser = conversion.userForced
            updatePreview(client)
            return true

        case .letter, .printable:
            commit(client: client)
            return handle(key, client: client)

        case .other:
            commit(client: client)
            return false
        }
    }

    /// Commits the selected candidate; if it covers only the start of the reading,
    /// keeps converting the rest.
    private func commitCandidate(client: TextClient) {
        if let conversion, conversion.language != .japanese { return commitPhrase(client: client) }
        guard let conversion, let converter else { return }
        let candidate = conversion.current
        converter.learn(candidate, for: conversion.kana)
        client.insertText(candidate.text, replacing: nil)
        noteRun(candidate.text)
        noteBrackets(in: candidate.text)
        let rest = String(conversion.kana.dropFirst(candidate.kanaCount))
        self.conversion = nil
        guard !rest.isEmpty else { return }
        let restKeys = Self.keys(conversion.keys, after: max(0, candidate.kanaCount - conversion.numberPrefix.count))
        let candidates = conversionCandidates(for: rest)
        if candidates.isEmpty {
            client.insertText(rest, replacing: nil)
            noteRun(rest)
        } else {
            // The rest is the engine's Japanese, not something the user corrected.
            self.conversion = Conversion(kana: rest, keys: restKeys, candidates: candidates, selected: 0)
            showConversion(client)
        }
    }

    /// The converter's candidates, with a number kept as typed: a reading that is only a number
    /// offers itself (１２３) and its half-width form (123) first; otherwise the candidates that keep
    /// the digits come before those that spell them out (３月, 3月, then 三月; 東京都１, not 東京都一).
    private func conversionCandidates(for kana: String) -> [ConversionCandidate] {
        let candidates = converter?.candidates(for: kana) ?? []
        let digits = Self.digits(of: kana)
        guard !digits.isEmpty else { return candidates }
        let whole = candidates.filter { $0.kanaCount == kana.count }
        var ordered = whole.filter { Self.digits(of: $0.text) == digits } + whole.filter { Self.digits(of: $0.text) != digits }
        if kana.allSatisfy({ Self.numberCharacters.contains($0) }) {
            ordered = [ConversionCandidate(text: kana, kanaCount: kana.count),
                       ConversionCandidate(text: Self.halfWidth(kana), kanaCount: kana.count)] + ordered
        }
        var shown = Set<String>()
        return (ordered + candidates.filter { $0.kanaCount != kana.count }).filter { shown.insert($0.text).inserted }
    }

    /// What a number reading is made of: digits and the punctuation inside numbers, either width.
    static let numberCharacters = Set("0123456789０１２３４５６７８９－．，／：-.,/:")

    /// The digits of `text` in order, as ASCII ("東京都１－２" → "12").
    static func digits(of text: String) -> String {
        String(halfWidth(text).filter { $0.isASCII && $0.isNumber })
    }

    /// Full-width ASCII (！ to ～) as ASCII.
    static func halfWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0xFF01...0xFF5E).contains($0.value) ? Unicode.Scalar($0.value - 0xFEE0)! : $0
        }))
    }

    /// The romaji left after the part that produced the first `kanaCount` kana: the
    /// shortest tail that composes to exactly the remaining kana ("kitte" after きっ is
    /// "te"; "konnichiha" after こん is "nichiha").
    static func keys(_ keys: String, after kanaCount: Int) -> String {
        let chars = Array(keys)
        let rest = String(RomajiComposer.compose(keys).text.dropFirst(kanaCount))
        for i in stride(from: chars.count, through: 0, by: -1) where RomajiComposer.compose(String(chars[i...])).text == rest {
            return String(chars[i...])
        }
        return ""
    }

    // MARK: - Private

    private func decide(partial: Bool) -> Decision {
        // A segment of a URL or path goes in as typed, before the dictionary is asked (so in a
        // URL is so even where it was taught to be 내).
        if inURLRun {
            keptEnglishByStrict = false
            let decision = Decision(language: .english, confidence: 1, output: keys, explanation: "inside a URL or path")
            lastTrace = Trace(keys: keys, previous: previousLanguage, decision: decision, partial: partial)
            return decision
        }
        if let shortcut = shortcutReading(partial: partial) {
            // As sure as a split word, so a Strict app shows it too.
            keptEnglishByStrict = false
            let decision = Decision(language: shortcut.language, confidence: SplittingEngine.confidence,
                                    output: shortcut.text, explanation: "text replacement shortcut")
            lastTrace = Trace(keys: keys, previous: previousLanguage, decision: decision, partial: partial)
            return decision
        }
        // A word typed straight after a number in Japanese text is a counter when it is romaji
        // (3ji, 5fun, 3hon); a unit like km or pm has letters that aren't (5km stays English).
        if afterNumberInJapanese, keys.allSatisfy(\.isLetter), RomajiComposer.compose(keys, partial: partial).strayLetters == 0 {
            keptEnglishByStrict = false
            let decision = Decision(language: .japanese, confidence: SplittingEngine.confidence,
                                    output: RomajiComposer.compose(keys, partial: partial).text,
                                    explanation: "counter after a number")
            lastTrace = Trace(keys: keys, previous: previousLanguage, decision: decision, partial: partial)
            return decision
        }
        // 3-set's 0 is ㅋ: after Korean, 0000 is ㅋㅋㅋㅋ (a number to the engine, which a switch key gives).
        if KoreanLayout.current.isSebeolsik, previousLanguage == .korean, startsAfterHangul, Sebeolsik.isLaughter(keys) {
            keptEnglishByStrict = false
            let decision = Decision(language: .korean, confidence: SplittingEngine.confidence,
                                    output: HangulComposer.compose(keys: keys)?.text ?? keys, explanation: "ㅋ on 3-set's 0 after Korean")
            lastTrace = Trace(keys: keys, previous: previousLanguage, decision: decision, partial: partial)
            return decision
        }
        var d = engine.decide(keys, context: DecisionContext(previousLanguage: previousLanguage, partial: partial, app: app))
        // A word learned as Japanese while Japanese was on: with it off, the engine without what
        // was learned decides it (sushi stays sushi, not すし). Turned on again, it is learned again.
        if d.language == .japanese, !japaneseEnabled {
            d = engine.base.decide(keys, context: DecisionContext(previousLanguage: previousLanguage, partial: partial, app: app))
        }
        // While typing, a consonant at the end may still be waiting for its vowel, which keeps
        // Japanese close and a Korean word under a Strict app's threshold until the word ends
        // (qud: 0.60 while typed, 0.98 at Space). The word as it would go in now decides, so the
        // preview shows what Space commits (병), not English that turns Korean on Space.
        if partial, d.language == .korean, d.confidence < policy.conversionThreshold {
            let now = engine.decide(keys, context: DecisionContext(previousLanguage: previousLanguage, partial: false, app: app))
            if now.language == .korean, now.confidence >= policy.conversionThreshold { d = now }
        }
        // Typed with Caps Lock, keys that are loose jamo throughout, two or more, are an acronym
        // (RST, RD, DDR): the capitals that made them English without Caps Lock are gone, and as
        // lowercase they read as chat jamo (ㄱㄴㅅ). The same while typing and at Space, so what is
        // shown goes in; a word with a syllable in it (안녕ㄱ) and one jamo alone (ㅎ, on its way
        // to 하면) read as without Caps Lock. English the engine chose by a hair over Korean gets the
        // same certainty, so the ㄱ shown on RD's first key doesn't hold on through the hysteresis;
        // over Japanese it stays as it was (hon is ほん). A word the dictionary remembers keeps its
        // language.
        if capsWord, d.language == .korean || d.language == .english && d.runnerUp == .korean,
           engine.rememberedLanguage(keys, app: app) == nil,
           let composed = HangulComposer.compose(keys: keys), composed.units.count >= 2, composed.syllables.isEmpty {
            d = Decision(language: .english, confidence: 1, output: keys, explanation: "Caps Lock: loose jamo")
        }
        let kept = d.language != .english && d.confidence < policy.conversionThreshold
        keptEnglishByStrict = kept && policy.conversionThreshold >= AppPolicy.strictThreshold && keys.count <= 3
        let decision = kept
            ? Decision(language: .english, confidence: 1 - d.confidence, output: keys,
                       explanation: String(format: "kept English (%.2f < %.2f); ", d.confidence,
                                           policy.conversionThreshold) + d.explanation)
            : d
        lastTrace = Trace(keys: keys, previous: previousLanguage, decision: decision, partial: partial)
        return decision
    }

    /// The last decision and what it was made from, for the settings window's typing test.
    public struct Trace: Sendable {
        public let keys: String
        public let previous: Language?
        public let decision: Decision
        /// Still being typed (the preview) rather than committed.
        public let partial: Bool
    }
    public private(set) var lastTrace: Trace?

    /// The language the current word will be committed in.
    private func currentLanguage() -> Language {
        forced ?? pinned ?? committedLanguage()
    }

    /// What Space/Return commits without Esc: the full-word decision, except that a hesitant
    /// change away from the reading on screen doesn't win (unless Strict kept it English). The
    /// same rule as the preview, so what you see is what you get.
    private func committedLanguage() -> Language {
        let d = decide(partial: false)
        guard let shown = enginePreview, shown != d.language else { return d.language }
        // Japanese on screen, kana or kanji: Space converts it, unless the keys are an English
        // word. A short word reads as the start of a longer Japanese one while typed and as
        // English once it ends (zi showed 地 and zio じお, then went in as "zi", "zio"), and a
        // Strict app's short token kept English would go in as letters under its kana (ka under か).
        if shown == .japanese, d.language == .english,
           !EnglishModel.shared.isKnownWord(keys), RomajiComposer.compose(keys).isClean {
            return shown
        }
        return isWeakFlipAllowed(to: d, from: shown) ? d.language : shown
    }

    /// Whether `decision` may replace the reading on screen: when it's confident, when it's
    /// a dictionary English word (which is what Space/Return will commit), or when a Strict app
    /// kept a short token English: there the typed letters win over a reading shown along the
    /// way (gs showed ㅎㄴ, but gst stays gst).
    private func isWeakFlipAllowed(to decision: Decision, from shown: Language) -> Bool {
        decision.confidence >= Self.previewFlipConfidence
            || (decision.language == .english && (keptEnglishByStrict || EnglishModel.shared.isKnownWord(keys)))
            || preview(as: shown) == nil
    }

    private func updatePreview(_ client: TextClient) {
        if keys.isEmpty {
            heldBoundary = nil
            previewLanguage = nil
            enginePreview = nil
            client.setMarkedText("")
        } else if let forced = forced ?? pinned {
            previewLanguage = forced
            show(rendering(as: forced), client)
        } else {
            if !inURLRun {
                splitOffKoreanBeforeOther(client)
                splitOffJapaneseBeforeKorean(client)
            }
            let decision = decide(partial: true)
            var language = decision.language
            // Hysteresis: a weak flip on one keystroke (わた → "wat" → わたし) isn't shown,
            // except into a dictionary English word, which is what Space/Return will commit.
            if let shown = previewLanguage, shown != language, keys.count > 1, !isWeakFlipAllowed(to: decision, from: shown) {
                language = shown
            }
            previewLanguage = language
            enginePreview = language
            show(language == .japanese ? japaneseDisplay() : preview(as: language) ?? keys, client)
        }
    }

    /// The word being typed as a reading the user chose (a switch key) shows it.
    private func rendering(as language: Language) -> String {
        switch language {
        case .japanese: return japaneseDisplay()
        case .korean: return hangul() ?? keys
        default: return engine.render(keys, as: language)
        }
    }

    /// A committed word's keys as they go in when cycled to `language`.
    private func committedReading(_ keys: String, as language: Language) -> String {
        language == .japanese ? JapaneseSegmenter.reading(of: keys, segmenter: segmenter) : engine.render(keys, as: language)
    }

    /// The switch key's readings for `keys`, `language` selected; nil when there is nothing to
    /// choose between.
    /// `decided` is the reading the keys got before any switch: Araso's own unless the dictionary
    /// has them, then asked again without it, as the dictionary does when a switch goes back.
    private func readings(of keys: String, as language: Language, decided: Language,
                          rendered: (String, Language) -> String) -> Readings? {
        let cycle = language.cycle(for: keys, japanese: japaneseEnabled, splits: engineSplits(keys))
        guard cycle.count > 1, let selected = cycle.firstIndex(of: language) else { return nil }
        let remembered = engine.rememberedLanguage(keys, app: app)
        let once = engine.correctedOnce(keys, app: app)
        let own = remembered == nil && once == nil ? decided
            : engine.ownDecision(keys, context: DecisionContext(app: app)).language
        return Readings(texts: cycle.map { rendered(keys, $0) }, languages: cycle, selected: selected,
                        own: cycle.firstIndex(of: own), remembered: remembered.flatMap { cycle.firstIndex(of: $0) },
                        once: once.flatMap { cycle.firstIndex(of: $0) })
    }

    /// The word being composed as the marked text, with its boundary while it is held.
    private func show(_ text: String, _ client: TextClient) {
        client.setMarkedText(heldBoundary(in: previewLanguage).map { text + String($0) } ?? text)
    }

    /// An ASCII symbol that ends a word and is held with it in a `holdSpace` app: anything the
    /// input method types after a word except Space (held on its own terms) and digits (which
    /// commit the word and go to the app, as they do with holding off).
    static func isBoundarySymbol(_ ch: Character) -> Bool {
        ch.isASCII && ch != " " && !ch.isLetter && !ch.isNumber
    }

    private static let koreanModel = KoreanModel()

    private static func isHangul(_ ch: Character) -> Bool {
        ("가"..."힣").contains(ch) || ("ㄱ"..."ㅣ").contains(ch)
    }

    /// Korean with another language typed straight after it reads as broken Hangul: 이력 then
    /// rireki (dlfurrireki, 이력갹다ㅑ), 오늘은 then google에서 (dhsmfdmsgoogledptj, 오늘은해ㅐ힏에서).
    /// When the keys only make Hangul with stray jamo, but a front of two or more ordinary
    /// syllables is followed by a known English word (or one with a particle) or by romaji the
    /// engine is sure is Japanese, the Korean goes in as typed and the rest carries on as its own
    /// word (live conversion and Space for candidates when it's Japanese: 이력履歴).
    private func splitOffKoreanBeforeOther(_ client: TextClient) {
        guard keys.count >= 7,
              HangulComposer.compose(keys: keys)?.isBroken == true,
              // Only what reads as Korean on its own: a Japanese phrase whose start happens to
              // spell Hangul (chanwo…, 초무をころした) stays whole. Judged without context, since
              // right after Japanese everything leans Japanese.
              engine.decide(keys, context: DecisionContext(partial: true, app: app)).language == .korean else { return }
        let chars = Array(keys)
        for cut in 4...(chars.count - 3) {
            let front = String(chars[..<cut]), back = String(chars[cut...])
            guard let korean = HangulComposer.compose(keys: front), korean.strayJamo.isEmpty,
                  korean.syllables.count >= 2,
                  korean.syllables.allSatisfy({ Self.koreanModel.syllableLogProbability($0) > KoreanModel.unknownSyllableLogP }),
                  isOtherLanguageWord(back) else { continue }
            client.insertText(korean.text, replacing: nil)
            noteRun(korean.text)
            keys = back
            syllableStart = nil
            previousLanguage = .korean
            previewLanguage = nil
            enginePreview = nil
            return
        }
    }

    /// A known English word, one with a Korean particle (google에서), or romaji the engine is
    /// sure is Japanese (no word starts with っ or ん: that cut takes a letter from the Korean).
    private func isOtherLanguageWord(_ keys: String) -> Bool {
        let decision = engine.decide(keys, context: DecisionContext(previousLanguage: .korean, partial: true, app: app))
        switch decision.language {
        case .english: return keys.count >= 3 && EnglishModel.shared.isKnownWord(keys)
        case .mixed: return true
        case .japanese:
            guard japaneseEnabled, decision.confidence >= 0.9, keys.count >= 4 else { return false }
            let romaji = RomajiComposer.compose(keys, partial: true)
            return romaji.strayLetters == 0 && romaji.text.first.map { $0 != "っ" && $0 != "ん" } ?? false
        case .korean: return false
        }
    }

    /// Japanese with Korean typed straight after it reads as broken Hangul: a particle
    /// (rirekifmf, 履歴를, not 갹다ㅑ를) or a word (kyouhaehtl…, 今日は도시락은). Once the Korean
    /// part is a particle or two ordinary syllables, the Japanese goes in (kanji with live
    /// conversion) and the rest carries on as Korean, so 를요, 에서 or 도시락은 can follow.
    private func splitOffJapaneseBeforeKorean(_ client: TextClient) {
        guard japaneseEnabled, keys.count >= 5,
              HangulComposer.compose(keys: keys)?.isBroken ?? true,
              // Keys that still spell romaji are more Japanese (kyouhago is きょうはご, not きょうは해).
              RomajiComposer.compose(keys, partial: true).strayLetters > 0 else { return }
        let chars = Array(keys)
        // The longest Japanese front first: きょうは|도시, not きょう|하ㄷ….
        for cut in stride(from: chars.count - 1, through: 3, by: -1) {
            let front = String(chars[..<cut]), back = String(chars[cut...])
            guard back.first.map(DubeolsikLayout.startsSyllable) == true,
                  let korean = HangulComposer.compose(keys: back), korean.strayJamo.isEmpty,
                  MixedWord.suffixes.contains(korean.text)
                    || (korean.syllables.count >= 2
                        && korean.syllables.allSatisfy({ Self.koreanModel.syllableLogProbability($0) > KoreanModel.unknownSyllableLogP })),
                  RomajiComposer.compose(front).isClean,
                  // Not an English word with a particle (linderman isn't linで그무).
                  segmenter?.englishWithParticle(front) == nil,
                  case let decision = engine.decide(front, context: DecisionContext(previousLanguage: previousLanguage, app: app)),
                  decision.language == .japanese, decision.confidence >= 0.9 else { continue }
            keys = front
            let japanese = committedJapanese()
            client.insertText(japanese, replacing: nil)
            noteRun(japanese)
            keys = back
            syllableStart = nil
            previousLanguage = .japanese
            forced = .korean
            forcedByUser = false
            previewLanguage = nil
            enginePreview = nil
            return
        }
    }

    /// The preview only switches language mid-word when the new reading is at least this likely.
    static let previewFlipConfidence = 0.7

    /// The word so far rendered in `language`, or nil when it has no such reading.
    private func preview(as language: Language) -> String? {
        switch language {
        case .english: return keys
        case .korean: return hangul()
        case .mixed:
            let text = engine.render(keys, as: .mixed)
            return text == keys ? nil : text
        case .japanese:
            // Only っ and letters (ss: っs) is no Japanese word, so it isn't a reading to hold on to.
            guard japaneseEnabled else { return nil }
            return RomajiComposer.compose(keys, partial: true).isOnlySokuon ? nil : japaneseReading(partial: true)
        }
    }

    /// The word goes in as the engine chose: if its dictionary entry decided that, the input
    /// menu lists it among the words the dictionary changed.
    private func noteRemembered(as language: Language) {
        guard pinned == nil else { return }
        let decision = decide(partial: false)
        guard decision.language == language, let keys = decision.rememberedKeys, let count = decision.remembered else { return }
        engine.noteApplied(keys: keys, text: String(decision.output.prefix(count)), language: language)
    }

    /// The word being typed ends as `language`: it goes in, or its conversion, kana forms or a
    /// shortcut's phrases start. A correction the user made to it is learned; otherwise it was
    /// typed again (a weak entry saying so stays) and, when its dictionary entry decided it, it
    /// is listed. Inside a URL or path it isn't a word: neither.
    private func wordEnds(as language: Language, engineChoice: Language) {
        guard !inURLRun else { return }
        if forced != nil, forcedByUser {
            record(keys, as: language, engineChoice: engineChoice)
        } else {
            engine.used(keys, as: language)
            noteRemembered(as: language)
        }
    }

    /// Decides the current word, learns an Esc override, and resets the buffer.
    private func finishWord() -> (keys: String, text: String, language: Language, decided: Language) {
        let engineChoice = committedLanguage()
        let language = forced ?? pinned ?? engineChoice
        if language != .japanese { dropNMarker() }
        // "Back to kana" without the user's Esc, or a reading kept while deleting, isn't a
        // correction: report it as the engine's.
        let decided = (forced != nil && !forcedByUser) || (forced == nil && pinned != nil) ? language : engineChoice
        wordEnds(as: language, engineChoice: decided)
        let text = language == .japanese ? committedJapanese()
                 : language == .korean ? hangul() ?? engine.render(keys, as: language) : engine.render(keys, as: language)
        liveSuppressed = false
        liveKept = nil
        noteBrackets(in: text)
        let word = (keys, text, language, decided)
        previousLanguage = language.sentenceLanguage
        keys = ""
        forced = nil
        forcedByUser = false
        pinned = nil
        syllableStart = nil
        addedNMarker = false
        previewLanguage = nil
        enginePreview = nil
        return word
    }

    /// Takes the last kana off a Japanese phrase, as a Japanese IME does (かんこく → かんこ, not
    /// かんこk): the keys become a spelling of the shorter reading, keeping as much of what was
    /// typed as composes to it. A letter still waiting for its vowel goes alone (かんこk → かんこ),
    /// and so does anything in a phrase with English in it.
    private func deleteKana() {
        let composed = RomajiComposer.compose(keys, partial: true)
        guard composed.pending.isEmpty, composed.strayLetters == 0, !composed.text.isEmpty else {
            keys.removeLast()
            return
        }
        keys = Self.keys(spelling: String(composed.text.dropLast()), from: keys) ?? String(keys.dropLast())
    }

    /// The longest start of `keys` that composes to a start of `kana`, followed by a spelling of
    /// the rest ("kya" for き is "ki"; "kitte" for きっ is "kiltu").
    static func keys(spelling kana: String, from keys: String) -> String? {
        let chars = Array(keys)
        for cut in stride(from: chars.count - 1, through: 0, by: -1) {
            let front = String(chars[..<cut])
            let composed = RomajiComposer.compose(front, partial: true)
            guard composed.pending.isEmpty, composed.strayLetters == 0, kana.hasPrefix(composed.text),
                  let rest = RomajiComposer.romaji(String(kana.dropFirst(composed.text.count))) else { continue }
            let respelled = RomajiComposer.compose(front + rest, partial: true)
            if respelled.pending.isEmpty, respelled.text == kana { return front + rest }
        }
        return nil
    }

    /// Korean as the system's 2-set input deletes it: jamo by jamo in the syllable being typed
    /// (한국 → 한구 → 한ㄱ → 한), then whole syllables, which it had already committed (한 → nothing).
    private func deleteJamoOrSyllable() {
        let chars = Array(keys)
        if syllableStart == nil {
            guard let units = HangulComposer.compose(keys: keys)?.units else { keys.removeLast(); return }
            syllableStart = Self.cut(chars, before: Array(units.dropLast()))
        }
        if syllableStart! < chars.count {
            keys.removeLast()
            return
        }
        // Nothing left being typed: a whole committed syllable goes.
        guard let units = HangulComposer.compose(keys: keys)?.units else { keys.removeLast(); return }
        let cut = Self.cut(chars, before: Array(units.dropLast()))
        keys = String(chars[..<cut])
        syllableStart = cut
    }

    /// Where the keys of the last syllable start: the longest front that makes `earlier` alone.
    /// No front at all makes nothing, whatever the layout: 3-set composes no keys as nil, not as
    /// no units, and the first syllable cut after its first key (안 → 아, then ㄴ made 아ㄴ).
    private static func cut(_ chars: [Character], before earlier: [HangulComposer.Unit]) -> Int {
        stride(from: chars.count - 1, through: 0, by: -1).first {
            $0 == 0 ? earlier.isEmpty : HangulComposer.compose(keys: String(chars[..<$0]))?.units == earlier
        } ?? chars.count - 1
    }

    /// The word as Hangul, with the syllable being typed kept apart from those before it
    /// after a Delete (`syllableStart`).
    private func hangul() -> String? {
        guard let start = syllableStart, start > 0, start < keys.count else { return HangulComposer.compose(keys: keys)?.text }
        let chars = Array(keys)
        guard let front = HangulComposer.compose(keys: String(chars[..<start])),
              let back = HangulComposer.compose(keys: String(chars[start...])) else { return nil }
        return front.text + back.text
    }

    private func dropNMarker() {
        if addedNMarker, keys.hasSuffix("'") { keys.removeLast() }
        addedNMarker = false
    }

    /// The last correction handed to the learning engine, for the word being typed or just
    /// committed: going back and forth (Space, Esc, Space while converting) is one correction.
    private var lastRecorded: (keys: String, language: Language)?

    private func record(_ keys: String, as language: Language, engineChoice: Language) {
        if let last = lastRecorded, last.keys == keys, last.language == language { return }
        lastRecorded = (keys, language)
        if let learning = engine.learn(keys, as: language, engineChoice: engineChoice) {
            learned = Learned(text: committedReading(keys, as: language), language: language, learning: learning)
        }
    }

    /// Replaces a just-committed word with its next rendering, but only if the caret
    /// still sits right after it and the text there is what we inserted.
    /// Whether the keys have a split reading to cycle to: the engine's (x에, hello월드), which the
    /// particle split alone doesn't find.
    private func engineSplits(_ keys: String) -> Bool {
        engine.render(keys, as: .mixed) != keys
    }

    private func cycle(_ commit: Committed, client: TextClient) -> Committed? {
        let range = NSRange(location: commit.location, length: (commit.text as NSString).length)
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0, cursor.location == NSMaxRange(range),
              client.text(in: range) == commit.text else { return nil }

        let language = commit.language.next(for: commit.keys, japanese: japaneseEnabled, splits: engineSplits(commit.keys))
        let text = committedReading(commit.keys, as: language) + commit.boundary(in: language)
        client.insertText(text, replacing: range)
        if runText.hasSuffix(commit.text) { runText = String(runText.dropLast(commit.text.count)) + text }
        previousLanguage = language.sentenceLanguage
        return Committed(keys: commit.keys, decided: commit.decided, committedAs: commit.committedAs,
                         language: language, text: text, boundary: commit.boundary, location: commit.location,
                         previous: commit.previous, learns: commit.learns, typedBoundary: commit.typedBoundary)
    }

    private func closeFlipWindow() {
        if let pending = lastCommit { finalize(pending) }
        lastCommit = nil
    }

    /// The undo window closed: learn where the word ended up (once, not every reading Esc
    /// passed through on the way).
    private func finalize(_ commit: Committed) {
        if commit.learns, commit.language != commit.committedAs {
            record(commit.keys, as: commit.language, engineChoice: commit.decided)
        }
    }
}
