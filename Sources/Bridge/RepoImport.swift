import AppKit
import Shared
import SwiftUI

/// A git repository found on this Mac, with what it takes to decide whether to add it.
struct FoundRepo: Hashable {
    let path: String
    /// The repository's full path on its host (owner/name), from its remote.
    let hostedName: String?
    /// The host's id and `hostedName` lowercased, to tell it apart from the host's list (`RepoImport.key`).
    let hostedKey: String?
    let lastCommit: Date?
    let framework: Framework?

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

/// How the repositories added from the search are put in groups (`RepoGroups`).
enum ImportGrouping: String, CaseIterable, Identifiable {
    case none, folder, owner
    var id: String { rawValue }
}

/// Finds the repositories a user already has, on this Mac and on their git hosts, for a page where
/// they're ticked or unticked before anything is added, and, when switched on, keeps adding new ones
/// from the same folders every hour. Adding everything found at once (as Find in folder did) filled
/// the list with archived experiments, caches and second clones, and offered no way to bring in what's
/// only on GitHub; ticking through a list with sensible defaults is quicker than removing rows afterwards.
///
/// What's ticked to begin with, and what's added automatically: repositories on this Mac with a commit
/// in the last year that aren't in a folder for old things and aren't a second copy of one already
/// there. Nothing that would be cloned is ticked: a clone takes time and disk, so each is the user's choice.
///
/// One for the app, rather than one per page: macOS asking for access to Documents or Desktop takes
/// the keyboard from the menu bar panel, which closes it. The search goes on meanwhile, and the panel
/// opens on the page again once it's done (`reopenWhenDone`).
@MainActor
final class RepoImport: ObservableObject {
    static let shared = RepoImport()

    enum HostState: Equatable {
        case loading, loaded
        /// Its command line isn't installed or isn't logged in; `installed` says which.
        case needsLogin(installed: Bool)
        case failed(String)
    }

    /// Repositories on this Mac that aren't in Bridge, the most recently committed to first.
    @Published private(set) var found: [FoundRepo] = []
    @Published private(set) var isSearching = false
    @Published private(set) var lastSearch: Date?
    @Published private(set) var hosts: [any GitHost] = []
    @Published private(set) var hostStates: [String: HostState] = [:]
    @Published private(set) var hostedRepos: [String: [HostedRepo]] = [:]
    /// Ticked: paths of repositories on this Mac, `hostedID`s of ones to clone.
    @Published var selected: Set<String> = []
    /// Names of repositories the hourly search just added, for the panel to mention; emptied once read.
    @Published var addedAutomatically: [String] = []

