import SwiftUI

/// Sizes shared by the Repos and Servers rows, so the two tabs' rows are equally tall.
enum PanelRowMetrics {
    /// A row's top line: as tall as its small buttons, whatever the name or the badges beside it are.
    static let lineHeight: CGFloat = 22
}

/// The favorite star at the start of a row, before its logo and name. Favorites always show it,
/// filled. Others show an outline only while the pointer is at the row's leading edge: the name
/// slides aside to make room for it, so resting rows keep their names at the edge and a row is
/// starred by reaching for its start, where the star of a favorite is.
struct LeadingStar: View {
    let isFavorite: Bool
    /// The pointer is at the row's leading edge (see `tracksLeadingEdge`).
    let isShown: Bool
    let action: () -> Void

    /// The star and the gap after it.
    static let width: CGFloat = 20

    var body: some View {
        let visible = isFavorite || isShown
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(isFavorite ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 14, height: 18)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.panel)
        .panelTooltip(isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        // Grows into place as the name makes room, rather than appearing at full size in a gap.
        .scaleEffect(visible ? 1 : 0.5, anchor: .leading)
        .opacity(visible ? 1 : 0)
        .frame(width: visible ? Self.width : 0, alignment: .leading)
        // Hidden, it is zero wide but would still take clicks at the row's edge.
        .allowsHitTesting(visible)
        .clipped()
    }

    /// The slide: soft and without overshoot, so the name glides aside rather than bouncing. Set on the
    /// state change (see `tracksLeadingEdge`), not on the star, so the name beside it moves with it.
    static let slide = Animation.spring(response: 0.2, dampingFraction: 0.92)
}

extension View {
    /// Sets `isAtEdge` while the pointer is within the row's leading edge: the margin and the logo, so
    /// coming from the name the star and the color stripe are out by the time the pointer gets there,
    /// the stripe right under it (with a zone of just the margin, they slid out to the right of the
    /// pointer, and had to be gone back for). Once out, the zone reaches past both, so moving onto
    /// them doesn't slide them away again.
    func tracksLeadingEdge(_ isAtEdge: Binding<Bool>) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let reach: CGFloat = isAtEdge.wrappedValue ? 64 : 42
                let inside = location.x < reach
                if inside != isAtEdge.wrappedValue {
                    withAnimation(LeadingStar.slide) { isAtEdge.wrappedValue = inside }
                }
            case .ended:
                if isAtEdge.wrappedValue {
                    withAnimation(LeadingStar.slide) { isAtEdge.wrappedValue = false }
                }
            }
        }
    }
}
