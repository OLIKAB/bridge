import AppKit
import SwiftUI

public extension View {
    /// What a control without words of its own does (an icon, a switch, a badge like ↓3), shown just
    /// above it soon after the pointer rests on it. The system's tooltip (`.help`) takes a second or
    /// more and often isn't noticed at all, which left the panels' icons a guess.
    ///
    /// The first line is the name of the thing; further lines (after "\n") are details, in grey. Also
    /// the control's VoiceOver label unless it has one. Only for controls that are just an icon: on
    /// rows, fields, badges and text buttons, tooltips got in the way of what was being reached for,
    /// and those say what they are anyway.
    func panelTooltip(_ text: String) -> some View {
        modifier(PanelTooltipModifier(text: text))
    }
}

private struct PanelTooltipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    @State private var anchor = TooltipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside, !text.isEmpty {
                    TooltipController.shared.schedule(id, text: text, over: anchor)
                } else {
                    TooltipController.shared.hide(id)
                }
            }
            .onChange(of: text) { _, new in TooltipController.shared.update(id, text: new) }
            .onDisappear { TooltipController.shared.hide(id) }
            .accessibilityHint(text.split(separator: "\n").dropFirst().joined(separator: ". "))
    }
}

/// The AppKit view behind a control, to find where it is on screen.
@MainActor
private final class TooltipAnchor {
    weak var view: NSView?

    var screenRect: CGRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// A row, a field or a block of text rather than a small control: its tooltip waits longer and
    /// shows by the pointer.
    var isLarge: Bool {
        guard let size = view?.bounds.size else { return false }
        return size.width > 160 || size.height > 34
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// One tooltip at a time, in a window of its own: a view inside a menu bar panel can't reach past the
/// panel's edge, and the top row's tooltips would be cut off by it.
@MainActor
private final class TooltipController {
    static let shared = TooltipController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<TooltipBubble>?
    private var owner: UUID?
    private var anchor: TooltipAnchor?
    private var pending: Task<Void, Never>?
    private var pendingID: UUID?
    private var pendingIsLarge = false
    private var ownerIsLarge = false
    private var watcher: Timer?
    private var clickMonitor: Any?
    /// When the last tooltip went away: moving straight on to the next icon shows its tooltip at once,
    /// as macOS's own tooltips and menu bar do.
    private var hiddenAt = Date.distantPast

    init() {
        // A menu opening (Settings, a branch menu, a right-click) takes the click before the click
        // monitor sees it, and keeps the pointer's moves to itself, so the tooltip of the button that
        // opened it stayed up over whatever came next. Any menu opening ends tooltips.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAll() }
        }
    }

    private func dismissAll() {
        pending?.cancel()
        pending = nil
        pendingID = nil
        pendingIsLarge = false
        if let owner { hide(owner) }
    }

    func schedule(_ id: UUID, text: String, over anchor: TooltipAnchor) {
        let large = anchor.isLarge
        // A control inside a row (an icon in it) wins over the row's own tooltip, whichever hover
        // SwiftUI reports first.
        if large, (pendingID != nil && !pendingIsLarge) || (owner != nil && !ownerIsLarge) { return }
        pending?.cancel()
        pendingID = id
        pendingIsLarge = large
        // A row or a field: later, and never straight after another tooltip, so moving the pointer down
        // a list doesn't pop one up over each row. A small control: soon, and at once when moving on
        // from another tooltip, as macOS's menu bar does.
        let warm = !large && (owner != nil || Date().timeIntervalSince(hiddenAt) < 0.6)
        pending = Task { [weak self] in
            if !warm { try? await Task.sleep(for: .milliseconds(large ? 1000 : 450)) }
            guard !Task.isCancelled else { return }
            self?.show(id, text: text, over: anchor)
        }
    }

    func update(_ id: UUID, text: String) {
        guard owner == id, let anchor else { return }
        show(id, text: text, over: anchor)
    }

    func hide(_ id: UUID) {
        // Moving straight from one icon to the next can report the next one's enter first: leaving the
        // first mustn't cancel the next one's tooltip.
        if pendingID == id {
            pending?.cancel()
            pending = nil
            pendingID = nil
            pendingIsLarge = false
        }
        guard owner == id else { return }
        owner = nil
        ownerIsLarge = false
        anchor = nil
        hiddenAt = Date()
        watcher?.invalidate()
        watcher = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
    }

    private func show(_ id: UUID, text: String, over anchor: TooltipAnchor) {
        guard let rect = anchor.screenRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        hosting?.rootView = TooltipBubble(text: text)
        let size = Self.size(of: text)

        // Above the control, centered on it (on the pointer, for a row or field, which is too wide to
        // center on); below it where there's no room above (the top row of a menu bar panel, right
        // under the menu bar). Kept on the screen at the sides.
        let visible = screen.visibleFrame
        let centerX = anchor.isLarge ? NSEvent.mouseLocation.x : rect.midX
        var origin = CGPoint(x: centerX - size.width / 2, y: rect.maxY + 4)
        if origin.y + size.height > visible.maxY { origin.y = rect.minY - 4 - size.height }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        let wasShown = owner != nil
        owner = id
        ownerIsLarge = anchor.isLarge
        self.anchor = anchor
        if !wasShown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
        watch(id)
    }

    /// Hides it when the pointer has left the control without a hover-out (the panel closed, the row
    /// scrolled away), and on any click, which does what the tooltip described.
    private func watch(_ id: UUID) {
        watcher?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.owner == id else { return }
                guard let rect = self.anchor?.screenRect, rect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else {
                    self.hide(id)
                    return
                }
            }
        }
        // In the common modes, so it also runs while a menu is open: in the default mode alone it
        // paused during menu tracking, and a tooltip stayed up after the pointer had moved on.
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                // Nor does a tooltip still waiting to show come up after the click.
                self?.dismissAll()
                return event
            }
        }
    }

    /// The bubble's size with its text wrapped at the widest a tooltip gets. The hosting view's
    /// `fittingSize` measured it unwrapped, one line tall, so a long tooltip wrapped into two lines
    /// in a window sized for one, ran over its edge and covered the control it was about.
    private static func size(of text: String) -> CGSize {
        let sizer = NSHostingController(rootView: TooltipBubble(text: text))
        let unwrapped = sizer.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        guard unwrapped.width > TooltipBubble.maxWidth else { return unwrapped }
        return sizer.sizeThatFits(in: CGSize(width: TooltipBubble.maxWidth, height: .greatestFiniteMagnitude))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // Above the menu bar panels, which sit at the pop-up menu level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: TooltipBubble(text: ""))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// The tooltip itself: macOS's own tooltip material, small type, the name first and details in grey.
private struct TooltipBubble: View {
    let text: String
    /// The widest a tooltip gets, padding included; longer text wraps (see `TooltipController.size(of:)`).
    /// Wide enough that a tooltip is a line or two: narrower, they wrapped into tall narrow blocks.
    static let maxWidth: CGFloat = 380

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        VStack(alignment: .leading, spacing: 2) {
            if let first = lines.first {
                Text(first).foregroundStyle(.primary)
            }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(TooltipMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary))
    }
}

private struct TooltipMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .toolTip
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
