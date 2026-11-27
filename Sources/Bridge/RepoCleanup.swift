import AppKit
import Shared
import SwiftUI

// MARK: - Undo

/// The last removal from Bridge, for a while, so it can be undone: one repository from a row's menu
/// or dozens from Clean up. Removing is cheap to undo, so it's done at once and offered back rather
/// than asked about first; folders that went to the Trash are moved back from it.
@MainActor
final class RepoRemoval: ObservableObject {
    static let shared = RepoRemoval()

    struct Removal: Identifiable {
        let id = UUID()
        let paths: [String]
        /// Where the folders moved to the Trash went, by their old path.
        let trashed: [String: URL]
        let groups: RepoGroups.Snapshot
        /// The main window's repository, when it was one of these.
        let wasSelected: String?
    }

    @Published private(set) var last: Removal?
    /// Why an undo couldn't put everything back, said in the same line until dismissed.
    @Published private(set) var failure: String?

    /// Long enough to notice a mistake; after that an old Undo line would only be in the way.
    private static let offeredFor: TimeInterval = 10 * 60

    private init() {}

    func record(_ paths: [String], trashed: [String: URL], groups: RepoGroups.Snapshot, wasSelected: String?) {
        let removal = Removal(paths: paths, trashed: trashed, groups: groups, wasSelected: wasSelected)
        last = removal
        failure = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offeredFor) { [weak self] in
            if self?.last?.id == removal.id { self?.last = nil }
        }
    }

    func dismiss() {
        last = nil
        failure = nil
    }

    /// Moves trashed folders back (unless something has taken their place meanwhile) and adds the
    /// repositories again, in the groups they were in. Color, star and order were kept by path.
    func undo(_ store: RepoStore) {
        guard let removal = last else { return }
        last = nil
        var back: [String] = []
        var failed: [String] = []
        for path in removal.paths {
            if let url = removal.trashed[path], !FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: path))
                } catch {
                    failed.append((path as NSString).lastPathComponent)
                    continue
                }
            }
            back.append(path)
        }
        store.addRoots(back)
        RepoGroups.shared.restore(removal.groups, for: Set(back))
        if let selected = removal.wasSelected, back.contains(selected) { store.selectedPath = selected }
        if !failed.isEmpty {
            failure = "Couldn't put \(Self.list(failed)) back from the Trash."
        }
    }

    /// What the last removal did, in a few words.
    func summary(of removal: Removal) -> String {
        let count = removal.paths.count
        let trashed = removal.trashed.count
        let only = (removal.paths.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        if trashed == 0 {
            return count == 1 ? "Removed \(only) from Bridge." : "Removed \(count) repositories from Bridge."
        }
        if trashed == count {
            return count == 1 ? "Moved \(only) to the Trash." : "Moved \(count) repositories to the Trash."
        }
        return "Removed \(count) repositories, \(trashed) of them to the Trash."
    }

    static func list(_ names: [String]) -> String {
        names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }
}

/// The line at the top of the list after repositories were removed, with Undo. Observes the removal
/// alone, so the list doesn't redraw with it.
struct RemovalUndoRow: View {
    /// Not observed: it changes with every repository's every change.
    let store: RepoStore
    var showsDivider = true
    @ObservedObject private var removal = RepoRemoval.shared

    var body: some View {
        if let message = removal.last.map(removal.summary) ?? removal.failure {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if removal.last != nil {
                    Button("Undo") { removal.undo(store) }
                        .buttonStyle(.link)
                }
                IconButton(systemName: "xmark", help: "Dismiss") { removal.dismiss() }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .revealsGently()
            if showsDivider { PanelDivider() }
        }
    }
}

// MARK: - What's suggested

/// Whether a repository in Bridge is suggested for cleaning up, and what its row says about it.
/// Suggested: folders that are gone, older copies of a repository listed twice, and repositories
/// without a commit in half a year. Never suggested, though they can be ticked: anything where work
/// is going on (changes, unpushed commits, a branch not pushed, a server running, an agent session)
/// and favorites. A cleanup is for what's stale, so nothing in use is ticked behind the user's back.
struct CleanupAssessment {
    enum Kind {
        /// Ticked to begin with.
        case suggested
        /// Not ticked, with nothing to warn about.
        case kept
        /// Not ticked: it holds work that exists only on this Mac.
        case inUse
        /// Not read yet, so it's neither ticked nor called anything.
        case reading
    }

