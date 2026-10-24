import Cocoa
import SwiftUI
import ArasoCore

/// A content-sized, nonactivating panel; IMK's scrolling list reserves nine rows even
/// for a single accent. This window never becomes key or owns the text field's focus.
@MainActor final class AccentPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let panel: NSPanel

    init() {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
    }

    func hide() { panel.orderOut(nil); panel.contentView = nil }

    func show(_ hold: AccentHold, caret: NSRect, choose: @escaping (Int) -> Void, move: @escaping (Int) -> Void) {
        let paged = hold.candidates.count > 9
        let size = NSSize(width: CGFloat(hold.page.count) * 48 + 12, height: paged ? 88 : 64)
        panel.contentView = NSHostingView(rootView: AccentChoices(hold: hold, choose: choose, move: move)
            .frame(width: size.width, height: size.height))
        let anchor = caret == .zero ? NSEvent.mouseLocation : caret.origin
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
        var origin = NSPoint(x: anchor.x, y: caret == .zero ? anchor.y - size.height : caret.minY - size.height - 4)
        if let visible {
            if origin.y < visible.minY, caret != .zero { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

private struct AccentChoices: View {
    let hold: AccentHold
    let choose: (Int) -> Void
    let move: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                ForEach(Array(hold.page), id: \.self) { index in
                    Button { choose(index) } label: {
                        VStack(spacing: 2) {
                            Text(String(hold.candidates[index])).font(.system(size: 24))
                            Text(String(index - hold.pageStart + 1)).font(.system(size: 10))
                        }
                        .frame(width: 44, height: 52)
                        .foregroundStyle(index == hold.selected ? Color.white : Color.primary)
                        .background(index == hold.selected ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(hold.candidates[index]))
                    .accessibilityValue(index == hold.selected ? L("Selected") : "")
                }
            }
            if hold.candidates.count > 9 {
                HStack {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    Text("\(hold.pageStart / 9 + 1) / \((hold.candidates.count + 8) / 9)").font(.caption)
                    Button { move(1) } label: { Image(systemName: "chevron.right") }
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    }
}
