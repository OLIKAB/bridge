import AppKit
import Carbon.HIToolbox
import Shared
import SwiftUI

enum PanelTab: String, CaseIterable {
    case repos
    case servers

    var title: String {
        switch self {
        case .repos: "Repos"
        case .servers: "Servers"
        }
    }
}

/// Which tab the menu bar panel shows. Each tab has its own global shortcut, kept from when they were two apps.
@MainActor
final class PanelState: ObservableObject {
    static let shared = PanelState()

    @Published var tab = PanelTab(rawValue: UserDefaults.standard.string(forKey: "panelTab") ?? "") ?? .repos {
        willSet {
            // The other tab is built anew; content in it that would fade in on a click shows at once.
            if newValue != tab {
                PanelMotion.revealsInstantly()
                // The tab going away stays built, hidden; a field in it mustn't keep taking the typing.
                window?.makeFirstResponder(nil)
            }
        }
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "panelTab") }
    }
    /// The panel's window, once it has been shown. MenuBarExtra has no API to tell whether it's open.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { PanelState.shared.closedAt = Date() }
                }
            }
        }
    }
    private var resignObserver: NSObjectProtocol?

    /// When the panel last closed (lost the keyboard, which it does when it closes), to tell a quick
    /// look away, after which it should be just as it was, from coming back to it later.
    var closedAt: Date?

    /// Whether the panel has been closed long enough to open it fresh: at the top, nothing open. Within
    /// a minute it's most likely the same task (checking something in another app and coming back),
    /// so it stays where it was.
    var isReturningLater: Bool {
        closedAt.map { Date().timeIntervalSince($0) > 60 } ?? false
    }

    /// A page to show in the Repos tab, asked for from outside the panel (the main window's Settings).
    @Published var requestedPage: PanelPage?

    /// Opens the panel on the Repos tab showing `page`.
    func open(_ page: PanelPage) {
        tab = .repos
        requestedPage = page
        if window?.isVisible != true { MenuBarPanel.toggle() }
    }

    /// A shortcut opens the panel on its tab; pressed again it closes it, and with the other tab showing it switches.
    func shortcut(_ target: PanelTab) {
        if window?.isVisible == true && tab != target {
            tab = target
            return
        }
        tab = target
        MenuBarPanel.toggle()
    }
}

extension HotKey {
    static let repos = HotKey(keyCode: kVK_ANSI_G, modifiers: cmdKey | optionKey, displayName: "⌥⌘G", signature: "BRDG", id: 1) {
        MainActor.assumeIsolated { PanelState.shared.shortcut(.repos) }
    }
    static let servers = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey, displayName: "⌥⌘P", signature: "BRDG", id: 2) {
        MainActor.assumeIsolated { PanelState.shared.shortcut(.servers) }
    }
}

/// The menu bar panel: repositories or servers, each with its own header.
struct BridgePanel: View {
    @ObservedObject var store: RepoStore
    @ObservedObject var ports: PortModel
    @ObservedObject private var state = PanelState.shared
    /// The tabs shown so far. A tab once built stays, hidden while the other shows: building one anew
    /// on every switch (every row, laid out and measured) held the main thread for 70–100 ms, a visible
    /// hitch, and ran everything its `onAppear` does for the panel opening again.
    @State private var built: Set<PanelTab> = []

    var body: some View {
        VStack(spacing: 0) {
            AppUpdateBar()
            ClaudeUpdateBar()
            TabStack(shown: state.tab) {
                if built.contains(.repos) || state.tab == .repos {
                    MenuPanel(store: store).tabPage(isShown: state.tab == .repos)
                        .layoutValue(key: TabStack.Tab.self, value: .repos)
                }
                if built.contains(.servers) || state.tab == .servers {
                    ServersPanel(model: ports).tabPage(isShown: state.tab == .servers)
                        .layoutValue(key: TabStack.Tab.self, value: .servers)
                }
            }
            .onChange(of: state.tab, initial: true) { _, tab in built.insert(tab) }
        }
        .frame(width: 460)
        .overlayPreferenceValue(PanelTabsAnchor.self) { anchor in
            if #available(macOS 27, *) {
                // One control for both tabs, laid over the place each tab's header keeps for it. A
                // control in each header was torn down mid-animation on every switch, and the new one
                // came up under the pointer enlarged, as if pressed, a few points off.
                GeometryReader { proxy in
                    let rect = anchor.map { proxy[$0] } ?? .zero
                    TabSegments(selection: $state.tab)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        // A page of the Repos tab has no tabs.
                        .fadesIn(anchor != nil)
                }
            }
        }
        // Here rather than on each tab, or the update bar above the tab would count as empty space and be cut away.
        .fitsMenuBarPanel()
        .background(PanelWindowReader())
        .onAppear {
            AppUpdate.shared.checkIfDue()
            if AgentStatus.shared.info.can(.selfUpdate) { ClaudeUpdate.shared.checkIfDue() }
        }
    }
}

