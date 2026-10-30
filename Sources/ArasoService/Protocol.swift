import ArasoCore
import Foundation

/// What the Windows input method (ArasoTip.dll, in the app being typed in) asks the host, one JSON
/// object per request over the named pipe; the host hands it to `ServiceRuntime.handle`.
public struct ServiceRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        /// A text service started in an app's thread: answers its client id.
        case attach
        /// It stopped (the app quit, or the user picked another input method).
        case detach
        /// A text field got the focus (`app` is the exe name).
        case focus
        /// The field lost it, or the app ended the composition: what was typed goes in as shown.
        case blur
        /// The app ended the composition itself (`OnCompositionTerminated`): the text stays as it is.
        case terminated
        /// A key went down (`key`).
        case key
        /// A key before it goes anywhere (`OnTestKeyDown`): whether the text service keeps it from the
        /// app. TSF holds it to that answer: a key kept goes nowhere else, so one the session then
        /// passes on is typed by the host (`claimed`) or sent again (`replay`). Not kept: the app gets
        /// it untouched (a shortcut's accelerator, keys while paused) and the session only hears of it.
        /// With `up`, a modifier going up: whether it ends a tap that does something.
        case test
        /// A key went up: only modifiers matter (taps).
        case keyUp
        /// Edits the host started for this client (a click in the candidate window, a menu item).
        case pending
        /// Where the word and the caret are now, after the edits were applied (`rects`).
        case place
        /// The language bar menu, built when it opens.
        case menu
        /// A language bar menu item was chosen (`item`).
        case menuSelect
        /// A candidate was clicked in the candidate card (`index`); sent by the host itself.
        case choose
        /// A reading was clicked in the switch key's strip (`index`, of `UIState.Readings.texts`):
        /// switched to as the switch key would, a press at a time; sent by the host itself.
        case pick
        /// Vim changed mode (`vim`, with the terminal's exe in `app` when known).
        case vim
        /// The settings window changed the files (`kanjiReset` when it reset the kanji order).
        case reload
        /// The settings window: everything it shows (`SettingsModel`).
        case settings
        /// The settings window: a change (`change`).
        case change
        /// The latest release as GitHub answered (`body`), for the updater.
        case release
        /// What the dictionary decided for some keys, with scores (the Dictionary pane's preview).
        case decide
        /// The readings some keys can be added to the dictionary as (`keys`), for the Dictionary pane.
        case readings
        /// A key pressed to record the pause shortcut (`key`): the shortcut as settings.json stores
        /// it, and why it can't pause if it can't.
        case shortcut
    }

    public var op: Op
    public var client: Int?
    public var app: String?
    public var key: WindowsKey?
    public var context: TextContext?
    public var rects: Rects?
    public var item: String?
    public var index: Int?
    public var vim: String?
    public var kanjiReset: Bool?
    public var change: SettingsChange?
    public var body: String?
    public var keys: String?
    /// `key`: the text service kept the key from the app (`test` said so), so it can't go there.
    public var claimed: Bool?
    /// `test`: the key is going up.
    public var up: Bool?

    public init(op: Op, client: Int? = nil, app: String? = nil, key: WindowsKey? = nil, context: TextContext? = nil) {
        self.op = op
        self.client = client
        self.app = app
        self.key = key
        self.context = context
    }
}

/// A key event as the text service saw it.
public struct WindowsKey: Codable, Equatable, Sendable {
    /// The virtual key (`VK_*`).
    public var vk: Int
    /// The scan code, and whether it had the extended flag (right Alt, right Ctrl, arrows…).
    public var scan: Int
    public var extended: Bool
    public var shift: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var win: Bool
    public var capsLock: Bool

    public init(vk: Int, scan: Int = 0, extended: Bool = false, shift: Bool = false, ctrl: Bool = false,
                alt: Bool = false, win: Bool = false, capsLock: Bool = false) {
        self.vk = vk
        self.scan = scan
        self.extended = extended
        self.shift = shift
        self.ctrl = ctrl
        self.alt = alt
        self.win = win
        self.capsLock = capsLock
    }
}

