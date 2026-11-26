import AppKit
import Shared
import SwiftUI

/// The narrowest each part of the main window can be. The window's minimum is the sum of what's shown,
/// so the content never overflows it: when it did (all the minimums added up to more than the window's
/// own), SwiftUI centered the content and cut it off on both sides.
enum MainLayout {
    static let sidebar: CGFloat = 190
    static let list: CGFloat = 240
    static let detail: CGFloat = 440
    /// The notes pane opens at this width (its ideal, not a smaller minimum), so this is the room it takes.
    static let notes: CGFloat = 260
    /// Without the sidebar or notes.
    static let minWidth = list + detail
    /// The top bar and the sidebar's strip: exactly the title bar's height with the compact toolbar
    /// (`MainWindow`), so they share its row with the traffic lights, centered on the same line, and
    /// what's below starts where the title bar ends. A 52 pt bar under the regular toolbar's 66 pt title
    /// bar left the panes below overlapping it, and each pane then took the overlap as extra inset.
    static let barHeight: CGFloat = 40

    /// The narrowest each shown pane may be in a window `width` wide. The window's own minimum keeps it
    /// wide enough when the user resizes it, but a resize from outside (System Events, window managers,
    /// tiling) skips that minimum; then the panes' minimums shrink in proportion so they still add up
    /// to no more than the window, and notes that don't fit stay closed.
    ///
    /// The panes beside the diff also get a widest size from the room that's left. The split view only
    /// shrinks its last pane when the window narrows and keeps the others as they were dragged, so a
    /// wide sidebar or list pushed the rest out of the window; capped, together they always fit, and
    /// the diff takes what remains.
    struct Widths {
        var sidebar: CGFloat
        var list: CGFloat
        var detail: CGFloat
        var notes: CGFloat?
        var sidebarMax: CGFloat
        var listMax: CGFloat
        var notesMax: CGFloat

        init(width: CGFloat, sidebar showsSidebar: Bool, notes wantsNotes: Bool) {
            let base = (showsSidebar ? MainLayout.sidebar : 0) + MainLayout.minWidth
            let showsNotes = wantsNotes && width >= base + MainLayout.notes
            let total = base + (showsNotes ? MainLayout.notes : 0)
            // A little under the window, so rounding and the split view's dividers still fit.
            let room = max(0, width - 12)
            let scale = min(1, room / total)
            sidebar = (MainLayout.sidebar * scale).rounded(.down)
            list = (MainLayout.list * scale).rounded(.down)
            detail = (MainLayout.detail * scale).rounded(.down)
            notes = showsNotes ? (MainLayout.notes * scale).rounded(.down) : nil
            // Shares of the room above the minimums; they add up to less than all of it, so the diff
            // always keeps at least its minimum.
            let slack = max(0, room - (showsSidebar ? sidebar : 0) - list - detail - (notes ?? 0))
            sidebarMax = min(380, sidebar + (slack * 0.3).rounded(.down))
            listMax = min(520, list + (slack * 0.3).rounded(.down))
            notesMax = min(520, (notes ?? 0) + (slack * 0.25).rounded(.down))
        }

        /// `preferred`, kept between a pane's narrowest and widest, for its ideal width.
        static func ideal(_ preferred: CGFloat, _ least: CGFloat, _ most: CGFloat) -> CGFloat {
            min(max(preferred, least), most)
        }
    }
}

extension EnvironmentValues {
    /// The narrowest the diff side of the main window may be now, for split views inside it (History's).
    @Entry var detailMinWidth: CGFloat = MainLayout.detail
}

/// The main window, laid out like GitHub Desktop: repository, branch and sync along the top,
/// changes or history on the left, and the diff on the right.
struct MainView: View {
    @ObservedObject var store: RepoStore
    @State private var notice: String?
    @AppStorage("showNotes") private var showNotes = false
    /// The sidebar as the user last chose with its button, or nil to follow the window's width
    /// (shown when there's room). Crossing that width hands it back to the automatic choice, like Mail.
    @State private var sidebarChoice: Bool?
    @State private var isNarrow = false
    @State private var windowWidth: CGFloat = 1400

