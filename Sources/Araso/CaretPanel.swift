import ArasoCore
import Cocoa

/// A small panel under the caret that never takes focus: what PauseHUD, the strip of a word's
/// readings and the card of kana→kanji candidates are shown in.
@MainActor enum CaretPanel {
    /// The system's input source indicator, measured on screen: its capsule's height and its gap
    /// below the caret. PauseHUD is one, and the strip's thumb is one.
    static let indicatorHeight: CGFloat = 23
    static let indicatorGap: CGFloat = 4

    /// The indicator's blue: the accent color's sRGB components taken as Display P3, more vivid
    /// than the accent color itself (measured against it on screen).
    static var indicatorFill: NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return NSColor(displayP3Red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent, alpha: 1)
    }

    static func make(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// Just under the caret's line (above it near the bottom of the screen), kept on screen:
    /// centered on the caret, or starting where it does. Without a caret, near the top of the
    /// screen the mouse is on.
    static func origin(for size: NSSize, caret: NSRect, gap: CGFloat, centered: Bool) -> NSPoint {
        let anchor = caret == .zero ? NSEvent.mouseLocation : caret.origin
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return anchor }
        var point: NSPoint
        if caret == .zero {
            point = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40)
        } else {
            let x = centered ? caret.midX.rounded() - size.width / 2 : caret.minX.rounded()
            point = NSPoint(x: x, y: caret.minY - gap - size.height)
            if point.y < visible.minY { point.y = caret.maxY + gap }
        }
        point.x = min(max(point.x, visible.minX), visible.maxX - size.width)
        point.y = min(max(point.y, visible.minY), visible.maxY - size.height)
        return point
    }
}

/// Lays its subviews out top-down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Motion keeps out of the way of typing: each animation is short, and none when the user
/// asked the system for less motion.
@MainActor private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

@MainActor private func animate(_ duration: TimeInterval, _ curve: CAMediaTimingFunction? = nil,
                                _ changes: @escaping () -> Void, done: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = reduceMotion ? 0 : duration
        context.timingFunction = curve
        context.allowsImplicitAnimation = true
        changes()
    }, completionHandler: { MainActor.assumeIsolated { done?() } })
}

/// Fast out, gentle in: a move that is over before the next key.
private let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

/// Araso's paper, as on the website and in the settings window: the strip's track, birch paper
/// and navy ink, navy paper in the dark.
@MainActor enum Paper {
    static let background = dynamic(0xfaf8f4, 0x0d213b)
    static let ink2 = dynamic(0x4a5b70, 0xa9b6c6)
    static let line = dynamic(0xe6e1d8, 0xf3f1ec, darkAlpha: 0.16)
    /// The capsule of a word that went back to Araso's own reading: nothing remembered any more.
    static let reset = dynamic(0x6e6e73, 0x636366)

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, alpha: darkAlpha) : rgb(light, alpha: 1)
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// What the dictionary knows about a reading, shown after it in the strip: a check where it
/// remembers it (corrected twice, or added by hand), a pencil where it was corrected once.
private enum Mark: Equatable { case remembered, once }

private extension InputSession.Readings {
    func mark(_ index: Int) -> Mark? {
        index == remembered ? .remembered : index == once ? .once : nil
    }
}