    let kind: Kind
    let note: String?
    /// The newest commit on a local branch.
    let activity: Date?
    /// No remote: the folder is the only copy.
    var isOnlyCopy = false
    var warns: Bool { kind == .inUse || isOnlyCopy }

    /// Half a year, as on the import page: older than that is set aside rather than worked on.
    static let staleAfter: TimeInterval = 182 * 24 * 3600

    @MainActor
    static func of(_ repo: Repository, newestCopy: [String: String], sessions: Int) -> CleanupAssessment {
        if repo.isMissing { return .init(kind: .suggested, note: "Folder missing", activity: nil) }
        guard let status = repo.status else { return .init(kind: .reading, note: nil, activity: nil) }
        let activity = repo.branches.filter { !$0.isRemote }.map(\.date).max()

        if !status.files.isEmpty {
            return .init(kind: .inUse, note: status.files.count == 1 ? "1 change" : "\(status.files.count) changes", activity: activity)
        }
        if status.ahead > 0 { return .init(kind: .inUse, note: "\(status.ahead) unpushed", activity: activity) }
        if repo.canPublish { return .init(kind: .inUse, note: "Branch not pushed", activity: activity) }
        if sessions > 0 { return .init(kind: .kept, note: "Agent session", activity: activity) }
        if repo.server.isActive { return .init(kind: .kept, note: "Server running", activity: activity) }
        if repo.isFavorite { return .init(kind: .kept, note: "Favorite", activity: activity) }

        // Without a remote the folder is the only copy: fine to take out of Bridge, but said in
        // orange, as moving it to the Trash would lose it.
        let noRemote = repo.remotes.isEmpty
        if let key = hostedKey(of: repo), let newest = newestCopy[key], newest != repo.path {
            return .init(kind: .suggested, note: "Older copy", activity: activity)
        }
        guard let activity else {
            return .init(kind: .suggested, note: noRemote ? "No commits, no remote" : "No commits", activity: nil, isOnlyCopy: noRemote)
        }
        let when = activity.relative
        let note = noRemote ? "No remote, \(when)" : when
        return .init(kind: activity < Date().addingTimeInterval(-staleAfter) ? .suggested : .kept, note: note, activity: activity,
                     isOnlyCopy: noRemote)
    }

    @MainActor
    static func hostedKey(of repo: Repository) -> String? {
        repo.host.flatMap { host in repo.hostedName.map { RepoImport.key(host, $0) } }
    }

    /// For each repository listed more than once (the same remote), the copy committed to last.
    @MainActor
    static func newestCopies(in repos: [Repository]) -> [String: String] {
        var newest: [String: (path: String, date: Date)] = [:]
        for repo in repos where !repo.isMissing {
            guard let key = hostedKey(of: repo) else { continue }
            let date = repo.branches.filter { !$0.isRemote }.map(\.date).max() ?? .distantPast
            if newest[key].map({ date > $0.date }) ?? true { newest[key] = (repo.path, date) }
        }
        return newest.mapValues(\.path)
    }
}

// MARK: - The page

/// Clean up repositories: every repository in Bridge, in its group, to tick before they're all taken
/// out at once, with what's stale ticked to begin with (`CleanupAssessment`). The counterpart of Find
/// repositories, laid out the same way; a page of the menu bar panel (`PanelPage.cleanUp`) and a
/// popover in the main window. Removing only takes them out of Bridge and is undone from the list
/// (`RepoRemoval`); the folders go to the Trash only when switched on, after one alert that lists
/// everything that exists only on this Mac.
struct CleanUpRepositoriesForm: View {
    @ObservedObject var store: RepoStore
    var isPage = false
    /// Called with what went wrong, for the panel to show, or nil.
    let done: (String?) -> Void
    @ObservedObject private var groups = RepoGroups.shared
    @State private var selected: Set<String> = []
    /// Repositories whose suggestion has been applied: one read later doesn't undo what the user ticked.
    @State private var defaulted: Set<String> = []
    @State private var filter = ""
    @State private var opened: Set<String> = []
    /// Off each time the page opens: the Trash is the exception, not something to find left on.
    @State private var movesToTrash = false
    @State private var isChecking = false
    @FocusState private var filterFocused: Bool

    private struct Item {
        let repo: Repository
        let assessment: CleanupAssessment
    }

