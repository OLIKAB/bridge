import AppKit
import SwiftUI

public extension View {
    /// MenuBarExtra grows its panel when the content grows, but never shrinks it again, leaving
    /// the content floating in the middle of an oversized transparent window. This trims the
    /// panel to the content, keeping its top edge under the menu bar.
    func fitsMenuBarPanel() -> some View {
        background(PanelSizer())
    }
}

/// A line between parts of a panel, inset to the content's edge like the separators in macOS's own
/// menu bar panels (Control Center, Screen Mirroring), not running from edge to edge.
public struct PanelDivider: View {
    /// Fainter, for lines between rows of a list rather than between parts of the panel.
    let subtle: Bool

    public init(subtle: Bool = false) {
        self.subtle = subtle
    }

    public var body: some View {
        Divider()
            .opacity(subtle ? 0.5 : 1)
            .padding(.horizontal, 12)
    }
}

public extension View {
    /// A rounded background for a row or a block inside a panel, the way the system draws highlights:
    /// on macOS 26 its corners are concentric with the window's, so a row by the panel's rounded bottom
    /// follows its curve, and elsewhere they're as round as a menu item's highlight. Older macOS: 6 pt.
    func panelBackground<S: ShapeStyle>(_ style: S) -> some View {
        modifier(PanelBackground(style: AnyShapeStyle(style)))
    }

    /// `panelBackground` while `isOn`, nothing otherwise: a row's hover or drop highlight. Immediate,
    /// as a menu's, and kept `PanelMotion.highlightGap` clear of the rows above and below.
    func panelHighlight<S: ShapeStyle>(_ isOn: Bool, _ style: S) -> some View {
        background {
            if isOn {
                Color.clear
                    .panelBackground(style)
                    .padding(.vertical, PanelMotion.highlightGap)
                    .allowsHitTesting(false)
            }
        }
    }
}

public extension View {
    /// Every text field, in the panels, their popovers and the main window: the system's rounded field,
    /// large so it's as tall as the buttons beside it (`fieldRowButton`), with the system's focus ring.
    /// A drawn field (fill, hairline, accent ring) was used while the apps were linked as for macOS 14
    /// and got the old square fields; with the real SDK (`currentSDK` in Package.swift) the system's
    /// own is the one that looks at home. `compact` for a field that stands in for a row's title while
    /// renaming it, so the row keeps its height.
    func panelField(compact: Bool = false) -> some View {
        textFieldStyle(.roundedBorder)
            .controlSize(compact ? .regular : .large)
    }
}

private struct PanelBackground: ViewModifier {
    let style: AnyShapeStyle

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(style, in: .rect(corners: .concentric(minimum: 8), isUniform: true))
        } else {
            content.background(style, in: .rect(cornerRadius: 6))
        }
    }
}

/// A list that is as tall as its rows, and scrolls once they pass `maxHeight`.
/// A plain ScrollView collapses to zero height inside MenuBarExtra; measuring the rows into
/// state instead leaves the list empty for a frame on every open, so the panel jumps.
///
/// Always the same ScrollView. Switching between the bare rows and a ScrollView (ViewThatFits)
/// when the rows pass `maxHeight` rebuilt every row and lost the scroll position, and when it
/// happened while the panel was resizing (opening a folded group) the panel ended up the wrong
/// size, unable to scroll.
public struct MenuPanelList<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content

    public init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    public var body: some View {
        CappedHeight(maxHeight: maxHeight) {
            ScrollView { content }
        }
    }
}

/// As tall as the content, up to `maxHeight`, whatever it is offered itself. A ScrollView's ideal
/// height is its content's, so asking for that gives the rows' height without measuring into state.
/// The panel's size follows the content's, so if the content followed the offer too, a panel that
/// happened to be too large or too small would stay that way.
private struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // Not a fixed height: that becomes the panel's minimum size, so it never shrinks below it.
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct PanelSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> SizerView { SizerView() }
    func updateNSView(_ nsView: SizerView, context: Context) { nsView.scheduleFit() }
}

/// Sits behind the content, so its frame is the content's frame. Whenever the content or the
/// window changes size, it cuts away the empty space around the content. It only ever shrinks
/// the window by space that is actually empty, so it never fights SwiftUI growing it.
private final class SizerView: NSView {
    private var observer: NSObjectProtocol?
    private var isScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFit() }
        }
        scheduleFit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFit()
    }

    func scheduleFit() {
        guard !isScheduled else { return }
        isScheduled = true
        // Let SwiftUI finish its own layout and resizing first.
        DispatchQueue.main.async { [weak self] in
            self?.isScheduled = false
            self?.fit()
        }
    }

    private func fit() {
        guard let window, let contentView = window.contentView, bounds.height > 0 else { return }
        let content = convert(bounds, to: nil)
        let available = contentView.frame
        let top = available.maxY - content.maxY
        let bottom = content.minY - available.minY
        let left = content.minX - available.minX
        let right = available.maxX - content.maxX
        guard top > 0.5 || bottom > 0.5 || left > 0.5 || right > 0.5 else { return }
        var frame = window.frame
        frame.origin.x += max(left, 0)
        frame.origin.y += max(bottom, 0)
        frame.size.width -= max(left, 0) + max(right, 0)
        frame.size.height -= max(top, 0) + max(bottom, 0)
        window.setFrame(frame, display: true)
    }
}