    /// Folders chosen with Add folder…, searched besides the home folder.
    @Published private(set) var extraFolders = UserDefaults.standard.stringArray(forKey: "importFolders") ?? [] {
        didSet { UserDefaults.standard.set(extraFolders, forKey: "importFolders") }
    }
    /// The folders macOS asks permission for (`protectedFolders`) that the user has let it search.
    @Published private(set) var allowedFolders = Set(UserDefaults.standard.stringArray(forKey: "importAllowedFolders") ?? []) {
        didSet { UserDefaults.standard.set(Array(allowedFolders), forKey: "importAllowedFolders") }
    }
    /// By folder unless changed: a first import of dozens of repositories was one long flat list.
    @Published var grouping = ImportGrouping(rawValue: UserDefaults.standard.string(forKey: "importGrouping") ?? "") ?? .folder {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "importGrouping") }
    }
    /// Searches the same folders every hour and adds what would be ticked. Turned on, what's unticked
    /// on the page now is remembered as passed over, so it isn't added behind the user's back.
    @Published var addsAutomatically = UserDefaults.standard.bool(forKey: "autoAddRepositories") {
        didSet {
            UserDefaults.standard.set(addsAutomatically, forKey: "autoAddRepositories")
            if addsAutomatically { markSeen(found.filter { !selected.contains($0.path) }) }
        }
    }
    /// Every repository the search has offered and the user passed over or added, so one removed from
    /// Bridge or left unticked isn't added again by the hourly search.
    private var seen = Set(UserDefaults.standard.stringArray(forKey: "importSeen") ?? []) {
        didSet { UserDefaults.standard.set(Array(seen), forKey: "importSeen") }
    }

    /// Clones started from the page, shown as one row in the panel (`ImportProgressRow`) rather than a
    /// row each: dozens of Cloning rows pushed the list out of the panel.
    @Published private(set) var cloneTotal = 0
    @Published private(set) var cloneDone = 0
    @Published private(set) var cloningNow: [String] = []
    private var stopsCloning = false
    private var cloneQueue: [PendingClone] = []
    private var cloneWorkers = 0
    private var cloneFailures: [String] = []

    private weak var store: RepoStore?
    /// The folders the last search started from, which folder groups are named after the first level below.
    private var roots: [String] = []
    private var timer: Timer?
    private var hostsLoadedAt: Date?
    /// Who's logged in on each host, so their own repositories don't get a group named after them.
    private var logins: [String: String] = [:]
    /// Repositories in Bridge by `key`, so another copy of one isn't offered as new and one on the host isn't offered to clone.
    private var bridgeKeys: Set<String> = []
    /// Items whose default has been applied: a search again doesn't undo what the user ticked or unticked.
    private var defaulted: Set<String> = []
    /// Set when the search is about to make macOS ask for access, which closes the panel.
    private var reopenWhenDone = false

    private init() {}

    /// Starts the hourly search. Folders macOS guards that already hold a repository in Bridge have been
    /// read before, so they count as allowed from the start.
    func start(_ store: RepoStore) {
        self.store = store
        if UserDefaults.standard.object(forKey: "importAllowedFolders") == nil {
            allowedFolders = Set(Self.protectedFolders.filter { folder in store.repos.contains { $0.path.hasPrefix(folder + "/") } })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.searchInBackground() }
        }
        timer?.tolerance = 5 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.searchInBackground() }
    }

    private func searchInBackground() {
        guard addsAutomatically else { return }
        search(automatic: true)
    }

    nonisolated static func key(_ host: any GitHost, _ name: String) -> String { "\(host.id):\(name.lowercased())" }
    nonisolated static func hostedID(_ host: any GitHost, _ repo: HostedRepo) -> String { "\(host.id):\(repo.name)" }

    // MARK: Where to look

    /// Home folders that are never searched: they hold no code, are huge, or (Downloads) hold copies
    /// of things rather than the user's work. Each media folder also asks for permission of its own.
    static let skippedHomeFolders: Set<String> = ["Library", "Applications", "Downloads", "Movies", "Music", "Pictures", "Public"]

    /// Home folders macOS asks the user about before an app reads them. Only searched once allowed
    /// here, so the hourly search never makes a dialog appear out of nowhere.
    static let protectedFolders = ["Documents", "Desktop"].map { (NSHomeDirectory() as NSString).appendingPathComponent($0) }

    /// Folders never gone into: dependencies and build output, which can hold thousands of folders
    /// and the odd repository of someone else's. `Library` is also where a Unity project keeps its cache.
    private nonisolated static let skippedFolders: Set<String> = [
        "node_modules", "bower_components", "vendor", "Pods", "Carthage", "DerivedData", "build", "dist", "target",
        "venv", "__pycache__", "site-packages", "Library", "Temp", "obj",
    ]

    /// Folder names that say what's in them is kept rather than worked on.
    private static let setAsideFolders: Set<String> = ["archive", "archives", "archived", "old", "backup", "backups", "tmp", "temp", "trash"]

    var missingPermissions: [String] { Self.protectedFolders.filter { !allowedFolders.contains($0) } }

    /// Lets the search into Documents and Desktop. macOS asks about each, which closes the panel, so
    /// it opens again on this page when the search is done.
    func allowProtectedFolders() {
        allowedFolders.formUnion(Self.protectedFolders)
        reopenWhenDone = true
        search()
    }

    func setAllowed(_ folder: String, _ isAllowed: Bool) {
        if isAllowed { allowedFolders.insert(folder) } else { allowedFolders.remove(folder) }
        reopenWhenDone = isAllowed
        search()
    }

    func addFolder(_ folder: String) {
        if !extraFolders.contains(folder) { extraFolders.append(folder) }
        search()
    }

    func removeFolder(_ folder: String) {
        extraFolders.removeAll { $0 == folder }
        search()
    }

    /// The home folder's own folders (the guarded ones once allowed), the folders added, and the
    /// folders of repositories in Bridge that are elsewhere (another disk).
    private func searchRoots(bridgePaths: [String]) -> [String] {
        let home = NSHomeDirectory()
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
            .filter { !$0.hasPrefix(".") && !Self.skippedHomeFolders.contains($0) }
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { !Self.protectedFolders.contains($0) || allowedFolders.contains($0) }
        let elsewhere = bridgePaths.filter { !$0.hasPrefix(home + "/") }.map { ($0 as NSString).deletingLastPathComponent }
        var unique = Set<String>()
        return (children + extraFolders + elsewhere).filter { unique.insert($0).inserted }
    }

    // MARK: Searching

    /// Looks through the folders, and the hosts unless `automatic` (whose lists are kept ten minutes,
    /// or reloaded with `reloadHosts`). An automatic search adds what it finds that would be ticked
    /// and hasn't been offered before.
    func search(automatic: Bool = false, reloadHosts: Bool = false) {
        guard let store, !isSearching else { return }
        isSearching = true
        let inBridge = Set(store.repos.map(\.path))
        var keys = Set(store.repos.compactMap { repo in repo.host.flatMap { host in repo.hostedName.map { Self.key(host, $0) } } })
        let roots = searchRoots(bridgePaths: Array(inBridge))
        self.roots = roots
        Task {
            let paths = await Task.detached { Self.findRepositories(in: roots) }.value
            // Bridge's own are looked at too: their remotes say which repositories on the host are here already.
            let described = await Self.describe(paths)
            keys.formUnion(described.filter { inBridge.contains($0.path) }.compactMap(\.hostedKey))
            bridgeKeys = keys
            // Bridge's list as it is now: something may have been added while the search ran.
            let current = Set(store.repos.map(\.path))
            found = described
                .filter { !current.contains($0.path) }
                .sorted { ($0.lastCommit ?? .distantPast, $1.path) > ($1.lastCommit ?? .distantPast, $0.path) }
            for repo in found where defaulted.insert(repo.path).inserted && note(for: repo) == nil {
                selected.insert(repo.path)
            }
            if automatic {
                let new = found.filter { !seen.contains($0.path) && note(for: $0) == nil }
                markSeen(found)
                if !new.isEmpty {
                    addLocal(new)
                    addedAutomatically = new.map(\.name)
                }
            }
            isSearching = false
            lastSearch = Date()
            if reopenWhenDone {
                reopenWhenDone = false
                if PanelState.shared.window?.isVisible != true { PanelState.shared.open(.importRepos) }
            }
        }
        guard !automatic else { return }
        hosts = GitHosts.all.filter { $0.id == GitHosts.gitHub.id || HostCLI(host: $0).isInstalled }
        if reloadHosts || hostsLoadedAt.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true {
            hostsLoadedAt = Date()
            for host in hosts { loadHosted(host) }
        }
    }

    /// Repositories up to five folders below each of `roots`, breadth first, without going into one
    /// (a repository inside another is nearly always a stray copy) or following links. A `.git` that's
    /// a file is a worktree or submodule of a repository found on its own. Stops after 60,000 folders,
    /// so a home folder full of something unexpected can't keep it searching for minutes.
    private nonisolated static func findRepositories(in roots: [String]) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var queue = roots.map { (url: URL(fileURLWithPath: $0), depth: 0) }
        var next = 0
        var visited = Set<String>()
        var found: [String] = []
        while next < queue.count, visited.count < 60_000 {
            let (folder, depth) = queue[next]
            next += 1
            guard visited.insert(folder.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: folder.appendingPathComponent(".git").path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { found.append(folder.path) }
                continue
            }
            guard depth < 5, let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for child in children where !skippedFolders.contains(child.lastPathComponent) {
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      values.isSymbolicLink != true, values.isPackage != true else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// Each repository's remote, last commit and framework, eight at a time.
    private nonisolated static func describe(_ paths: [String]) async -> [FoundRepo] {
        await withTaskGroup(of: FoundRepo.self) { group in
            var pending = paths[...]
            var results: [FoundRepo] = []
            for _ in 0..<8 {
                guard let path = pending.popFirst() else { break }
                group.addTask { await describe(path) }
            }
            for await repo in group {
                results.append(repo)
                if let path = pending.popFirst() { group.addTask { await describe(path) } }
            }
            return results
        }
    }

    private nonisolated static func describe(_ path: String) async -> FoundRepo {
        async let log = Git.run(["log", "-1", "--format=%ct"], in: path, timeout: 10)
        async let urls = Git.run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: path, timeout: 10)
        let framework = Framework.detect(projectAt: path)
        // "remote.origin.url git@github.com:owner/name.git": origin's, or else the first remote's.
        let remotes = await urls.stdout.split(separator: "\n").compactMap { line -> (name: String, url: String)? in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0].dropFirst("remote.".count).dropLast(".url".count)), String(parts[1]))
        }
        let remote = remotes.first { $0.name == "origin" } ?? remotes.first
        let page = remote.flatMap { Repository.webPage(forRemoteURL: $0.url) }
        let host = GitHosts.host(for: page)
        let parts = page?.pathComponents.filter { $0 != "/" } ?? []
        let hostedName = host != nil && parts.count >= 2 ? parts.joined(separator: "/") : nil
        let seconds = await TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return FoundRepo(path: path, hostedName: hostedName,
                         hostedKey: host.flatMap { host in hostedName.map { key(host, $0) } },
                         lastCommit: seconds.map(Date.init(timeIntervalSince1970:)), framework: framework)
    }

    private func loadHosted(_ host: any GitHost) {
        hostStates[host.id] = .loading
        Task {
            let cli = await Task.detached { HostCLI(host: host) }.value
            guard cli.isInstalled else {
                hostStates[host.id] = .needsLogin(installed: false)
                return
            }
            guard let login = await host.currentUser(cli) else {
                hostStates[host.id] = .needsLogin(installed: true)
                return
            }
            logins[host.id] = login
            do {
                hostedRepos[host.id] = try await host.repositories(cli)
                hostStates[host.id] = .loaded
            } catch {
                hostStates[host.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: What's offered

    /// Why a repository on this Mac isn't ticked to begin with, or nil when it is.
    func note(for repo: FoundRepo) -> String? {
        let home = NSHomeDirectory()
        let inside = repo.parent.hasPrefix(home) ? String(repo.parent.dropFirst(home.count)) : repo.parent
        if let folder = inside.split(separator: "/").first(where: { Self.setAsideFolders.contains($0.lowercased()) }) {
            return "In “\(folder)”"
        }
        if let key = repo.hostedKey {
            if bridgeKeys.contains(key) { return "Copy" }
            // `found` is newest first, so the newest copy is the one ticked.
            if let newest = found.first(where: { $0.hostedKey == key }), newest.path != repo.path { return "Older copy" }
        }
        guard let date = repo.lastCommit else { return "No commits" }
        // Half a year: a year ticked most of a folder of experiments on a first import.
        if date < Date().addingTimeInterval(-182 * 24 * 3600) { return date.relative }
        return nil
    }

    /// What's on `host` and neither on this Mac nor in Bridge, the most recently pushed first.
    func hostedOnly(_ host: any GitHost) -> [HostedRepo] {
        let here = bridgeKeys.union(found.compactMap(\.hostedKey))
        return (hostedRepos[host.id] ?? []).filter { !here.contains(Self.key(host, $0.name)) }
    }

    func login(on host: any GitHost) -> String? { logins[host.id] }

    var selectedLocal: [FoundRepo] { found.filter { selected.contains($0.path) } }

    var selectedClones: [(host: any GitHost, repo: HostedRepo)] {
        hosts.flatMap { host in hostedOnly(host).filter { selected.contains(Self.hostedID(host, $0)) }.map { (host, $0) } }
    }

    // MARK: Groups

    /// The folder a repository's group is named after: the first folder below the one searched, so
    /// ~/Documents/Playground/physics/physics-v0 is in Playground, as are the rest of the experiments
    /// there, rather than in a group of its own for "physics". A repository right in a searched folder
    /// (~/Developer/dashboard) is in that folder's group. Nil in the home folder itself.
    private func folderGroup(of path: String) -> String? {
        let root = roots.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            ?? (path as NSString).deletingLastPathComponent
        let below = path.dropFirst(root.count).split(separator: "/")
        if below.count >= 2 { return String(below[0]) }
        return root == NSHomeDirectory() ? nil : (root as NSString).lastPathComponent
    }

    /// The owner on the host, or nil for the user's own, which would otherwise all sit in a group
    /// named after them.
    private func ownerGroup(_ hostedName: String, hostID: String) -> String? {
        let owner = hostedName.split(separator: "/").dropLast().joined(separator: "/")
        return owner.caseInsensitiveCompare(logins[hostID] ?? "") == .orderedSame ? nil : owner
    }

    private func proposedGroup(for repo: FoundRepo) -> String? {
        switch grouping {
        case .none: return nil
        case .folder: return folderGroup(of: repo.path)
        case .owner:
            guard let name = repo.hostedName, let key = repo.hostedKey else { return nil }
            return ownerGroup(name, hostID: String(key.prefix { $0 != ":" }))
        }
    }

    /// The group each repository on this Mac would go in. A group of one isn't a group: it goes without,
    /// unless a group of that name is in Bridge already, which it joins.
    var localGroups: [String: String] {
        let proposed = found.compactMap { repo in proposedGroup(for: repo).map { (repo.path, $0) } }
        let counts = Dictionary(proposed.map { ($0.1, 1) }, uniquingKeysWith: +)
        let existing = Set(RepoGroups.shared.names)
        return Dictionary(proposed.filter { counts[$0.1, default: 0] > 1 || existing.contains($0.1) }, uniquingKeysWith: { first, _ in first })
    }

    private func group(for repo: HostedRepo, on host: any GitHost, at path: String) -> String? {
        switch grouping {
        case .none: return nil
        case .folder: return folderGroup(of: path)
        case .owner: return ownerGroup(repo.name, hostID: host.id)
        }
    }

    // MARK: Adding

    private func markSeen(_ repos: [FoundRepo]) {
        markSeen(paths: repos.map(\.path))
    }

    /// Also called for every repository removed from Bridge (`RepoStore.remove`), however it got
    /// there: one added by hand or dropped in was never offered here, so without this the hourly search
    /// would add it back after a cleanup.
    func markSeen(paths: some Sequence<String>) {
        let new = paths.filter { !seen.contains($0) }
        if !new.isEmpty { seen.formUnion(new) }
    }

    /// Adds repositories on this Mac at once, in their groups, and takes them off the page.
    /// A group this import makes with more than this many repositories starts folded, so a first import
    /// leaves a list of groups to open rather than a wall of rows.
    private static let foldedGroupSize = 6

    private func addLocal(_ repos: [FoundRepo]) {
        guard let store else { return }
        let groups = localGroups
        let existing = Set(RepoGroups.shared.names)
        store.addRoots(repos.map(\.path))
        for repo in repos {
            if let group = groups[repo.path] { RepoGroups.shared.setGroup(group, ofRepo: repo.path) }
        }
        let made = Dictionary(repos.compactMap { groups[$0.path] }.filter { !existing.contains($0) }.map { ($0, 1) }, uniquingKeysWith: +)
        for (group, count) in made where count > Self.foldedGroupSize && !RepoGroups.shared.isCollapsed(group, in: .repos) {
            RepoGroups.shared.toggleCollapsed(group, in: .repos)
        }
        let paths = Set(repos.map(\.path))
        found.removeAll { paths.contains($0.path) }
        selected.subtract(paths)
        bridgeKeys.formUnion(repos.compactMap(\.hostedKey))
    }

    /// Adds what's ticked on this Mac at once and clones what's ticked on a host, three at a time, into
    /// `cloneFolder`; the panel shows each as Cloning meanwhile, and failures come together in one alert
    /// at the end. Everything on the page counts as seen, ticked or not. Returns what was done.
    func addSelected(cloneFolder: String) -> String? {
        guard let store else { return nil }
        let local = selectedLocal
        markSeen(found)
        addLocal(local)
        let clones = selectedClones.map { clone in
            let path = (cloneFolder as NSString).appendingPathComponent(clone.repo.shortName)
            return PendingClone(host: clone.host, repo: clone.repo, path: path, group: group(for: clone.repo, on: clone.host, at: path))
        }
        for clone in clones {
            bridgeKeys.insert(Self.key(clone.host, clone.repo.name))
            selected.remove(Self.hostedID(clone.host, clone.repo))
        }
        if !clones.isEmpty {
            // Joins a run still going, so a second batch shows in the same row.
            if cloneWorkers == 0 {
                cloneDone = 0
                cloneTotal = 0
                cloneFailures = []
            }
            cloneTotal += clones.count
            cloneQueue += clones
            stopsCloning = false
            while cloneWorkers < 3 {
                cloneWorkers += 1
                Task {
                    await cloneNext(store)
                    cloneWorkers -= 1
                    if cloneWorkers == 0 { finishCloning() }
                }
            }
        }
        var done: [String] = []
        if !local.isEmpty { done.append(local.count == 1 ? "Added 1 repository" : "Added \(local.count) repositories") }
        if !clones.isEmpty { done.append((done.isEmpty ? "Cloning " : "cloning ") + "\(clones.count)") }
        return done.isEmpty ? nil : done.joined(separator: ", ") + "."
    }

    struct PendingClone {
        let host: any GitHost
        let repo: HostedRepo
        let path: String
        let group: String?
    }

    /// Takes clones off the queue one after another; three of these run at once.
    private func cloneNext(_ store: RepoStore) async {
        while !stopsCloning, !cloneQueue.isEmpty {
            let clone = cloneQueue.removeFirst()
            cloningNow.append(clone.repo.shortName)
            let message = await Self.clone(clone.repo, from: clone.host, to: clone.path, store: store)
            cloningNow.removeAll { $0 == clone.repo.shortName }
            cloneDone += 1
            if let message {
                cloneFailures.append("\(clone.repo.name): \(message)")
                bridgeKeys.remove(Self.key(clone.host, clone.repo.name))
            } else if let group = clone.group {
                RepoGroups.shared.setGroup(group, ofRepo: clone.path)
            }
        }
    }

    /// Once the last clone is done: what was stopped before it started can be ticked again, and
    /// failures come in one alert.
    private func finishCloning() {
        for clone in cloneQueue { bridgeKeys.remove(Self.key(clone.host, clone.repo.name)) }
        cloneQueue = []
        cloneTotal = 0
        cloneDone = 0
        cloningNow = []
        let failures = cloneFailures
        cloneFailures = []
        guard !failures.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? "Couldn't clone 1 repository" : "Couldn't clone \(failures.count) repositories"
        alert.informativeText = failures.joined(separator: "\n\n")
        alert.runModal()
    }

    /// Lets the clones running finish and starts no more.
    func stopCloning() {
        stopsCloning = true
    }

    /// A folder of that name that's already a repository is most likely the same one, cloned before
    /// into a folder the search doesn't reach; it's added rather than failing.
    private static func clone(_ repo: HostedRepo, from host: any GitHost, to path: String, store: RepoStore) async -> String? {
        if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return await store.add(path)
        }
        return await store.clone(repo.name, to: path, host: host, listed: false)
    }
}

// MARK: - The page

/// The search's results, to tick or untick before anything is added: a page of the menu bar panel
/// (`PanelPage.importRepos`), and a popover in the main window. Kept to the rows and what changes
/// them; where it looks is behind the folder menu rather than spelled out above the list.
struct ImportRepositoriesForm: View {
    @ObservedObject var store: RepoStore
    var isPage = false
    /// Called with what was done, for the panel to show, or nil when nothing was.
    let done: (String?) -> Void
    @ObservedObject private var model = RepoImport.shared
    @State private var filter = ""
    @State private var cloneFolder = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !isPage {
                    Text("Find repositories").font(.headline)
                }
                HStack(spacing: 6) {
                    TextField("Filter", text: $filter)
                        .focused($filterFocused)
                        .panelField()
                    if model.isSearching {
                        ProgressView().controlSize(.small).frame(width: PanelMetrics.fieldHeight + 4, height: PanelMetrics.fieldHeight)
                    } else {
                        Button { model.search(reloadHosts: true) } label: { Image(systemName: "arrow.clockwise") }
                            .fieldRowButton()
                            .panelTooltip("Search again")
                            .accessibilityLabel("Search again")
                    }
                    PanelMenu("folder", help: "Where to look") { folderMenu }
                }
                // Up here rather than by Add: it decides how the list below is laid out, which is how
                // the repositories will be grouped in Bridge.
                PanelSegments("Group by", selection: $model.grouping, fills: true, segments: [
                    PanelSegment("By folder", value: ImportGrouping.folder),
                    PanelSegment("By owner", value: ImportGrouping.owner),
                    PanelSegment("No groups", value: ImportGrouping.none),
                ])
            }
            .padding(12)
            PanelDivider()
            MenuPanelList(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 0) {
                    localSection
                    ForEach(model.hosts, id: \.id) { host in
                        hostSection(host)
                    }
                }
                .padding(.vertical, 6)
            }
            PanelDivider()
            footer.padding(12)
        }
        .frame(width: isPage ? nil : 460)
        .frame(maxWidth: isPage ? .infinity : nil, alignment: .leading)
        .onAppear {
            if cloneFolder.isEmpty { cloneFolder = store.newProjectFolder }
            // Fresh unless it was searched a moment ago (the panel opened again after a permission dialog).
            if model.lastSearch.map({ Date().timeIntervalSince($0) > 60 }) ?? true { model.search() }
        }
        .focusesWhenShown { filterFocused = true }
    }

    @ViewBuilder
    private var folderMenu: some View {
        Text("Your home folder")
        ForEach(RepoImport.protectedFolders, id: \.self) { folder in
            Toggle((folder as NSString).lastPathComponent, isOn: Binding(
                get: { model.allowedFolders.contains(folder) },
                set: { model.setAllowed(folder, $0) }))
        }
        if !model.extraFolders.isEmpty {
            Divider()
            ForEach(model.extraFolders, id: \.self) { folder in
                Toggle((folder as NSString).abbreviatingWithTildeInPath, isOn: Binding(
                    get: { true }, set: { if !$0 { model.removeFolder(folder) } }))
            }
        }
        Divider()
        Button("Add folder…") {
            if let folder = store.chooseFolder(message: "Choose a folder to look for repositories in") { model.addFolder(folder) }
        }
    }

    // MARK: Sections

    private func matches(_ texts: String?...) -> Bool {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        return filter.isEmpty || texts.contains { $0?.localizedCaseInsensitiveContains(filter) == true }
    }

    /// Groups are folded to one line until opened, so a first search shows a handful of groups with how
    /// many in each are ticked, rather than every repository at once. A filter opens them all, and a
    /// section that's the only one is open.
    @State private var opened: Set<String> = []

    private func isOpen(_ id: String, only: Bool) -> Bool {
        only || opened.contains(id) || !filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func toggle(_ id: String) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }

    /// The repositories on this Mac in the groups they'd go in, by name, those without one last.
    private func localSections(_ repos: [FoundRepo]) -> [(id: String, title: String, repos: [FoundRepo])] {
        guard !repos.isEmpty else { return [] }
        guard model.grouping != .none else { return [("local", "All repositories", repos)] }
        let groups = model.localGroups
        let byGroup = Dictionary(grouping: repos) { groups[$0.path] }
        let names = byGroup.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var sections = names.map { (id: "local:" + $0, title: $0, repos: byGroup[$0] ?? []) }
        if let rest = byGroup[nil] { sections.append((id: "local", title: names.isEmpty ? "All repositories" : "Not in a group", repos: rest)) }
        return sections
    }

    @ViewBuilder
    private var localSection: some View {
        let repos = model.found.filter { matches($0.path, $0.hostedName) }
        ChecklistHeading(title: "On this Mac", isLoading: model.isSearching)
        let missing = model.missingPermissions
        if !missing.isEmpty {
            // macOS asks once for each; the page comes back by itself when that's done.
            ChecklistStatusLine {
                Button("Search \(missing.map { ($0 as NSString).lastPathComponent }.joined(separator: " and ")) too…") {
                    model.allowProtectedFolders()
                }
                .buttonStyle(.link)
            }
        }
        if repos.isEmpty && !model.isSearching {
            ChecklistStatusLine { Text(model.found.isEmpty ? "Nothing new." : "No matches.") }
        }
        let sections = localSections(repos)
        ForEach(sections, id: \.id) { section in
            let open = isOpen(section.id, only: sections.count == 1)
            ChecklistGroupHeader(title: section.title, ids: section.repos.map(\.path), isOpen: open,
                              toggleOpen: { toggle(section.id) }, selected: $model.selected)
            if open {
                ForEach(section.repos, id: \.path) { repo in
                    ChecklistRow(isOn: binding(repo.path), title: repo.name,
                              // The folder it's in, when the group doesn't already say so.
                              detail: repo.parent == NSHomeDirectory() || (repo.parent as NSString).lastPathComponent == section.title
                                  ? nil : (repo.parent as NSString).lastPathComponent,
                              trailing: model.note(for: repo)) {
                        FrameworkLogo(framework: repo.framework, size: 14)
                    }
                }
            }
        }
    }

    /// What's only on the host, by owner (the user's own first), every group folded to begin with:
    /// cloning is the exception, and an owner's whole list shouldn't be one click away from it.
    private func hostedSections(_ repos: [HostedRepo], login: String?) -> [(id: String, title: String, repos: [HostedRepo])] {
        let byOwner = Dictionary(grouping: repos, by: \.owner)
        let owners = byOwner.keys.sorted { a, b in
            let mine = (a.caseInsensitiveCompare(login ?? "") == .orderedSame, b.caseInsensitiveCompare(login ?? "") == .orderedSame)
            if mine.0 != mine.1 { return mine.0 }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return owners.map { (id: "hosted:" + $0, title: $0, repos: byOwner[$0] ?? []) }
    }

    @ViewBuilder
    private func hostSection(_ host: any GitHost) -> some View {
        let repos = model.hostedOnly(host).filter { matches($0.name, $0.description) }
        let state = model.hostStates[host.id] ?? .loading
        ChecklistHeading(title: "Only on \(host.name)", isLoading: state == .loading)
            .padding(.top, 10)
        switch state {
        case .loading:
            EmptyView()
        case let .needsLogin(installed):
            ChecklistStatusLine {
                Button(installed ? "Log in to \(host.name)…" : "Install the \(host.cliName)…") { HostLogin.logIn(to: host) }
                    .buttonStyle(.link)
                Button("Check again") { model.search(reloadHosts: true) }.buttonStyle(.link)
            }
        case let .failed(message):
            ChecklistStatusLine {
                Text(verbatim: message).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { model.search(reloadHosts: true) }.buttonStyle(.link)
            }
        case .loaded:
            if repos.isEmpty {
                ChecklistStatusLine { Text(model.hostedOnly(host).isEmpty ? "Nothing that isn't on this Mac." : "No matches.") }
            }
            ForEach(hostedSections(repos, login: model.login(on: host)), id: \.id) { section in
                let id = "\(host.id):\(section.id)"
                let open = isOpen(id, only: false)
                ChecklistGroupHeader(title: section.title, ids: section.repos.map { RepoImport.hostedID(host, $0) }, isOpen: open,
                                  toggleOpen: { toggle(id) }, selected: $model.selected)
                if open {
                    ForEach(section.repos) { repo in
                        ChecklistRow(isOn: binding(RepoImport.hostedID(host, repo)), title: repo.shortName, detail: nil,
                                  trailing: repo.isArchived ? "Archived" : repo.isFork ? "Fork" : nil) {
                            Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { if $0 { model.selected.insert(id) } else { model.selected.remove(id) } })
    }

    // MARK: Footer

    private var footer: some View {
        let local = model.selectedLocal.count
        let clones = model.selectedClones.count
        return VStack(alignment: .leading, spacing: 8) {
            if clones > 0 {
                LabeledContent("Clone into") {
                    HStack {
                        Text(verbatim: (cloneFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Change…", action: chooseCloneFolder).controlSize(.small)
                    }
                }
            }
            PanelSwitch("Add new ones automatically", isOn: $model.addsAutomatically)
            HStack {
                Spacer()
                if !isPage {
                    Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                }
                Button(local == 0 && clones > 0 ? "Clone \(clones)" : "Add \(local + clones)") {
                    done(model.addSelected(cloneFolder: cloneFolder))
                }
                .keyboardShortcut(.defaultAction)
                .prominentButton()
                .disabled(local + clones == 0)
            }
        }
    }

    private func chooseCloneFolder() {
        guard let folder = store.chooseFolder(message: "Choose where to clone the repositories") else { return }
        cloneFolder = folder
        store.newProjectFolder = folder
    }
}

/// The page's clones, as one row at the top of the list while they run: how far along, which are
/// cloning now, and a way to stop the rest. Observes the import alone, so the list doesn't redraw with it.
struct ImportProgressRow: View {
    var showsDivider = true
    @ObservedObject private var model = RepoImport.shared

    var body: some View {
        if model.cloneTotal > 0 {
            HStack(spacing: 8) {
                ProgressView(value: Double(model.cloneDone), total: Double(max(model.cloneTotal, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cloning \(model.cloneDone) of \(model.cloneTotal)")
                        .monospacedDigit()
                    if !model.cloningNow.isEmpty {
                        Text(verbatim: model.cloningNow.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                IconButton(systemName: "stop.fill", help: "Stop cloning", action: model.stopCloning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showsDivider { PanelDivider() }
        }
    }
}
