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

    var body: some View {
        VStack(spacing: 0) {
            AppUpdateBar()
            ClaudeUpdateBar()
            switch state.tab {
            case .repos: MenuPanel(store: store)
            case .servers: ServersPanel(model: ports)
            }
        }
        .frame(width: 460)
        // Here rather than on each tab, or the update bar above the tab would count as empty space and be cut away.
        .fitsMenuBarPanel()
        .background(PanelWindowReader())
        .onAppear {
            AppUpdate.shared.checkIfDue()
            if AgentStatus.shared.info.can(.selfUpdate) { ClaudeUpdate.shared.checkIfDue() }
        }
    }
}

/// Switches between the tabs; sits where the app name used to be in each tab's header.
struct PanelTabs: View {
    @ObservedObject private var state = PanelState.shared

    var body: some View {
        // The system's own segmented control. Drawn imitations of Liquid Glass's lens on it were tried
        // and looked home-made; on macOS 26 the lens is only on the system switch and slider.
        Picker("Show", selection: $state.tab) {
            ForEach(PanelTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