    private var notesWidth: CGFloat { showNotes && store.selected != nil ? MainLayout.notes : 0 }
    private var widths: MainLayout.Widths {
        .init(width: windowWidth, sidebar: showsSidebar && store.selected != nil, notes: showNotes)
    }
    /// Below this the sidebar hides by itself: the list and diff need the room more.
    private var sidebarThreshold: CGFloat { MainLayout.sidebar + MainLayout.minWidth + notesWidth + 120 }
    /// Without a repository the sidebar is all there is, at its usual widths.
    private var sidebarMin: CGFloat { store.selected == nil ? MainLayout.sidebar : widths.sidebar }
    private var sidebarMax: CGFloat { store.selected == nil ? 380 : widths.sidebarMax }
    /// Without a repository there's nothing but the sidebar to show.
    private var showsSidebar: Bool { store.selected == nil || (sidebarChoice ?? !isNarrow) }

    var body: some View {
        // The window's width, not the content's: measured on the content, a sidebar that made the content
        // too wide for the window kept the content wide enough for the sidebar to stay.
        GeometryReader { window in
            split
                .frame(width: window.size.width, height: window.size.height)
                // Up under the title bar, so the top bar and the sidebar's strip share the row with the
                // window's traffic lights. The reader passes its safe area on to what's inside, so the
                // reader ignoring it (below) wasn't enough: the bar sat under an empty title bar strip.
                .ignoresSafeArea(.container, edges: .top)
                .onChange(of: window.size.width, initial: true) { _, width in
                    windowWidth = width
                    let narrow = width < sidebarThreshold
                    guard narrow != isNarrow else { return }
                    isNarrow = narrow
                    sidebarChoice = nil
                }
        }
        // No minimum height here: the window has one for the user's resizes, and content taller than a
        // window squeezed from outside would be cut off at both ends, like too-wide content was.
        .onChange(of: minContentWidth, initial: true) { _, width in
            MainWindow.shared.requireContentWidth(width)
        }
        // Widened only for what the user switched on. When the sidebar hid by itself because something
        // outside made the window narrow, widening it again undid that resize.
        .onChange(of: showNotes) { _, shown in
            if shown { MainWindow.shared.requireContentWidth(minContentWidth, grow: true) }
        }
        .onChange(of: sidebarChoice) { _, choice in
            if choice == true { MainWindow.shared.requireContentWidth(minContentWidth, grow: true) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // ⌘W closes the window, as in every Mac app. The window has no File menu to carry it
            // (Bridge is a menu bar app), so an invisible button does.
            Button("Close window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var split: some View {
        // A split view, so the sidebar's edge can be dragged like any Mac sidebar's; it was a fixed 230.
        HSplitView {
            if showsSidebar {
                RepoSidebar(store: store)
                    .frame(minWidth: sidebarMin, idealWidth: MainLayout.Widths.ideal(230, sidebarMin, sidebarMax), maxWidth: sidebarMax)
                    // Each pane of a split view is hosted on its own and gets the title bar's inset again.
                    .ignoresSafeArea(.container, edges: .top)
            }
            VStack(spacing: 0) {
                if let repo = store.selected {
                    TopBar(repo: repo, showsSidebar: Binding(get: { showsSidebar }, set: { sidebarChoice = $0 }))
                    Divider()
                    if repo.isMissing {
                        Placeholder(title: "Can't find \(repo.name)", detail: "\(repo.path) has been moved or deleted.", systemImage: "questionmark.folder") {
                            HStack {
                                Button("Locate…") { Task { notice = await store.locateWithPanel(repo) } }
                                Button("Remove from Bridge") { store.remove(repo) }
                            }
                            if let notice {
                                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            }
                        }
                    } else {
                        RepoView(repo: repo, widths: widths)
                            // A new split view when notes come or go, for the same reason as the sidebar's below.
                            .id("\(repo.path)|\(widths.notes != nil)")
                    }
                } else {
                    Placeholder(title: "No repositories yet", systemImage: "folder.badge.plus") {
                        HStack {
                            Button("Add repository…") { Task { notice = await store.addWithPanel() } }
                            Button("Find repositories in folder…") { Task { notice = await store.scanWithPanel() } }
                        }
                        if let notice {
                            Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        }
                        SetupChecklist().padding(.top, 20)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        // A new split view whenever a pane comes or goes. The split view kept its panes' old widths when
        // one left while the window shrank (1400 → 900 hid the sidebar and notes at once), so the rest
        // stayed wider than the window until it was resized again.
        .id(showsSidebar)
    }

    private var minContentWidth: CGFloat {
        guard store.selected != nil else { return MainLayout.sidebar + 300 }
        return (showsSidebar ? MainLayout.sidebar : 0) + MainLayout.minWidth + notesWidth
    }
}

/// An empty state, drawn by the system's `ContentUnavailableView` so it looks like the empty states in
/// Apple's own apps: a large symbol, a title, a line of explanation where one is needed and the next step's buttons.
struct Placeholder<Actions: View>: View {
    let title: String
    var detail: String? = nil
    var systemImage = "tray"
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let detail { Text(detail) }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var repo: Repository
    @Binding var showsSidebar: Bool
    @State private var showBranches = false
    @AppStorage("showNotes") private var showNotes = false
    @AppStorage(DevWorkspace.agentBrowserKey) private var agentWithBrowser = false
    @ObservedObject private var agent = AgentStatus.shared

    var body: some View {
        HStack(spacing: 0) {
            // ⌃⌘S as in Finder and Mail. Without the sidebar the window's traffic lights sit on this bar.
            Toggle(isOn: $showsSidebar) {
                Image(systemName: "sidebar.left")
            }
            .toggleStyle(.panel)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .panelTooltip(showsSidebar ? "Hide repositories (⌃⌘S)" : "Show repositories (⌃⌘S)")
            .accessibilityLabel("Repositories")
            // On glass, as the sidebar button in macOS 26's own toolbars.
            .padding(2)
            .glassCapsule()
            // Clear of the traffic lights, with the gap Finder leaves before its own sidebar button.
            .padding(.leading, showsSidebar ? 10 : 86)
            .padding(.trailing, 4)
            Divider()
            // ⌘B like GitHub Desktop's branch list.
            BarButton(icon: "arrow.triangle.branch", spokenCaption: "Current branch", title: repo.currentBranch) { showBranches.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .popover(isPresented: $showBranches, arrowEdge: .bottom) {
                    BranchPicker(repo: repo) { showBranches = false }
                }
            Divider()
            SyncButton(repo: repo)
            Divider()
            if repo.pullRequest != nil || repo.canCreatePullRequest {
                PullRequestButton(repo: repo)
                Divider()
            }
            Spacer()
            HStack(spacing: 2) {
                ServerControls(repo: repo)
                IconButton(systemName: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                    EditorMenu.show(for: repo.path)
                }
                if agent.info.isInstalled {
                    let chrome = agentWithBrowser && agent.info.can(.browser)
                    IconButton(image: Agent.current.logo, help: "Open \(agent.info.name)\(chrome ? " with Chrome" : "") in \(agent.terminalName)",
                               hoverTint: Agent.current.tint, badge: chrome ? Logo.chrome : nil) {
                        DevWorkspace.openAgentInTerminal(repo.path)
                    }
                }
                if let page = repo.webPage {
                    // The host's own mark (GitHub, GitLab) where that's where it goes; other hosts are just "the web".
                    if let host = repo.host {
                        IconButton(image: host.logo, help: "View on \(host.name)") {
                            NSWorkspace.shared.open(page)
                        }
                    } else {
                        IconButton(systemName: "safari", help: "View on the web") {
                            NSWorkspace.shared.open(page)
                        }
                    }
                }
                // Shows or hides a pane: a switch, so it looks like one (on in the accent color).
                Toggle(isOn: $showNotes) {
                    Image(systemName: "note.text")
                }
                .toggleStyle(.panel)
                .panelTooltip(showNotes ? "Hide notes" : "Show notes")
                .accessibilityLabel("Notes")
            }
            // One glass capsule around the icons, as macOS 26 groups a toolbar's items; each icon
            // keeps its own hover and press, as the items in those groups do.
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .glassCapsule()
            .padding(.horizontal, 10)
            // The icons keep their room; the wide buttons on the left give way first.
            .fixedSize()
            .layoutPriority(1)
        }
        .frame(height: MainLayout.barHeight)
        .background(.bar)
        .alert("Git", isPresented: Binding(get: { repo.error != nil }, set: { if !$0 { repo.error = nil } })) {
            Button("OK") { repo.error = nil }
        } message: {
            Text(verbatim: repo.error ?? "")
        }
    }
}

/// A wide button in the top bar: a title with a small caption above it only when the caption tells
/// something (when it was last fetched, a draft); without one the title sits centered in the same height.
private struct BarButton: View {
    let icon: String
    var caption: String? = nil
    /// What VoiceOver says before the title when there's no caption to read ("Current branch, main").
    var spokenCaption: String? = nil
    let title: String
    var detail: String? = nil
    var isBusy = false
    var showsChevron = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Shrinks (the title truncates) rather than staying 230 wide, and in a very narrow window
            // shows only its icon: three of these at a fixed width pushed the icons at the bar's
            // trailing end out of the window. VoiceOver still reads the title.
            ViewThatFits(in: .horizontal) {
                // Below 140 the title is down to "…", which says less than the icon alone.
                full.frame(minWidth: 140, idealWidth: 140, maxWidth: 230, minHeight: MainLayout.barHeight, maxHeight: MainLayout.barHeight)
                glyph.frame(width: 44, height: MainLayout.barHeight)
            }
            .background(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing to click while it's working; the spinner says why.
        .disabled(isBusy)
        .onHover { hovering = $0 }
        // Read as one control, "Current branch, main", rather than three bits of text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([caption ?? spokenCaption, title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var glyph: some View {
        if isBusy {
            ProgressView().controlSize(.small).frame(width: 18)
        } else {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 18).foregroundStyle(.secondary)
        }
    }

    private var full: some View {
            HStack(spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    if let caption {
                        Text(verbatim: caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: title).font(.system(.body, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if let detail {
                            Text(verbatim: detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                if showsChevron {
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
    }
}

/// The open pull (or merge) request for the branch, or GitHub Desktop's Create Pull Request when there's none.
private struct PullRequestButton: View {
    @ObservedObject var repo: Repository

    var body: some View {
        let host = repo.host
        let kind = host?.changeRequest ?? "pull request"
        if let pr = repo.pullRequest {
            BarButton(icon: "arrow.triangle.pull", caption: pr.isDraft ? "Draft" : nil, spokenCaption: kind.prefix(1).uppercased() + kind.dropFirst(),
                      title: "\(host?.numberPrefix ?? "#")\(pr.number)", showsChevron: false) {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            }
        } else {
            BarButton(icon: "arrow.triangle.pull", caption: "Into \(repo.defaultBranch ?? "main")",
                      title: "Create \(kind)", showsChevron: false) {
                Task { await repo.createPullRequest() }
            }
        }
    }
}

/// Fetch, pull, push or publish, whichever is the next useful step.
private struct SyncButton: View {
    @ObservedObject var repo: Repository
    @State private var showPublish = false

    var body: some View {
        let status = repo.status
        let remote = repo.remote ?? "remote"
        Group {
            if let activity = repo.activity {
                BarButton(icon: "", caption: activity.rawValue, title: remote, isBusy: true, showsChevron: false) {}
            } else if repo.remote == nil {
                BarButton(icon: "icloud.and.arrow.up", title: "Publish repository", showsChevron: false) {
                    showPublish = true
                }
                .popover(isPresented: $showPublish, arrowEdge: .bottom) {
                    PublishRepositoryForm(repo: repo) { showPublish = false }
                }
            } else if repo.canPublish {
                BarButton(icon: "icloud.and.arrow.up", title: "Publish branch", showsChevron: false) {
                    Task { await repo.push() }
                }
            } else if let status, status.behind > 0 {
                BarButton(icon: "arrow.down", caption: lastFetched, title: titled("Pull"), detail: arrows(status), showsChevron: false) {
                    Task { await repo.pull() }
                }
            } else if let status, status.ahead > 0 {
                BarButton(icon: "arrow.up", caption: lastFetched, title: titled("Push"), detail: arrows(status), showsChevron: false) {
                    Task { await repo.push() }
                }
            } else {
                BarButton(icon: "arrow.triangle.2.circlepath", caption: lastFetched, title: titled("Fetch"), showsChevron: false) {
                    Task { await repo.fetch() }
                }
            }
        }
        .contextMenu {
            if repo.remote != nil {
                Button("Fetch") { Task { await repo.fetch() } }.keyboardShortcut("r", modifiers: .command)
                Button("Pull") { Task { await repo.pull() } }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button(repo.canPublish ? "Publish branch" : "Push") { Task { await repo.push() } }.keyboardShortcut("p", modifiers: .command)
            }
        }
        // The same three from the keyboard at any time, whichever the button shows: ⌘R to fetch (refresh,
        // as everywhere on the Mac), ⌘P to push and ⌘⇧P to pull (as in GitHub Desktop). The window has no
        // menu bar of its own (Bridge is a menu bar app), so invisible buttons carry the shortcuts.
        .background {
            if repo.remote != nil {
                Group {
                    Button("Fetch") { Task { await repo.fetch() } }.keyboardShortcut("r", modifiers: .command)
                    Button("Pull") { Task { await repo.pull() } }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Push") { Task { await repo.push() } }.keyboardShortcut("p", modifiers: .command)
                }
                .disabled(repo.activity != nil)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    /// "Push", or "Push upstream" when the remote isn't the usual origin, so the name is only there when it says something.
    private func titled(_ verb: String) -> String {
        guard let remote = repo.remote, remote != "origin" else { return verb }
        return "\(verb) \(remote)"
    }

    private var lastFetched: String {
        repo.lastFetched.map { "Last fetched \($0.relative)" } ?? "Never fetched"
    }

    private func arrows(_ status: RepoStatus) -> String {
        [status.behind > 0 ? "↓\(status.behind)" : nil, status.ahead > 0 ? "↑\(status.ahead)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Pickers

/// All repositories, always in view on the left, like a mail app's mailboxes.
private struct RepoSidebar: View {
    @ObservedObject var store: RepoStore
    @State private var filter = ""
    @State private var notice: String?
    @State private var showNewProject = false
    @State private var showClone = false
    /// The repository whose Publish form is open, from its right-click menu.
    @State private var publishing: String?
    /// The repository whose New group form is open, from its right-click menu.
    @State private var newGroupFor: String?
    @FocusState private var filterFocused: Bool
    @ObservedObject private var groups = RepoGroups.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's traffic lights sit on top of this strip.
            HStack(spacing: 2) {
                Spacer()
                if store.isFetchingAll {
                    ProgressView().controlSize(.small).frame(width: 24, height: 22)
                } else {
                    IconButton(systemName: "arrow.triangle.2.circlepath", help: "Fetch all repositories") {
                        Task { await store.fetchAll(quietly: false) }
                    }
                }
                AddRepositoryMenu(store: store, notice: $notice, showNewProject: $showNewProject, showClone: $showClone)
                SettingsMenu(store: store) { PanelState.shared.open(.setup) }
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 10)
            .frame(height: MainLayout.barHeight)

            ForEach(store.cloning, id: \.self) { path in
                SettingUpRow(path: path, verb: "Cloning")
            }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onTapGesture { self.notice = nil }
            }

            TextField("Filter repositories", text: $filter)
                .focused($filterFocused)
                .panelField(compact: true)
                // Esc clears the filter, as in a search field.
                .onExitCommand { filter = "" }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .background {
                    // ⌘F, as in any Mac window with a list to search; an invisible button carries it.
                    Button("Filter") { filterFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }

            List(selection: Binding(get: { store.selected?.path }, set: { if let path = $0 { store.selectedPath = path } })) {
                let shown = shownRepos
                // The panel's groups as sidebar sections, always open: the window has room for every repository.
                ForEach(groups.sections(shown) { groups.group(ofRepo: $0.path) }, id: \.id) { section in
                    if section.isOnly {
                        rows(section)
                    } else {
                        Section {
                            rows(section)
                        } header: {
                            Text(verbatim: section.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .groupDropTarget(section.name, kind: .repo)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if !filter.isEmpty && shownRepos.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .background(.bar)
    }

    private var shownRepos: [Repository] {
        store.visibleRepos.filter { filter.isEmpty || $0.displayName.localizedCaseInsensitiveContains(filter) || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func rows(_ section: GroupSection<Repository>) -> some View {
        ForEach(section.items) { repo in
            SidebarRow(repo: repo)
                .groupRow(GroupDragItem(kind: .repo, key: repo.path), title: repo.displayName, in: section)
                .tag(repo.path)
                .popover(isPresented: Binding(get: { publishing == repo.path }, set: { if !$0 { publishing = nil } }), arrowEdge: .trailing) {
                    PublishRepositoryForm(repo: repo) { publishing = nil }
                }
                // Its own view to anchor to: two popovers on one view don't both open reliably.
                .background {
                    Color.clear.popover(isPresented: Binding(get: { newGroupFor == repo.path }, set: { if !$0 { newGroupFor = nil } }), arrowEdge: .trailing) {
                        GroupNameForm(title: "New group with \(repo.displayName)", action: "Create") { name in
                            groups.setGroup(name, ofRepo: repo.path)
                            newGroupFor = nil
                        }
                    }
                }
                .contextMenu {
                    Button(repo.isFavorite ? "Remove from favorites" : "Add to favorites") { repo.isFavorite.toggle() }
                    RepoColorMenu(repo: repo)
                    GroupMenu(current: groups.group(ofRepo: repo.path), set: { groups.setGroup($0, ofRepo: repo.path) }) { newGroupFor = repo.path }
                    Divider()
                    Button("Show in Finder") { repo.reveal() }
                    ForEach(Editor.installed.filter { $0.name != "Finder" }) { editor in
                        Button("Open in \(editor.name)") { editor.open(repo.path) }
                    }
                    // Read when the menu opens, so the sidebar doesn't need to observe it.
                    let agent = AgentStatus.shared
                    if agent.info.isInstalled {
                        Button("Open \(agent.info.name) in \(agent.terminalName)") { DevWorkspace.openAgentInTerminal(repo.path) }
                    }
                    Divider()
                    GitHubMenuItems(repo: repo) { publishing = repo.path }
                    Divider()
                    Button("Remove from Bridge") { store.remove(repo) }
                    Button("Move to Trash…") { Task { notice = await store.moveToTrash(repo) } }
                }
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// A green dot while the repository's web app runs in the background.
private struct RunningIndicator: View {
    @ObservedObject var server: DevServer

    var body: some View {
        if server.isActive {
            Circle().fill(.green).frame(width: 6, height: 6)
        }
    }
}

private struct SidebarRow: View {
    @ObservedObject var repo: Repository

    var body: some View {
        HStack(spacing: 8) {
            // A color only where one is set, like a Finder tag; a grey dot on every other row was noise.
            // The space stays, so names line up.
            Circle()
                .fill(repo.color?.color ?? .clear)
                .frame(width: 8, height: 8)
            if let framework = repo.framework {
                FrameworkLogo(framework: framework, size: 14)
            }
            Text(verbatim: repo.displayName).lineLimit(1).truncationMode(.middle)
            if let folder = repo.folderNameIfDifferent {
                Text(verbatim: folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            if repo.isFavorite {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            RunningIndicator(server: repo.server)
            if let status = repo.status {
                // The same marks as the menu bar panel's rows, so a bare number isn't left to guess at.
                // Counts roll as they change and count down after a commit or push (`RollingCount`).
                HStack(spacing: 6) {
                    RollingCount(value: status.files.count) { Text("\(Image(systemName: "pencil")) \($0)") }
                    RollingCount(value: status.behind) { Text(verbatim: "↓\($0)") }
                    RollingCount(value: status.ahead) { Text(verbatim: "↑\($0)") }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BranchPicker: View {
    @ObservedObject var repo: Repository
    let dismiss: () -> Void
    @State private var filter = ""
    @State private var newName = ""
    @State private var creating = false
    @FocusState private var nameFocused: Bool
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Return switches to the first branch the filter finds, so a branch is a few keys away.
                TextField("Filter branches", text: $filter)
                    .focused($filterFocused)
                    .panelField()
                    .onSubmit {
                        if !filter.isEmpty, let first = local.first ?? remote.first { switchTo(first) }
                    }
                Button("New branch") {
                    creating = true
                    newName = filter
                    nameFocused = true
                }
                .fieldRowButton()
            }
            .padding(10)

            if creating {
                HStack(spacing: 8) {
                    TextField("Name", text: $newName)
                        .focused($nameFocused)
                        .onSubmit(create)
                        .onExitCommand { creating = false }
                        .panelField()
                    Button("Cancel") { creating = false }
                        .fieldRowButton()
                    Button("Create", action: create)
                        .fieldRowButton(prominent: true)
                        .disabled(cleanName.isEmpty)
                }
                .padding([.horizontal, .bottom], 10)
                Text("Based on \(repo.currentBranch). Uncommitted changes come along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 10)
            }

            Divider()
            List {
                Section("Local") {
                    ForEach(local) { branch in
                        PickerRow(title: branch.name, detail: branch.date.relative, isCurrent: branch.name == repo.status?.branch) {
                            switchTo(branch)
                        }
                        .contextMenu {
                            // No dialog, so no "…": `git branch -d` refuses to delete work that isn't merged.
                            Button("Delete branch") { Task { await repo.deleteBranch(branch) } }
                                .disabled(branch.name == repo.status?.branch)
                        }
                    }
                }
                if !remote.isEmpty {
                    Section("Remote") {
                        ForEach(remote) { branch in
                            PickerRow(title: branch.name, detail: branch.date.relative, isCurrent: false) { switchTo(branch) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !filter.isEmpty && local.isEmpty && remote.isEmpty {
                    ContentUnavailableView {
                        Label("No branch matches \u{201C}\(filter)\u{201D}", systemImage: "arrow.triangle.branch")
                    } actions: {
                        Button("Create \(filter.replacingOccurrences(of: " ", with: "-"))") {
                            newName = filter
                            create()
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 440)
        .task {
            // A popover's window isn't key on its first frame, so focus set in onAppear is lost.
            try? await Task.sleep(for: .milliseconds(50))
            filterFocused = true
        }
    }

    private func matches(_ branch: Branch) -> Bool {
        filter.isEmpty || branch.name.localizedCaseInsensitiveContains(filter)
    }

    /// Current branch first, then the most recently used.
    private var local: [Branch] {
        repo.branches.filter { !$0.isRemote && matches($0) }.sorted {
            if ($0.name == repo.status?.branch) != ($1.name == repo.status?.branch) { return $0.name == repo.status?.branch }
            return $0.date > $1.date
        }
    }

    /// Only remote branches without a local one, like GitHub Desktop.
    private var remote: [Branch] {
        let localNames = Set(repo.branches.filter { !$0.isRemote }.map(\.name))
        return repo.branches
            .filter { $0.isRemote && !localNames.contains($0.nameWithoutRemote) && matches($0) }
            .sorted { $0.date > $1.date }
    }

    /// Branch names can't contain spaces; GitHub Desktop turns them into dashes too.
    private var cleanName: String {
        newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    private func create() {
        let name = cleanName
        guard !name.isEmpty else { return }
        dismiss()
        Task { await repo.createBranch(name) }
    }

    private func switchTo(_ branch: Branch) {
        dismiss()
        Task { await repo.switchTo(branch) }
    }
}

private struct PickerRow: View {
    let title: String
    let detail: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").opacity(isCurrent ? 1 : 0).font(.caption.weight(.bold))
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Repository

private struct RepoView: View {
    @ObservedObject var repo: Repository
    @ObservedObject private var state: ViewState
    let widths: MainLayout.Widths

    init(repo: Repository, widths: MainLayout.Widths) {
        self.repo = repo
        self.widths = widths
        state = ViewState.shared(for: repo.path)
    }

    private var tab: RepoTab { state.tab }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // A segmented picker doesn't truncate its labels, so in a narrow list it was cut off at
                // both ends; shorter labels and then icons take over instead.
                ViewThatFits(in: .horizontal) {
                    tabPicker(changes: repo.changeCount > 0 ? "Changes (\(repo.changeCount))" : "Changes", history: "History")
                    tabPicker(changes: "Changes", history: "History")
                    tabPicker(changes: repo.changeCount > 0 ? "\(repo.changeCount)" : "", history: nil)
                }
                .padding(10)
                .background {
                    // ⌘1 and ⌘2 as in GitHub Desktop; invisible buttons carry them, as the window has no menu.
                    Group {
                        Button("Changes") { state.tab = .changes }.keyboardShortcut("1", modifiers: .command)
                        Button("History") { state.tab = .history }.keyboardShortcut("2", modifiers: .command)
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
                Divider()
                // Both stay alive so switching tabs keeps each one's selection.
                ZStack {
                    ChangesView(repo: repo).opacity(tab == .changes ? 1 : 0).allowsHitTesting(tab == .changes)
                    HistoryView(repo: repo).opacity(tab == .history ? 1 : 0).allowsHitTesting(tab == .history)
                }
            }
            .frame(minWidth: widths.list, idealWidth: MainLayout.Widths.ideal(340, widths.list, widths.listMax), maxWidth: widths.listMax)
            .layoutPriority(0)

            Group {
                switch tab {
                case .changes: ChangesDetail(repo: repo)
                case .history: HistoryDetail(repo: repo)
                }
            }
            .frame(minWidth: widths.detail, maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.detailMinWidth, widths.detail)
            .layoutPriority(1)

            // A pane of this split view rather than an `.inspector`: the inspector sat in a split view of
            // its own around this one, which didn't shrink this one's panes for it, so with notes open the
            // content outgrew a narrow window and was cut off on both sides.
            // Shown only while it fits (`widths.notes`), even when switched on.
            if let notes = widths.notes {
                NotesView(repo: repo)
                    .frame(minWidth: notes, idealWidth: MainLayout.Widths.ideal(MainLayout.notes, notes, widths.notesMax),
                           maxWidth: widths.notesMax, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .environmentObject(state)
    }

    /// The Changes/History switch. Without a History title it's down to icons (and the change count).
    private func tabPicker(changes: String, history: String?) -> some View {
        Picker("", selection: $state.tab) {
            if let history {
                Text(verbatim: changes).tag(RepoTab.changes)
                Text(verbatim: history).tag(RepoTab.history)
            } else {
                Group {
                    if changes.isEmpty {
                        Image(systemName: "pencil.line")
                    } else {
                        Label(changes, systemImage: "pencil.line").labelStyle(.titleAndIcon)
                    }
                }
                .tag(RepoTab.changes)
                Image(systemName: "clock").tag(RepoTab.history)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

enum RepoTab: Hashable {
    case changes, history
}

/// Selections and the commit message draft, kept per repository while switching between them.
@MainActor
final class ViewState: ObservableObject {
    /// Here rather than in the view, so History can send the user to Changes (after Undo commit).
    @Published var tab = RepoTab.changes
    @Published var files: Set<String> = []
    @Published var commit: Commit?
    @Published var commitFile: String?
    @Published var summary = ""
    @Published var description = ""

    private static var byRepo: [String: ViewState] = [:]

    static func shared(for path: String) -> ViewState {
        if let existing = byRepo[path] { return existing }
        let state = ViewState()
        byRepo[path] = state
        return state
    }
}
