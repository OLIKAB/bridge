import AppKit
import Carbon.HIToolbox
import Shared
import SwiftUI

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            BridgePanel(store: appDelegate.store, ports: appDelegate.ports)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: RepoStore
    @ObservedObject private var claude = BackgroundClaude.shared

    var body: some View {
        // The knot's rings light up for what's going on: code while something isn't pushed, server
        // while a dev server runs in one of the repositories, agent while a Claude session works, with
        // a dot when one waits for an answer, so it can be seen at a glance without another
        // notification. Only sessions in Bridge's repositories.
        let waiting = claude.sessions.contains { $0.state == .blocked }
        let lit = KnotMark.Lit(
            code: store.localWorkCount > 0,
            server: store.repos.contains { $0.server.isActive },
            agent: waiting || claude.sessions.contains { $0.state == .working },
            badge: waiting
        )
        Image(nsImage: KnotMark.image(lit))
            .accessibilityLabel(waiting ? "Bridge, a Claude session needs you" : "Bridge")
        // How many repositories have changes or commits that aren't pushed, like a Mail badge: a
        // count, where server and agent are on or off. The number of repositories was shown too,
        // but it hardly ever changes, so it took room without telling anything.
        if store.localWorkCount > 0 {
            Text(verbatim: String(store.localWorkCount))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: RepoStore
    let ports: PortModel
    private var termination: DispatchSourceSignal?

    override init() {
        store = RepoStore()
        ports = PortModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (pkill, as `build.sh --install` does, or a logout that doesn't ask) would end the
        // app without applicationWillTerminate, leaving dev servers writing into a pipe nobody reads.
        // Quitting the usual way stops them first.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        termination = source
        EditMenu.install()
        if MoveToApplications.offerIfNeeded() { return }
        // Nothing to show in the menu bar yet, so start where repositories can be added.
        if store.repos.isEmpty { MainWindow.shared.show(store) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DevServer.terminateAll(store.repos.map(\.server))
    }

    /// Opening the app again (Finder, Spotlight, Dock) brings up the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindow.shared.show(store)
        return false
    }
}

/// Text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through the main menu, which a menu bar app may not have.
enum EditMenu {
    @MainActor static func install() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        let hasPaste = mainMenu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true }
        guard !hasPaste else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
    }
}

/// The main window, managed by hand: a SwiftUI Window scene would open by itself at launch.
/// While it's open the app shows in the Dock and the app switcher, like a normal app.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?
    private var requiredWidth = MainLayout.minWidth

    func show(_ store: RepoStore, selecting repo: Repository? = nil) {
        if let repo { store.selectedPath = repo.path }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Bridge"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // An empty compact toolbar makes the title bar 40 pt, the top bar's height (`MainLayout.barHeight`),
            // with the traffic lights centered in it, so they share the bar's row, as in Safari, instead of
            // sitting in a strip of their own above it. The regular unified toolbar's title bar is 66 pt
            // on macOS 26 (52 shown and 14 below it), which no bar height lined up with.
            window.toolbar = NSToolbar(identifier: "BridgeMainWindow")
            window.toolbarStyle = .unifiedCompact
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: MainLayout.minWidth, height: 520)
            let host = NSHostingController(rootView: MainView(store: store))
            // Otherwise the window shrinks to the content's minimum size.
            host.sizingOptions = []
            window.contentViewController = host
            // Setting the controller resizes the window to the view's current size.
            window.setContentSize(NSSize(width: 1400, height: 780))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("BridgeMainWindow")
            self.window = window
            // The saved frame may be narrower than what the view asked for while the window was built.
            requireContentWidth(requiredWidth, grow: true)
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Makes the window at least `width` wide inside for the user's resizes, and with `grow` widens it now
    /// if it's narrower, so a pane the user just switched on (notes) gets its room.
    func requireContentWidth(_ width: CGFloat, grow: Bool = false) {
        requiredWidth = width
        // The view asks while the window is being built, before `window` is set; `show` applies it then.
        guard let window else { return }
        window.contentMinSize.width = width
        let content = window.contentRect(forFrameRect: window.frame)
        guard grow, content.width < width else { return }
        var frame = window.frame
        frame.size.width += width - content.width
        // Grow to the left when there's no room on the right, so it stays on screen.
        if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
            frame.origin.x = max(screen.minX, screen.maxX - frame.width)
        }
        // Not animated: a resize from outside during the animation was undone by it.
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