    var body: some View {
        let items = assessed()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !isPage {
                    Text("Clean up repositories").font(.headline)
                }
                HStack(spacing: 6) {
                    TextField("Filter", text: $filter)
                        .focused($filterFocused)
                        .panelField()
                    PanelMenu("checklist", help: "Select") {
                        Button("Select suggested") { selectSuggested(items) }
                        Button("Select all") { selected = Set(items.map(\.repo.path)) }
                        Button("Select none") { selected = [] }
                    }
                }
            }
            .padding(12)
            PanelDivider()
            MenuPanelList(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 0) {
                    list(items)
                }
                .padding(.vertical, 6)
            }
            PanelDivider()
            footer.padding(12)
        }
        .frame(width: isPage ? nil : 460)
        .frame(maxWidth: isPage ? .infinity : nil, alignment: .leading)
        .onAppear {
            store.refreshAll()
            applySuggestions()
        }
        .focusesWhenShown { filterFocused = true }
        // Repositories read after the page opened get their suggestion then.
        .onReceive(store.objectWillChange) { _ in
            DispatchQueue.main.async { applySuggestions() }
        }
    }

    private func assessed() -> [Item] {
        let newest = CleanupAssessment.newestCopies(in: store.repos)
        return store.repos.map { repo in
            Item(repo: repo, assessment: .of(repo, newestCopy: newest,
                                             sessions: BackgroundClaude.shared.sessions(in: repo.path).filter { [.working, .blocked].contains($0.state) }.count))
        }
    }

    private func applySuggestions() {
        for item in assessed() where item.assessment.kind != .reading && defaulted.insert(item.repo.path).inserted {
            if item.assessment.kind == .suggested { selected.insert(item.repo.path) }
        }
    }

    private func selectSuggested(_ items: [Item]) {
        selected = Set(items.filter { $0.assessment.kind == .suggested }.map(\.repo.path))
    }

    // MARK: List

    private func matches(_ repo: Repository) -> Bool {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        return filter.isEmpty || [repo.displayName, repo.path, repo.hostedName ?? ""].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    /// Folders that are gone first, then the longest untouched, so what's ticked is at the top of
    /// each group; repositories still being read go last.
    private func ordered(_ items: [Item]) -> [Item] {
        func rank(_ item: Item) -> (Int, Double) {
            if item.repo.isMissing { return (0, 0) }
            if item.assessment.kind == .reading { return (2, 0) }
            return (1, item.assessment.activity?.timeIntervalSince1970 ?? 0)
        }
        return items.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.repo.name.localizedStandardCompare(b.repo.name) == .orderedAscending
        }
    }

    /// The repositories in their groups, in the groups' order, those without one last; one section
    /// when there are no groups or they're switched off.
    private func sections(_ items: [Item]) -> [(id: String, title: String, items: [Item])] {
        guard !items.isEmpty else { return [] }
        guard groups.showsGroups, !groups.names.isEmpty else { return [("all", "All repositories", ordered(items))] }
        let byGroup = Dictionary(grouping: items) { groups.group(ofRepo: $0.repo.path) }
        var sections = groups.names.compactMap { name in byGroup[name].map { (id: "group:" + name, title: name, items: ordered($0)) } }
        if let rest = byGroup[nil] {
            sections.append((id: "none", title: sections.isEmpty ? "All repositories" : "Not in a group", items: ordered(rest)))
        }
        return sections
    }

    @ViewBuilder
    private func list(_ all: [Item]) -> some View {
        let items = all.filter { matches($0.repo) }
        let reading = all.filter { $0.assessment.kind == .reading }.count
        ChecklistHeading(title: "In Bridge", isLoading: reading > 0)
        if items.isEmpty {
            ChecklistStatusLine { Text(store.repos.isEmpty ? "No repositories in Bridge." : "No matches.") }
        } else if all.allSatisfy({ $0.assessment.kind != .suggested && $0.assessment.kind != .reading }) && filter.isEmpty {
            ChecklistStatusLine { Text("Nothing looks stale. Tick what you want to remove.") }
        }
        let sections = sections(items)
        ForEach(sections, id: \.id) { section in
            let open = sections.count == 1 || opened.contains(section.id) || !filter.trimmingCharacters(in: .whitespaces).isEmpty
            ChecklistGroupHeader(title: section.title, ids: section.items.map(\.repo.path), isOpen: open,
                                 toggleOpen: { toggle(section.id) }, selected: $selected)
            if open {
                ForEach(section.items, id: \.repo.path) { item in
                    ChecklistRow(isOn: binding(item.repo.path), title: item.repo.displayName,
                                 // The folder it's in, when its name says something the name shown doesn't.
                                 detail: item.repo.displayName == item.repo.name ? nil : item.repo.name,
                                 trailing: item.assessment.note, trailingWarns: item.assessment.warns) {
                        if item.repo.isMissing {
                            Image(systemName: "questionmark.folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            FrameworkLogo(framework: item.repo.framework, size: 14)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) },
                set: { if $0 { selected.insert(path) } else { selected.remove(path) } })
    }

    // MARK: Footer

    /// What's ticked, as listed now (a repository removed elsewhere meanwhile drops out).
    private var chosen: [Repository] { store.repos.filter { selected.contains($0.path) } }

    private var footer: some View {
        let count = chosen.count
        return VStack(alignment: .leading, spacing: 8) {
            PanelSwitch("Also move the folders to the Trash", isOn: $movesToTrash)
            Text(movesToTrash
                 ? "Anything that exists only on this Mac is listed before a folder moves. Undo puts them back."
                 : "They leave Bridge only: the folders stay where they are, and Undo brings them back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking \(count == 1 ? "1 folder" : "\(count) folders")…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isPage {
                    Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                }
                Button(movesToTrash ? (count == 0 ? "Move to Trash" : "Move \(count) to Trash") : (count == 0 ? "Remove" : "Remove \(count)")) {
                    run()
                }
                .keyboardShortcut(.defaultAction)
                .prominentButton()
                .disabled(count == 0 || isChecking)
            }
        }
    }

    private func run() {
        let chosen = chosen
        guard !chosen.isEmpty else { return }
        guard movesToTrash else {
            store.remove(chosen)
            done(nil)
            return
        }
        isChecking = true
        Task {
            let risks = await Self.risks(of: chosen.filter { !$0.isMissing }.map(\.path))
            isChecking = false
            guard let confirmed = Self.confirmTrash(chosen, risks: risks) else { return }
            let result = store.trash(confirmed)
            done(result.failures.isEmpty ? nil : "Couldn't move \(RepoRemoval.list(result.failures)) to the Trash.")
        }
    }

    /// What would be lost with each folder, checked side by side (git itself runs at most eight at a time).
    private static func risks(of paths: [String]) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            for path in paths { group.addTask { (path, await RepoStore.trashRisks(at: path)) } }
            var risks: [String: [String]] = [:]
            for await (path, found) in group where !found.isEmpty { risks[path] = found }
            return risks
        }
    }

    /// One alert for the whole batch: with nothing at stake a plain confirmation, otherwise what each
    /// folder holds that exists only here, and the choice to leave those out. Return cancels then.
    /// Returns what to move, or nil to move nothing.
    private static func confirmTrash(_ repos: [Repository], risks: [String: [String]]) -> [Repository]? {
        let risky = repos.filter { risks[$0.path] != nil }
        let safe = repos.filter { risks[$0.path] == nil }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let folders = repos.count == 1 ? repos[0].name : "\(repos.count) folders"
        if risky.isEmpty {
            alert.messageText = "Move \(folders) to the Trash?"
            alert.informativeText = "Everything in them is committed and pushed. Undo in Bridge puts them back, and the repositories on GitHub or GitLab aren't touched."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? repos : nil
        }
        alert.messageText = risky.count == 1
            ? "\(risky[0].name) has work that's only on this Mac"
            : "\(risky.count) of the \(repos.count) have work that's only on this Mac"
        let shown = risky.prefix(8).map { "• \($0.name): " + (risks[$0.path] ?? []).joined(separator: "; ") }
        alert.informativeText = shown.joined(separator: "\n")
            + (risky.count > 8 ? "\n• and \(risky.count - 8) more" : "")
            + "\n\nLost if you empty the Trash. The repositories on GitHub or GitLab aren't touched."
        alert.alertStyle = .critical
        let all = alert.addButton(withTitle: repos.count == 1 ? "Move to Trash Anyway" : "Move All \(repos.count) Anyway")
        all.hasDestructiveAction = true
        all.keyEquivalent = ""
        if !safe.isEmpty {
            alert.addButton(withTitle: safe.count == 1 ? "Move Only \(safe[0].name)" : "Move Only the \(safe.count) Others")
        }
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return repos
        case .alertSecondButtonReturn where !safe.isEmpty: return safe
        default: return nil
        }
    }
}