/// A mark's 11 pt square: the pencil and the arrow back as SF Symbols, the check as a stroke so it
/// can draw itself when a word is learned. Each moves about its own center.
private final class MarkView: NSView {
    enum Kind { case check, pencil, back }
    static let side: CGFloat = 11
    private(set) var kind: Kind?
    private var shape: CALayer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `kind` (nil: nothing) in `color`.
    func show(_ kind: Kind?, color: NSColor) {
        shape?.removeFromSuperlayer()
        shape = nil
        self.kind = kind
        guard let kind, let layer else { return }
        let shape: CALayer
        if kind == .check {
            let check = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1.6, y: 5.6))
            path.addLine(to: CGPoint(x: 4.4, y: 2.6))
            path.addLine(to: CGPoint(x: 9.6, y: 8.9))
            check.path = path
            check.fillColor = nil
            check.lineWidth = 1.9
            check.lineCap = .round
            check.lineJoin = .round
            shape = check
        } else {
            shape = CALayer()
            shape.contentsGravity = .resizeAspect
            shape.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
        shape.frame = bounds
        layer.addSublayer(shape)
        self.shape = shape
        tint(color)
    }

    func tint(_ color: NSColor) {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        if let check = shape as? CAShapeLayer {
            check.strokeColor = resolved
        } else if let kind, let shape {
            let name = kind == .pencil ? "pencil" : "arrow.uturn.backward"
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(.init(paletteColors: [NSColor(cgColor: resolved) ?? color]))
            shape.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
    }

    /// The check draws itself, the short stroke then the long one.
    func draw(_ duration: CFTimeInterval) {
        guard let check = shape as? CAShapeLayer, !reduceMotion else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = duration
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        check.add(draw, forKey: "draw")
    }

    /// Comes up from small, a little past its size and back.
    func popIn() {
        guard let shape, !reduceMotion else { return }
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [0.4, 1.15, 1]
        grow.keyTimes = [0, 0.6, 1]
        grow.duration = 0.22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        shape.add(grow, forKey: "grow")
        shape.add(fade, forKey: "fade")
    }

    /// Goes small and away, then `done`.
    func popOut(_ done: @escaping () -> Void) {
        guard let shape, !reduceMotion else { return done() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        for animation in [shrink, fade] {
            animation.duration = 0.12
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            shape.add(animation, forKey: animation.keyPath)
        }
        CATransaction.commit()
    }

    /// The pencil writes: a quick wobble about its point.
    func wiggle() {
        guard let shape, !reduceMotion else { return }
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = [0, 0.3, -0.18, 0.07, 0].map { $0 as NSNumber }
        turn.duration = 0.45
        turn.beginTime = CACurrentMediaTime() + 0.1
        shape.add(turn, forKey: "wiggle")
    }

    /// The arrow turns back once, as it points.
    func spin() {
        guard let shape, !reduceMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = -CGFloat.pi * 1.8
        turn.toValue = 0
        turn.duration = 0.5
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)
        shape.add(turn, forKey: "spin")
    }
}

/// One reading of the strip or candidate of the card: its number (candidates), its text cut at
/// 140 pt, its mark (readings). White on the thumb, the paper's ink beside it.
private final class StripCell: NSView {
    static let pad: CGFloat = 10
    static let maxText: CGFloat = 140
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// The numbers' digits are all as wide, so the candidates start at one x down the card.
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let numberWidth = ceil(number(8).fittingSize.width) + 1
    private static let measure = Paper.label("", size: 13, weight: .medium)
    /// The line every text of the strip sits on, numbers and outcome words too: the reading's cap
    /// height centered in the capsule. Marks are centered on the same middle, so a check or a
    /// pencil sits level with the letters rather than with the label's frame, which hangs lower.
    static var baseline: CGFloat { (CaretPanel.indicatorHeight + font.capHeight) / 2 }

    /// Puts `label` at `x`, its baseline on the strip's, kept on a backing pixel.
    static func place(_ label: NSTextField, x: CGFloat, width: CGFloat? = nil) {
        let size = label.fittingSize
        label.frame = NSRect(x: x, y: 0, width: width ?? ceil(size.width) + 1, height: size.height)
        label.setFrameOrigin(NSPoint(x: x, y: ((baseline - label.firstBaselineOffsetFromTop) * 2).rounded() / 2))
    }

    /// Where a mark's square goes after `x`: centered on the letters' middle.
    private static func markOrigin(after x: CGFloat) -> NSPoint {
        NSPoint(x: x + 5, y: baseline - font.capHeight / 2 - MarkView.side / 2)
    }

    private static func number(_ n: Int) -> NSTextField {
        let label = Paper.label("\(n)", size: 10, weight: .medium)
        label.font = numberFont
        return label
    }

