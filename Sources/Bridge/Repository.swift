import AppKit
import Foundation
import Shared

@MainActor
final class Repository: ObservableObject, Identifiable {
    /// The panel's commit message while it's being written, and Claude's suggestion it came from.
    /// Kept here rather than in the row, which is rebuilt when it folds away, moves in the list or the
    /// panel closes, so a written or generated message was lost. Not published: the row has its own
    /// copy while open, and publishing would redraw the whole list on every key.
    var commitDraft = ""
    var commitSuggestion: (summary: String, description: String)?
    /// While Claude writes the panel's commit message. Here rather than in the row for the same reason
    /// as the draft: opening another row rebuilt this one, which forgot Claude was writing and dropped
    /// the message when it came. Published, as it changes only when Claude starts and finishes.
    @Published private(set) var isWritingCommitMessage = false

    /// Has Claude write the commit message into `commitDraft`, unless something is typed there
    /// meanwhile. Done here, not in the row's task, so it lands even if the row is folded or rebuilt;
    /// the row types it out into its field when `isWritingCommitMessage` turns off.
    func writeCommitMessage() {
        guard !isWritingCommitMessage else { return }
        isWritingCommitMessage = true
        Task {
            if let suggestion = await suggestCommitMessage(), commitDraft.isEmpty {
                commitSuggestion = suggestion
                // The shimmer's light finishes its pass first, and the message is written in on the
                // beat after it, so the rhythm carries on into the text instead of being cut off.
                try? await Task.sleep(for: .seconds(ShimmerText.untilPassEnds()))
                if commitDraft.isEmpty { commitDraft = suggestion.summary }
            }
            isWritingCommitMessage = false
        }
    }

    enum Activity: String {
        case fetching = "Fetching…"
        case pulling = "Pulling…"
        case pushing = "Pushing…"
        case committing = "Committing…"
        case switching = "Switching branch…"
        case publishing = "Publishing…"
        case working = "Working…"
    }

    let path: String
    nonisolated var id: String { path }
    /// The folder's name; used where it's the folder that's meant (moving, trashing, finding it again).
    var name: String { (path as NSString).lastPathComponent }

    /// The repository's full path on its host (owner/repo on GitHub, group/subgroup/repo on GitLab), from
    /// the remote's URL. That's the URL git pushes to, so after a rename on the host it's the old name
    /// until the remote is updated (the hosts redirect meanwhile).
    var hostedName: String? {
        guard host != nil, let parts = webPage?.pathComponents.filter({ $0 != "/" }), parts.count >= 2 else { return nil }
        return parts.joined(separator: "/")
    }

    /// What lists show, like GitHub Desktop: the repository's name on its host, or the folder's when it isn't on one.
    var displayName: String { hostedName.map { String($0.split(separator: "/").last ?? "") } ?? name }

    /// The folder's name when it differs from the name shown, so a renamed clone can still be told apart.
    var folderNameIfDifferent: String? { displayName.caseInsensitiveCompare(name) == .orderedSame ? nil : name }