/// The text field around the caret, as offsets in UTF-16 units from the start of the document
/// (TSF's ACP, NSRange's units).
public struct TextContext: Codable, Equatable, Sendable {
    /// The selection: `[location, length]`; a location of -1 when the field doesn't say.
    public var selection: [Int]
    /// The composition (marked text), or nil when there is none.
    public var marked: [Int]?
    /// The field's text from `start`: up to 256 units before the composition or caret, through
    /// the end of the composition and the selection, and on to the end of the line where the text
    /// service can read it.
    public var text: String
    public var start: Int
    /// The text can't be read (a field that gives no text): only the selection is known.
    public var unreadable: Bool?
    /// The field is a password or private field (`IS_PASSWORD`): keys go to the app as typed.
    public var masked: Bool?
    /// A composition can only be at the caret (fcitx5's preedit, a word Windows keeps for a
    /// classic app): `TextClient.marksAnywhere` is false.
    public var marksAtCaret: Bool?
    /// A composition goes at the caret whatever range is named, while text replaced around the
    /// caret goes where it says (fcitx5's preedit, with deletions around the caret): the caret is
    /// moved first to mark a word elsewhere, as in a macOS text view (`TextClient.marksFromCaret`).
    public var marksFromCaret: Bool?

    public init(selection: [Int], marked: [Int]? = nil, text: String = "", start: Int = 0) {
        self.selection = selection
        self.marked = marked
        self.text = text
        self.start = start
    }
}

/// Screen rectangles in pixels: `[left, top, right, bottom]`.
public struct Rects: Codable, Equatable, Sendable {
    /// The composition's, while there is one.
    public var word: [Int]?
    /// The caret's (an empty range's text extent).
    public var caret: [Int]?

    public init(word: [Int]? = nil, caret: [Int]? = nil) {
        self.word = word
        self.caret = caret
    }
}

/// An edit for the text service to make, in order, inside its edit session.
public struct EditOp: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Show `text` as the composition (start one if there is none), in place of `replace` when
        /// given (text the app already has: the composition, if any, goes too), with `clause` (UTF-16,
        /// within `text`) drawn as the clause the candidates are for and the rest as the reading.
        case mark
        /// Put `text` in: in place of `replace` when given, else of the composition (or the
        /// selection), and end the composition.
        case insert
    }

    public var kind: Kind
    public var text: String
    public var replace: [Int]?
    public var clause: [Int]?

    public init(kind: Kind, text: String, replace: [Int]? = nil, clause: [Int]? = nil) {
        self.kind = kind
        self.text = text
        self.replace = replace
        self.clause = clause
    }
}

/// The answer to the text service.
public struct ServiceReply: Codable, Equatable, Sendable {
    /// The key was taken; false: the app gets it (also after edits, as Space after a word).
    public var handled = false
    public var ops: [EditOp] = []
    public var client: Int?
    /// The language bar menu.
    public var menu: [MenuItem]?
    /// Whether a Japanese phrase is being converted: the text service draws the composition as
    /// converted text.
    public var converting: Bool?
    /// A kept key the session passed on and the host can't type (Return, Tab, a shortcut): the
    /// text service sends it again, for the app.
    public var replay: Bool?

    public init(handled: Bool = false, ops: [EditOp] = []) {
        self.handled = handled
        self.ops = ops
    }
}

/// One line of the language bar menu (the macOS input menu's items).
public struct MenuItem: Codable, Equatable, Sendable {
    /// What `menuSelect` gets back; nil for a title or a separator.
    public var id: String?
    public var title: String
    public var checked: Bool
    public var enabled: Bool
    public var separator: Bool