    /// How wide a numbered cell for `string` is, without making one.
    static func width(numbered string: String) -> CGFloat {
        measure.stringValue = string
        return pad + numberWidth + 3 + min(ceil(measure.fittingSize.width) + 1, maxText) + pad
    }

    /// The card's footer, the reading and the page: its digits as wide as each other too, so the
    /// page count doesn't move it.
    static func footer(_ text: String) -> NSTextField {
        let label = Paper.label(text, size: 11)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Paper.ink2.withAlphaComponent(0.85)
        return label
    }
    let text: NSTextField
    private let number: NSTextField?
    private let mark: Mark?
    private var markView: MarkView?
    private var outcome: NSTextField?

    override var isFlipped: Bool { true }

    init(_ string: String, number: Int? = nil, mark: Mark? = nil) {
        let height = CaretPanel.indicatorHeight
        text = Paper.label(string, size: 13, weight: .medium)
        self.number = number.map(Self.number)
        self.mark = mark
        super.init(frame: .zero)
        var x = Self.pad
        if let number = self.number {
            Self.place(number, x: x)
            addSubview(number)
            x = number.frame.maxX + 3
        }
        Self.place(text, x: x, width: min(ceil(text.fittingSize.width) + 1, Self.maxText))
        addSubview(text)
        x = text.frame.maxX
        if let mark {
            let view = MarkView()
            view.setFrameOrigin(Self.markOrigin(after: x))
            addSubview(view)
            view.show(mark == .remembered ? .check : .pencil, color: Paper.ink2)
            markView = view
            x += 5 + MarkView.side
        }
        frame = NSRect(x: 0, y: 0, width: x + Self.pad, height: height)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let spoken = switch mark {
        case .remembered: "\(string), \(L("Remembered"))"
        case .once: "\(string), \(L("Corrected once"))"
        case nil: string
        }
        setAccessibilityLabel(spoken)
    }

    required init?(coder: NSCoder) { nil }

    func color(on: Bool) {
        let ink = on ? NSColor.white : Paper.ink2
        text.textColor = ink
        number?.textColor = ink.withAlphaComponent(0.72)
        markView?.tint(on ? .white : mark == .remembered ? CaretPanel.indicatorFill : Paper.ink2)
    }

    /// Makes room after the text for what a correction did (the mark's place, then `word`) and
    /// returns the width it now takes.
    func makeRoom(for word: String) -> CGFloat {
        let height = CaretPanel.indicatorHeight
        let view = markView ?? {
            let view = MarkView()
            view.setFrameOrigin(Self.markOrigin(after: text.frame.maxX))
            addSubview(view)
            markView = view
            return view
        }()
        let label = Paper.label(word, size: 12, weight: .semibold)
        label.textColor = .white
        Self.place(label, x: view.frame.maxX + 6)
        label.alphaValue = 0
        addSubview(label)
        outcome = label
        setFrameSize(NSSize(width: label.frame.maxX + Self.pad, height: height))
        return frame.width
    }

    /// What a correction did: a pencil that writes once, the check drawing itself when learned
    /// (the pencil of the first correction making way), the arrow back turning when forgotten.
    func say(_ learning: DictionaryEngine.Learning) {
        animate(0.2, ease, { self.outcome?.animator().alphaValue = 1 })
        guard let view = markView else { return }
        switch learning {
        case .once:
            if view.kind != .pencil { view.show(.pencil, color: .white); view.popIn() }
            view.wiggle()
        case .forGood:
            let check = { view.show(.check, color: .white); view.draw(0.3) }
            if view.kind == .pencil { view.popOut(check) } else { check() }
        case .forgot:
            view.show(.back, color: .white)
            view.popIn()
            view.spin()
        }
    }
}