private extension View {
    /// A tab kept while the other shows (`TabStack` puts it outside the window): nothing in it to click,
    /// and its place for the tab switch withdrawn, or the switch would be drawn over its header.
    /// Not `.disabled`, `.accessibilityHidden` or `.opacity`: flipped on a whole tab, they had SwiftUI
    /// update every control's environment and accessibility element, or drop and rebuild every layer,
    /// which cost most of a switch. Shortcuts are turned off where they are (`TabShortcuts`), and
    /// `PanelState` takes the keyboard from a field in the tab going away.
    func tabPage(isShown: Bool) -> some View {
        allowsHitTesting(isShown)
            .transformPreference(PanelTabsAnchor.self) { if !isShown { $0 = nil } }
    }
}

/// The panel's tabs, all laid out alike, as large as the one shown, the others placed outside the
/// window. Being offered the same size whether shown or not, a tab keeps its layout and its layers
/// through a switch, so switching only moves it: the panel's height follows at once.
private struct TabStack: Layout {
    let shown: PanelTab

    struct Tab: LayoutValueKey {
        static let defaultValue: PanelTab? = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first { $0[Tab.self] == shown }?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let isShown = subview[Tab.self] == shown
            // Well past the panel's right edge, where nothing of it is drawn.
            let origin = isShown ? bounds.origin : CGPoint(x: bounds.minX + 4000, y: bounds.minY)
            subview.place(at: origin, proposal: proposal)
        }
    }
}

/// A tab's keyboard shortcuts, working only while it shows: both tabs stay built, and both have ⌘R.
struct TabShortcuts<Content: View>: View {
    let tab: PanelTab
    @ViewBuilder let content: Content
    @ObservedObject private var state = PanelState.shared

    var body: some View {
        content.disabled(state.tab != tab)
    }
}

/// Switches between the tabs; sits where the app name used to be in each tab's header.
struct PanelTabs: View {
    @ObservedObject private var state = PanelState.shared

    var body: some View {
        // The system's own segmented control. Drawn imitations of Liquid Glass's lens on it were tried
        // and looked home-made. macOS 27 gives a segmented control the lens (dragged from one segment
        // to the other) and the grey selection of the system's tab switchers when its role is tabs,
        // which SwiftUI's segmented picker has no way to ask for, so AppKit's control is used there.
        if #available(macOS 27, *) {
            // Only the place for it: `BridgePanel` draws the control there.
            Color.clear
                .frame(width: TabSegments.size.width, height: TabSegments.size.height)
                .anchorPreference(key: PanelTabsAnchor.self, value: .bounds) { $0 }
        } else {
            Picker("Show", selection: $state.tab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Where the current tab's header keeps room for the tab switch.
private struct PanelTabsAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// An `NSSegmentedControl` in the tabs role, one segment per `PanelTab`.
@available(macOS 27, *)
private struct TabSegments: NSViewRepresentable {
    @Binding var selection: PanelTab

    /// Its own size, for the room the headers keep for it.
    @MainActor static let size = makeControl().fittingSize

    private static func makeControl() -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: PanelTab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        control.role = .tabs
        control.setAccessibilityLabel("Show")
        return control
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = Self.makeControl()
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = PanelTab.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PanelTab>
        init(selection: Binding<PanelTab>) { self.selection = selection }

        @objc func changed(_ control: NSSegmentedControl) {
            let tabs = PanelTab.allCases
            guard tabs.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = tabs[control.selectedSegment]
        }
    }
}

private struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderView { ReaderView() }
    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { PanelState.shared.window = window }
        }
    }
}