    @Published private(set) var status: RepoStatus?
    @Published private(set) var branches: [Branch] = []
    @Published private(set) var remotes: [String] = []
    @Published private(set) var operation: RepoOperation?
    @Published private(set) var activity: Activity?
    @Published private(set) var lastFetched: Date?
    /// Lines added and removed in tracked files since the last commit; nil before the first commit.
    @Published private(set) var lineStats: (added: Int, removed: Int)?
    @Published private(set) var isMissing = false
    /// The remote's web page, looked up when the remotes change.
    @Published private(set) var webPage: URL?
    /// The open pull request for the current branch, on GitHub; looked up when the branch or its
    /// upstream changes and after fetches and pushes, since each lookup is a network call.
    @Published private(set) var pullRequest: PullRequest?
    /// The branch pull requests go into: the remote's HEAD, usually main.
    @Published private(set) var defaultBranch: String?
    /// The last failed command's message, shown until dismissed.
    @Published var error: String?
    /// Writing a commit message failed because the agent's login is missing or ran out (`AgentLoginError`):
    /// the row offers to log in instead of showing the agent's error output.
    @Published var needsAgentLogin = false
    /// Bumped when a refresh finds something different (status, branches, line counts or the changed
    /// files on disk), so open views (diffs) know to reload.
    @Published private(set) var revision = 0
    /// How to start this project's web app, when it looks like one.
    @Published private(set) var detectedStartCommand: String?
    /// The subfolder the detected command runs from, when the app isn't at the root.
    @Published private(set) var detectedStartFolder: String?
    /// What the project is built with (Nuxt, an Xcode app, Django ...), shown as a logo next to the name.
    @Published private(set) var framework: Framework?
    /// The app to start in a repository with several (three Next and three Nuxt apps, say), chosen by the user.
    @Published var startFolder: String? {
        didSet {
            var all = UserDefaults.standard.dictionary(forKey: "repositoryStartFolders") as? [String: String] ?? [:]
            all[path] = startFolder
            UserDefaults.standard.set(all, forKey: "repositoryStartFolders")
            // Detection reads the file system, so it runs in load(), off the main thread.
            refresh()
        }
    }
    /// A start command chosen by the user, for projects we don't recognize (a `start.py` and the like).
    @Published var customStart: CustomStart? {
        didSet {
            var all = UserDefaults.standard.dictionary(forKey: "repositoryStartCommands") as? [String: [String: Any]] ?? [:]
            all[path] = customStart.map { ["command": $0.command, "terminal": $0.inTerminal] }
            UserDefaults.standard.set(all, forKey: "repositoryStartCommands")
        }
    }

    struct CustomStart: Equatable {
        var command: String
        /// Interactive scripts (a curses status screen) need a terminal; their output can't go to a log.
        var inTerminal: Bool
    }

    /// What the play button runs: the user's own command, or the detected one.
    var startCommand: String? { customStart.map { DevWorkspace.announced($0.command) } ?? detectedStartCommand }
    var startsInTerminal: Bool { customStart?.inTerminal ?? false }
    let server: DevServer
    /// A color to tell repositories apart at a glance, chosen by the user.
    @Published var color: RepoColor? {
        didSet {
            var colors = UserDefaults.standard.dictionary(forKey: "repositoryColors") as? [String: String] ?? [:]
            colors[path] = color?.rawValue
            UserDefaults.standard.set(colors, forKey: "repositoryColors")
        }
    }

    /// Starred repositories go to the top of the list, whatever it's sorted by.
    @Published var isFavorite: Bool {
        didSet {
            var all = UserDefaults.standard.dictionary(forKey: "repositoryFavorites") as? [String: Bool] ?? [:]
            all[path] = isFavorite ? true : nil
            UserDefaults.standard.set(all, forKey: "repositoryFavorites")
        }
    }