/// The switch key's readings on one strip under the word, the kana→kanji candidates in a card under
/// the clause, until the next key (`InputSession.readings`, `.conversion`): the system's input
/// source indicator, its blue capsule white inside, as the thumb on what's on screen, the others on
/// Araso's paper beside it or below it, each as it would go in, so the next presses can be read off.
/// The thumb moves in 0.12 s and the next key cuts it short. A click chooses too. When the key after
/// a switch made the dictionary take the correction (`InputSession.learned`), the paper closes onto
/// the chosen reading, whose capsule moves under the word and says what happened.
/// The panel is a little larger than the strip, for the shadow the views cast themselves: only
/// views move, never the window, so what moves stays in step and keeps its shadow.
@MainActor enum StripHUD {
    private enum Shown: Equatable {
        case readings([String], [Mark?], numbered: Bool)
        case candidates([String], page: Int)
    }

    /// The readings on one line; the candidates in a card `width` wide and `rows` tall on every
    /// page, so turning one doesn't move anything, the reading and the page (`footer`) under them.
    private enum Layout {
        case row
        case card(width: CGFloat, rows: Int, footer: String)
    }

    private static var panel: NSPanel?
    private static var root: NSView?
    private static var strip: NSView?
    private static var track: NSView?
    private static var thumb: NSView?
    private static var cells: [StripCell] = []
    private static var shown: Shown?
    private static var selected = 0
    private static var languages: [Language] = []
    private static var pageStart = 0
    private static var pick: ((Language) -> Void)?
    private static var choose: ((Int) -> Void)?
    /// Bumped on every show and hide, so a fade left from before stops.
    private static var generation = 0
    private static var hiding = false
    /// Saying what a correction did; the keys typed meanwhile don't put it away.
    private static var settling = false

    private static let height = CaretPanel.indicatorHeight
    private static let pageSize = InputSession.Conversion.pageSize
    /// Room around the strip for its shadow.
    private static let margin: CGFloat = 12
    /// The card's paper around its rows, and the room under them for the footer.
    private static let inset: CGFloat = 3
    private static let footerHeight: CGFloat = 16
    /// The card's width for the candidates it was last measured for.
    private static var measured: (texts: [String], footer: String, width: CGFloat)?

    private static var isUp: Bool { panel?.isVisible == true && !hiding }

    /// `word` is the word's line in screen coordinates; without one (`.zero`) nothing is shown,
    /// since readings away from the word say little. `pick` switches to a reading clicked.
    static func show(_ readings: InputSession.Readings, word: NSRect, pick: @escaping (Language) -> Void) {
        guard word != .zero else { return hide(force: true) }
        self.pick = pick
        choose = nil
        generation += 1
        let marks = readings.texts.indices.map { readings.mark($0) }
        let next = Shown.readings(readings.texts, marks, numbered: readings.numbered)
        if isUp, !settling, shown == next {
            select(readings.selected)
        } else {
            settling = false
            pageStart = 0
            build(readings.texts.indices.map {
                StripCell(readings.texts[$0], number: readings.numbered && $0 < 9 ? $0 + 1 : nil, mark: marks[$0])
            }, layout: .row,
                  selected: readings.selected, word: word)
        }
        shown = next
        languages = readings.languages
        let text = readings.texts[readings.selected]
        root?.setAccessibilityLabel(L("Readings, %@ selected", text))
        announce(L("%@, %ld of %ld", text, readings.selected + 1, readings.texts.count))
    }

    /// `clause` is where the clause being converted starts; `choose` commits candidate `index` of
    /// the whole list. A card under the clause, nine rows to a page numbered for the digits, the
    /// reading and the page under them; as wide as the widest candidate on any page.
    static func show(_ conversion: InputSession.Conversion, clause: NSRect, choose: @escaping (Int) -> Void) {
        self.choose = choose
        pick = nil
        generation += 1
        let texts = conversion.candidates.map(\.text)
        let page = conversion.selected / pageSize
        let next = Shown.candidates(texts, page: page)
        if isUp, !settling, shown == next {
            select(conversion.selected % pageSize)
        } else {
            var turn: CGFloat?
            if isUp, !settling, case .candidates(texts, let old)? = shown { turn = page > old ? 1 : -1 }
            settling = false
            pageStart = page * pageSize
            let pages = (texts.count + pageSize - 1) / pageSize
            let footer = { (page: Int) in pages > 1 ? "\(conversion.kana) · \(page + 1)/\(pages)" : conversion.kana }
            let cells = texts[pageStart..<min(pageStart + pageSize, texts.count)].enumerated().map { StripCell($1, number: $0 + 1) }
            build(cells, layout: .card(width: cardWidth(texts, footer: footer(pages - 1)), rows: min(pageSize, texts.count),
                                       footer: footer(page)),
                  selected: conversion.selected % pageSize, word: clause, turn: turn)
        }
        shown = next
        root?.setAccessibilityLabel(L("Candidates, %@ selected", conversion.current.text))
    }

