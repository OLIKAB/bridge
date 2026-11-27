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
    /// Something arriving that no click asked for (`arrives`), and a symbol turning into the next one.
    /// Apple's own `.snappy`, as are `disclose` and `page`: the system's preset for quick changes, not a
    /// curve of our own. Own curves (0.28–0.35 s) felt sluggish beside the system's panels.
    public static let arrive = Animation.snappy
    /// A row opening or folding, its height growing or shrinking with the rows below following.
    public static let disclose = Animation.snappy
    /// A page of the panel pushed in or back.
    public static let page = Animation.snappy
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
        modifier(Reveal(isOn: true))
    }

    /// `revealsGently` only when `isOn` as it appears: for rows of a lazy list, which appear as they're
    /// scrolled to as well as when a click shows them, and should only settle in for the click.
    func revealsGently(when isOn: Bool) -> some View {
        modifier(Reveal(isOn: isOn))
    }

    /// News arriving on its own rather than opened by a click (the status line's message): like
    /// `revealsGently`, but it comes down further and a little slower, so a message that turns up
    /// while the eye is elsewhere in the panel is noticed. The short reveal went by unseen there.
    func arrives() -> some View {
        modifier(Reveal(isOn: true, distance: 10, animation: PanelMotion.arrive))
    }

    /// For what a row's opening shows (`PanelMotion.disclose`): it stands still where it will be and the
    /// row's edge, clipped (`clipped()` on the row), uncovers it as the row grows, as Finder's outline
    /// does. Never faded, so a field or glass button in it never draws black, and kept while the row
    /// folds over it.
    func unrollsWithRow() -> some View {
        transition(Unroll())
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

extension EnvironmentValues {
    /// True while the view is inside content that is fading in (`revealsGently`), so controls drawn
    /// with the system's materials can stay hidden until it's opaque (`hiddenWhileFadingIn`).
    @Entry var panelIsFadingIn = false
}

public extension View {
    /// For a control drawn with the system's materials (a text field, a glass button): hidden while
    /// the content around it fades in, and there at once when that's done. Those materials draw black
    /// while their layer is partly transparent, so fading them in flashed them black. `panelField`,
    /// `fieldRowButton` and `prominentButton` already do this.
    func hiddenWhileFadingIn() -> some View {
        modifier(HiddenWhileFadingIn())
    }
}

private struct HiddenWhileFadingIn: ViewModifier {
    @Environment(\.panelIsFadingIn) private var isFadingIn

    func body(content: Content) -> some View {
        content.opacity(isFadingIn ? 0 : 1)
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

/// Stands still: the row's clipped edge does the uncovering. Half a point of movement between its
/// phases only so SwiftUI has something to animate, which keeps a removed view until the row has
/// folded over it (a transition that changes nothing is dropped at once, leaving a blank row shrinking).
private struct Unroll: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.offset(y: phase.isIdentity ? 0 : -0.5)
    }
}

private struct Reveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var settled: Bool
    private let distance: CGFloat
    private let animation: Animation

    init(isOn: Bool, distance: CGFloat = 4, animation: Animation = PanelMotion.reveal) {
        let instantly = PanelMotion.isRevealingInstantly || !isOn
        _shown = State(initialValue: instantly)
        _settled = State(initialValue: instantly)
        self.distance = distance
        self.animation = animation
    }

    func body(content: Content) -> some View {
        content
            // Fields and glass buttons in it wait until it's opaque (`hiddenWhileFadingIn`).
            .environment(\.panelIsFadingIn, !settled)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -distance)
            // Only this view's own state changes in the transaction, so nothing around it is animated.
            .onAppear {
                guard !shown else { return }
                withAnimation(animation) { shown = true } completion: { settled = true }
            }
    }
}
