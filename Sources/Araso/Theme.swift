import ArasoCore
import Cocoa
import SwiftUI

/// The website's palette (nyttastudio.com/araso): birch paper, navy ink, blue and yellow,
/// with its dark counterpart. Each color follows the window's appearance.
enum Seam {
    static let bg = dynamic(0xfaf8f4, 0x081a30)
    static let bg2 = dynamic(0xf1ede5, 0x0f2440)
    static let card = dynamic(0xffffff, 0x0d213b)
    static let ink = dynamic(0x0b2545, 0xf3f1ec)
    static let ink2 = dynamic(0x4a5b70, 0xa9b6c6)
    static let ink3 = dynamic(0x8592a3, 0x6f8197)
    static let line = dynamic(0xe6e1d8, 0xf3f1ec, darkAlpha: 0.1)
    static let blue = dynamic(0x006aa7, 0x1f86c4)
    static let yellow = dynamic(0xfecc02, 0xfecc02)
    static let english = dynamic(0x8592a3, 0x8a9bb0)
    static let korean = dynamic(0x006aa7, 0x4fa8e0)
    static let japanese = dynamic(0xe0b000, 0xfecc02)
    /// Japanese as text: the yellow is too light to read on paper.
    static let japaneseInk = dynamic(0x8a6a00, 0xfecc02)
    static let warning = dynamic(0xb45309, 0xf59e0b)

    private static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? rgb(dark, alpha: darkAlpha) : rgb(light, alpha: 1)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Language {
    /// The language's color on the website: its underline in the typing demo.
    var tint: Color {
        switch self {
        case .english: return Seam.english
        case .korean: return Seam.korean
        case .mixed: return Seam.ink3
        case .japanese: return Seam.japanese
        }
    }

    /// The color for the language's name as text.
    var ink: Color { self == .japanese ? Seam.japaneseInk : tint }
}

// MARK: - Pane pieces

/// A settings pane: a scrolling column on the paper color, its header first.
struct Pane<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PaneHeader(tab: tab)
                content
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Seam.bg)
    }
}

/// The pane's title and what it's for, on a band with a small picture of it at the right.
struct PaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 22, weight: .bold)).tracking(-0.4)
                    .foregroundStyle(Seam.ink)
                Text(tab.subtitle)
                    .font(.system(size: 13)).foregroundStyle(Seam.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HeaderArt(tab: tab)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Seam.bg2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// What each pane's band shows: the thing the pane changes, as it looks while typing.
private struct HeaderArt: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general:
                HStack(spacing: 10) {
                    Underlined(text: "A", color: Seam.english)
                    Underlined(text: "아", color: Seam.korean)
                    Underlined(text: "あ", color: Seam.japanese)
                }
            case .keys:
                HStack(spacing: 6) {
                    Keycap(key: .rightShift, on: true)
                    Keycap(key: .shiftEscape, on: true)
                }
            case .accents:
                HStack(spacing: 8) {
                    Text(verbatim: "a").font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 11))
                    Underlined(text: "ä", color: Seam.blue)
                }.foregroundStyle(Seam.ink2)
            case .apps:
                HStack(spacing: 8) {
                    Text(verbatim: "gst").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Seam.ink2)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Seam.ink3)
                    Underlined(text: "gst", color: Seam.english, size: 18)
                }
            case .learning:
                HStack(spacing: 8) {
                    Text(verbatim: "so").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Seam.ink2)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Seam.ink3)
                    Underlined(text: "내", color: Seam.korean, size: 18)
                }
            case .typing:
                HStack(spacing: 4) {
                    Underlined(text: "안녕", color: Seam.korean, size: 18)
                    Underlined(text: "hello", color: Seam.english, size: 18)
                }
            case .about:
                EmptyView() // the pane opens with the mark itself
            }
        }
        .accessibilityHidden(true)
    }
}

/// A word with the website's language underline.
struct Underlined: View {
    let text: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Seam.ink)
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) { Capsule().fill(color).frame(height: 3) }
    }
}

/// A titled group of rows on a white card, as the website's cards.
struct SeamCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Seam.korean)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                _VariadicView.Tree(Divided()) { content }
            }
            .background(Seam.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Seam.line))
        }
    }

    /// A hairline between the card's rows.
    private struct Divided: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            ForEach(children) { child in
                child
                if child.id != last { Rectangle().fill(Seam.line).frame(height: 1).padding(.leading, 16) }
            }
        }
    }
}

/// One setting: its name and what it does at the left, the control at the right.
struct SeamRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel(title: title, detail: detail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A row's name and the line under it.
struct RowLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Seam.ink)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Seam.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row with a switch.
struct SeamToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SeamRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A small rounded label in a color of the palette.
struct Badge: View {
    let title: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(fill, in: Capsule())
    }
}