    /// Wide enough for every candidate in `texts`, whichever page it is on, and for `footer`, the
    /// widest the footer gets (the last page's count, its digits as wide as any).
    private static func cardWidth(_ texts: [String], footer: String) -> CGFloat {
        if let measured, measured.texts == texts, measured.footer == footer { return measured.width }
        let widest = texts.map(StripCell.width(numbered:)).max() ?? 0
        let footerWidth = ceil(StripCell.footer(footer).fittingSize.width) + 1 + StripCell.pad * 2
        let width = ceil(max(widest, footerWidth)) + inset * 2
        measured = (texts, footer, width)
        return width
    }

    /// Puts the strip away; one saying what a correction did stays its moment unless `force`d
    /// (the field lost focus, the input method paused).
    static func hide(force: Bool = false) {
        guard let panel, panel.isVisible, !hiding, force || !settling else { return }
        generation += 1
        let current = generation
        hiding = true
        settling = false
        shown = nil
        animate(0.1, CAMediaTimingFunction(name: .easeIn), { panel.animator().alphaValue = 0 }) {
            guard current == generation else { return }
            panel.orderOut(nil)
            hiding = false
        }
    }

    /// The correction the dictionary just took: the paper closes onto the chosen reading, whose
    /// capsule moves under the word's first letter and says what happened, a pencil and "Noted"
    /// after the first correction, the check drawing itself and "Learned" once learned for good,
    /// the arrow back and "Reset" on gray when a switch back to Araso's own reading forgot the
    /// word. Without a strip up (`word`, the word's line, places it) the capsule shows on its own.
    static func settle(_ learned: InputSession.Learned, word: NSRect) {
        let index: Int
        if isUp, !settling, case .readings? = shown, cells.indices.contains(selected) {
            index = selected
        } else {
            guard word != .zero else { return }
            pageStart = 0
            build([StripCell(learned.text)], layout: .row, selected: 0, word: word)
            index = 0
        }
        guard let panel, let strip, let track, let thumb else { return }
        generation += 1
        let current = generation
        settling = true
        shown = nil
        let (said, spoken) = switch learned.learning {
        case .once: (L("Noted"), L("%@ → %@, once", learned.text, learned.language.displayName))
        case .forGood: (L("Learned"), L("%@ → always %@", learned.text, learned.language.displayName))
        case .forgot: (L("Reset"), L("%@, back to Araso's own reading", learned.text))
        }
        root?.setAccessibilityLabel(spoken)
        announce(spoken)

        // Where the capsule goes: under the word's first letter, as wide as what it says. The panel
        // grows to cover it at once, nothing moving on screen, so the views can travel there.
        let cell = cells[index]
        let start = cell.frame
        let stripOnScreen = NSRect(x: panel.frame.minX + strip.frame.minX, y: panel.frame.minY + margin,
                                   width: strip.frame.width, height: height)
        let width = cell.makeRoom(for: said)
        let from = stripOnScreen.minX + start.minX
        let to = word == .zero ? from : CaretPanel.origin(for: NSSize(width: width, height: height),
                                                          caret: word.offsetBy(dx: -StripCell.pad, dy: 0),
                                                          gap: CaretPanel.indicatorGap, centered: false).x
        let covered = stripOnScreen.union(NSRect(x: min(from, to), y: stripOnScreen.minY, width: abs(to - from) + width, height: height))
            .insetBy(dx: -margin, dy: -margin)
        panel.ignoresMouseEvents = true
        panel.setFrame(covered, display: false)
        // The strip grows too, so the wider capsule isn't cut at its old end.
        strip.frame = NSRect(x: stripOnScreen.minX - covered.minX, y: margin,
                             width: max(strip.frame.width, start.minX + width), height: height)

        // The paper closes onto the chosen reading and goes with the others; the capsule takes
        // over its shadow.
        animate(0.15, ease, {
            track.animator().frame = start
            track.animator().alphaValue = 0
            for other in cells where other !== cell { other.animator().alphaValue = 0 }
            thumb.layer?.shadowOpacity = shadowOpacity(for: thumb)
        })

        // Then it moves under the word and says it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard current == generation else { return }
            animate(0.22, ease, {
                strip.animator().setFrameOrigin(NSPoint(x: strip.frame.minX + to - from, y: margin))
                thumb.animator().frame = NSRect(x: start.minX, y: 0, width: width, height: height)
                if learned.learning == .forgot {
                    var gray = Paper.reset.cgColor
                    thumb.effectiveAppearance.performAsCurrentDrawingAppearance { gray = Paper.reset.cgColor }
                    thumb.layer?.backgroundColor = gray
                }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard current == generation else { return }
                cell.say(learned.learning)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            guard current == generation else { return }
            animate(0.25, nil, { panel.animator().alphaValue = 0 }) {
                guard current == generation else { return }
                panel.orderOut(nil)
                settling = false
            }
        }
    }

    /// The readings in a row or the candidates in a card, `selected` on the thumb, the first text
    /// under the word's first letter (the clause's, for candidates). A page turned (`turn`, +1
    /// forward) keeps the card where it is and brings the next page up into it (the one before,
    /// down); a new strip or card comes down 2 pt as it shows (up, when it is above the word).
    private static func build(_ cells: [StripCell], layout: Layout, selected: Int, word: NSRect, turn: CGFloat? = nil) {
        let wasUp = isUp
        let oldStrip = wasUp ? panel.map { NSPoint(x: $0.frame.minX + margin, y: $0.frame.minY + margin) } : nil
        hiding = false
        let panel = panel ?? CaretPanel.make(size: .zero)
        self.panel = panel
        panel.ignoresMouseEvents = false

        let size: NSSize
        var radius = height / 2
        var clip: NSView?
        var footer: NSTextField?
        switch layout {
        case .row:
            var x: CGFloat = 0
            for cell in cells {
                cell.setFrameOrigin(NSPoint(x: x, y: 0))
                x += cell.frame.width
            }
            size = NSSize(width: ceil(x), height: height)
        case .card(let width, let rows, let text):
            // The rows inside the paper's inset, cut at its edge, so a page turned slides in under it.
            let inside = FlippedView(frame: NSRect(x: inset, y: inset, width: width - inset * 2, height: CGFloat(rows) * height))
            inside.wantsLayer = true
            inside.layer?.masksToBounds = true
            inside.layer?.cornerRadius = height / 2
            inside.layer?.cornerCurve = .continuous
            for (i, cell) in cells.enumerated() {
                cell.frame = NSRect(x: 0, y: CGFloat(i) * height, width: inside.frame.width, height: height)
            }
            let label = StripCell.footer(text)
            StripCell.place(label, x: inset + StripCell.pad)
            label.setFrameOrigin(NSPoint(x: label.frame.minX, y: label.frame.minY + inside.frame.maxY - 4))
            size = NSSize(width: width, height: inside.frame.maxY + footerHeight + inset)
            // The corners round about the thumb's, the inset further out.
            radius = inset + height / 2
            clip = inside
            footer = label
        }
        // Measured now: once it is the panel's content, the root takes the panel's old size.
        let full = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)

        let root = FlippedView(frame: NSRect(origin: .zero, size: full))
        root.wantsLayer = true
        let strip = FlippedView(frame: NSRect(origin: NSPoint(x: margin, y: margin), size: size))
        strip.wantsLayer = true
        let track = capsule(NSRect(origin: .zero, size: size), radius: radius)
        let thumb = capsule(cells[selected].frame)
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            track.layer?.backgroundColor = Paper.background.cgColor
            track.layer?.borderColor = Paper.line.cgColor
            track.layer?.borderWidth = 1
            thumb.layer?.backgroundColor = CaretPanel.indicatorFill.cgColor
        }
        track.layer?.shadowOpacity = shadowOpacity(for: root)
        thumb.layer?.shadowOpacity = 0
        strip.addSubview(track)
        // What holds the thumb and the cells: the strip itself, or a card's page in its clip.
        var page: NSView = strip
        if let clip {
            page = FlippedView(frame: clip.bounds)
            page.wantsLayer = true
            clip.addSubview(page)
            strip.addSubview(clip)
        }
        page.addSubview(thumb)
        cells.forEach(page.addSubview)
        page.addSubview(ClickView(frame: page.bounds) { clicked(at: $0) })
        footer.map(strip.addSubview)
        root.addSubview(strip)
        root.setAccessibilityRole(.list)
        panel.contentView = root
        self.root = root
        self.strip = strip
        self.track = track
        self.thumb = thumb
        self.cells = cells
        self.selected = selected
        for (i, cell) in cells.enumerated() { cell.color(on: i == selected) }

