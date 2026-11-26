import AppKit
import Shared
import SwiftUI

/// The Servers tab: processes listening on local ports.
struct ServersPanel: View {
    @ObservedObject var model: PortModel
    @ObservedObject private var groups = RepoGroups.shared
    /// Not observed: each row watches its own part (`ExpandedServer.Row`).
    private var expansion: ExpandedServer { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PanelTabs()
                Spacer()
                // Settings in the same place as the Repos tab's.
                HStack(spacing: 2) {
                    // Refresh is in the settings menu (and ⌘R); while it runs, this says so.
                    if model.isRefreshingByHand {
                        ProgressView().controlSize(.small).frame(width: 24, height: 22)
                    }
                    // An on/off switch, the same control as the Repos tab's switches beside its prompt.
                    PanelToggleBar([PanelToggleItem(systemImage: "eye", name: "System processes and apps", isOn: $model.showAll)])
                        .controlSize(.regular)
                        .fixedSize()
                        // As tall as the icon buttons beside it in layout, reaching into the header's
                        // margin: taller, it made this line taller than the Repos tab's, and the panel's
                        // content shifted between the tabs.
                        .frame(height: 22)
                    PanelMenu("gearshape", help: "Settings") {
                        Button("Refresh") { model.refreshByHand() }
                            .keyboardShortcut("r", modifiers: .command)
                        Divider()
                        // One switch for the graphs and the top consumers both. It's on while either is, so
                        // settings saved from when they were two switches still show as they are.
                        Toggle("Show usage", isOn: Binding(
                            get: { model.showUsageGraphs || model.showTopConsumers },
                            set: { model.showUsageGraphs = $0; model.showTopConsumers = $0 }
                        ))
                        Toggle("Show in groups", isOn: $groups.showsGroups)
                        Divider()
                        Toggle("Start servers in the background", isOn: $model.runInBackground)
                        Divider()
                        Toggle("Notify about new and stopped servers", isOn: $model.notificationsOn)
                        Divider()
                        LicenseMenuItem()
                        Button("Quit Bridge") { NSApp.terminate(nil) }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(12)
            // ⌘R while the panel is open, as the menu item's shortcut only works with the menu open.
            .background {
                TabShortcuts(tab: .servers) {
                    Button("Refresh") { model.refreshByHand() }
                        .keyboardShortcut("r", modifiers: .command)
                }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            PanelDivider()

            if let error = model.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(verbatim: error)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Dismiss") { model.lastError = nil }
                        .accessibilityLabel("Dismiss")
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                PanelDivider()
            }

            if model.usageHistory.count > 1 && (model.showUsageGraphs || model.showTopConsumers) {
                UsageHeader(
                    samples: model.usageHistory,
                    processes: model.processes.filter { !$0.isSystem },
                    colorSlots: model.colorSlots,
                    showGraphs: model.showUsageGraphs,
                    showBreakdown: model.showTopConsumers,
                    onSelect: reveal
                )
                PanelDivider()
            }

            if model.visibleProcesses.isEmpty && model.stoppedServers.isEmpty {
                emptyState
            } else {
                MenuPanelList(maxHeight: 520) {
                    // Inside the scroll view, so it can scroll to a row opened from Top consumers.
                    ScrollViewReader { proxy in
                    // A faint inset line between rows and before each group, as in the Repos tab.
                    VStack(spacing: 0) {
                        let items = model.stoppedServers.map(ServerItem.favorite) + model.visibleProcesses.map(ServerItem.process)
                        let sections = groups.sections(items) { groups.group(ofServer: $0.key, projectRoot: $0.projectRoot) }
                        ForEach(sections, id: \.id) { section in
                            if !section.isOnly {
                                if section.id != sections.first?.id {
                                    PanelDivider(subtle: true).padding(.top, 4)
                                }
                                ServerGroupHeader(section: section, model: model)
                            }
                            if section.isOnly || !groups.isCollapsed(section.name, in: .servers) {
                                VStack(spacing: 0) {
                                ForEach(section.items) { item in
                                    if item.id != section.items.first?.id {
                                        PanelDivider(subtle: true)
                                    }
                                    Group {
                                        switch item {
                                        case .favorite(let favorite): FavoriteRow(favorite: favorite, model: model)
                                        case .process(let process): ProcessRow(process: process, model: model)
                                        }
                                    }
                                    .groupRow(GroupDragItem(kind: .server, key: item.key, projectRoot: item.projectRoot), title: item.title, in: section)
                                    .id(item.id)
                                }
                                }
                                .revealsGently()
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .onReceive(expansion.$revealCount.dropFirst()) { _ in
                        // After the opened row is laid out, as `onChange` came.
                        DispatchQueue.main.async {
                            if let id = expansion.id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    }
                }
            }
        }
        .frame(width: 460)
    }

    /// A process clicked in Top consumers: unfold its group if it's folded away, open its row, scroll to it.
    private func reveal(_ id: String) {
        guard let process = model.processes.first(where: { $0.id == id }) else { return }
        let group = groups.group(ofServer: process.favoriteKey, projectRoot: process.projectRoot)
        if groups.showsGroups, groups.isCollapsed(group, in: .servers) {
            groups.toggleCollapsed(group, in: .servers)
        }
        expansion.reveal(id)
    }

    /// Says whether there's really nothing, or only system processes that are hidden, with a way to show them.
    private var emptyState: some View {
        let hidden = model.showAll ? 0 : model.processes.filter(\.isSystem).count
        return VStack(spacing: 8) {
            Text(hidden > 0 ? "No dev servers running" : "Nothing is listening on a port")
                .foregroundStyle(.secondary)
            if hidden > 0 {
                Button(hidden == 1 ? "Show 1 system process" : "Show \(hidden) system processes") { model.showAll = true }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// A row in the Servers tab: a favorite that isn't running, or a process listening on a port.
enum ServerItem: Identifiable {
    case favorite(Favorite)
    case process(ListeningProcess)

    var id: String {
        switch self {
        case .favorite(let favorite): "favorite:" + favorite.key
        case .process(let process): process.id
        }
    }

    /// What its group is stored under: the same for a favorite and its process when it runs.
    var key: String {
        switch self {
        case .favorite(let favorite): favorite.key
        case .process(let process): process.favoriteKey
        }
    }

    var title: String {
        switch self {
        case .favorite(let favorite): favorite.title
        case .process(let process): process.title
        }
    }

    /// For the repository's group. A favorite only has its key, which is the project folder unless
    /// it's a container (`docker:`) or a command (`cmd:`).
    var projectRoot: String? {
        switch self {
        case .favorite(let favorite): favorite.key.hasPrefix("/") ? favorite.key : nil
        case .process(let process): process.projectRoot
        }
    }
}

/// A group's header in the Servers tab, with what's running in it, and its menu to start its stopped
/// favorites or stop its servers together.
private struct ServerGroupHeader: View {
    let section: GroupSection<ServerItem>
    @ObservedObject var model: PortModel

    var body: some View {
        let processes = section.items.compactMap { if case .process(let process) = $0 { process } else { nil } }
        let favorites = section.items.compactMap { if case .favorite(let favorite) = $0 { favorite } else { nil } }
        let startable = favorites.filter { $0.launch != nil && !model.busy.contains($0.key) }
        let stoppable = processes.filter { !$0.isSystem && !($0.framework == .docker && $0.container == nil) }
        GroupHeader(section: section.name, title: section.title, count: section.items.count, tab: .servers) {
            if !processes.isEmpty {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    // Rolls to the new count, like an odometer, when a server starts or stops.
                    Text(verbatim: String(processes.count))
                        .contentTransition(.numericText(value: Double(processes.count)))
                        .animation(.snappy, value: processes.count)
                }
            }
        } menu: {
            if !startable.isEmpty {
                Button(startable.count == 1 ? "Start 1 favorite" : "Start \(startable.count) favorites") {
                    startable.forEach(model.start)
                }
            }
            if !stoppable.isEmpty {
                Button(stoppable.count == 1 ? "Stop 1 server" : "Stop \(stoppable.count) servers") {
                    for process in stoppable { model.stop(process) }
                }
            }
        }
    }
}

extension View {
    /// The New group form for a server row, opened from its context menu's Group entry.
    func newServerGroupPopover(_ isPresented: Binding<Bool>, item: ServerItem, title: String) -> some View {
        background {
            Color.clear.panelPopover(isPresented: isPresented, arrowEdge: .bottom) {
                GroupNameForm(title: "New group with \(title)", action: "Create") { name in
                    RepoGroups.shared.setGroup(name, ofServer: item.key, projectRoot: item.projectRoot)
                    isPresented.wrappedValue = false
                }
            }
        }
    }
}

/// The Group entry of a server row's context menu.
private struct ServerGroupMenu: View {
    let item: ServerItem
    @Binding var showNewGroup: Bool
    @ObservedObject private var groups = RepoGroups.shared

    var body: some View {
        GroupMenu(current: groups.group(ofServer: item.key, projectRoot: item.projectRoot),
                  set: { groups.setGroup($0, ofServer: item.key, projectRoot: item.projectRoot) }) {
            showNewGroup = true
        }
    }
}

/// Which server row is open, showing its ports, process, uptime and command. One at a time, as in the Repos tab.
@MainActor
final class ExpandedServer: ObservableObject {
    static let shared = ExpandedServer()
    @Published private(set) var id: String? {
        didSet {
            guard id != oldValue else { return }
            oldValue.map { row($0).isExpanded = false }
            id.map { row($0).isExpanded = true }
        }
    }

    /// One row's part of this, for the row to observe, as in the Repos tab (`ExpandedRepo.Row`): only
    /// the row that opens and the one that folds redraw.
    final class Row: ObservableObject {
        @Published fileprivate(set) var isExpanded = false
    }
    private var rows: [String: Row] = [:]

    func row(_ id: String) -> Row {
        if let row = rows[id] { return row }
        let row = Row()
        row.isExpanded = self.id == id
        rows[id] = row
        return row
    }
    /// Bumped to scroll to `id`, for a row opened from elsewhere (a process in Top consumers).
    @Published private(set) var revealCount = 0

    func toggle(_ id: String) {
        self.id = self.id == id ? nil : id
    }

    /// Opens the row and asks the list to scroll to it.
    func reveal(_ id: String) {
        self.id = id
        revealCount += 1
    }
}

/// A server that isn't running and can be started: a favorite, or one just stopped from Bridge
/// (`PortModel.recentlyStopped`). Dimmed, as nothing is going on (that says it's stopped), its port while resting,
/// its start button in their place under the pointer, and how it starts behind a click.
struct FavoriteRow: View {
    let favorite: Favorite
    /// Not observed, only used in actions: what the row shows from it comes as values (`isFavorite`,
    /// `isBusy`), as in `ProcessRow`.
    let model: PortModel
    let isFavorite: Bool
    let isBusy: Bool
    @ObservedObject private var rowState: ExpandedServer.Row
    private var expansion: ExpandedServer { .shared }
    @State private var hovering = false
    @State private var showNewGroup = false
    @State private var atLeadingEdge = false
    /// False for a moment on a server just stopped from Bridge: its row starts as bright as the running
    /// row it replaces and fades to the dimmed stopped look, rather than snapping to it.
    @State private var settled: Bool

    init(favorite: Favorite, model: PortModel) {
        self.favorite = favorite
        self.model = model
        isFavorite = model.isFavorite(favorite)
        isBusy = model.busy.contains(favorite.key)
        rowState = ExpandedServer.shared.row(ServerItem.favorite(favorite).id)
        _settled = State(initialValue: !model.justStopped(favorite))
    }

    private var id: String { ServerItem.favorite(favorite).id }
    private var isExpanded: Bool { rowState.isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    // A server just stopped isn't a favorite: its outline star keeps it in the list for good.
                    LeadingStar(isFavorite: isFavorite, isShown: atLeadingEdge) {
                        if isFavorite { model.removeFavorite(favorite) } else { model.keep(favorite) }
                    }
                    HStack(spacing: 6) {
                        if let framework = favorite.framework {
                            FrameworkLogo(framework: framework, size: 14).opacity(settled ? 0.5 : 1)
                        }
                        // Dimmed by opacity rather than a grey style, so it can fade there from full strength.
                        Text(favorite.title)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(.primary)
                            .opacity(settled ? 0.55 : 1)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                trailing
            }
            // One height in both tabs, so a repository and a server row are equally tall.
            .frame(height: PanelRowMetrics.lineHeight)
            .contentShape(Rectangle())
            .onTapGesture { expansion.toggle(id) }

            if isExpanded {
                launchDescription.revealsGently()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .panelHighlight(hovering || isExpanded, .quinary)
        // The whole row, gaps included, takes the hover; the clear highlight alone doesn't.
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { expansion.toggle(id) }, including: isExpanded ? .subviews : .all)
        // Double-click starts it, as a double-click on a running server opens it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if favorite.launch != nil { model.start(favorite) } })
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .tracksLeadingEdge($atLeadingEdge)
        .onAppear {
            guard !settled else { return }
            // Only `settled` changes in this transaction: the name and logo fade, nothing moves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeOut(duration: 0.8)) { settled = true }
            }
        }
        .newServerGroupPopover($showNewGroup, item: .favorite(favorite), title: favorite.title)
        .contextMenu {
            if favorite.launch != nil {
                Button("Start") { model.start(favorite) }
                Divider()
            }
            ServerGroupMenu(item: .favorite(favorite), showNewGroup: $showNewGroup)
            Divider()
            if isFavorite {
                Button("Remove from favorites") { model.removeFavorite(favorite) }
            } else {
                Button("Add to favorites") { model.keep(favorite) }
                Button("Remove from list") { model.dismiss(favorite) }
            }
        }
    }

    /// As tall as the start button, so the row keeps its height when the button takes over on hover.
    private var trailing: some View {
        HStack(spacing: 2) {
            if isBusy {
                ProgressView().controlSize(.small).frame(width: 24, height: 22)
            } else if hovering || isExpanded, favorite.launch != nil {
                if !isFavorite {
                    IconButton(systemName: "xmark", help: "Remove from list") { model.dismiss(favorite) }
                }
                IconButton(systemName: "play.fill", help: "Start (or double-click the row)", hoverTint: .green) { model.start(favorite) }
                    .accessibilityLabel("Start \(favorite.title)")
            } else if let port = favorite.ports.first {
                Text(verbatim: ":\(port)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 22)
        .fixedSize()
    }

    /// How it starts: the command in monospace like a running server's, or a
    /// sentence when there's no command to show.
    @ViewBuilder private var launchDescription: some View {
        switch favorite.launch {
        case let .terminal(command, _):
            launchCommand(command)
        case let .brew(formula):
            launchCommand("brew services start \(formula)")
        case let .docker(container):
            launchCommand("docker start \(container)")
        case nil:
            Text("Bridge doesn't know how to start it")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func launchCommand(_ command: String) -> some View {
        Text(verbatim: command)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(3)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// A process listening on a port, built to be scanned like a repository row: one line with its port
/// (and its CPU or memory only when they're high), the buttons in their place under the pointer, and
/// the rest behind a click. System processes are dimmed, so the dev servers stand out.
struct ProcessRow: View {
    let process: ListeningProcess
    /// Not observed, only used in actions. A row that observed the model was redrawn, every row of it,
    /// on every scan (a few seconds apart, with new CPU figures for some process) and whenever any
    /// server was busy; as values, only the rows whose server changed redraw.
    let model: PortModel
    let isFavorite: Bool
    let isBusy: Bool
    let runsInBackground: Bool
    /// Whether this row is open (see `ExpandedServer.Row`).
    @ObservedObject private var rowState: ExpandedServer.Row
    private var expansion: ExpandedServer { .shared }
    @State private var hovering = false
    @State private var showNewGroup = false
    @State private var atLeadingEdge = false
    /// 1 while the port glows green for a server that just began answering, fading to 0. Starts at 1
    /// (from `init`) so the first frame already has it; set in `onAppear` it would be skipped.
    @State private var glow: Double

    init(process: ListeningProcess, model: PortModel) {
        self.process = process
        self.model = model
        isFavorite = model.isFavorite(process)
        isBusy = model.busy.contains(process.id)
        runsInBackground = model.runInBackground
        rowState = ExpandedServer.shared.row(process.id)
        _glow = State(initialValue: model.justStartedListening(process) ? 1 : 0)
    }

    private var isExpanded: Bool { rowState.isExpanded }
    /// Without a container, a Docker row is Docker Desktop's own backend, which runs every container.
    private var canStop: Bool { !(process.framework == .docker && process.container == nil) }
    private var canRestart: Bool { !process.isSystem && canStop }
    private var isQuiet: Bool { process.isSystem && !hovering && !isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                title
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // The state while resting, the buttons under the pointer, while open or while restarting.
                // Both laid out, one invisible, so the name doesn't move when they swap.
                let showsActions = hovering || isExpanded || isBusy || showNewGroup
                ZStack(alignment: .trailing) {
                    badges.fadesIn(!showsActions)
                    actions.fadesIn(showsActions)
                }
            }
            // One height in both tabs, so a repository and a server row are equally tall.
            .frame(height: PanelRowMetrics.lineHeight)
            // The whole top line, gaps included, folds an open row away again. Buttons in it still take their own clicks.
            .contentShape(Rectangle())
            .onTapGesture { expansion.toggle(process.id) }

            if isExpanded {
                details.revealsGently()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        // Inset and rounded like a sidebar's highlight, as in the Repos tab; an open row keeps it.
        .panelHighlight(hovering || isExpanded || showNewGroup, .quinary)
        // The whole row, gaps included, takes the hover; the clear highlight alone doesn't.
        .contentShape(Rectangle())
        // A closed row opens from a click anywhere on it. An open one only from its top line (above),
        // so selecting its command's text isn't taken for folding it.
        .gesture(TapGesture().onEnded { expansion.toggle(process.id) }, including: isExpanded ? .subviews : .all)
        // What most people try first on a server: double-click to open it. Alongside the single click,
        // not instead of it, so opening a row isn't delayed while waiting for a second click; the two
        // single clicks of a double-click open and close the row again.
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.open(process) })
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .tracksLeadingEdge($atLeadingEdge)
        .newServerGroupPopover($showNewGroup, item: .process(process), title: process.title)
        // Same as a repository row: the folder lives behind a right-click instead of a button.
        .contextMenu {
            // Opening and copying the address are expected on the row itself, not only on the link.
            if let port = process.ports.first, let url = URL(string: "http://localhost:\(port)") {
                Button("Open localhost:\(String(port))") { NSWorkspace.shared.open(url) }
                Button("Copy localhost:\(String(port))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Divider()
            }
            if canRestart {
                Button("Restart") { model.restart(process) }
            }
            if canStop {
                Button("Stop") { model.stop(process) }
                Button("Force stop") { model.stop(process, force: true) }
            }
            if FileManager.default.fileExists(atPath: Restarter.logFile(title: process.title).path) {
                Button("Show log") { NSWorkspace.shared.open(Restarter.logFile(title: process.title)) }
            }
            if canRestart || canStop { Divider() }
            Button(isFavorite ? "Remove from favorites" : "Add to favorites") { model.toggleFavorite(process) }
            ServerGroupMenu(item: .process(process), showNewGroup: $showNewGroup)
            if let root = process.projectRoot, root != "/" {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
                ForEach(Editor.installed.filter { $0.name != "Finder" }) { editor in
                    Button("Open in \(editor.name)") { editor.open(root) }
                }
            }
        }
    }

    private var title: some View {
        HStack(spacing: 0) {
            LeadingStar(isFavorite: isFavorite, isShown: atLeadingEdge) {
                model.toggleFavorite(process)
            }
            HStack(spacing: 6) {
                if let framework = process.framework {
                    FrameworkLogo(framework: framework, size: 14)
                        .opacity(isQuiet ? 0.5 : 1)
                }
                Text(verbatim: process.title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Its port in grey, and CPU or memory only when they're high enough to need a look.
    private var badges: some View {
        HStack(spacing: 10) {
            UsageWarning(process: process)
            if let port = process.ports.first {
                let text = process.ports.count > 1 ? ":\(port) +\(process.ports.count - 1)" : ":\(port)"
                Text(verbatim: text)
                    // The moment it can be opened: the port lights up green once and settles to grey,
                    // so a server started and left to boot says when it's ready without being watched.
                    .overlay {
                        Text(verbatim: text)
                            .foregroundStyle(.green)
                            .shadow(color: .green.opacity(0.7), radius: 4)
                            .opacity(glow)
                            .allowsHitTesting(false)
                    }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .fixedSize()
        .onAppear {
            guard glow > 0 else { return }
            // Held a moment so it's seen, then fades. Only opacity, so nothing else moves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.9)) { glow = 0 }
            }
        }
    }

    /// The first port as a link (the rest are in the open row), restart and stop. One line as tall as
    /// the resting badges, so the row keeps its height when these take their place.
    private var actions: some View {
        HStack(spacing: 2) {
            if let port = process.ports.first {
                PortLink(port: port)
                    .padding(.trailing, 4)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 22)
            } else if canRestart {
                IconButton(systemName: "arrow.clockwise", help: restartHelp, hoverTint: .accentColor) {
                    model.restart(process)
                }
                .accessibilityLabel("Restart \(process.title)")
            }
            if canStop {
                StopButton(process: process, model: model)
            }
            // As in a repository row: says the row opens, and turns when it has.
            Button { expansion.toggle(process.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .disclosureRotation(isExpanded)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(.panel)
            .panelTooltip(isExpanded ? "Fold away" : "Show its ports, process, uptime and command")
            .accessibilityLabel(isExpanded ? "Fold" : "Unfold")
        }
        .frame(height: 22)
        .fixedSize()
    }

    /// The open row: what it is, its process and uptime, every port, and the command that runs it.
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if process.ports.count > 1 {
                HStack(spacing: 10) {
                    ForEach(process.ports, id: \.self) { PortLink(port: $0) }
                }
            }
            Text(verbatim: process.command)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var detailLine: String {
        [
            process.framework?.title ?? process.name,
            process.container == nil ? "PID \(process.pid)" : nil,
            process.uptimeText.map { "up \($0)" },
            process.cpu.map { "CPU \(UsageFormat.cpu($0))" },
            process.memoryText,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var restartHelp: String {
        if process.container != nil { return "Restart with docker restart" }
        if process.isDatabase { return "Restart with brew services" }
        return runsInBackground ? "Restart in the background" : "Restart – opens in a new terminal window"
    }
}

/// Stop, or force stop while ⌥ is held, as a Mac user tries for "stop harder" (like Force Quit in the
/// Dock menu). Its own view, so only the hovered row's button watches ⌥, not every row.
private struct StopButton: View {
    let process: ListeningProcess
    /// Only used when clicked (see `ProcessRow.model`).
    let model: PortModel
    @ObservedObject private var keys = ModifierKeys.shared

    var body: some View {
        IconButton(
            systemName: keys.option ? "xmark.octagon.fill" : "stop.fill",
            help: keys.option ? "Force stop (SIGKILL)" : "Stop the process\nHold ⌥ to force stop",
            hoverTint: .red
        ) {
            model.stop(process, force: keys.option)
        }
        .accessibilityLabel(keys.option ? "Force stop \(process.title)" : "Stop \(process.title)")
    }
}

/// A port as the same quiet link the Repos tab uses for a running app's address.
struct PortLink: View {
    let port: Int

    var body: some View {
        let url = URL(string: "http://localhost:\(port)")!
        AddressLink(url: url, label: "localhost:\(port)")
    }
}

/// CPU or memory in a resting row, only when it's high: orange from 30% CPU or 2 GB, red from 80% CPU.
/// Everything else stays out of the row, so color there means something needs a look.
private struct UsageWarning: View {
    let process: ListeningProcess

    var body: some View {
        // The figures roll to their new values on each scan, like an odometer, rather than flicker.
        if let cpu = process.cpu, cpu >= 30 {
            Text(verbatim: "CPU \(UsageFormat.cpu(cpu))")
                .foregroundStyle(cpu >= 80 ? .red : .orange)
                .contentTransition(.numericText(value: cpu))
                .animation(.snappy, value: cpu)
        }
        if let memory = process.memoryText, let bytes = process.memory, bytes >= 2048 {
            Text(verbatim: memory)
                .foregroundStyle(.orange)
                .contentTransition(.numericText(value: Double(bytes)))
                .animation(.snappy, value: bytes)
        }
    }
}