    public init(id: String?, title: String, checked: Bool = false, enabled: Bool = true, separator: Bool = false) {
        self.id = id
        self.title = title
        self.checked = checked
        self.enabled = enabled
        self.separator = separator
    }

    public static let line = MenuItem(id: nil, title: "", enabled: false, separator: true)
}

/// What the host draws (the candidate card, the strip of the readings a switch key went through and
/// what a correction did, the pause indicator) and does. Only the host reads it.
public struct UIState: Codable, Equatable, Sendable {
    public struct Candidates: Codable, Equatable, Sendable {
        public var texts: [String]
        public var selected: Int
        /// The reading being converted (the shortcut, for a text replacement's phrases): the card's
        /// footer, with the page.
        public var reading: String
    }

    public struct Readings: Codable, Equatable, Sendable {
        public var texts: [String]
        /// `EN`, `KO`, `JA`, `MIX` per reading (the host localizes them).
        public var tags: [String]
        public var selected: Int
        /// The reading the dictionary remembers (a check after it in the strip) and the one
        /// corrected once (a pencil), as macOS's strip marks them.
        public var remembered: Int?
        public var once: Int?
    }

    public struct Learned: Codable, Equatable, Sendable {
        public var text: String
        public var tag: String
        /// `once`, `forGood` or `forgot`.
        public var learning: String
    }

    public var candidates: Candidates?
    public var readings: Readings?
    public var learned: Learned?
    /// Set when the key paused or resumed the field: the indicator shows it.
    public var paused: Bool?
    /// A word is being typed.
    public var composing = false
    /// How the word just decided was decided, for Try Typing (only in the settings window's field).
    public var trace: TraceInfo?
    /// The files changed (from the language bar menu): an open settings window reads them again.
    public var settingsChanged: Bool?
    /// The host starts the settings window at this pane (`general`, `keys`, `apps`, `typing`,
    /// `learning`, `about`).
    public var openSettings: String?

    public init() {}

    /// Nothing to draw or do: the text service then doesn't say where things are.
    public var isEmpty: Bool {
        candidates == nil && readings == nil && learned == nil && paused == nil && trace == nil
            && settingsChanged == nil && openSettings == nil
    }
}

/// `InputSession.Trace`, for the Try Typing pane.
public struct TraceInfo: Codable, Equatable, Sendable {
    public var keys: String
    public var previous: String?
    public var language: String
    public var confidence: Double
    public var output: String
    public var explanation: String
    public var partial: Bool
}

/// Everything the host gets back for one request.
public struct ServiceResponse: Codable, Equatable, Sendable {
    public var reply: ServiceReply
    public var ui: UIState?
    /// For the settings window's requests (`settings`, `release`, `decide`): their answer.
    public var settings: SettingsModel?
    public var release: ReleaseInfo?
    public var decision: TraceInfo?
    /// For `readings`: each reading the keys can go in as, in the switch key's order.
    public var choices: [Choice]?
    /// For `shortcut`: the shortcut, its name as Windows writes it, and `types`, `arasos` or
    /// `switchKey` when it can't pause.
    public var shortcut: PauseKey.Shortcut?
    public var shortcutName: String?
    public var problem: String?
    public var error: String?
    /// For `release`: GitHub answered, and its latest release has no file this platform installs.
    public var upToDate: Bool?
    /// Clients with edits waiting (`pending`): the host tells their text services to ask.
    public var notify: [Int]?

    public init(reply: ServiceReply = ServiceReply(), ui: UIState? = nil) {
        self.reply = reply
        self.ui = ui
    }
}

/// A reading some keys can be written as.
public struct Choice: Codable, Equatable, Sendable {
    public var language: String
    public var text: String
}

extension Language {
    /// The tag the readings list shows.
    public var tag: String {
        switch self {
        case .english: return "EN"
        case .korean: return "KO"
        case .japanese: return "JA"
        case .mixed: return "MIX"
        }
    }
}
