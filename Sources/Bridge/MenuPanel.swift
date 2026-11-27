import AppKit
import Shared
import SwiftUI

/// The menu bar panel: every repository at a glance, with quick commit, pull and push.
struct MenuPanel: View {
    @ObservedObject var store: RepoStore
    @ObservedObject private var groups = RepoGroups.shared
    /// Not observed: each row watches its own part (`ExpandedRepo.Row`), and the list only reacts to
    /// changes (`onReceive`), so opening a row doesn't go over the whole list.
    private var expansion: ExpandedRepo { .shared }
    @ObservedObject private var agent = AgentStatus.shared
    /// For each row's sessions, handed to it as values (see `RepoRow.isExpanded`).
    @ObservedObject private var claude = BackgroundClaude.shared
    /// What the last action came to, said in the panel's status line (`StatusLine`). Not observed:
    /// the list doesn't show it.
    private var notice: String? {
        get { PanelNotice.shared.message }
        nonmutating set { PanelNotice.shared.message = newValue }
    }
    private var noticeBinding: Binding<String?> {
        Binding(get: { PanelNotice.shared.message }, set: { PanelNotice.shared.message = $0 })
    }
    @State private var showNewProject = false
    @State private var showClone = false
    /// A form shown in place of the list, like a page of Control Center, rather than a popover over the
    /// panel. Kept while the panel closes (choosing a folder closes it), so nothing typed is lost.
    @State private var page: PanelPage?
    /// Where to scroll the list once it's there, as the panel opens.
    @State private var scrollRequest: ScrollRequest?
    private static let topID = "list-top"