    /// Free-form notes about the project. Kept in Application Support rather than in the
    /// repository, so they never show up as changes or get committed by accident.
    @Published var notes: String {
        didSet {
            let url = Self.notesURL(for: path)
            if notes.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? notes.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Claude Code skills (or any prompt) pinned to this repository, each one click from Terminal.
    @Published var skills: [String] {
        didSet {
            var all = UserDefaults.standard.dictionary(forKey: "repositorySkills") as? [String: [String]] ?? [:]
            all[path] = skills.isEmpty ? nil : skills
            UserDefaults.standard.set(all, forKey: "repositorySkills")
        }
    }

    /// Called when the folder has disappeared, so the store can look for where it went.
    var onMissing: (() -> Void)?

    private var gitDir: String?
    private var watcher: FileWatcher?
    private var savedBookmark = false
    private var isRefreshing = false
    private var needsRefresh = false
    /// What the changed files looked like on disk at the last refresh; see `worktreeStamp`.
    private var lastWorktreeStamp: Int?
    private var loadedWebPage = false
    /// Branch and upstream at the last pull request lookup, so file changes don't trigger one.
    private var pullRequestKey: String?

    /// For commands that change the working tree or index (switch, restore, pull, commit with its hooks):
    /// killing git halfway through a large checkout leaves a half-switched tree and a stale index.lock.
    private static let worktreeTimeout: TimeInterval = 600

    init(path: String) {
        self.path = path
        server = DevServer(path: path)
        let colors = UserDefaults.standard.dictionary(forKey: "repositoryColors") as? [String: String]
        color = colors?[path].flatMap(RepoColor.init)
        isFavorite = (UserDefaults.standard.dictionary(forKey: "repositoryFavorites") as? [String: Bool])?[path] ?? false
        notes = (try? String(contentsOf: Self.notesURL(for: path), encoding: .utf8)) ?? ""
        skills = (UserDefaults.standard.dictionary(forKey: "repositorySkills") as? [String: [String]])?[path] ?? []
        let start = (UserDefaults.standard.dictionary(forKey: "repositoryStartCommands") as? [String: [String: Any]])?[path]
        startFolder = (UserDefaults.standard.dictionary(forKey: "repositoryStartFolders") as? [String: String])?[path]
        customStart = (start?["command"] as? String).map { CustomStart(command: $0, inTerminal: start?["terminal"] as? Bool ?? false) }
        watcher = FileWatcher(path: path) { [weak self] in self?.refresh() }
        refresh()
    }

    /// One Markdown file per repository, named after its path so it stays readable in Finder.
    static func notesURL(for path: String) -> URL {
        let name = path.split(separator: "/").joined(separator: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge/Notes/\(name).md")
    }

    /// The remote to fetch from and publish to: origin if it exists.
    var remote: String? { remotes.contains("origin") ? "origin" : remotes.first }
    var hasChanges: Bool { !(status?.files.isEmpty ?? true) }
    var changeCount: Int { status?.files.count ?? 0 }
    var currentBranch: String { status?.branch ?? "Detached HEAD" }

    /// Whether there's work here that only exists locally: changed files or commits not pushed yet.
    var hasLocalWork: Bool {
        guard let status else { return false }
        return !status.files.isEmpty || status.ahead > 0 || canPublish
    }

    var canPublish: Bool { status?.branch != nil && status?.upstream == nil && remote != nil && status?.head != nil }

    /// The git host the repository is on (GitHub, GitLab), from its remote's web page; nil elsewhere.
    var host: (any GitHost)? { GitHosts.host(for: webPage) }

    /// Whether the current branch can be proposed as a pull or merge request: on a host, not the
    /// branch it would go into, and without one open already.
    var canCreatePullRequest: Bool {
        guard host != nil, pullRequest == nil, let branch = status?.branch, status?.head != nil else { return false }
        return branch != (defaultBranch ?? "main") && !(defaultBranch == nil && branch == "master")
    }

    // MARK: Moving

    private static let settingsKeys = ["repositoryColors", "repositoryFavorites", "repositorySkills", "repositoryStartCommands", "repositoryStartFolders", "repositoryBookmarks"]

    /// A bookmark follows the folder through renames and moves on the same disk (it refers to the
    /// file system's id, not the path), so a renamed repository can be found again.
    private static func saveBookmark(for path: String) {
        guard let data = try? URL(fileURLWithPath: path).bookmarkData() else { return }
        var all = UserDefaults.standard.dictionary(forKey: "repositoryBookmarks") as? [String: Data] ?? [:]
        all[path] = data
        UserDefaults.standard.set(all, forKey: "repositoryBookmarks")
    }

    /// Where the folder is now, if it was renamed or moved rather than deleted.
    nonisolated static func movedPath(of path: String) -> String? {
        guard let data = (UserDefaults.standard.dictionary(forKey: "repositoryBookmarks") as? [String: Data])?[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) else { return nil }
        let moved = url.standardizedFileURL.path
        // Deleting in Finder is a move to the Trash, which the bookmark follows too.
        guard moved != path, !moved.contains("/.Trash/"), FileManager.default.fileExists(atPath: moved + "/.git") else { return nil }
        return moved
    }

    /// Carries color, star, skills, start command and notes over to the folder's new path.
    static func moveSettings(from old: String, to new: String) {
        for key in settingsKeys {
            guard var all = UserDefaults.standard.dictionary(forKey: key), let value = all.removeValue(forKey: old) else { continue }
            all[new] = value
            UserDefaults.standard.set(all, forKey: key)
        }
        let notes = notesURL(for: old)
        if FileManager.default.fileExists(atPath: notes.path) {
            try? FileManager.default.moveItem(at: notes, to: notesURL(for: new))
        }
    }

    // MARK: Reading

    func refresh() {
        // Coalesce: one refresh at a time, and one more if something changed meanwhile.
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        Task {
            await load()
            isRefreshing = false
            if needsRefresh {
                needsRefresh = false
                refresh()
            }
        }
    }

    private func load() async {
        guard FileManager.default.fileExists(atPath: path) else {
            if !isMissing { isMissing = true }
            // Stale status would offer a commit field for a folder that isn't there.
            if status != nil { status = nil }
            onMissing?()
            return
        }
        if isMissing { isMissing = false }
        if !savedBookmark {
            savedBookmark = true
            Self.saveBookmark(for: path)
        }
        if gitDir == nil {
            gitDir = try? await git(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        async let statusText = Git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: path)
        async let branchText = Git.run(["for-each-ref", Branch.refFormat, "refs/heads", "refs/remotes"], in: path)
        async let remoteText = Git.run(["remote"], in: path)
        async let numstatText = Git.run(["diff", "HEAD", "--numstat", "-z"], in: path)
        let (s, b, r, n) = await (statusText, branchText, remoteText, numstatText)
        // Every assignment to a @Published property redraws the panel and the window, even with the
        // same value, and this runs on every file change; so only what actually changed is assigned.
        var changed = false
        if s.succeeded, case let new = RepoStatus.parse(s.stdout), new != status {
            status = new
            changed = true
        }
        let stats = n.succeeded ? Self.parseNumstat(n.stdout) : nil
        if stats?.added != lineStats?.added || stats?.removed != lineStats?.removed {
            lineStats = stats
            changed = true
        }
        // A failed or timed-out call says nothing about the branches, so the last ones stay.
        if b.succeeded, case let new = Branch.parse(b.stdout), new != branches {
            branches = new
            changed = true
        }
        if r.succeeded, case let new = r.stdout.split(separator: "\n").map(String.init), new != remotes || !loadedWebPage {
            if new != remotes { remotes = new }
            loadedWebPage = true
            let page = await webURL()
            if page != webPage { webPage = page }
            pullRequestKey = nil
        }
        let key = "\(status?.branch ?? "")\u{1f}\(status?.upstream ?? "")\u{1f}\(webPage?.absoluteString ?? "")"
        if key != pullRequestKey {
            pullRequestKey = key
            Task { await refreshPullRequest() }
        }
        let operation = gitDir.flatMap { RepoOperation.detect(gitDir: $0) }
        if operation != self.operation { self.operation = operation }

        // Detection walks the project's folders (a few levels down for an app in a subfolder), which
        // can be slow on a big repository or a network disk, so it stays off the main thread.
        let root = path, folder = startFolder, files = status?.files.map(\.path) ?? []
        let detected = await Task.detached {
            let start = DevWorkspace.start(in: root, webOnly: true, folder: folder)
            // An app in a subfolder (nuxt/frontend) has nothing at the root to go by.
            let framework = Framework.detect(projectAt: root) ?? start?.folder.flatMap { Framework.detect(projectAt: root + "/" + $0) }
            return (command: start?.command, folder: start?.folder, framework: framework,
                    stamp: Self.worktreeStamp(path: root, files: files, numstat: n.stdout))
        }.value
        if detected.command != detectedStartCommand { detectedStartCommand = detected.command }
        if detected.folder != detectedStartFolder { detectedStartFolder = detected.folder }
        if detected.framework != framework { framework = detected.framework }

        if let gitDir, lastFetched == nil {
            lastFetched = (try? FileManager.default.attributesOfItem(atPath: gitDir + "/FETCH_HEAD"))?[.modificationDate] as? Date
        }
        // Editing a file that is already modified changes neither the status (porcelain v2 lists
        // HEAD's and the index's blobs, not the working tree's) nor, when a line is replaced, the line
        // counts; the open diff has to reload anyway, hence the stamp of the changed files on disk.
        if detected.stamp != lastWorktreeStamp {
            lastWorktreeStamp = detected.stamp
            changed = true
        }
        if changed { revision += 1 }
    }

    /// A hash of the per-file line counts and each changed file's size and modification date:
    /// cheap (one stat per changed file), and different whenever a changed file is saved again.
    private nonisolated static func worktreeStamp(path: String, files: [String], numstat: String) -> Int {
        var hasher = Hasher()
        hasher.combine(numstat)
        for file in files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(file))
            hasher.combine(file)
            hasher.combine(attributes?[.size] as? Int)
            hasher.combine((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    /// Sums `git diff --numstat -z`; binary files ("-") count as nothing. Renames put the paths
    /// in their own NUL-separated fields, so only fields starting with two counts are lines.
    private static func parseNumstat(_ text: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for field in text.split(separator: "\0") {
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            if let a = Int(parts[0]) { added += a }
            if let r = Int(parts[1]) { removed += r }
        }
        return (added, removed)
    }

    @discardableResult
    func git(_ args: [String], timeout: TimeInterval = 30) async throws -> String {
        try await Git.output(args, in: path, timeout: timeout)
    }

    func log(skip: Int, count: Int = 100) async -> [Commit] {
        guard status?.head != nil else { return [] }
        let text = (try? await git(["log", Commit.logFormat, "-n", "\(count)", "--skip", "\(skip)"])) ?? ""
        return Commit.parseLog(text)
    }

    /// Commits on HEAD that the upstream doesn't have yet.
    func unpushedShas() async -> Set<String> {
        let range = status?.upstream != nil ? "@{upstream}..HEAD" : remote.map { "HEAD --not --remotes=\($0)" }
        guard status?.head != nil, let range else { return [] }
        let text = (try? await git(["rev-list"] + range.split(separator: " ").map(String.init))) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// The diff of a working-tree change against HEAD (staged and unstaged together).
    func diff(for file: FileChange) async -> FileDiff {
        let args: [String]
        if file.isUntracked {
            args = ["diff", "--no-index", "--", "/dev/null", file.path]
        } else if status?.head == nil {
            args = ["diff", "--cached", "--", file.path]
        } else {
            args = ["diff", "HEAD", "-M", "--"] + [file.originalPath, file.path].compactMap { $0 }
        }
        // `diff --no-index` exits with 1 when the files differ.
        return FileDiff.parse(await Git.run(args, in: path).stdout)
    }

    func files(in commit: Commit) async -> [CommitFile] {
        let text = (try? await git(["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", commit.sha])) ?? ""
        return CommitFile.parse(text)
    }

    func diff(for file: CommitFile, in commit: Commit) async -> FileDiff {
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let text = (try? await git(["show", "--format=", "-M", "--diff-merges=first-parent", commit.sha, "--"] + paths)) ?? ""
        return FileDiff.parse(text)
    }

    func message(of commit: Commit) async -> String {
        (try? await git(["show", "-s", "--format=%B", commit.sha]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? commit.subject
    }

    // MARK: Changing

    /// Runs one user-visible operation at a time, reports its error and refreshes afterwards.
    @discardableResult
    func perform(_ activity: Activity, _ work: () async throws -> Void) async -> Bool {
        guard self.activity == nil else { return false }
        self.activity = activity
        defer {
            self.activity = nil
            refresh()
        }
        do {
            try await work()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func fetch(quietly: Bool = false) async {
        guard let remote else { return }
        if quietly {
            // Background fetches don't show errors (e.g. offline), and give way to anything the user does.
            guard activity == nil else { return }
            if await Git.run(["fetch", "--prune", remote], in: path, timeout: 120).succeeded { lastFetched = Date() }
            refresh()
            await refreshPullRequest()
            return
        }
        await perform(.fetching) {
            try await git(["fetch", "--prune", remote], timeout: 120)
            lastFetched = Date()
        }
        await refreshPullRequest()
    }

    func pull() async {
        await perform(.pulling) {
            // Like GitHub Desktop: merge unless the user has configured pull.rebase themselves.
            let configured = await Git.run(["config", "--get", "pull.rebase"], in: path).succeeded
            try await git(["pull"] + (configured ? [] : ["--no-rebase"]), timeout: Self.worktreeTimeout)
            lastFetched = Date()
        }
    }

    @discardableResult
    func push() async -> Bool {
        guard let remote else { return false }
        return await perform(.pushing) {
            if canPublish {
                try await git(["push", "--set-upstream", remote, "HEAD"], timeout: 300)
            } else {
                try await git(["push"], timeout: 300)
            }
        }
    }

    // MARK: Git hosts

    /// Creates the repository on `host` and pushes to it, like GitHub Desktop's Publish repository.
    /// `owner` is an organization or group, or nil for the user's own account. Without a commit yet
    /// there's nothing to push, so the repository is only created and set as origin.
    @discardableResult
    func publish(to host: any GitHost, name: String, description: String, isPrivate: Bool, owner: String?) async -> Bool {
        let hasCommit = status?.head != nil
        let path = path
        return await perform(.publishing) {
            let cli = await Task.detached { HostCLI(host: host) }.value
            try await host.publish(cli, in: path, name: name, description: description, isPrivate: isPrivate, owner: owner, hasCommit: hasCommit)
            lastFetched = Date()
        }
    }

    /// Opens the host's page for a new pull or merge request from the current branch, pushing it first
    /// if the host doesn't have all of it yet, as GitHub Desktop does.
    func createPullRequest() async {
        guard let host, let branch = status?.branch, let base = webPage else { return }
        if canPublish || (status?.ahead ?? 0) > 0 {
            guard await push() else { return }
        }
        if let url = host.newChangeRequestURL(base: base, from: branch, into: defaultBranch ?? "main") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPullRequest() async {
        guard let host, let branch = status?.branch, status?.upstream != nil else {
            if pullRequest != nil { pullRequest = nil }
            if host != nil, defaultBranch == nil { defaultBranch = await remoteDefaultBranch() }
            return
        }
        if defaultBranch == nil { defaultBranch = await remoteDefaultBranch() }
        let path = path
        let cli = await Task.detached { HostCLI(host: host) }.value
        let found = await host.openChangeRequest(cli, branch: branch, in: path)
        // Still on the same branch: a switch meanwhile looks up its own.
        if status?.branch == branch, found != pullRequest { pullRequest = found }
    }

    /// The remote's default branch, from `refs/remotes/<remote>/HEAD` (set by clone, or by `remote set-head`).
    private func remoteDefaultBranch() async -> String? {
        guard let remote else { return nil }
        let result = await Git.run(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: path)
        let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, ref.hasPrefix("\(remote)/") else {
            return branches.contains { $0.name == "\(remote)/main" } ? "main"
                : branches.contains { $0.name == "\(remote)/master" } ? "master" : nil
        }
        return String(ref.dropFirst(remote.count + 1))
    }

    /// Commits what is staged, or everything if nothing is.
    func commit(summary: String, description: String) async -> Bool {
        await perform(.committing) {
            // Ask git rather than trust `status`: something staged in Terminal a moment ago isn't in it yet.
            let staged = await Git.run(["diff", "--cached", "--quiet"], in: path)
            if staged.status == 0 { try await git(["add", "--all"], timeout: Self.worktreeTimeout) }
            var args = ["commit", "-m", summary]
            if !description.isEmpty { args += ["-m", description] }
            // Hooks like lint-staged can take a while, and stash and restore the working tree meanwhile.
            try await git(args, timeout: Self.worktreeTimeout)
        }
    }

    /// Asks Claude for a message describing what `commit` would commit: the staged changes, or everything if nothing is staged.
    func suggestCommitMessage() async -> (summary: String, description: String)? {
        do {
            var diff: String
            if status?.stagedCount != 0 || status?.head == nil {
                diff = try await git(["diff", "--cached", "-M"])
            } else {
                diff = try await git(["diff", "HEAD", "-M"])
            }
            if status?.stagedCount == 0 {
                let untracked = try await git(["ls-files", "--others", "--exclude-standard"])
                if !untracked.isEmpty { diff += "\nNew untracked files:\n\(untracked)" }
            }
            let message = try await Agent.commitMessage(for: diff, in: path)
            needsAgentLogin = false
            return message
        } catch is AgentLoginError {
            needsAgentLogin = true
            AgentStatus.shared.refresh()
            return nil
        } catch {
            // The cause may be in the agent's setup (a model it can't use), which the panel's top
            // notice can then offer to fix.
            AgentStatus.shared.refresh()
            self.error = error.localizedDescription
            return nil
        }
    }

    func setStaged(_ files: [FileChange], _ staged: Bool) async {
        // Staging a conflicted file marks it resolved, and Continue would then commit the conflict
        // markers. Staging all or a selection leaves those out; they're staged one at a time, once resolved.
        let files = staged ? files.filter { !$0.isConflicted } : files
        guard !files.isEmpty else { return }
        let paths = files.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
        await perform(.working) {
            if staged {
                try await git(["add", "--all", "--"] + paths, timeout: Self.worktreeTimeout)
            } else if status?.head == nil {
                try await git(["rm", "--cached", "-r", "-q", "--"] + paths, timeout: Self.worktreeTimeout)
            } else {
                try await git(["restore", "--staged", "--"] + paths, timeout: Self.worktreeTimeout)
            }
        }
    }

    /// Throws away local changes. The current contents go to the Trash first, so nothing is lost for good.
    func discard(_ files: [FileChange]) async {
        await perform(.working) {
            for file in files {
                try moveToTrash(file.path, keepCopy: !file.isUntracked && file.index != "A")
            }
            let tracked = files.filter { !$0.isUntracked && $0.index != "A" }
            let added = files.filter { $0.index == "A" }
            if !added.isEmpty {
                try await git(["rm", "--cached", "-r", "-q", "--force", "--"] + added.map(\.path), timeout: Self.worktreeTimeout)
            }
            if !tracked.isEmpty {
                let paths = tracked.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
                try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths, timeout: Self.worktreeTimeout)
            }
        }
    }

    /// Moves a file to the Trash, or for tracked files a copy of it (git restores the original).
    private func moveToTrash(_ relativePath: String, keepCopy: Bool) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        if keepCopy {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            target = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
        }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    func switchTo(_ branch: Branch) async {
        await perform(.switching) {
            if branch.isRemote {
                let local = branch.nameWithoutRemote
                if branches.contains(where: { !$0.isRemote && $0.name == local }) {
                    try await git(["switch", local], timeout: Self.worktreeTimeout)
                } else {
                    try await git(["switch", "--track", branch.name], timeout: Self.worktreeTimeout)
                }
            } else {
                try await git(["switch", branch.name], timeout: Self.worktreeTimeout)
            }
        }
    }

    func createBranch(_ name: String) async -> Bool {
        await perform(.switching) {
            try await git(["switch", "--create", name], timeout: Self.worktreeTimeout)
        }
    }

    func deleteBranch(_ branch: Branch) async {
        await perform(.working) {
            // -d refuses to delete unmerged work.
            try await git(["branch", "--delete", branch.name])
        }
    }

    func abortOperation() async {
        guard let operation else { return }
        await perform(.working) { try await git(operation.abortArgs, timeout: Self.worktreeTimeout) }
    }

    func continueOperation() async {
        guard let operation else { return }
        // There is no editor to write the message in, so keep git's prepared one.
        await perform(.working) { try await git(["-c", "core.editor=true"] + operation.continueArgs, timeout: Self.worktreeTimeout) }
    }

    // MARK: Elsewhere

    func reveal(_ relativePath: String? = nil) {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relativePath ?? "")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func absolutePath(_ relativePath: String) -> String {
        (path as NSString).appendingPathComponent(relativePath)
    }

    /// The remote's web page (GitHub, GitLab, …), if its URL can be turned into one.
    func webURL() async -> URL? {
        guard let remote, var url = try? await git(["remote", "get-url", remote]).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // git@github.com:owner/repo.git → https://github.com/owner/repo
        if url.hasPrefix("git@"), let colon = url.firstIndex(of: ":") {
            url = "https://" + url[url.index(url.startIndex, offsetBy: 4)..<colon] + "/" + url[url.index(after: colon)...]
        } else if url.hasPrefix("ssh://git@") {
            url = "https://" + url.dropFirst("ssh://git@".count)
        }
        if url.hasSuffix(".git") { url.removeLast(4) }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        return URL(string: url)
    }
}
