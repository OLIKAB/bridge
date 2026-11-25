import AppKit
import Combine
import Foundation
import Shared

/// How repositories are ordered in the panel and the main window's sidebar. Sorting by framework and
/// by local changes were dropped: the logo already shows the framework, and rows with nothing going on
/// are dimmed. A saved order that's gone falls back to `.color`.
enum RepoSortOrder: String, CaseIterable, Identifiable {
    /// By color, then within a color in the order dragged into. Called Color rather than Custom: the
    /// color decides the order, and dragging only fine-tunes it within one.
    case color, name, recent

    var id: String { rawValue }
    var name: String {
        switch self {
        case .color: "Color"
        case .name: "Name"
        case .recent: "Latest commit"
        }
    }
}

@MainActor
final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repository] = []
    @Published var selectedPath = UserDefaults.standard.string(forKey: "selectedRepository") {
        didSet { UserDefaults.standard.set(selectedPath, forKey: "selectedRepository") }
    }
    @Published var sortOrder = UserDefaults.standard.string(forKey: "repositorySortOrder").flatMap(RepoSortOrder.init) ?? .color {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "repositorySortOrder") }
    }
    @Published var hideUncolored = UserDefaults.standard.bool(forKey: "hideUncoloredRepositories") {
        didSet { UserDefaults.standard.set(hideUncolored, forKey: "hideUncoloredRepositories") }
    }
    @Published var favoritesOnly = UserDefaults.standard.bool(forKey: "showOnlyFavoriteRepositories") {
        didSet { UserDefaults.standard.set(favoritesOnly, forKey: "showOnlyFavoriteRepositories") }
    }
    @Published var hideInactive = UserDefaults.standard.bool(forKey: "hideInactiveRepositories") {
        didSet { UserDefaults.standard.set(hideInactive, forKey: "hideInactiveRepositories") }
    }
    @Published var autoFetch = UserDefaults.standard.object(forKey: "autoFetch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFetch, forKey: "autoFetch") }
    }
    /// Pinned Claude skills under each repository in the panel; notes stay visible either way.
    @Published var showSkills = UserDefaults.standard.object(forKey: "showSkills") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSkills, forKey: "showSkills") }
    }
    @Published var hotKeyOn = UserDefaults.standard.object(forKey: "hotKey") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hotKeyOn, forKey: "hotKey")
            for hotKey in [HotKey.repos, HotKey.servers] { hotKeyOn ? hotKey.register() : hotKey.unregister() }
        }
    }
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet {
            LoginItem.set(launchAtLogin)
            if LoginItem.isEnabled != launchAtLogin { launchAtLogin = LoginItem.isEnabled }
        }
    }
    /// Agent buttons start the agent with the browser (Claude's `--chrome`); DevWorkspace reads the same default.
    @Published var agentWithBrowser = UserDefaults.standard.bool(forKey: DevWorkspace.agentBrowserKey) {
        didSet { UserDefaults.standard.set(agentWithBrowser, forKey: DevWorkspace.agentBrowserKey) }
    }
    /// Terminal windows opened from Bridge use the "Clear Dark" profile; DevWorkspace reads the same default.
    @Published var darkTerminal = UserDefaults.standard.bool(forKey: DevWorkspace.darkTerminalKey) {
        didSet { UserDefaults.standard.set(darkTerminal, forKey: DevWorkspace.darkTerminalKey) }
    }
    @Published var rexSplit = UserDefaults.standard.object(forKey: DevWorkspace.rexSplitKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(rexSplit, forKey: DevWorkspace.rexSplitKey) }
    }
    @Published private(set) var isFetchingAll = false
    /// Typed at the top of the panel; the Claude buttons start Claude with it while it's there.
    /// Not saved, so a forgotten `/init` doesn't run in some repository days later.
    @Published var claudePrompt = ""

    /// `claudePrompt` without surrounding whitespace, or nil when there's nothing to send.
    var pendingClaudePrompt: String? {
        let prompt = claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private var fetchTimer: Timer?
    private var serverTimer: Timer?
    private var isScanningServers = false
    /// Missing repositories being looked for, so repeated refreshes don't start the same search twice.
    private var searching: Set<String> = []
    /// Forwards each repository's changes, so views of the whole list (the menu bar badge) update too.
    private var repoChanges: [AnyCancellable] = []

    init() {
        // Launch at login is on by default; only enabled once so turning it off sticks.
        if !UserDefaults.standard.bool(forKey: "didSetUpLoginItem") {
            UserDefaults.standard.set(true, forKey: "didSetUpLoginItem")
            LoginItem.set(true)
            launchAtLogin = LoginItem.isEnabled
        }
        if hotKeyOn { HotKey.repos.register(); HotKey.servers.register() }
        let paths = UserDefaults.standard.stringArray(forKey: "repositories") ?? []
        setRepos(paths.map(Repository.init))

        fetchTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoFetch else { return }
                await self.fetchAll(quietly: true)
            }
        }
        fetchTimer?.tolerance = 60
        // Cheap (libproc, no processes spawned), so often enough that a server started in a terminal shows up quickly.
        serverTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanServers() }
        }
        serverTimer?.tolerance = 1
        scanServers()
        if autoFetch {
            Task { await fetchAll(quietly: true) }
        }
    }

    var selected: Repository? {
        repos.first { $0.path == selectedPath } ?? repos.first
    }

    /// `repos` in the order chosen in the sort menu. `repos` is kept sorted by name, and the sorts
    /// below are stable, so repositories that tie stay in name order.
    /// Repository paths in the order they've been dragged into. Only used when sorted by color, and only
    /// within a color: the color (and favorites first) decides the rest.
    @Published private(set) var manualOrder = UserDefaults.standard.stringArray(forKey: "repositoryManualOrder") ?? [] {
        didSet { UserDefaults.standard.set(manualOrder, forKey: "repositoryManualOrder") }
    }

    /// Why `repo` can't be dragged next to `target` in the list, or nil when it can. The list's order
    /// comes from the sorting, so a repository can only move among the ones the sorting puts beside it.
    func reorderBlocker(_ repo: Repository, nextTo target: Repository) -> String? {
        guard sortOrder == .color else { return "Sorted by \(sortOrder.name.lowercased()). Sort by color to arrange by hand" }
        if repo.isFavorite != target.isFavorite { return repo.isFavorite ? "Favorites stay on top" : "Only favorites go up here" }
        if repo.color != target.color { return repo.color.map { "Only among \($0.name.lowercased()) repositories" } ?? "Only among repositories without a color" }
        return nil
    }

    /// Puts `repo` right before or after `target` (see `reorderBlocker`).
    func move(_ repo: Repository, nextTo target: Repository, after: Bool) {
        guard repo !== target, reorderBlocker(repo, nextTo: target) == nil else { return }
        var order = sortedRepos.map(\.path).filter { $0 != repo.path }
        guard let index = order.firstIndex(of: target.path) else { return }
        order.insert(repo.path, at: after ? index + 1 : index)
        manualOrder = order
    }

    var sortedRepos: [Repository] {
        // Starred repositories come first, each group in the chosen order.
        let ordered = orderedRepos
        return ordered.filter(\.isFavorite) + ordered.filter { !$0.isFavorite }
    }

    private var orderedRepos: [Repository] {
        switch sortOrder {
        case .color:
            // Colored repositories first, grouped in the order of the color menu, then the rest; within
            // a color in the order they were dragged into (`manualOrder`), the rest by name.
            let manual = Dictionary(manualOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return stableSorted { repo in
                let color = repo.color.flatMap(RepoColor.allCases.firstIndex) ?? RepoColor.allCases.count
                return color * 1_000_000 + (manual[repo.path] ?? 999_999)
            }
        case .name:
            // By the name shown, which is only known once the remote's been read, so not at load.
            return stableSorted { $0.displayName.lowercased() }
        case .recent:
            // Newest commit on any local branch; repositories not loaded yet go last.
            return stableSorted { repo in -(repo.branches.filter { !$0.isRemote }.map(\.date.timeIntervalSince1970).max() ?? 0) }
        }
    }

    /// `sortedRepos` without the ones hidden by the filters in the sort menu. Inactive means no dev
    /// server running, whether Bridge started it or it was found running from a terminal.
    /// A repository with a background Claude session waiting for an answer always shows, as that's
    /// where the session is, and a notification about it brings you here.
    var visibleRepos: [Repository] {
        sortedRepos.filter { isShown($0, favoritesOnly: favoritesOnly, hideUncolored: hideUncolored, hideInactive: hideInactive) }
    }

    private func isShown(_ repo: Repository, favoritesOnly: Bool, hideUncolored: Bool, hideInactive: Bool) -> Bool {
        ((!favoritesOnly || repo.isFavorite) && (!hideUncolored || repo.color != nil) && (!hideInactive || repo.server.isActive))
            || BackgroundClaude.shared.sessions(in: repo.path).contains { $0.state == .blocked }
    }

    var isFiltering: Bool { favoritesOnly || hideUncolored || hideInactive }

    /// Whether turning on one more "Show only" filter (with those already on) would leave something to
    /// show. The menu disables the filters that would empty the list: an empty list looked broken.
    func showsAny(favoritesOnly: Bool? = nil, hideUncolored: Bool? = nil, hideInactive: Bool? = nil) -> Bool {
        repos.contains {
            isShown($0, favoritesOnly: favoritesOnly ?? self.favoritesOnly, hideUncolored: hideUncolored ?? self.hideUncolored,
                    hideInactive: hideInactive ?? self.hideInactive)
        }
    }

    private func stableSorted<Key: Comparable>(by key: (Repository) -> Key) -> [Repository] {
        repos.enumerated()
            .map { (key: key($0.element), offset: $0.offset, repo: $0.element) }
            .sorted { ($0.key, $0.offset) < ($1.key, $1.offset) }
            .map(\.repo)
    }

    /// Repos with changed files or unpushed commits, for the menu bar badge.
    var localWorkCount: Int { repos.filter(\.hasLocalWork).count }

    private func setRepos(_ newRepos: [Repository]) {
        repos = newRepos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The server's too, so the "hide inactive" filter follows servers starting and stopping.
        repoChanges = repos.flatMap { repo in
            [repo.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
             repo.server.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
        }
        for repo in repos {
            repo.onMissing = { [weak self, weak repo] in
                guard let self, let repo else { return }
                Task { await self.findMoved(repo) }
            }
        }
        UserDefaults.standard.set(repos.map(\.path), forKey: "repositories")
        BackgroundClaude.shared.repoPaths = repos.map(\.path)
    }

    // MARK: Moved folders

    /// Follows a renamed or moved repository folder instead of showing it as missing.
    private func findMoved(_ repo: Repository) async {
        guard !searching.contains(repo.path) else { return }
        searching.insert(repo.path)
        defer { searching.remove(repo.path) }
        let known = Set(repos.map(\.path))
        let old = repo.path
        let found = await Task.detached { Repository.movedPath(of: old) }.value
        if let found, !known.contains(found) {
            relocate(repo, to: found)
        } else if let found = await renamedSibling(of: old, known: known) {
            relocate(repo, to: found)
        }
    }

    /// When the bookmark doesn't find it: the one new repository next to where it was whose remote
    /// still has the old name (renaming the folder doesn't rename the remote).
    private func renamedSibling(of path: String, known: Set<String>) async -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent.lowercased()
        let siblings = await Task.detached {
            ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
                .map { (parent as NSString).appendingPathComponent($0) }
                .filter { !known.contains($0) && FileManager.default.fileExists(atPath: $0 + "/.git") }
        }.value
        var matches: [String] = []
        for sibling in siblings {
            let urls = await Git.run(["remote", "-v"], in: sibling).stdout.lowercased()
            if urls.contains("/\(name).git") || urls.contains("/\(name) ") || urls.contains(":\(name).git") { matches.append(sibling) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Replaces `repo` with the same repository at `newPath`, keeping its settings.
    func relocate(_ repo: Repository, to newPath: String) {
        guard repos.contains(where: { $0 === repo }) else { return }
        if repos.contains(where: { $0.path == newPath }) {
            remove(repo)
            return
        }
        Repository.moveSettings(from: repo.path, to: newPath)
        RepoGroups.shared.moveRepo(from: repo.path, to: newPath)
        // A server it started keeps running in the moved folder; the scan picks it up again as external.
        let wasSelected = selectedPath == repo.path
        setRepos(repos.filter { $0 !== repo } + [Repository(path: newPath)])
        if wasSelected { selectedPath = newPath }
    }

    /// Lets the user point a missing repository at its new folder.
    func locateWithPanel(_ repo: Repository) async -> String? {
        guard let path = chooseFolder(message: "Where is \(repo.name) now?") else { return nil }
        let result = await Git.run(["rev-parse", "--show-toplevel"], in: path)
        guard result.succeeded else { return "\((path as NSString).lastPathComponent) is not a git repository" }
        relocate(repo, to: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return nil
    }

    /// Notices dev servers started outside Bridge.
    func scanServers() {
        guard !isScanningServers else { return }
        isScanningServers = true
        let paths = repos.map(\.path)
        Task {
            let found = await Task.detached { ExternalServers.scan(paths) }.value
            for repo in repos { repo.server.setExternal(found[repo.path]) }
            isScanningServers = false
        }
    }

    func refreshAll() {
        repos.forEach { $0.refresh() }
    }

    func fetchAll(quietly: Bool) async {
        guard !isFetchingAll else { return }
        isFetchingAll = true
        // A few at a time, so dozens of repos don't open dozens of connections at once. A new fetch
        // starts as soon as one finishes, so one slow remote doesn't hold up the next three.
        var pending = repos.filter { !$0.isMissing }[...]
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                guard let repo = pending.popFirst() else { break }
                group.addTask { await repo.fetch(quietly: quietly) }
            }
            for await _ in group {
                if let repo = pending.popFirst() {
                    group.addTask { await repo.fetch(quietly: quietly) }
                }
            }
        }
        isFetchingAll = false
    }

    // MARK: Adding and removing

    /// Adds the repository containing `path`. Returns an error message if it isn't one.
    @discardableResult
    func add(_ path: String) async -> String? {
        let result = await Git.run(["rev-parse", "--show-toplevel"], in: path)
        guard result.succeeded else { return "\((path as NSString).lastPathComponent) is not a git repository" }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repos.contains(where: { $0.path == root }) {
            setRepos(repos + [Repository(path: root)])
        }
        selectedPath = root
        return nil
    }

    func remove(_ repo: Repository) {
        repo.server.terminate()
        RepoGroups.shared.forgetRepo(repo.path)
        setRepos(repos.filter { $0 !== repo })
        if selectedPath == repo.path { selectedPath = repos.first?.path }
    }

    /// Finds git repositories up to three levels below `folder` and adds them all.
    func scan(_ folder: String) async -> Int {
        let found = await Task.detached { Self.findRepositories(in: URL(fileURLWithPath: folder), depth: 3) }.value
        let known = Set(repos.map(\.path))
        let new = found.filter { !known.contains($0) }
        if !new.isEmpty { setRepos(repos + new.map(Repository.init)) }
        return new.count
    }

    private nonisolated static func findRepositories(in folder: URL, depth: Int) -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) { return [folder.path] }
        guard depth > 0, let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "node_modules" }
            .flatMap { findRepositories(in: $0, depth: depth - 1) }
    }

    /// Shows an open panel; used from both the menu bar panel and the window.
    func chooseFolder(message: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func addWithPanel() async -> String? {
        guard let path = chooseFolder(message: "Choose a git repository") else { return nil }
        return await add(path)
    }

    func scanWithPanel() async -> String? {
        guard let path = chooseFolder(message: "Choose a folder to search for git repositories") else { return nil }
        let count = await scan(path)
        return count == 0 ? "No new repositories found in \((path as NSString).lastPathComponent)" : nil
    }

    // MARK: New projects

    /// Where new projects go: the last folder chosen, or else the folder most repositories are in.
    var newProjectFolder: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "newProjectFolder") { return saved }
            let parents = Dictionary(grouping: repos.map { ($0.path as NSString).deletingLastPathComponent }, by: { $0 })
            return parents.max { $0.value.count < $1.value.count }?.key
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        }
        set { UserDefaults.standard.set(newValue, forKey: "newProjectFolder") }
    }

    /// Projects being set up in Terminal, shown in the panel until their repository shows up.
    @Published private(set) var settingUp: [String] = []

    /// Creates a project at `path`. An empty one is made right here; anything that needs a framework's
    /// setup, GitHub or Claude runs as one script in Terminal, so its questions can be answered and its
    /// errors are seen, and Claude only starts once everything is installed. Returns an error message.
    func createProject(at path: String, template: ProjectTemplate, packageManager: String,
                       openClaude: Bool, prompt: String?, gitHub: Bool) async -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if template == .none, !gitHub {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                return error.localizedDescription
            }
            let result = await Git.run(["init", "-q"], in: path)
            guard result.succeeded else { return result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let error = await add(path) { return error }
            if openClaude { DevWorkspace.openAgentInTerminal(path, prompt: prompt) }
            return nil
        }

        let q = DevWorkspace.quoted(name)
        var steps: [String]
        if let create = template.createCommand(name: name, packageManager: packageManager) {
            steps = [
                DevWorkspace.say("Creating \(name) with \(template.title)"), create, "cd \(q)",
                DevWorkspace.say("Installing packages with \(packageManager)"), "\(packageManager) install",
                // Some create commands make the repository and first commit themselves, others don't.
                "{ [ -d .git ] || git init -q; }",
                "{ git rev-parse -q --verify HEAD >/dev/null || { git add -A && git commit -qm 'Initial commit'; }; }",
            ]
        } else {
            steps = ["mkdir \(q)", "cd \(q)", "git init -q"]
        }
        if gitHub {
            let push = template == .none ? "" : " --push"
            steps += [DevWorkspace.say("Creating the GitHub repository"), "gh repo create \(q) --private --source .\(push)"]
        }
        if openClaude { steps.append(DevWorkspace.agentCommand(prompt: prompt)) }
        DevWorkspace.runInTerminal(steps.joined(separator: " && "), in: parent, kind: "new-\(name)", rexSession: name)
        waitForRepository(at: path)
        return nil
    }

    /// Adds the project once its repository exists. Gives up after an hour, or when the row is dismissed.
    private func waitForRepository(at path: String) {
        settingUp.append(path)
        Task {
            let deadline = Date().addingTimeInterval(60 * 60)
            while settingUp.contains(path), Date() < deadline {
                if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                    await add(path)
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
            settingUp.removeAll { $0 == path }
        }
    }

    func stopWaiting(for path: String) {
        settingUp.removeAll { $0 == path }
    }

    // MARK: Cloning

    /// Repositories being cloned, shown in the panel until they're done.
    @Published private(set) var cloning: [String] = []

    /// Clones `repository` (a full path on `host`, or a URL) into `path` and adds it, like GitHub
    /// Desktop's Clone repository. Runs here rather than in a terminal so it can't stop at a question.
    /// Through the host's command line when it's installed (gh and glab set up a fork's `upstream`
    /// remote too), otherwise plain git for a URL. Returns an error message.
    func clone(_ repository: String, to path: String, host: (any GitHost)? = nil) async -> String? {
        guard !FileManager.default.fileExists(atPath: path) else {
            return "\((path as NSString).abbreviatingWithTildeInPath) already exists"
        }
        let parent = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        cloning.append(path)
        defer { cloning.removeAll { $0 == path } }
        // A plain URL works without the host's command line; owner/name typed as a URL goes to GitHub, as before.
        let isURL = repository.contains("://") || repository.hasPrefix("git@")
        let host = host ?? (isURL ? GitHosts.host(for: URL(string: repository)) : GitHosts.gitHub)
        let cli = await Task.detached { host.map { HostCLI(host: $0) } }.value
        let result = if let host, let cli, cli.isInstalled || !isURL {
            await cli.run(host.cloneArguments(repository, to: path), in: parent, timeout: 1800)
        } else {
            await Git.run(["clone", repository, path], in: parent, timeout: 1800)
        }
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Couldn't clone \(repository)" : message
        }
        return await add(path)
    }

    // MARK: Moving to the Trash

    /// Moves the repository's folder to the Trash after saying what exists only here: GitHub has
    /// what's committed and pushed, not changes, unpushed commits, stashes or ignored files like `.env`.
    /// The Trash rather than deleting, so a mistake can be undone in Finder. Returns an error message.
    @discardableResult
    func moveToTrash(_ repo: Repository) async -> String? {
        let path = repo.path
        async let remotes = Git.run(["remote"], in: path)
        // Spelled out, so settings like status.showUntrackedFiles=no or submodule.*.ignore don't hide anything.
        async let changes = Git.run(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], in: path)
        // HEAD as well as the branches, so commits only on a detached HEAD count too. Not --all:
        // that also counts backup refs (refs/original, rewrite backups) and the stash, counted below.
        async let unpushed = Git.run(["log", "--branches", "HEAD", "--not", "--remotes", "--oneline"], in: path)
        async let stashes = Git.run(["stash", "list"], in: path)
        async let ignored = Git.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: path)
        async let worktreeRisks = Self.worktreeRisks(of: path)
        // nil when git failed or timed out: that's not the same as having nothing to lose.
        func lines(_ result: GitResult) -> [String]? {
            result.succeeded ? result.stdout.split(separator: "\n").map(String.init) : nil
        }

        var risks: [String] = []
        switch lines(await remotes) {
        case nil:
            risks.append("Couldn't check remotes")
        case let remotes? where remotes.isEmpty:
            risks.append("No remote: this folder is the only copy")
        default:
            switch lines(await unpushed)?.count {
            case nil: risks.append("Couldn't check for unpushed commits")
            case 0: break
            case 1: risks.append("1 commit isn't pushed")
            case let count?: risks.append("\(count) commits aren't pushed")
            }
        }
        switch lines(await changes)?.count {
        case nil: risks.append("Couldn't check for uncommitted changes")
        case 0: break
        case 1: risks.append("1 file has uncommitted changes")
        case let count?: risks.append("\(count) files have uncommitted changes")
        }
        switch lines(await stashes)?.count {
        case nil: risks.append("Couldn't check for stashes")
        case 0: break
        case 1: risks.append("1 stash")
        case let count?: risks.append("\(count) stashes")
        }
        risks += await worktreeRisks
        if let ignoredFiles = lines(await ignored) {
            let env = ignoredFiles.filter { !$0.hasSuffix("/") && ($0 as NSString).lastPathComponent.hasPrefix(".env") }
            if !env.isEmpty {
                risks.append("Not in git: " + env.prefix(4).joined(separator: ", ") + (env.count > 4 ? " and \(env.count - 4) more" : ""))
            }
        } else {
            risks.append("Couldn't check for files not in git")
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move \(repo.name) to the Trash?"
        alert.informativeText = risks.isEmpty
            ? "Everything is committed and pushed. The folder goes to the Trash, and the repository on GitHub isn't touched."
            : "Lost if you empty the Trash:\n• " + risks.joined(separator: "\n• ") + "\n\nThe repository on GitHub isn't touched."
        alert.alertStyle = risks.isEmpty ? .warning : .critical
        let trash = alert.addButton(withTitle: risks.isEmpty ? "Move to Trash" : "Move to Trash Anyway")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // With something at stake, Return cancels instead of trashing.
        if !risks.isEmpty {
            trash.keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Trash first: if that fails, the repository stays in the list and its server keeps running.
        // A running server doesn't stop the move (open files move along with the folder), and it's
        // stopped by process id, so it's found again after the move.
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        repo.server.stopExternal()
        remove(repo)
        return nil
    }

    /// Uncommitted changes in the repository's other worktrees. Those inside the folder go to the Trash
    /// with it; those outside stay, but lose the repository their `.git` file points to.
    private nonisolated static func worktreeRisks(of path: String) async -> [String] {
        let list = await Git.run(["worktree", "list", "--porcelain"], in: path)
        guard list.succeeded else { return ["Couldn't check worktrees"] }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // Records are separated by blank lines; the first is the main worktree. Prunable ones are gone already.
        let worktrees = list.stdout.components(separatedBy: "\n\n").dropFirst().compactMap { record -> String? in
            let lines = record.split(separator: "\n")
            guard !lines.contains(where: { $0.hasPrefix("prunable") }),
                  let line = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let worktree = URL(fileURLWithPath: String(line.dropFirst("worktree ".count))).resolvingSymlinksInPath().path
            return worktree == root ? nil : worktree
        }
        var risks: [String] = []
        for worktree in worktrees {
            let inside = worktree.hasPrefix(root + "/")
            let name = inside ? String(worktree.dropFirst(root.count + 1)) : (worktree as NSString).lastPathComponent
            let label = inside ? "worktree \(name)" : "worktree \(name) (outside the folder, stays but is cut off from the repository)"
            let status = await Git.run(["status", "--porcelain"], in: worktree)
            guard status.succeeded else {
                risks.append("Couldn't check \(label)")
                continue
            }
            let count = status.stdout.split(separator: "\n").count
            if count == 1 {
                risks.append("1 file has uncommitted changes in \(label)")
            } else if count > 1 {
                risks.append("\(count) files have uncommitted changes in \(label)")
            }
        }
        return risks
    }
}