        let indent = (clip?.frame.minX ?? 0) + (cells.first?.text.frame.minX ?? StripCell.pad)
        var origin = CaretPanel.origin(for: size, caret: word == .zero ? .zero : word.offsetBy(dx: -indent, dy: 0),
                                       gap: CaretPanel.indicatorGap, centered: false)
        if turn != nil, let oldStrip { origin = oldStrip }
        let above = word != .zero && origin.y > word.minY
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x - margin, y: origin.y - margin), size: full), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if let turn, wasUp {
            let rest = page.frame.origin
            page.alphaValue = 0
            page.setFrameOrigin(NSPoint(x: rest.x, y: rest.y + 14 * turn))
            animate(0.14, ease, {
                page.animator().alphaValue = 1
                page.animator().setFrameOrigin(rest)
            })
        } else if !wasUp {
            root.alphaValue = 0
            strip.setFrameOrigin(NSPoint(x: margin, y: margin + (above ? 2 : -2)))
            animate(0.12, ease, {
                root.animator().alphaValue = 1
                strip.animator().setFrameOrigin(NSPoint(x: margin, y: margin))
            })
        }
    }

    /// A capsule the strip's height (or, `radius` larger, the card), casting the strip's shadow
    /// when it shows one.
    private static func capsule(_ frame: NSRect, radius: CGFloat? = nil) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = radius ?? height / 2
        view.layer?.cornerCurve = .continuous
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowRadius = 5
        view.layer?.shadowOffset = CGSize(width: 0, height: -3)
        return view
    }

    /// The strip's shadow, deeper on dark paper.
    private static func shadowOpacity(for view: NSView) -> Float {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.45 : 0.14
    }

    /// The next switch or candidate: the thumb moves to it.
    private static func select(_ index: Int) {
        guard cells.indices.contains(index), let thumb else { return }
        selected = index
        animate(0.12, ease, { thumb.animator().frame = cells[index].frame })
        for (i, cell) in cells.enumerated() { cell.color(on: i == index) }
    }

    /// `point` is in the cells' view: on a reading or a candidate, or between the last one and the
    /// card's end, where nothing is.
    private static func clicked(at point: NSPoint) {
        guard !settling, let index = cells.firstIndex(where: { $0.frame.contains(point) }) else { return }
        if let choose {
            choose(pageStart + index)
        } else if let pick, index != selected, languages.indices.contains(index) {
            pick(languages[index])
        }
    }

    /// Read out by VoiceOver.
    private static func announce(_ text: String) {
        guard let panel else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Takes a click on the strip (the panel never takes focus) and says where, top-down.
private final class ClickView: NSView {
    private let clicked: (NSPoint) -> Void
    init(frame: NSRect, clicked: @escaping (NSPoint) -> Void) {
        self.clicked = clicked
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked(convert(event.locationInWindow, from: nil)) }
}
