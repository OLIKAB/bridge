import AppKit
import SwiftUI

/// Small animations that show what a click did: content that opens settles into place, a chevron
/// turns. Never what the pointer does: hover feedback is immediate, as in macOS's own menus. A
/// highlight that glided or faded after the pointer made the panels feel like they lagged behind.
/// And never the panel's height: `MenuBarExtra` resizes its window on its own, and an animated
/// height change there leaves the panel the wrong size (see CLAUDE.md). So each one is scoped to
/// opacity, offset or rotation, which don't change layout.
public enum PanelMotion {
    /// Something opening or turning after a click: short, so it never holds up the next click.
    public static let reveal = Animation.easeOut(duration: 0.15)
    /// Kept clear above and below every highlight, so two lit rows next to each other (one hovered,
    /// one open) read as two shapes rather than merging into one block.
    public static let highlightGap: CGFloat = 1
}

extension PanelMotion {
    /// Writes `text` into a field a few words at a time, as if typed, for text Claude wrote: it reads as
    /// arriving rather than swapped in. Always done within about half a second, however long the text,
    /// so it never holds anyone up. Stops, leaving the field alone, as soon as someone types in it
    /// (`current()` no longer what was last written). At once with Reduce Motion on.
    @MainActor
    public static func typeOut(_ text: String, current: () -> String, set: (String) -> Void) async {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            set(text)
            return
        }
        let pause = min(0.04, 0.45 / Double(words.count))
        var written = ""
        for (index, word) in words.enumerated() {
            guard current() == written else { return }
            written += (index == 0 ? "" : " ") + word
            set(written)
            try? await Task.sleep(for: .seconds(pause))
        }
    }
}

public extension View {
    /// Content that a click has just shown (an opened row's details, a group's rows): it fades in and
    /// settles from a few points above, so the eye follows where it came from. It's laid out at once,
    /// only drawn in over a moment. Closing is immediate, as a menu's is.
    func revealsGently() -> some View {
        modifier(Reveal())
    }

    /// A page of the panel coming in, as Control Center's pages do: from the trailing edge when going
    /// in (a form opened from the list), from the leading edge when going back. Nil: no animation, as
    /// when the panel opens. Only offset and opacity, so the panel's height isn't animated.
    func slidesIn(from edge: HorizontalEdge?) -> some View {
        modifier(SlideIn(edge: edge))
    }

    /// A disclosure chevron pointing right while closed and down while open, turning between them.
    func disclosureRotation(_ isOpen: Bool) -> some View {
        animation(PanelMotion.reveal) { $0.rotationEffect(.degrees(isOpen ? 90 : 0)) }
    }

    /// Shown or hidden at once while staying laid out (and taking no clicks while hidden), so what's
    /// beside it doesn't move when it comes and goes.
    func fadesIn(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

/// Grey text with a faint light passing over it, left to right, every 1.2 seconds: something is
/// being worked on, said in the panel's own greys, as macOS shows a model thinking. Still with Reduce Motion.
public struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass of the light, start to end. Every shimmer runs on the same clock, so passes start at
    /// the same moments everywhere (`untilPassEnds`).
    public static let period: TimeInterval = 1.2

    public init(_ text: String) {
        self.text = text
    }

    /// How long until the light has passed all the way over: what replaces the shimmer (the text Claude
    /// wrote) comes in on that beat, so the rhythm carries on rather than being cut off mid-pass.
    /// Nothing to wait for with Reduce Motion, as the light doesn't move then.
    @MainActor
    public static func untilPassEnds() -> TimeInterval {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        return period - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
    }

    public var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            LinearGradient(colors: [.clear, .primary.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width * 0.45)
                                .offset(x: -width * 0.45 + phase * width * 1.45)
                        }
                        .mask(Text(text))
                    }
                }
            }
            .accessibilityLabel(text)
    }
}

private struct SlideIn: ViewModifier {
    let edge: HorizontalEdge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let distance: CGFloat = reduceMotion ? 0 : edge == .leading ? -16 : 16
        content
            .opacity(shown || edge == nil ? 1 : 0)
            .offset(x: shown || edge == nil ? 0 : distance)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
    }
}

extension PanelMotion {
    @MainActor private static var instantUntil = Date.distantPast

    /// Content that appears in the next moment is there at once rather than fading in: a whole page or
    /// tab built anew (Bridge switching tabs) isn't something a click opened, and every group and open
    /// row in it fading in made the switch flicker.
    @MainActor
    public static func revealsInstantly() {
        instantUntil = Date().addingTimeInterval(0.25)
    }

    @MainActor static var isRevealingInstantly: Bool {
        Date() < instantUntil
    }
}

private struct Reveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = PanelMotion.isRevealingInstantly

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -4)
            // Only this view's own state changes in the transaction, so nothing around it is animated.
            .onAppear {
                guard !shown else { return }
                withAnimation(PanelMotion.reveal) { shown = true }
            }
    }
}