    private enum ScrollRequest: Equatable {
        case top
        case row(String)
    }
    /// Groups opened in the last moment (as `RepoGroups.collapsed` keys), whose rows settle in.
    @State private var justOpened: Set<String> = []
    @State private var lastCollapsed = RepoGroups.shared.collapsed
    @State private var dropTargeted = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        // A page is pushed in as a navigation stack pushes one: the list moves out to the left as the
        // page comes in from the right, side by side, and back the other way. Moved only, never faded:
        // fields and glass buttons draw black while partly transparent.
        // The list stays built under a page (`PageStack`), so going back doesn't build it again.
        PageStack(showsPage: page != nil, showsBoth: pushes > 0) {
            listPage
                .offset(x: page == nil ? 0 : -Self.width)
            if let page {
                VStack(alignment: .leading, spacing: 0) {
                    PanelPageHeader(title: page.title, back: closePage)
                    PanelDivider()
                    switch page {
                    case .newProject: NewProjectForm(store: store, isPage: true, dismiss: closePage)
                    case .clone: CloneRepositoryForm(store: store, isPage: true, dismiss: closePage)
                    case .importRepos:
                        ImportRepositoriesForm(store: store, isPage: true) { result in
                            closePage()
                            if let result { notice = result }
                        }
                    case .cleanUp:
                        CleanUpRepositoriesForm(store: store, isPage: true) { failure in
                            closePage()
                            if let failure { notice = failure }
                        }
                    case .settings: SettingsPage(store: store, done: closePage)
                    case .setup: SettingsPage(store: store, isFirstRun: true, done: closePage)
                    case .startCommand(let path):
                        if let repo = store.repos.first(where: { $0.path == path }) {
                            StartCommandEditor(repo: repo, isPage: true, dismiss: closePage)
                        }
                    }
                }
                .transition(.move(edge: .trailing))
                .id(page)
                .layoutValue(key: PageStack.IsPage.self, value: true)
            }
        }
        // What's pushed out stays inside the panel's edges on its way.
        .clipped()
        .frame(width: Self.width)
        .onChange(of: page) { PanelState.shared.showsPage = page != nil }
        // Folders dragged in from Finder are added, as dropping a folder on an app that lists folders
        // does elsewhere; one that isn't a repository is searched for repositories inside it.
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                Color.clear
                    .panelBackground(Color.accentColor.opacity(0.12))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            store.refreshAll()
            agent.refresh()
            if agent.info.can(.background) { BackgroundClaude.shared.reload() }
            // Back within a minute: just as it was, the open row in view. Later: fresh, at the top.
            if PanelState.shared.isReturningLater {
                expansion.collapse()
                expansion.selected = nil
                scrollRequest = .top
            } else if let path = expansion.path {
                scrollRequest = .row(path)
            }
            // A new user is shown what Bridge works with first, once.
            if page == nil, store.repos.isEmpty, !UserDefaults.standard.bool(forKey: SettingsPage.shownKey) {
                UserDefaults.standard.set(true, forKey: SettingsPage.shownKey)
                openPage(.setup)
            }
            // The prompt is the panel's only text field, so typing goes straight into it.
            if page == nil && expansion.path == nil { promptFocused = true }
        }
        // Back from the Servers tab, which keeps this one built but hidden and takes the keyboard from
        // it: typing goes to the prompt again, as when the panel opens.
        .onReceive(PanelState.shared.$tab.dropFirst()) { tab in
            guard tab == .repos, page == nil, expansion.path == nil else { return }
            DispatchQueue.main.async { promptFocused = true }
        }
        .onReceive(PanelState.shared.$backRequests.dropFirst()) { _ in
            if page != nil { closePage() }
        }
        .onReceive(groups.$collapsed) { collapsed in
            let opened = lastCollapsed.subtracting(collapsed)
            lastCollapsed = collapsed
            guard !opened.isEmpty else { return }
            justOpened = opened
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { justOpened = [] }
        }
        // What the hourly search added (`RepoImport.addsAutomatically`), said once in the notice line.
        .onReceive(RepoImport.shared.$addedAutomatically) { names in
            guard !names.isEmpty else { return }
            RepoImport.shared.addedAutomatically = []
            let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            notice = "Added \(list) from your folders."
        }
        .onReceive(PanelState.shared.$requestedPage) { requested in
            guard let requested else { return }
            PanelState.shared.requestedPage = nil
            openPage(requested)
        }
        // A row folded away (Esc in its commit field, or its top line clicked) hands the keyboard back
        // to the prompt, where the arrow keys and Return work.
        // Received rather than observed (see `ExpandedRepo.Row`); the publisher sends the new value.
        .onReceive(expansion.$path.dropFirst().removeDuplicates()) { path in
            if path == nil { promptFocused = true }
        }
    }

    /// The list and, while one is open, a page in its place, sized to whichever shows. Like `TabStack`:
    /// the list stays built and is placed outside the window meanwhile, offered the same size, so going
    /// back only moves it. Building the list again (every row in view) on the way back held the main
    /// thread up to 700 ms with a long list.
    /// While a push runs, both are placed in the panel (`showsBoth`), each moved by its own offset or
    /// transition, and the panel takes the height of the one arriving at once.
    private struct PageStack: Layout {
        let showsPage: Bool
        let showsBoth: Bool

        struct IsPage: LayoutValueKey {
            static let defaultValue = false
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first { $0[IsPage.self] == showsPage }?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for subview in subviews {
                let isShown = showsBoth || subview[IsPage.self] == showsPage
                // Well past the panel's right edge, where nothing of it is drawn or clicked.
                subview.place(at: isShown ? bounds.origin : CGPoint(x: bounds.minX + 4000, y: bounds.minY), proposal: proposal)
            }
        }
    }

    private static let width: CGFloat = 460
    /// Pushes running, so both the list and the page are placed while they move.
    @State private var pushes = 0

    private func openPage(_ page: PanelPage) {
        push { self.page = page }
    }

    /// Back to the list. A project just created or cloned shows at its top as Setting up / Cloning.
    private func closePage() {
        push { page = nil }
        promptFocused = true
    }

    /// Brings the one moving in into the panel first, unanimated, so it isn't seen gliding over from
    /// where it waits off to the side, then pushes with the system's own spring (`.snappy`). At once
    /// with Reduce Motion, or while the panel is closed.
    private func push(_ change: @escaping () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, NSApp.keyWindow != nil else {
            change()
            return
        }
        pushes += 1
        DispatchQueue.main.async {
            withAnimation(PanelMotion.page, change, completion: { pushes -= 1 })
        }
    }

    private var listPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One row for the tab and its list, one for Claude. The list's buttons sit in the same
            // places as in the Servers tab, so switching tabs only changes the content.
            HStack(spacing: 10) {
                PanelTabs()
                Spacer()
                HStack(spacing: 2) {
                    // Fetch all is in the settings menu (and ⌘R); while it runs, this says so.
                    if store.isFetchingAll {
                        ProgressView().controlSize(.small).frame(width: 24, height: 22)
                    }
                    // Before settings, so settings lines up with the Servers tab's, which has no +.
                    AddRepositoryMenu(store: store, notice: noticeBinding, showNewProject: $showNewProject, showClone: $showClone,
                                      openPage: openPage)
                    SettingsMenu(store: store) { openPage(.settings) }
                        .padding(.leading, 4)
                }
            }
            .padding(12)
            .background {
                // The shortcuts a Mac user tries first in a window like this. The panel has no menu bar
                // of its own, so invisible buttons carry them.
                TabShortcuts(tab: .repos) {
                    Button("Fetch all") { Task { await store.fetchAll(quietly: false) } }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("New project") { openPage(.newProject) }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("Add repository") { Task { notice = await store.addWithPanel() } }
                        .keyboardShortcut("o", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }

            if !store.repos.isEmpty {
                ClaudeComposer(
                    store: store,
                    isFocused: $promptFocused,
                    moveSelection: { expansion.moveSelection(by: $0, in: shownRepos.map(\.path)) },
                    submitSelection: submitSelection,
                    escape: escape
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            PanelDivider()

            // What adding, finding or removing repositories did, and a problem with the agent's setup,
            // are said in the panel's status line (`StatusLine`) rather than in lines of their own here.
            ForEach(store.settingUp, id: \.self) { path in
                SettingUpRow(path: path) { store.stopWaiting(for: path) }
                PanelDivider()
            }
            ForEach(store.cloning, id: \.self) { path in
                SettingUpRow(path: path, verb: "Cloning")
                PanelDivider()
            }
            ImportProgressRow()

            if store.repos.isEmpty {
                // Four regular buttons in one line were wider than the panel; the usual first step leads.
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No repositories yet").font(.headline)
                    Text("You can also drop folders here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Finding what's already on this Mac and on GitHub first: someone new to Bridge
                    // nearly always has repositories already.
                    HStack {
                        Button("Find repositories…") { openPage(.importRepos) }
                            .prominentButton()
                        Button("New project…") { openPage(.newProject) }
                    }
                    HStack {
                        Button("Clone…") { openPage(.clone) }
                        Button("Add repository…") { Task { notice = await store.addWithPanel() } }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                if store.visibleRepos.isEmpty {
                    // With a way back, rather than leaving the filters to be found in the sort menu.
                    VStack(spacing: 8) {
                        Text("No repositories match the filters")
                            .foregroundStyle(.secondary)
                        Button("Show all") {
                            store.favoritesOnly = false
                            store.hideUncolored = false
                            store.hideInactive = false
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                MenuPanelList(maxHeight: 560, onOverflow: { ExpandedRepo.shared.overflow = $0 }) {
                    // Inside the scroll view, so a row picked with the arrow keys can be scrolled to.
                    ScrollViewReader { proxy in
                    // A faint inset line between rows and before each group, so a long list is easy to scan.
                    // Lazy, so only the rows in view are built: with nearly a hundred repositories, every
                    // row built made opening the panel take over a second, nearly all of it SwiftUI going
                    // over each row's buttons and menus when the prompt field took the keyboard. Sized by
                    // `MenuPanelList` all the same (it asks for the ideal height, which a lazy stack gives
                    // from the rows it has built). Each row is a child of its own, not wrapped in a stack
                    // per group, or a group would be built whole.
                    LazyVStack(spacing: 0) {
                        // Something to scroll back to the top by.
                        Color.clear.frame(height: 0).id(Self.topID)
                        let sections = groups.sections(store.visibleRepos) { groups.group(ofRepo: $0.path) }
                        ForEach(sections, id: \.id) { section in
                            if !section.isOnly {
                                if section.id != sections.first?.id {
                                    PanelDivider(subtle: true).padding(.top, 4)
                                }
                                RepoGroupHeader(section: section, store: store)
                            }
                            if section.isOnly || !groups.isCollapsed(section.name, in: .repos) {
                                ForEach(section.items) { repo in
                                    VStack(spacing: 0) {
                                        if repo.id != section.items.first?.id {
                                            PanelDivider(subtle: true)
                                        }
                                        RepoRow(repo: repo, store: store, options: rowOptions,
                                                sessions: claude.sessions(in: repo.path),
                                                isStartingSession: claude.isStarting(in: repo.path))
                                            // Press and hold to drag it into another group, or to another
                                            // place among its color (see `RepoStore.reorderBlocker`).
                                            .repoDragRow(repo, group: section.name, groupsShown: !section.isOnly, store: store)
                                    }
                                    // A group opened by a click settles its rows into place; rows
                                    // scrolled into view just show.
                                    .revealsGently(when: justOpened.contains("\(PanelTab.repos.rawValue):\(section.name ?? "")"))
                                    .id(repo.path)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .onReceive(expansion.$selected.removeDuplicates()) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                    // Where the panel opens (see `onAppear`), once the list is there to scroll.
                    .onChange(of: scrollRequest) { _, request in
                        guard let request else { return }
                        DispatchQueue.main.async {
                            switch request {
                            case .top: proxy.scrollTo(Self.topID, anchor: .top)
                            case let .row(path): proxy.scrollTo(path, anchor: .center)
                            }
                            scrollRequest = nil
                        }
                    }
                    }
                }
            }
        }
    }

    /// The rows as shown, top to bottom, skipping folded groups: the order the arrow keys move in.
    private var shownRepos: [Repository] {
        groups.sections(store.visibleRepos) { groups.group(ofRepo: $0.path) }
            .filter { $0.isOnly || !groups.isCollapsed($0.name, in: .repos) }
            .flatMap(\.items)
    }

    /// Return in the prompt with a row picked: runs the prompt there in the agent, or without a prompt
    /// opens the row, the way Return opens the selected item in a list.
    private func submitSelection() -> Bool {
        guard let path = expansion.selected, let repo = shownRepos.first(where: { $0.path == path }) else { return false }
        if let prompt = store.pendingClaudePrompt {
            DevWorkspace.openAgentInTerminal(repo.path, prompt: prompt)
        } else {
            expansion.toggle(repo.path)
        }
        return true
    }

    /// Esc backs out one step at a time, and closes the panel when there's nothing left to back out of.
    private func escape() {
        if !store.claudePrompt.isEmpty {
            store.claudePrompt = ""
        } else if expansion.selected != nil {
            expansion.selected = nil
        } else if expansion.path != nil {
            expansion.collapse()
        } else {
            MenuBarPanel.toggle()
        }
    }

    /// A dropped folder that is (in) a repository adds that repository; any other folder is searched
    /// for repositories, like Find in folder. A dropped file adds the repository it's in.
    private func addDropped(_ urls: [URL]) {
        Task {
            var misses: [String] = []
            for url in urls where url.isFileURL {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let folder = isFolder ? url.path : url.deletingLastPathComponent().path
                if await store.add(folder) == nil { continue }
                if isFolder, await store.scan(folder) > 0 { continue }
                misses.append(url.lastPathComponent)
            }
            notice = misses.isEmpty ? nil : "No git repository in \(misses.joined(separator: ", "))"
        }
    }

    private var rowOptions: RepoRowOptions {
        RepoRowOptions(
            showSkills: store.showSkills,
            hasPrompt: store.pendingClaudePrompt != nil && agent.info.can(.initialPrompt),
            withChrome: store.agentWithBrowser && agent.info.can(.browser),
            agent: agent.info,
            terminalName: agent.agentPlaceName
        )
    }
}

/// What a repository row needs from the store's settings, handed down as plain values. A row that
/// observed the store itself was redrawn on every change to any repository, since the store forwards
/// them all (for the list's sorting and the menu bar badge): one `git status` redrew every row.
/// As values, SwiftUI only redraws the rows whose repository or options actually changed.
struct RepoRowOptions: Equatable {
    var showSkills: Bool
    /// Only whether there is a prompt, not the prompt, so typing it doesn't redraw every row.
    var hasPrompt: Bool
    /// The browser switch is on and the agent can use it.
    var withChrome: Bool
    /// The coding agent in use; its buttons show only for what it can do (`AgentInfo.can`).
    var agent: AgentInfo
    var terminalName: String

    /// Pinned skills show when the setting is on and the agent has skills.
    var showsSkills: Bool { showSkills && agent.can(.skills) }
}

/// A group's header in the Repos tab. Folded, it still shows how many repositories have local work and
/// how many apps run, and its menu starts or stops every app in the group, like a client's front and back end.
private struct RepoGroupHeader: View {
    let section: GroupSection<Repository>
    @ObservedObject var store: RepoStore

    var body: some View {
        let changed = section.items.filter(\.hasLocalWork).count
        let running = section.items.filter(\.server.isActive)
        // Apps still to be built are left out: their build is a step of its own, from their row.
        let startable = section.items.filter { !$0.isMissing && !$0.server.isActive && $0.startCommand != nil && !$0.needsBuild }
        GroupHeader(section: section.name, title: section.title, count: section.items.count, tab: .repos) {
            HStack(spacing: 8) {
                RollingCount(value: changed) { Text("\(Image(systemName: "pencil")) \($0)") }
                if !running.isEmpty {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        RollingCount(value: running.count) { Text(verbatim: String($0)) }
                    }
                }
            }
        } menu: {
            if !startable.isEmpty {
                Button(startable.count == 1 ? "Start 1 app" : "Start \(startable.count) apps") {
                    for repo in startable {
                        guard let command = repo.startCommand else { continue }
                        if repo.startsInTerminal { DevWorkspace.runInTerminal(command, in: repo.path) } else { repo.server.start(command) }
                    }
                }
            }
            if !running.isEmpty {
                Button(running.count == 1 ? "Stop 1 app" : "Stop \(running.count) apps") {
                    for repo in running {
                        if repo.server.external != nil { repo.server.stopExternal() } else { repo.server.stop() }
                    }
                }
            }
        }
    }
}

/// Which repository row is open in the panel, showing its changes, commit field, skills and sessions.
/// One at a time, so the list stays one line per repository apart from the one being worked on.
@MainActor
final class ExpandedRepo: ObservableObject {
    static let shared = ExpandedRepo()
    @Published private(set) var path: String? {
        didSet {
            guard path != oldValue else { return }
            // Opening and folding grow and shrink the row, the rows below sliding along, as an outline
            // in Finder does, but only while the list reaches well past the panel's height: the panel
            // then stays the same size and only the scroll view's content changes. With a short list
            // the panel itself would grow and shrink, and `MenuBarExtra`'s window can't be animated
            // (see CLAUDE.md), so there the row opens at once as before.
            withAnimation(animatesHeight ? PanelMotion.disclose : nil) {
                oldValue.map { row($0).isExpanded = false }
                path.map { row($0).isExpanded = true }
            }
        }
    }

    /// How far the list reaches past the panel's height (`MenuPanelList`'s `onOverflow`). Not published:
    /// only read at the moment a row opens or folds.
    var overflow: CGFloat = 0
    var animatesHeight: Bool {
        overflow > Self.roomToAnimate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// More than an open row's details and commit field together, so a row folding can't take the
    /// list below the panel's height mid-animation.
    private static let roomToAnimate: CGFloat = 400

    /// The row picked with ↑/↓ from the prompt field, so the list can be used from the keyboard the way
    /// a list in a Spotlight-like panel is: arrows to pick, Return to act, Esc to back out.
    @Published var selected: String? {
        didSet {
            guard selected != oldValue else { return }
            oldValue.map { row($0).isSelected = false }
            selected.map { row($0).isSelected = true }
        }
    }

    /// One row's part of this, for the row to observe. Only the rows that open, fold or are picked
    /// then redraw: with the list (or every row) observing this whole object, a click on one row had
    /// SwiftUI go over the entire list, 60–90 ms.
    final class Row: ObservableObject {
        @Published fileprivate(set) var isExpanded = false
        @Published fileprivate(set) var isSelected = false
    }
    private var rows: [String: Row] = [:]

    func row(_ path: String) -> Row {
        if let row = rows[path] { return row }
        let row = Row()
        row.isExpanded = self.path == path
        row.isSelected = selected == path
        rows[path] = row
        return row
    }

    func toggle(_ path: String) {
        self.path = self.path == path ? nil : path
    }

    func collapse() {
        path = nil
    }

    /// Moves the keyboard selection through `order` (the rows as shown), stopping at the ends.
    func moveSelection(by step: Int, in order: [String]) {
        guard !order.isEmpty else { return }
        guard let current = selected, let index = order.firstIndex(of: current) else {
            selected = step > 0 ? order.first : order.last
            return
        }
        selected = order[min(max(index + step, 0), order.count - 1)]
    }
}

/// A repository in the panel, built to be scanned: one line that shows only what is particular to it
/// (changes, commits to pull or push, a running app, a Claude session), with the buttons in place of
/// that state under the pointer, and the rest behind a click. Repositories with nothing going on are
/// dimmed, so the ones being worked on stand out.
private struct RepoRow: View {
    @ObservedObject var repo: Repository
    /// Observed for the running app's dot and port, and to tell whether the repository is quiet.
    @ObservedObject var server: DevServer
    /// Not observed (see `RepoRowOptions`); only read in actions, when they run.
    let store: RepoStore
    let options: RepoRowOptions
    /// Whether this row is open or picked: its own part of `ExpandedRepo`, so opening a row redraws it
    /// and the one that folds, not the list. The background sessions are handed down as values, and
    /// only the commit button watches ⌥ (`CommitLabel`): every row observing those redrew them all
    /// whenever any session changed or a modifier key was pressed.
    @ObservedObject var rowState: ExpandedRepo.Row
    private var isExpanded: Bool { rowState.isExpanded }
    private var isSelected: Bool { rowState.isSelected }
    /// This repository's background sessions, and whether one is starting.
    let sessions: [ClaudeSession]
    let isStartingSession: Bool
    private var groups: RepoGroups { .shared }
    private var expansion: ExpandedRepo { .shared }
    private var claude: BackgroundClaude { .shared }
    @State private var showNewGroup = false
    /// Counts copies made from the row, for the "Copied" confirmation on it.
    @State private var copied = 0
    @State private var hovering = false
    /// The pointer is at the row's leading edge, where the star slides in (see `LeadingStar`).
    @State private var atLeadingEdge = false
    /// Copies of `repo.commitDraft` and `repo.commitSuggestion`, kept in step with them.
    @State private var message = ""
    @State private var suggestion: (summary: String, description: String)?
    private var isSuggesting: Bool { repo.isWritingCommitMessage }
    @State private var showNotes = false
    @State private var showSkillPicker = false
    @State private var showBackgroundClaude = false
    @State private var showPublish = false
    @FocusState private var commitFocused: Bool

    init(repo: Repository, store: RepoStore, options: RepoRowOptions, sessions: [ClaudeSession], isStartingSession: Bool) {
        self.repo = repo
        server = repo.server
        self.store = store
        self.options = options
        rowState = ExpandedRepo.shared.row(repo.path)
        self.sessions = sessions
        self.isStartingSession = isStartingSession
    }

    /// A click opens or folds the row. A double-click is two clicks, so the second puts the row back as
    /// it was, and opens the repository in the Bridge window, as a double-click opens an item elsewhere.
    private func rowClicked() {
        expansion.toggle(repo.path)
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            MainWindow.shared.show(store, selecting: repo)
        }
    }

    /// Whether one of the row's popovers is open: the row then stays as it is under the pointer, buttons
    /// and highlight, so nothing moves while the popover points at it.
    private var hasPopover: Bool {
        showNotes || showSkillPicker || showBackgroundClaude || showPublish || showNewGroup
    }

    /// The start command editor, as a page of the panel (`PanelPage.startCommand`).
    private func editStart() {
        PanelState.shared.open(.startCommand(path: repo.path))
    }

    /// Hovered, open, or with a popover open: shows the buttons, the star and the highlight.
    private var isActive: Bool { hovering || isExpanded || hasPopover }

    /// Nothing going on: no changes or commits to move, no app running, no Claude session, nothing wrong.
    private var isQuiet: Bool {
        !isActive && !repo.isMissing && repo.error == nil && !repo.needsAgentLogin && repo.activity == nil
            && !repo.hasLocalWork && (repo.status?.behind ?? 0) == 0 && !server.isActive && sessions.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                title
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                // The state while resting, the buttons under the pointer, while open or while one of
                // its popovers is. A missing folder always shows its Locate and Remove. Both are always
                // laid out, one of them invisible, so the right side is as wide either way: the name
                // doesn't move when they swap, and a popover from a button keeps its anchor.
                let showsActions = isActive || repo.isMissing
                ZStack(alignment: .trailing) {
                    badges.fadesIn(!showsActions)
                    actions.fadesIn(showsActions)
                }
            }
            // One height in both tabs, so a repository and a server row are equally tall.
            .frame(height: PanelRowMetrics.lineHeight)
            // Anchored to the whole top line, which is as wide whatever its right side shows, so a
            // popover doesn't shift when the buttons take the badges' place. Here rather than on the
            // strip below, so they can open from the context menu before that strip exists.
            .panelPopover(isPresented: $showNotes, arrowEdge: .bottom) {
                    NotesView(repo: repo).frame(width: 340, height: 280)
                }
                .panelPopover(isPresented: $showSkillPicker, arrowEdge: .bottom) {
                    SkillPicker(repo: repo) { showSkillPicker = false }
                }
                .panelPopover(isPresented: $showBackgroundClaude, arrowEdge: .bottom) {
                    BackgroundClaudeForm(repo: repo, prompt: store.pendingClaudePrompt) { showBackgroundClaude = false }
                }
                .background {
                    Color.clear.panelPopover(isPresented: $showPublish, arrowEdge: .bottom) {
                        PublishRepositoryForm(repo: repo) { showPublish = false }
                    }
                }
                .overlay {
                    Color.clear.allowsHitTesting(false).panelPopover(isPresented: $showNewGroup, arrowEdge: .bottom) {
                        GroupNameForm(title: "New group with \(repo.displayName)", action: "Create") { name in
                            groups.setGroup(name, ofRepo: repo.path)
                            showNewGroup = false
                        }
                    }
                }
            // The whole top line, gaps included, folds an open row away again. Buttons in it still take their own clicks.
            .contentShape(Rectangle())
            .onTapGesture(perform: rowClicked)

            if isExpanded {
                // Uncovered by the growing row when it animates; faded in when it opens at once instead.
                details.revealsGently(when: !ExpandedRepo.shared.animatesHeight).unrollsWithRow()
            }

            // Shown open or not: a failed command needs reading.
            if let error = repo.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(verbatim: error)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Dismiss") { repo.error = nil }
                }
                .font(.caption)
            }
            // Not when the panel's top already asks to log in, which fixes this row too.
            if repo.needsAgentLogin && AgentStatus.shared.shownProblem != .loggedOut {
                AgentLoginNotice(message: "\(AgentStatus.shared.info.name) needs you to log in again.",
                                 dismiss: { repo.needsAgentLogin = false },
                                 done: { repo.needsAgentLogin = false; repo.writeCommitMessage() })
            }

            // Quick commit, in the open row when something has changed. Return commits and pushes, ⌥ only commits.
            if isExpanded && showsCommit {
                HStack(spacing: 6) {
                    TextField(commitPlaceholder, text: $message)
                        .focused($commitFocused)
                        .onSubmit { commit(andPush: pushes) }
                        // Esc folds the row away again, as it closes other things being typed into.
                        .onExitCommand { expansion.toggle(repo.path) }
                        .claudeWrites(isEmpty: message.isEmpty, isWriting: isSuggesting, action: suggest)
                        .panelField()
                        // What was written before the row folded away, or was rebuilt, comes back.
                        .onAppear {
                            if message.isEmpty {
                                message = repo.commitDraft
                                suggestion = repo.commitSuggestion
                            }
                        }
                        .onChange(of: message) { _, new in repo.commitDraft = new }
                    Button { commit(andPush: pushes) } label: { commitLabel }
                        .fieldRowButton(prominent: true)
                        .disabled(!hasMessage)
                }
                .disabled(repo.activity != nil)
                .background {
                    // ⌘Z in the emptied field brings back the message Claude wrote. The field's own undo
                    // doesn't know about text set from code, so clearing Claude's message lost it for good.
                    // Only there while that's what ⌘Z would do, so the field's own undo works otherwise.
                    if commitFocused, message.isEmpty, !isSuggesting, let summary = repo.commitSuggestion?.summary {
                        Button("Restore \(options.agent.name)'s message") {
                            suggestion = repo.commitSuggestion
                            Task { await PanelMotion.typeOut(summary, current: { message }, set: { message = $0 }) }
                        }
                        .keyboardShortcut("z", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    }
                }
                // Shown at once rather than with `revealsGently`: the field and the prominent button are
                // drawn with the system's materials, which went black while their layer faded in and only
                // took their real colors once it was fully opaque. (Inside revealed content they now wait
                // until it's opaque, `hiddenWhileFadingIn`, but here they'd only pop in late.)
                // When the row grows open (`ExpandedRepo`), it unrolls with it, opaque all the way.
                .unrollsWithRow()
            }
        }
        // The same margin as a server row's. The color stripe is in the title (see `RepoColorStripe`).
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        // What opening shows unrolls under the row's edge as it grows, rather than over the rows below.
        .clipped()
        // On the row rather than the field, so it's heard while the row is folded too.
        .onChange(of: repo.isWritingCommitMessage) { _, writing in
            if !writing { claudeFinished() }
        }
        // Inset and rounded like a sidebar's highlight; an open row keeps it. The row picked with the
        // arrow keys is tinted with the accent color, like a list's selection.
        .panelHighlight(isActive || isSelected, isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quinary))
        // The whole row, gaps included, takes the hover: the highlight is clear while it isn't hovered,
        // and clear areas don't, so the hover came and went depending on what was under the pointer.
        .contentShape(Rectangle())
        // A closed row opens from a click anywhere on it, margins included. An open one only from its
        // top line (above), so clicks in its commit field and skills aren't taken for folding it.
        .gesture(TapGesture().onEnded(rowClicked), including: isExpanded ? .subviews : .all)
        // A context menu has nothing to point at once it's closed, so Copy path confirms on the row.
        .copiedConfirmation(copied, alignment: isExpanded ? .topTrailing : .trailing)
        .padding(.horizontal, 6)
        .onHover { inside in
            hovering = inside
            // The pointer takes over from the arrow keys, so two rows don't both look picked.
            if inside, let selected = expansion.selected, selected != repo.path { expansion.selected = nil }
        }
        .tracksLeadingEdge($atLeadingEdge)
        // Opening a row with changes is mostly to commit them, so the message can be typed right away.
        .onChange(of: isExpanded) { _, open in
            if open && repo.hasChanges { DispatchQueue.main.async { commitFocused = true } }
        }
        .contextMenu {
            // Opening and looking first, then what's done to it, how it's organized, its settings, and
            // the destructive ones last. The editors are one submenu: a line each made the menu long.
            Button("Open in the Bridge window") { MainWindow.shared.show(store, selecting: repo) }
            Menu("Open in") {
                ForEach(Editor.installed) { editor in
                    Button(editor.name) { editor.open(repo.path) }
                }
            }
            GitHubMenuItems(repo: repo) { showPublish = true }
            if !repo.isMissing {
                Divider()
                Menu("Switch branch") { BranchMenuItems(repo: repo, store: store) }
                if options.agent.can(.background) {
                    Button("Run \(options.agent.name) in background…") { showBackgroundClaude = true }
                }
            }
            Divider()
            // A checkmark, as for other on/off items, rather than a title that flips between two wordings.
            Toggle("Favorite", isOn: $repo.isFavorite)
            RepoColorMenu(repo: repo)
            GroupMenu(current: groups.group(ofRepo: repo.path), set: { groups.setGroup($0, ofRepo: repo.path) }) { showNewGroup = true }
            Divider()
            Button("Notes…") { showNotes = true }
            if options.agent.can(.skills) {
                Button("\(options.agent.name) skills…") { showSkillPicker = true }
            }
            Button("Start command…", action: editStart)
            Divider()
            Button("Copy path") {
                Pasteboard.copy(repo.path)
                copied += 1
            }
            Divider()
            Button("Remove from Bridge") { store.remove(repo) }
            Button("Move to Trash…") {
                // Shown in the row like a failed git command; the row is gone when it worked.
                Task { if let error = await store.moveToTrash(repo) { repo.error = error } }
            }
        }
    }

    private var title: some View {
        HStack(spacing: 0) {
            LeadingStar(isFavorite: repo.isFavorite, isShown: atLeadingEdge) { repo.isFavorite.toggle() }
            RepoColorStripe(repo: repo, isReaching: atLeadingEdge)
            HStack(spacing: 6) {
            if let framework = repo.framework {
                FrameworkLogo(framework: framework, size: 14)
                    .opacity(isQuiet ? 0.5 : 1)
            }
            Text(verbatim: repo.displayName)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(isQuiet ? .secondary : .primary)
                .lineLimit(1)
            if repo.isMissing {
                Text("Folder not found").font(.caption).foregroundStyle(.red)
            } else if !["main", "master"].contains(repo.currentBranch) {
                // Only worth a chip when it isn't the usual default branch. A branch name looks like
                // something to click to change branch, so it is.
                BranchSwitcher(repo: repo, store: store)
            }
            }
        }
    }

    /// What's particular to this repository, in grey, with color only where it needs you: a Claude
    /// session that needs you, a running app, something that failed.
    private var badges: some View {
        HStack(spacing: 10) {
            if repo.activity != nil {
                ProgressView().controlSize(.mini)
            }
            sessionBadge
            // Always there (empty while zero), so a count that drops to zero can roll down and fade.
            // A status not read yet counts as nothing to show.
            let status = repo.status
            RollingCount(value: status?.files.count ?? 0) { Text("\(Image(systemName: "pencil")) \($0)") }
            RollingCount(value: status?.behind ?? 0) { Text(verbatim: "↓\($0)") }
            RollingCount(value: status?.ahead ?? 0) { Text(verbatim: "↑\($0)") }
            ServerBadge(server: server)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .fixedSize()
    }

    /// One mark for the repository's background Claude sessions, the one that needs you most.
    @ViewBuilder private var sessionBadge: some View {
        if isStartingSession {
            ProgressView().controlSize(.mini)
        } else if sessions.contains(where: { $0.state == .blocked }) {
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
        } else if sessions.contains(where: { $0.state == .failed }) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else if sessions.contains(where: { $0.state == .working }) {
            ProgressView().controlSize(.mini)
        } else if sessions.contains(where: { $0.state == .done }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    /// Whether the open row has the commit field, which then carries the status (see `commitPlaceholder`).
    private var showsCommit: Bool { repo.hasChanges && repo.operation == nil }

    /// The open row: its status in words (unless the commit field has it), pinned skills and notes,
    /// and Claude sessions.
    @ViewBuilder private var details: some View {
        // With nothing going on the line says so, with the branch and when it was fetched: a row that
        // opened to nothing at all looked broken.
        let line = detailLine.isEmpty ? quietLine : detailLine
        if !showsCommit {
            Text(verbatim: line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if (options.showsSkills && !repo.skills.isEmpty) || !repo.notes.isEmpty {
            ShortcutStrip(repo: repo, options: options, showNotes: $showNotes, showSkillPicker: $showSkillPicker)
        }
        if !sessions.isEmpty {
            ClaudeSessionList(sessions: sessions)
        }
    }

    /// What's being committed, as the commit field's placeholder: "16 changes · +357 −1".
    /// Short, as "Write with Claude" shares the empty field with it. Empty while Claude writes, which the
    /// field then says itself. The status line isn't shown beside the field.
    private var commitPlaceholder: String {
        if isSuggesting { return "" }
        let files = repo.status?.files.count ?? 0
        var text = files == 1 ? "1 change" : "\(files) changes"
        if let stats = repo.lineStats, stats.added + stats.removed > 0 {
            text += " · +\(stats.added) −\(stats.removed)"
        }
        return text
    }

    /// The summary, with the line counts and the folder's name, which only the open row has room for.
    private var detailLine: String {
        var parts = [summary]
        if let stats = repo.lineStats, stats.added + stats.removed > 0 { parts.append("+\(stats.added) −\(stats.removed) lines") }
        if let folder = repo.folderNameIfDifferent { parts.append("folder \(folder)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Empty when nothing is going on: "Up to date" said nothing the dimmed row didn't.
    private var summary: String {
        if repo.isMissing { return "Folder not found" }
        if let activity = repo.activity { return activity.rawValue }
        guard let status = repo.status else { return "Loading…" }
        var parts: [String] = []
        if let operation = repo.operation { parts.append("\(operation.rawValue) in progress") }
        if !status.files.isEmpty { parts.append(status.files.count == 1 ? "1 change" : "\(status.files.count) changes") }
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        if repo.canPublish { parts.append("Not published") }
        if let pr = repo.pullRequest {
            let label = "\(repo.host?.changeRequestShort ?? "PR") \(repo.host?.numberPrefix ?? "#")\(pr.number)"
            parts.append(pr.isDraft ? "Draft \(label)" : label)
        }
        return parts.joined(separator: " · ")
    }

    /// The open row's line when nothing is going on: "Up to date on main · fetched 5 min ago".
    private var quietLine: String {
        var text = repo.remote == nil ? "Local only, on \(repo.currentBranch)" : "Up to date on \(repo.currentBranch)"
        if let fetched = repo.lastFetched { text += " · fetched \(fetched.relative)" }
        return text
    }

    private var actions: some View {
        // Room between Pull and Push so the two bezels don't run together; icon buttons have their own margin.
        HStack(spacing: 4) {
            if repo.isMissing {
                Button("Locate…") { Task { repo.error = await store.locateWithPanel(repo) } }
                Button("Remove from Bridge") { store.remove(repo) }
            } else if repo.activity != nil {
                ProgressView().controlSize(.small).frame(width: 24, height: 22)
            } else if let status = repo.status {
                if status.behind > 0 {
                    Button("Pull") { Task { await repo.pull() } }
                }
                // Where Push goes once it's published, so a local-only repository's next step is in the same spot.
                if repo.remote == nil {
                    Button("Publish") { showPublish = true }
                        .prominentButton()
                }
                if status.ahead > 0 || repo.canPublish {
                    Button(repo.canPublish ? "Publish" : "Push") { Task { await repo.push() } }
                        .prominentButton()
                }
            }
            if !repo.isMissing {
                // No star here: it sits by the name (see `title`). Its editor is a page of the panel.
                ServerControls(repo: repo, editStart: editStart)
                if isStartingSession {
                    // The first `claude --bg` can take a while to start Claude Code's service; without this nothing seems to happen.
                    ProgressView().controlSize(.small).frame(width: 24, height: 22)
                } else if options.agent.isInstalled {
                    agentButton
                }
            }
            if isExpanded {
                IconButton(systemName: "macwindow", help: "Open in the Bridge window") {
                    MainWindow.shared.show(store, selecting: repo)
                }
            }
            // That the row opens, and to what, wasn't findable: a disclosure chevron says so, with the
            // buttons rather than on every resting row, where it would only be more to scan past.
            Button { expansion.toggle(repo.path) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .disclosureRotation(isExpanded)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(.panel)
            .panelTooltip(isExpanded ? "Fold away" : "Show changes, commit, skills and Claude sessions")
            .accessibilityLabel(isExpanded ? "Fold" : "Unfold")
        }
        // Small buttons in a line as tall as the resting badges, so a row keeps its height when the
        // buttons replace them under the pointer. A taller row moved out from under the pointer,
        // which ended the hover and swapped the badges back: the row flickered.
        .controlSize(.small)
        .frame(height: 22)
        .fixedSize()
    }

    private var hasMessage: Bool { !message.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Commit & Push unless ⌥ is held or there's nowhere to push. Read when committing; the button's
    /// label follows ⌥ by itself (`CommitLabel`), so the row isn't redrawn on every modifier key.
    private var pushes: Bool { repo.remote != nil && !ModifierKeys.shared.option }

    private var commitLabel: some View {
        CommitLabel(canPush: repo.remote != nil)
    }

    private func suggest() {
        repo.writeCommitMessage()
    }

    /// Opens the agent in a terminal in the repository, with the prompt typed at the top. ⌥-click (or
    /// its right-click menu) runs it in the background instead, for agents that can.
    private var agentButton: some View {
        let agent = options.agent
        let background = agent.can(.background)
        var help = agentHelp(agent: agent.name, terminal: options.terminalName, prompt: options.hasPrompt ? "the prompt above" : nil, chrome: options.withChrome)
        if background { help += "\n⌥-click to run it in the background instead" }
        return IconButton(image: Agent.current.logo, help: help, hoverTint: Agent.current.tint, isHighlighted: options.hasPrompt,
                          badge: options.withChrome ? Logo.chrome : nil) {
            if ModifierKeys.shared.option && background {
                // With a prompt typed at the top it starts right away; without one there's nothing to run yet.
                if let prompt = store.pendingClaudePrompt {
                    // Only a failure goes to the row, so a start doesn't clear a git error still showing there.
                    Task { if let error = await claude.start(prompt, in: repo.path) { repo.error = error } }
                } else {
                    showBackgroundClaude = true
                }
            } else {
                DevWorkspace.openAgentInTerminal(repo.path, prompt: store.pendingClaudePrompt)
            }
        }
        .contextMenu {
            if background { Button("Run in background…") { showBackgroundClaude = true } }
        }
    }

    /// Claude is done (see `Repository.writeCommitMessage`): its message, now the draft, is written into
    /// the field a few words at a time, so it reads as arriving rather than swapped in. Someone who
    /// started typing meanwhile keeps their own message.
    private func claudeFinished() {
        guard message.isEmpty, let suggestion = repo.commitSuggestion,
              repo.commitDraft == suggestion.summary else { return }
        self.suggestion = suggestion
        Task {
            await PanelMotion.typeOut(suggestion.summary, current: { message }, set: { message = $0 })
            if message.isEmpty || suggestion.summary.hasPrefix(message) { repo.commitDraft = suggestion.summary }
        }
    }

    private func commit(andPush: Bool) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Claude's description goes along only while its summary is left as it was.
        let description = suggestion?.summary == text ? suggestion?.description ?? "" : ""
        Task {
            guard await repo.commit(summary: text, description: description) else { return }
            message = ""
            suggestion = nil
            repo.commitDraft = ""
            repo.commitSuggestion = nil
            if andPush { await repo.push() }
        }
    }
}

/// A repository's app in its resting row: a green dot and the port while it runs, a red mark if it crashed.
/// "Commit & Push", crossfading to "Commit" while ⌥ is held. Both are laid out, so the button keeps
/// the wider one's width and nothing beside it moves; only the words fade. Only this observes ⌥.
private struct CommitLabel: View {
    let canPush: Bool
    @ObservedObject private var keys = ModifierKeys.shared

    var body: some View {
        let pushes = canPush && !keys.option
        if !canPush {
            Text("Commit")
        } else {
            ZStack {
                Text("Commit & Push").opacity(pushes ? 1 : 0)
                Text("Commit").opacity(pushes ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.18), value: pushes)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pushes ? "Commit & Push" : "Commit")
        }
    }
}

private struct ServerBadge: View {
    @ObservedObject var server: DevServer
    /// 1 while the port glows green as the app starts answering (its address appears), fading to 0,
    /// as in the Servers tab: the moment it's ready shows without watching for it.
    @State private var glow: Double = 0

    var body: some View {
        content
            .onChange(of: server.url) { old, new in
                guard old == nil, new != nil else { return }
                glow = 1
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.easeOut(duration: 0.9)) { glow = 0 }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let external = server.external {
            running(external.url)
        } else if server.state == .running, server.url == nil {
            // Grey until it answers: the green dot said "running" while the first install had minutes to go.
            HStack(spacing: 4) {
                Circle().fill(.tertiary).frame(width: 6, height: 6)
                StartProgressLabel(server: server)
            }
        } else if server.state == .running {
            running(server.url)
        } else if server.state == .stopping {
            Text("Stopping…")
        } else if case .exited(let code) = server.state, code != 0 {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if let failure = server.failure { Text(verbatim: failure.summary) }
            }
        }
    }

    private func running(_ url: URL?) -> some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            if let port = url?.port {
                Text(verbatim: ":\(port)")
                    .overlay {
                        Text(verbatim: ":\(port)")
                            .foregroundStyle(.green)
                            .shadow(color: .green.opacity(0.6), radius: 4)
                            .opacity(glow)
                            .allowsHitTesting(false)
                    }
            }
        }
    }
}

/// The tooltip for an agent button, naming the agent, the terminal it opens in and the prompt it will run.
private func agentHelp(agent: String, terminal: String, in folder: String? = nil, prompt: String?, chrome: Bool) -> String {
    let base = "Open \(agent)" + (chrome ? " with Chrome" : "") + " in \(terminal)" + (folder.map { " in \($0)" } ?? "")
    return prompt.map { "\(base) and run \($0)" } ?? base
}

/// What the empty prompt field suggests. A fixed "like /init" was read once and then never again, so it
/// rotates through things worth asking an agent in a fresh session, each short enough for the field.
/// They take the agent's name so they read right for Codex, Cursor and the rest, not only Claude.
enum ComposerPlaceholder {
    static let all: [(String) -> String] = [
        { "Ask \($0) anything, or /init" },
        { "What should \($0) build today?" },
        { "/init to teach \($0) a repo" },
        { _ in "Explain this codebase to me" },
        { _ in "Find the bug I can't see" },
        { _ in "Write the tests I keep skipping" },
        { _ in "Tidy up that TODO from March" },
        { _ in "Why is the build so slow?" },
        { _ in "Review my last commit" },
        { _ in "Make the README worth reading" },
        { _ in "Upgrade the dependencies, carefully" },
        { "Hand \($0) the boring part" },
    ]

    /// With a row picked the prompt runs in that repository, so the field suggests the way Claude Code's
    /// own empty prompt does (`Try "how does <filepath> work?"`, its wording), with a file the repository
    /// actually has. Without a file only the suggestions that need none are left.
    static let withFile: [(String) -> String] = [
        { "Try \"how does \($0) work?\"" },
        { "Try \"refactor \($0)\"" },
        { "Try \"edit \($0) to…\"" },
        { "Try \"write a test for \($0)\"" },
    ]
    static let withoutFile = ["Try \"fix lint errors\"", "Try \"fix typecheck errors\""]

    /// A random other one, so the same line never shows twice in a row.
    static func next(after index: Int) -> Int {
        (index + Int.random(in: 1..<all.count)) % all.count
    }

    /// A suggestion about one of the repository's recent files, other than `other` when there's a choice.
    static func forRepo(recentFiles: [String], other: String?) -> String {
        let options = recentFiles.isEmpty
            ? withoutFile
            : recentFiles.flatMap { file in withFile.map { $0((file as NSString).lastPathComponent) } }
        return options.filter { $0 != other }.randomElement() ?? options[0]
    }

    /// Each repository's recent files, read for all of them when the panel opens (`prefetch`). Reading
    /// them when a row was picked left the field on a general suggestion for the moment git took, then
    /// swapped it, which looked like the panel stuttering on every click.
    @MainActor static var recentFilesCache: [String: [String]] = [:]

    /// Reads every repository's recent files into the cache, a few at a time, off the main thread.
    @MainActor static func prefetch(_ repos: [String]) async {
        await withTaskGroup(of: (String, [String]).self) { group in
            for (i, repo) in repos.enumerated() {
                if i >= 4, let (path, files) = await group.next() { recentFilesCache[path] = files }
                group.addTask { (repo, await recentFiles(in: repo)) }
            }
            for await (path, files) in group { recentFilesCache[path] = files }
        }
    }

    /// Source files committed to lately in `repo`, newest first: what the user is working on, so a
    /// suggestion names a file they'd recognise rather than any file in the tree. Only files still there.
    nonisolated static func recentFiles(in repo: String) async -> [String] {
        let log = await Git.run(["log", "-n", "40", "--name-only", "--format=", "--diff-filter=AM"], in: repo, timeout: 5)
        guard log.succeeded else { return [] }
        let source: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "vue", "svelte", "py", "rb", "go", "rs", "php",
                                   "java", "kt", "cs", "c", "cc", "cpp", "h", "m", "ex", "dart", "scala", "lua"]
        var seen = Set<String>()
        return log.stdout.split(separator: "\n").map(String.init).filter { file in
            source.contains((file as NSString).pathExtension.lowercased())
                && seen.insert(file).inserted
                && FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent(file))
        }
    }
}

/// Everything about starting the agent on one line: the prompt (or a skill such as `/init`) that the next
/// agent button clicked in the panel runs, the switches for how it and terminals open, a plain terminal
/// in `/`, and a send button that opens the agent in `/`. All native controls, so they look like the
/// system's. Without an agent installed only the terminal's part is left, and an agent that can't start
/// with a prompt has no prompt field (its send button just opens it in /).
private struct ClaudeComposer: View {
    @ObservedObject var store: RepoStore
    @ObservedObject private var agent = AgentStatus.shared
    var isFocused: FocusState<Bool>.Binding
    /// ↑/↓ in the field pick a row below (the field has focus whenever the panel opens, so this is
    /// where the keyboard is); Return acts on the picked row, or opens the agent in / without one.
    var moveSelection: (Int) -> Void = { _ in }
    /// Return with a row picked; false when none is, so Return falls back to opening the agent in /.
    var submitSelection: () -> Bool = { false }
    /// Esc, stepping back one thing at a time: the prompt, the pick, the open row, then the panel.
    var escape: () -> Void = {}

    private var withChrome: Bool { store.agentWithBrowser && agent.info.can(.browser) }

    /// The row picked with ↑/↓, or else the open one: the repository the suggestions are about.
    /// Observed here rather than by the list (see `ExpandedRepo.Row`).
    @ObservedObject private var expansion = ExpandedRepo.shared
    private var selectedRepo: String? { expansion.selected ?? expansion.path }

    /// Which of `ComposerPlaceholder.all` the empty field shows.
    @State private var placeholderIndex = Int.random(in: 0..<ComposerPlaceholder.all.count)
    /// The repository's suggestion, made once its recent files are read (nil until then).
    @State private var repoPlaceholder: String?

    /// How long a suggestion stays before the next. Long enough to read, short enough that it's seen to
    /// change while the panel is open, rather than only after closing and opening it again.
    private static let rotation: Duration = .seconds(5)

    private var placeholder: String {
        if selectedRepo != nil, let repoPlaceholder { return repoPlaceholder }
        return ComposerPlaceholder.all[placeholderIndex](agent.info.name)
    }

    /// Reads the repository's recent files off the main thread once, then moves on to another suggestion
    /// every few seconds for as long as the panel is open (closing it cancels the task, as the panel's
    /// views disappear). The general suggestion stays until the files are read, rather than the field
    /// going blank. Nothing changes while text is in the field, as the placeholder isn't showing then.
    private func rotatePlaceholders(for repo: String?) async {
        // From the cache when it's there, so the suggestion changes in the same frame as the row.
        // Otherwise the previous suggestion stays until git has answered, rather than flashing another.
        var files: [String] = []
        if let repo {
            if let cached = ComposerPlaceholder.recentFilesCache[repo] {
                files = cached
            } else {
                files = await ComposerPlaceholder.recentFiles(in: repo)
                guard !Task.isCancelled else { return }
                ComposerPlaceholder.recentFilesCache[repo] = files
            }
        } else {
            repoPlaceholder = nil
        }
        let recent = Array(files.prefix(8))
        while !Task.isCancelled {
            if store.claudePrompt.isEmpty {
                if repo != nil {
                    repoPlaceholder = ComposerPlaceholder.forRepo(recentFiles: recent, other: repoPlaceholder)
                } else {
                    placeholderIndex = ComposerPlaceholder.next(after: placeholderIndex)
                }
            }
            try? await Task.sleep(for: Self.rotation)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if agent.info.can(.initialPrompt) {
                // The suggestion is drawn over the field rather than set as its placeholder: AppKit's
                // placeholder is slow to change (setPlaceholderString), and it changes with every row
                // opened or picked, which made that a good part of opening a row.
                TextField(text: $store.claudePrompt, prompt: Text(verbatim: "")) { Text("Prompt") }
                    .overlay(alignment: .leading) {
                        if store.claudePrompt.isEmpty {
                            Text(verbatim: placeholder)
                                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                                .lineLimit(1)
                                .padding(.leading, PanelMetrics.fieldTextInset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityHint(placeholder)
                    .focused(isFocused)
                    .onSubmit { if !submitSelection() { send() } }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onExitCommand(perform: escape)
                    .panelField()
            } else {
                Spacer()
            }
            // Settings for how the agent and terminals open, in a tray of their own, set apart from the
            // terminal and send buttons beside them, which do something.
            PanelToggleBar(toggleItems)
                .controlSize(.regular)
                .fixedSize()
            // Field, switches, terminal and send all at the regular size, as tall as one another.
            Button { DevWorkspace.openTerminal("/") } label: { Image(systemName: "terminal") }
                .fieldRowButton()
                .panelTooltip("Open \(agent.terminalName) in /")
                .accessibilityLabel("Open \(agent.terminalName) in /")
            if agent.info.isInstalled {
                sendButton
            }
        }
        // Restarts on every open of the panel and whenever another row is picked or opened.
        .task(id: selectedRepo) { await rotatePlaceholders(for: selectedRepo) }
        // Fresh on every open, so files committed to since are in the next suggestions.
        .task { await ComposerPlaceholder.prefetch(store.repos.map(\.path)) }
    }

    /// Settings for how the agent and terminals open: each terminal's own (Terminal's Clear Dark
    /// profile, Rex's split windows), and Chrome for the agent.
    private var toggleItems: [PanelToggleItem] {
        var items: [PanelToggleItem] = []
        if !(Terminals.current is Rex) {
            items.append(PanelToggleItem(systemImage: "drop.fill", name: "Clear Dark Terminal profile", isOn: $store.darkTerminal))
        } else {
            items.append(PanelToggleItem(systemImage: store.rexSplit ? "rectangle.split.2x1" : "rectangle.stack",
                                         name: "Split the project's Rex window\nOff: tabs", isOn: $store.rexSplit))
        }
        if agent.info.can(.browser) {
            let name = "Start \(agent.info.name) with Chrome"
            // Chrome's logo in color while on, grey while off, like the symbols beside it.
            let image = Logo.chrome.map { store.agentWithBrowser ? $0 : $0.grayscale } ?? NSImage(systemSymbolName: "globe", accessibilityDescription: name) ?? NSImage()
            items.append(PanelToggleItem(image.sized(16), name: name, isOn: $store.agentWithBrowser))
        }
        return items
    }

    /// Prominent in the agent's color once there's a prompt to send, like the agent buttons in the rows.
    private var sendButton: some View {
        let help = agentHelp(agent: agent.info.name, terminal: agent.agentPlaceName, in: "/", prompt: store.pendingClaudePrompt, chrome: withChrome)
        return Button(action: send) { Image(systemName: "arrow.up").fontWeight(.semibold) }
            .fieldRowButton(prominent: store.pendingClaudePrompt != nil, tint: Agent.current.tint)
            .panelTooltip(help)
            .accessibilityLabel(help)
    }

    private func send() {
        DevWorkspace.openAgentInTerminal("/", prompt: store.pendingClaudePrompt)
    }
}

/// Notes and pinned skills under a repository's name; a skill opens the agent in a terminal running it.
private struct ShortcutStrip: View {
    @ObservedObject var repo: Repository
    let options: RepoRowOptions
    @Binding var showNotes: Bool
    @Binding var showSkillPicker: Bool

    var body: some View {
        FlowLayout(spacing: 4) {
            if !repo.notes.isEmpty {
                Chip(help: firstLine(of: repo.notes)) { showNotes = true } label: {
                    Image(systemName: "note.text")
                }
            }
            if options.showsSkills {
                let agent = options.agent
                ForEach(repo.skills, id: \.self) { skill in
                    Chip(help: "Open \(agent.name) in \(options.terminalName) and run \(skill)") {
                        DevWorkspace.openAgentInTerminal(repo.path, prompt: skill)
                    } label: {
                        Image(nsImage: Agent.current.logo).resizable().frame(width: 10, height: 10)
                        Text(verbatim: skill).lineLimit(1)
                    }
                    .contextMenu {
                        if agent.can(.background) {
                            Button("Run in background") {
                                // Shown in the row like a failed git command; the session shows up under the row once it runs.
                                Task { if let error = await BackgroundClaude.shared.start(skill, in: repo.path) { repo.error = error } }
                            }
                            Divider()
                        }
                        Button("Unpin \(skill)") { repo.skills.removeAll { $0 == skill } }
                    }
                }
                Chip(help: "Pin a \(agent.name) skill") { showSkillPicker = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func firstLine(of text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? ""
    }
}

/// A small capsule button, for pinned skills and notes, with the panels' hover (`PanelChipStyle`).
private struct Chip<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { label }
        }
        .buttonStyle(.panelChip)
        .accessibilityLabel(help)
    }
}

/// Lays children out left to right, wrapping onto new lines, so many pinned skills don't widen the panel.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row(y: 0)]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Type a skill (or any prompt) to pin, picking from the skills Claude Code has installed.
private struct SkillPicker: View {
    @ObservedObject var repo: Repository
    let dismiss: () -> Void
    @State private var text = ""
    @State private var available: [ClaudeSkill] = []
    @State private var projectOnly = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("/skill, or any prompt", text: $text)
                .focused($searchFocused)
                .onSubmit { pin(text) }
                .panelField()
                .padding(10)
            if available.contains(where: \.isProject) {
                PanelSegments("Show", selection: $projectOnly, fills: true,
                              segments: [PanelSegment("All", value: false), PanelSegment("This project", value: true)])
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider()
            List(matches) { skill in
                Button { pin("/" + skill.name) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(verbatim: "/" + skill.name)
                                .foregroundStyle(skill.isProject ? Color.accentColor : Color.primary)
                            if skill.isProject {
                                Text("Project")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.quaternary, in: .capsule)
                            }
                        }
                        if !skill.description.isEmpty {
                            Text(verbatim: skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 340, height: 380)
        .task {
            // A popover's window isn't key on its first frame, so focus set in onAppear is lost.
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
            let path = repo.path
            available = await Task.detached { ClaudeSkills.available(in: path) }.value
        }
    }

    private var matches: [ClaudeSkill] {
        let query = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return available.filter { !repo.skills.contains("/" + $0.name) && (!projectOnly || $0.isProject) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    /// A bare word is taken to be a skill, so `monday` becomes `/monday`; anything longer is kept as a prompt.
    private func pin(_ entry: String) {
        var entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        if !entry.hasPrefix("/") && !entry.contains(" ") { entry = "/" + entry }
        if !repo.skills.contains(entry) { repo.skills.append(entry) }
        dismiss()
    }
}

/// New projects, adding repositories and the app's settings, behind a gear button; in the panel and the main window.
/// The forms for a new project and cloning open as a page of the menu bar panel (`openPage`), and as
/// popovers from this button in the main window. Everything that brings in a repository, next to the tabs where the list is, rather than among the settings.
struct AddRepositoryMenu: View {
    @ObservedObject var store: RepoStore
    @Binding var notice: String?
    @Binding var showNewProject: Bool
    @Binding var showClone: Bool
    /// In the menu bar panel: the forms open as a page of the panel instead of a popover over it.
    var openPage: ((PanelPage) -> Void)?
    /// The main window's Find repositories popover; the panel opens it as a page.
    @State private var showImport = false
    /// The main window's Clean up repositories popover; the panel opens it as a page.
    @State private var showCleanUp = false

    var body: some View {
        PanelMenu("plus", help: "New project, clone, add or clean up repositories") {
            Button("New project…", systemImage: "sparkles") {
                if let openPage { openPage(.newProject) } else { showNewProject = true }
            }
            Button("Clone repository…", systemImage: "square.and.arrow.down") {
                if let openPage { openPage(.clone) } else { showClone = true }
            }
            Divider()
            Button("Find repositories…", systemImage: "magnifyingglass") {
                if let openPage { openPage(.importRepos) } else { showImport = true }
            }
            Button("Add repository…", systemImage: "folder.badge.plus") { Task { notice = await store.addWithPanel() } }
            // Beside finding them, as its counterpart: in and out in batches from the same menu.
            if !store.repos.isEmpty {
                Divider()
                Button("Clean up repositories…", systemImage: "minus.circle") {
                    if let openPage { openPage(.cleanUp) } else { showCleanUp = true }
                }
            }
        }
        .panelPopover(isPresented: $showNewProject, arrowEdge: .bottom) {
            NewProjectForm(store: store) { showNewProject = false }
        }
        // Their own views to anchor to: two popovers on one view don't both open reliably.
        .background {
            Color.clear.panelPopover(isPresented: $showClone, arrowEdge: .bottom) {
                CloneRepositoryForm(store: store) { showClone = false }
            }
        }
        .overlay {
            Color.clear.allowsHitTesting(false).panelPopover(isPresented: $showImport, arrowEdge: .bottom) {
                ImportRepositoriesForm(store: store) { result in
                    showImport = false
                    if let result { notice = result }
                }
            }
        }
        .background {
            Color.clear.allowsHitTesting(false).panelPopover(isPresented: $showCleanUp, arrowEdge: .bottom) {
                CleanUpRepositoriesForm(store: store) { failure in
                    showCleanUp = false
                    if let failure { notice = failure }
                }
            }
        }
    }
}

/// What's used often in the Repos tab (fetch, the list's order and filters) behind the gear button, and
/// Settings…, a page of the panel (`SettingsPage`) with everything else; in the panel and the main
/// window (where the order and filters apply to the sidebar). The settings were here too, about twenty
/// lines with the picks hidden in submenus.
struct SettingsMenu: View {
    @ObservedObject var store: RepoStore
    /// Opens the settings page (`PanelPage.settings`) in the panel.
    let openSettings: () -> Void
    @ObservedObject private var groups = RepoGroups.shared

    var body: some View {
        PanelMenu(help: "Settings") {
            if !store.repos.isEmpty {
                Button("Fetch all repositories") { Task { await store.fetchAll(quietly: false) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isFetchingAll)
                Divider()
                Menu("Sort by") {
                    Picker("Sort by", selection: $store.sortOrder) {
                        ForEach(RepoSortOrder.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // All worded the same way, as what to keep: a mix of "Show only" and "Hide … without"
                // read as some switches being the other way round.
                Menu("Show only") {
                    // One that would leave the list empty can't be turned on; one that's on can always be turned off.
                    Toggle("Favorites", isOn: $store.favoritesOnly)
                        .disabled(!store.favoritesOnly && !store.showsAny(favoritesOnly: true))
                    Toggle("Repositories with a color", isOn: $store.hideUncolored)
                        .disabled(!store.hideUncolored && !store.showsAny(hideUncolored: true))
                    Toggle("Repositories with a running server", isOn: $store.hideInactive)
                        .disabled(!store.hideInactive && !store.showsAny(hideInactive: true))
                }
                Toggle("Show in groups", isOn: $groups.showsGroups)
                Divider()
            }
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit Bridge") { NSApp.terminate(nil) }
        } icon: {
            Image(systemName: "gearshape").foregroundStyle(.secondary)
        }
        .accessibilityLabel("Settings")
    }
}
/// Start and stop the repository's web app, which runs in the background, and open it in the browser.
struct ServerControls: View {
    @ObservedObject var repo: Repository
    @ObservedObject var server: DevServer
    @State private var showEditor = false
    /// Opens the start command editor somewhere else than in a popover on these buttons: in the panel it's a
    /// page (`PanelPage.startCommand`). The buttons there fade out under a popover once the pointer moves
    /// into it, and a popover over a fading view draws its fields black. The main window keeps the popover.
    let editStart: (() -> Void)?

    /// The favorite star isn't here: in the panel it sits by the repository's name.
    init(repo: Repository, editStart: (() -> Void)? = nil) {
        self.repo = repo
        server = repo.server
        self.editStart = editStart
    }

    private func openEditor() {
        if let editStart { editStart() } else { showEditor = true }
    }

    var body: some View {
        if let external = server.external {
            address(external.url, pending: "")
            IconButton(systemName: "stop.fill", help: "Stop", hoverTint: .red) { server.stopExternal() }
        } else if let command = repo.startCommand {
            controls(command)
        } else {
            IconButton(systemName: "play.fill", help: "No web app found. Choose a start command or script…", action: openEditor)
                .opacity(0.45)
                .panelPopover(isPresented: $showEditor, arrowEdge: .bottom) {
                    StartCommandEditor(repo: repo) { showEditor = false }
                }
        }
    }

    private var isRunning: Bool { server.state == .running || server.state == .stopping }

    @ViewBuilder private func controls(_ command: String) -> some View {
        switch server.state {
        case .running, .stopping:
            if server.state == .running, server.url == nil {
                StartProgressLabel(server: server, showsTime: true)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                address(server.url, pending: "Stopping…")
            }
        case .stopped, .exited:
            if case .exited(let code) = server.state, code != 0 {
                // Bridge already reinstalled once on its own; this is for after the user fixed something, or a cause it missed.
                if server.failure?.kind == .missingDependencies, server.canReinstall, !repo.startsInTerminal {
                    Button("Reinstall") { server.start(command, reinstall: true) }
                        .buttonStyle(.panelChip)
                }
                IconButton(systemName: "exclamationmark.triangle",
                           help: "The app stopped (exit code \(code))\(server.failure.map { ": \($0.summary)" } ?? ""). Show its output",
                           hoverTint: .red) {
                    server.showOutput()
                }
            }
        }
        // One button for build, play and stop, outside the switch so it stays the same view as the
        // server starts and stops, and its symbol turns into the next one (`IconButton`'s `.replace`)
        // rather than one button being swapped for another: the click is answered at once, while the
        // app takes its seconds to start.
        primaryButton(command)
            .contextMenu {
                if isRunning {
                    // Output sits behind a right-click, like the log in the Servers tab, to keep the row short.
                    Button("Show output") { server.showOutput() }
                } else {
                    if let build = repo.buildCommand, !repo.needsBuild {
                        Button("Build again") { server.build(build) }
                    }
                    Button("Start command…", action: openEditor)
                }
            }
            .panelPopover(isPresented: $showEditor, arrowEdge: .bottom) {
                StartCommandEditor(repo: repo) { showEditor = false }
            }
    }

    private func primaryButton(_ command: String) -> IconButton {
        if isRunning {
            return IconButton(systemName: "stop.fill", help: server.isBuilding ? "Stop the build (right-click to show output)" : "Stop (right-click to show output)", hoverTint: .red) { server.stop() }
        }
        // An app that has to be compiled first gets the build button in play's place, and play once it's built:
        // the first compile (minutes for Rust or Spring) is then its own step with its own progress.
        if repo.needsBuild, let build = repo.buildCommand {
            return IconButton(systemName: "hammer.fill", help: "Build \(repo.detectedStartFolder ?? "the app") first\nIt can start once it's built", hoverTint: .orange) {
                server.build(build)
            }
        }
        return IconButton(systemName: "play.fill", help: repo.startsInTerminal ? "Run \(repo.customStart?.command ?? "") in Terminal" : "Start \(repo.customStart == nil ? repo.detectedStartFolder ?? "the app" : "the app") in the background", hoverTint: .green) {
            if repo.startsInTerminal { DevWorkspace.runInTerminal(command, in: repo.path) } else { server.start(command) }
        }
    }

    @ViewBuilder private func address(_ url: URL?, pending: String) -> some View {
        if let url, server.state != .stopping {
            AddressLink(url: url, label: Self.label(url))
        } else {
            Text(verbatim: pending)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// http://localhost:5173/ → localhost:5173
    private static func label(_ url: URL) -> String {
        url.port.map { "\(url.host ?? "localhost"):\($0)" } ?? url.host ?? url.absoluteString
    }
}

/// What a starting server is doing ("Installing…", "Building 42%"), from its output, and with `showsTime` how
/// long it has been at it once that passes a few seconds, so a first start that installs for minutes is seen
/// to be moving. Only this small view ticks, once a second, and only while the server starts.
struct StartProgressLabel: View {
    @ObservedObject var server: DevServer
    var showsTime = false

    var body: some View {
        let phase = server.phase ?? "Starting…"
        if showsTime {
            TimelineView(.periodic(from: server.startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(server.startedAt))
                Text(verbatim: seconds < 5 ? phase : "\(phase) \(Self.duration(seconds))")
                    .monospacedDigit()
            }
        } else {
            Text(verbatim: phase)
        }
    }

    /// 42 s, 1:05, 12:30.
    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// An address as a quiet link: grey like the rest of the row, blue and underlined under the pointer.
/// Only a click on the text itself opens the browser. Used for running apps and for ports in the Servers tab.
struct AddressLink: View {
    let url: URL
    let label: String
    @State private var hovering = false
    @State private var copied = 0

    var body: some View {
        Text(verbatim: label)
            .font(.caption.monospacedDigit())
            .underline(hovering)
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .fixedSize()
            .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onHover { inside in
            hovering = inside
            inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .contextMenu {
            Button("Open in browser") { NSWorkspace.shared.open(url) }
            Button("Copy URL") {
                Pasteboard.copy(url.absoluteString)
                copied += 1
            }
        }
        .copiedConfirmation(copied, alignment: .center)
    }
}

/// A count in a badge (✎ 3, ↑ 2, a group's ✎ 4) that rolls to its new value like an odometer, and on
/// reaching zero rolls down to 0 and then fades away rather than vanishing at once: after a commit or a
/// push the numbers visibly count down, so it can be seen that it went through. Its own animations,
/// scoped to its own state, so nothing else in the row moves with them.
struct RollingCount: View {
    let value: Int
    let text: (Int) -> Text
    /// What's shown: nil while hidden, 0 for a moment on the way out. Starts from the value, not set in
    /// `onAppear`: an empty `Group` never appears, so a count that started hidden never showed.
    @State private var shown: Int?

    init(value: Int, text: @escaping (Int) -> Text) {
        self.value = value
        self.text = text
        _shown = State(initialValue: value > 0 ? value : nil)
    }

    var body: some View {
        // A ZStack rather than a Group: it exists even while empty, so `onChange` still sees the count
        // come back. A Group's modifiers go to its children, and with none, nothing reacts.
        ZStack {
            if let shown {
                text(shown)
                    .contentTransition(.numericText(value: Double(shown)))
                    .transition(.opacity)
            }
        }
        .onChange(of: value) { _, new in
            if new > 0 {
                if shown == nil {
                    withAnimation(.easeOut(duration: 0.2)) { shown = new }
                } else {
                    withAnimation(.snappy(duration: 0.35)) { shown = new }
                }
            } else if shown != nil {
                withAnimation(.snappy(duration: 0.35)) { shown = 0 }
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    // Unless a new count came in meanwhile.
                    if shown == 0 { withAnimation(.easeOut(duration: 0.2)) { shown = nil } }
                }
            }
        }
    }
}

extension View {
    /// A commit message field Claude can fill in, without a button of its own: while the field is empty
    /// it ends in a grey "Write with Claude ⇥" (Tab, or a click), like an editor's completion, and while
    /// Claude writes, the field itself says so in shimmering grey. An icon beside the field (sparkles)
    /// looked out of place among the panel's plain controls, and wasn't clear about what it did.
    /// Apply to the text field, before `panelField`, so both line up with its text.
    /// The same for other fields the agent fills in (the start command), with their own words: `verb` for the
    /// hint ("Find" → "Find with Claude ⇥"), `working` for the shimmer ("is looking through the project…"),
    /// and the capability the agent needs for it.
    func claudeWrites(isEmpty: Bool, isWriting: Bool, enabled: Bool = true, verb: String = "Write", working: String = "is writing…",
                      needs capability: AgentCapability = .headless, action: @escaping () -> Void) -> some View {
        modifier(ClaudeWrites(isEmpty: isEmpty, isWriting: isWriting, enabled: enabled, verb: verb, working: working,
                              capability: capability, action: action))
    }
}

/// Only for agents that can do it (`.headless` for a commit message); with another one the field is a plain
/// field. Observes `AgentStatus`, which changes only when the agent does.
private struct ClaudeWrites: ViewModifier {
    let isEmpty: Bool
    let isWriting: Bool
    let enabled: Bool
    let verb: String
    let working: String
    let capability: AgentCapability
    let action: () -> Void
    @State private var hovering = false
    @ObservedObject private var agent = AgentStatus.shared

    private var canWrite: Bool { enabled && agent.info.can(capability) }

    func body(content: Content) -> some View {
        // Inside the field's border, at its end, only while the field is empty, so it never runs into
        // typed text; the placeholder there is short ("3 changes · +12 −4").
        content
            .overlay(alignment: .leading) {
                if isWriting && isEmpty {
                    ShimmerText("\(agent.info.name) \(working)")
                        .padding(.leading, PanelMetrics.fieldTextInset)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if isEmpty && !isWriting && canWrite {
                    Button(action: action) {
                        // The field's own placeholder color, as the prompt's suggestion has, not `.tertiary`: on a
                        // page of the panel, straight on its glass, the tertiary style blended into the field and
                        // the hint couldn't be seen, though it was there and worked.
                        Text("\(verb) with \(agent.info.name) \(Image(systemName: "arrow.right.to.line"))")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: hovering ? .secondaryLabelColor : .placeholderTextColor))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .padding(.trailing, PanelMetrics.fieldTextInset)
                    .onHover { hovering = $0 }
                }
            }
            // Tab in the empty field, as accepting a completion does in an editor.
            .onKeyPress(.tab) {
                guard isEmpty, !isWriting, canWrite else { return .ignored }
                action()
                return .handled
            }
    }
}

struct BranchChip: View {
    let name: String
    /// Under the pointer, where the chip is a button (`BranchSwitcher`).
    var isHovered = false
    /// A chevron after the name, where the chip opens a menu of branches.
    var isMenu = false

    var body: some View {
        Text("\(Image(systemName: "arrow.triangle.branch")) \(name)\(isMenu ? Text(" \(Image(systemName: "chevron.down"))").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) : Text(""))")
            .font(.caption)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: .capsule)
    }
}

/// The branch chip in a repository row, as a menu of its branches to switch to.
private struct BranchSwitcher: View {
    @ObservedObject var repo: Repository
    let store: RepoStore
    @State private var hovering = false

    var body: some View {
        Menu {
            BranchMenuItems(repo: repo, store: store)
        } label: {
            BranchChip(name: repo.currentBranch, isHovered: hovering, isMenu: true)
        }
        // A button-style menu draws its label as it is, so it still looks like the chip.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(repo.activity != nil)
    }
}

/// Local branches to switch to, most recent first, with the current one checked; the rest in the window.
private struct BranchMenuItems: View {
    @ObservedObject var repo: Repository
    let store: RepoStore

    var body: some View {
        let local = repo.branches.filter { !$0.isRemote }.sorted { $0.date > $1.date }
        ForEach(local.prefix(15)) { branch in
            Toggle(isOn: Binding(get: { branch.name == repo.currentBranch }, set: { on in
                if on { Task { await repo.switchTo(branch) } }
            })) {
                Text(verbatim: branch.name)
            }
        }
        if !local.isEmpty { Divider() }
        Button("All branches…") { MainWindow.shared.show(store, selecting: repo) }
    }
}

extension Date {
    var relative: String {
        if Date().timeIntervalSince(self) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

/// Whether ⌥ is held, so buttons can show their alternate action while it is.
@MainActor
final class ModifierKeys: ObservableObject {
    static let shared = ModifierKeys()
    @Published private(set) var option = false

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.option = event.modifierFlags.contains(.option)
            return event
        }
    }
}
