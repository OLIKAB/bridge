import SwiftUI

enum RepoColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// A repository's color as a short stripe before its logo, inside the row, which is also where the
/// color is chosen: a click opens the palette. Only rows with a color make room for it. On others an
/// empty one slides in with the star while the pointer is at the row's edge (see `LeadingStar`).
/// Tried and dropped: a stripe in a margin every row kept for it (indented the rows without a
/// color), and one in the gutter outside the row's highlight (cramped against the panel's edge,
/// and clicks there didn't reach it).
struct RepoColorStripe: View {
    @ObservedObject var repo: Repository
    /// The pointer is at the row's leading edge.
    let isReaching: Bool
    @State private var showPalette = false
    @State private var hovering = false

    /// The stripe and the gap after it.
    static let width: CGFloat = 12

    var body: some View {
        let visible = repo.color != nil || isReaching || showPalette
        Button { showPalette = true } label: {
            ZStack {
                if let color = repo.color {
                    Capsule().fill(color.color)
                } else {
                    Capsule().strokeBorder(.tertiary, lineWidth: 1.5)
                }
            }
            .frame(width: hovering ? 6 : 4, height: 16)
            // The whole slot, gap included, and the row's full height: the stripe alone was too
            // thin to hit. No tooltip: it covered the stripe being reached for.
            .frame(width: Self.width, height: PanelRowMetrics.lineHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(repo.color.map { "Color: \($0.name)" } ?? "Choose a color")
        .popover(isPresented: $showPalette, arrowEdge: .bottom) {
            RepoColorPalette(selection: repo.color) { color in
                withAnimation(LeadingStar.slide) { repo.color = color }
                showPalette = false
            }
        }
        .frame(width: visible ? Self.width : 0, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .clipped()
        .animation(LeadingStar.slide, value: hovering)
    }
}

/// The colors as swatches to click, with None first; the current one is ringed.
struct RepoColorPalette: View {
    let selection: RepoColor?
    let choose: (RepoColor?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            swatch(nil)
            ForEach(RepoColor.allCases) { swatch($0) }
        }
        .padding(10)
    }

    private func swatch(_ color: RepoColor?) -> some View {
        Button { choose(color) } label: {
            ZStack {
                if let color {
                    Circle().fill(color.color)
                } else {
                    Circle().strokeBorder(.tertiary, lineWidth: 1.5)
                    Rectangle().fill(.secondary).frame(width: 1.5, height: 14).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 18, height: 18)
            .padding(3)
            .overlay {
                if selection == color { Circle().strokeBorder(.secondary, lineWidth: 1.5) }
            }
        }
        .buttonStyle(.panel)
        .panelTooltip(color?.name ?? "No color")
        .accessibilityLabel(color?.name ?? "No color")
    }
}

/// The context menu entry for choosing a repository's color.
struct RepoColorMenu: View {
    @ObservedObject var repo: Repository

    var body: some View {
        Picker("Color", selection: $repo.color) {
            Text("None").tag(RepoColor?.none)
            Divider()
            ForEach(RepoColor.allCases) { color in
                // Menus drop foreground colors on text, but keep them on a palette-rendered symbol.
                Label {
                    Text(verbatim: color.name)
                } icon: {
                    Image(systemName: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(color.color)
                }
                .tag(RepoColor?.some(color))
            }
        }
    }
}
