import AppKit
import Shared
import SwiftUI

/// Commits on the current branch, newest first, loading more as you scroll.
struct HistoryView: View {
    @ObservedObject var repo: Repository
    @EnvironmentObject private var state: ViewState
    @State private var commits: [Commit] = []
    @State private var unpushed: Set<String> = []
    @State private var reachedEnd = false
    @State private var loadingMore = false
    /// Whether the first page has come in, to tell an empty history from one still loading.
    @State private var loaded = false
    /// Bumped whenever the list is loaded from the start, so a page asked for before that is dropped.
    @State private var generation = 0
    /// What's typed in the search field, and the commits git found for it (nil while not searching).
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var results: [Commit]?
    /// The commit whose Create branch prompt is open, and the name typed in it.
    @State private var branchFrom: Commit?
    @State private var branchName = ""
    /// Copies made from each commit's row, by SHA, for the "Copied" confirmation on that row.
    @State private var copies: [String: Int] = [:]

    private var shown: [Commit] { results ?? commits }

    /// Reload when HEAD moves or the upstream changes, not on every file change.
    private var reloadKey: String {
        let status = repo.status
        return "\(status?.head ?? "")|\(status?.branch ?? "")|\(status?.ahead ?? 0)|\(status?.behind ?? 0)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Finding a commit by its message, author or SHA is the first thing people look for in a
            // history; git searches the whole history, not just the pages loaded so far.
            if !commits.isEmpty || !query.isEmpty {
                TextField("Search commits", text: $query)
                    .onExitCommand { query = "" }
                    .focused($searchFocused)
                    .panelField(compact: true)
                    .padding(8)
                Divider()
            }
            list
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { results = nil; return }
            // Wait for a pause in the typing rather than run git on every key.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await repo.searchCommits(text)
            guard !Task.isCancelled else { return }
            results = found
        }
        .alert("Create a branch from \(branchFrom?.shortSha ?? "")", isPresented: Binding(get: { branchFrom != nil }, set: { if !$0 { branchFrom = nil } })) {
            TextField("Branch name", text: $branchName)
            Button("Create and switch") {
                let name = branchName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                if let commit = branchFrom, !name.isEmpty { Task { await repo.createBranch(name, at: commit) } }
                branchFrom = nil
            }
            Button("Cancel", role: .cancel) { branchFrom = nil }
        } message: {
            Text("Uncommitted changes come along.")
        }
    }

    @ViewBuilder private var list: some View {
        Group {
            if shown.isEmpty {
                // A spinner while the first page loads, instead of a blank column that looks like an empty history.
                if !loaded || (!query.isEmpty && results == nil) {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No commits yet", systemImage: "clock")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(selection: Binding(get: { state.commit?.id }, set: { id in
                    state.commit = shown.first { $0.id == id }
                    state.commitFile = nil
                })) {
                    ForEach(shown) { commit in
                        CommitRow(commit: commit, isUnpushed: unpushed.contains(commit.sha))
                            .copiedConfirmation(copies[commit.sha] ?? 0)
                            .tag(commit.id)
                            .onAppear { if results == nil, commit.id == commits.last?.id { loadMore() } }
                            .contextMenu { menu(for: commit) }
                    }
                    if loadingMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.plain)
                // ⌘C copies the selected commit's SHA, the thing a commit is referred to by elsewhere.
                .onCopyCommand {
                    guard let sha = state.commit?.sha else { return [] }
                    copies[sha, default: 0] += 1
                    return [NSItemProvider(object: sha as NSString)]
                }
            }
        }
        .task(id: reloadKey) {
            generation += 1
            async let first = repo.log(skip: 0)
            async let ahead = repo.unpushedShas()
            commits = await first
            loaded = true
            // Again once the new list is in, for a page asked for while it was loading.
            generation += 1
            unpushed = await ahead
            reachedEnd = commits.count < 100
            if let selected = state.commit, !commits.contains(selected) { state.commit = nil }
        }
    }

    private func loadMore() {
        guard !reachedEnd, !loadingMore else { return }
        loadingMore = true
        let started = generation
        Task {
            let more = await repo.log(skip: commits.count)
            loadingMore = false
            // The list was reloaded meanwhile (a commit, a pull): this page belongs to the old one and
            // would repeat commits already in the new list.
            guard generation == started else { return }
            commits += more
            reachedEnd = more.count < 100
        }
    }

    @ViewBuilder
    private func menu(for commit: Commit) -> some View {
        // Undo only the newest commit while it isn't pushed, like GitHub Desktop: its changes come back
        // staged and its message back in the commit box, so nothing is lost and nothing shared is rewritten.
        if canUndo(commit) {
            Button("Undo commit") { undo(commit) }
            Divider()
        }
        // A local branch label on the row: switching to it is what clicking one is mostly for.
        let localBranches = repo.branches.filter { branch in
            !branch.isRemote && branch.name != repo.status?.branch && commit.refs.contains { $0 == branch.name || $0 == "HEAD -> \(branch.name)" }
        }
        ForEach(localBranches) { branch in
            Button("Switch to \(branch.name)") { Task { await repo.switchTo(branch) } }
        }
        Button("Create branch from commit…") {
            branchName = ""
            branchFrom = commit
        }
        // A new commit that undoes this one: safe on pushed history, and itself undoable.
        Button("Revert this commit") { Task { await repo.revert(commit) } }
            .disabled(repo.operation != nil || repo.activity != nil)
        Divider()
        Button("Copy SHA") { copy(commit.sha, from: commit) }
            .keyboardShortcut("c", modifiers: .command)
        Button("Copy summary") { copy(commit.subject, from: commit) }
        Button("View on the web") {
            Task {
                if let base = await repo.webURL() { NSWorkspace.shared.open(base.appendingPathComponent("commit/\(commit.sha)")) }
            }
        }
    }

    private func canUndo(_ commit: Commit) -> Bool {
        commit.sha == repo.status?.head && !commit.parents.isEmpty && unpushed.contains(commit.sha)
            && repo.operation == nil && repo.activity == nil
    }

    private func undo(_ commit: Commit) {
        Task {
            let message = await repo.message(of: commit)
            guard await repo.undoCommit(commit) else { return }
            // Its message goes back where it was written, unless something else has been typed there since.
            if state.summary.isEmpty && state.description.isEmpty {
                let lines = message.components(separatedBy: "\n")
                state.summary = lines.first ?? commit.subject
                state.description = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            state.commit = nil
            state.tab = .changes
        }
    }

    /// Copies, and confirms it on the commit's row (by SHA, so only that row's confirmation shows).
    private func copy(_ text: String, from commit: Commit) {
        Pasteboard.copy(text)
        copies[commit.sha, default: 0] += 1
    }
}

/// What History's right-click menu and search do with git. Here rather than in Repository.swift, as only History uses them.
extension Repository {
    /// Commits whose message or author contains `text` (any case), or the commit `text` names (a SHA
    /// or its start), newest first. From the whole history, not only the pages loaded.
    func searchCommits(_ text: String) async -> [Commit] {
        guard status?.head != nil else { return [] }
        async let byMessage = git(["log", Commit.logFormat, "-n", "200", "-i", "--fixed-strings", "--grep", text])
        async let byAuthor = git(["log", Commit.logFormat, "-n", "200", "-i", "--fixed-strings", "--author", text])
        var found = Commit.parseLog((try? await byMessage) ?? "") + Commit.parseLog((try? await byAuthor) ?? "")
        let isHex = text.count >= 4 && text.allSatisfy(\.isHexDigit)
        if isHex, let named = try? await git(["log", Commit.logFormat, "-n", "1", text, "--"]) {
            found += Commit.parseLog(named)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.sha).inserted }.sorted { $0.date > $1.date }
    }

    /// Takes the newest commit back out, leaving its changes staged (`reset --soft`).
    func undoCommit(_ commit: Commit) async -> Bool {
        guard commit.sha == status?.head, !commit.parents.isEmpty else { return false }
        return await perform(.working) {
            try await git(["reset", "--soft", "HEAD~1"])
        }
    }

    /// Commits the opposite of `commit`. A merge is reverted against its first parent, the branch it was merged into.
    func revert(_ commit: Commit) async {
        await perform(.committing) {
            try await git(["revert", "--no-edit"] + (commit.parents.count > 1 ? ["-m", "1"] : []) + [commit.sha], timeout: 600)
        }
    }

    /// A new branch at `commit`, switched to.
    func createBranch(_ name: String, at commit: Commit) async {
        await perform(.switching) {
            try await git(["switch", "--create", name, commit.sha], timeout: 600)
        }
    }
}

private struct CommitRow: View {
    let commit: Commit
    let isUnpushed: Bool

    /// "HEAD -> main" → "main"; a tag loses its "tag:" prefix and is marked with the tag symbol instead.
    private var labels: [(name: String, isTag: Bool)] {
        commit.refs.compactMap { ref in
            if ref == "HEAD" { return nil }
            if ref.hasPrefix("HEAD -> ") { return (String(ref.dropFirst(8)), false) }
            if ref.hasPrefix("tag: ") { return (String(ref.dropFirst(5)), true) }
            return (ref, false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: commit.subject)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(verbatim: "\(commit.author) · \(commit.date.relative)")
                    .lineLimit(1)
                Spacer(minLength: 4)
                ForEach(labels.prefix(2), id: \.name) { label in
                    Label(label.name, systemImage: label.isTag ? "tag" : "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .background(.tint.quaternary, in: .capsule)
                }
                if isUnpushed {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// The selected commit: its message and author, the files it touched and the diff of one of them.
struct HistoryDetail: View {
    @ObservedObject var repo: Repository
    @EnvironmentObject private var state: ViewState

    var body: some View {
        if let commit = state.commit {
            CommitDetail(repo: repo, commit: commit, selectedFile: $state.commitFile)
                .id(commit.id)
        } else {
            Placeholder(title: "Select a commit", systemImage: "clock.arrow.circlepath") { EmptyView() }
        }
    }
}

private struct CommitDetail: View {
    @ObservedObject var repo: Repository
    let commit: Commit
    @Binding var selectedFile: String?
    @Environment(\.detailMinWidth) private var detailMinWidth
    @State private var paneWidth: CGFloat = 0
    @State private var message: String?
    @State private var files: [CommitFile] = []
    @State private var diff: FileDiff?
    @State private var copied = false
    /// Copies of each file's path, for the "Copied" confirmation on its row.
    @State private var fileCopies: [String: Int] = [:]

    private var fileListMin: CGFloat { (detailMinWidth * 0.38).rounded(.down) }
    private var diffMin: CGFloat { (detailMinWidth * 0.56).rounded(.down) }
    private var fileListMax: CGFloat {
        guard paneWidth > 0 else { return 300 }
        // Under half of this side, so in a narrow window the diff keeps most of it.
        return max(fileListMin, min(300, (paneWidth * 0.45).rounded(.down), paneWidth - diffMin - 12))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                let body = (message ?? commit.subject)
                // Scrolls past a few lines instead of cutting a long message off at eight.
                ScrollView {
                    Text(verbatim: body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(verbatim: commit.author).fontWeight(.medium)
                    Text(commit.date, format: .dateTime.day().month().year().hour().minute())
                    Button {
                        Pasteboard.copy(commit.sha)
                        copied = true
                    } label: {
                        // A checkmark for a moment, so the click visibly did something.
                        Label(copied ? "Copied" : commit.shortSha, systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.borderless)
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                    Spacer()
                    Text(files.count == 1 ? "1 file" : "\(files.count) files")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            HSplitView {
                List(files, selection: $selectedFile) { file in
                    HStack(spacing: 6) {
                        PathLabel(directory: file.directory, fileName: file.fileName)
                        Spacer(minLength: 4)
                        KindBadge(kind: file.kind)
                    }
                    .copiedConfirmation(fileCopies[file.id] ?? 0)
                    .tag(file.id)
                }
                .listStyle(.plain)
                // As in Changes: a double-click opens the file (as it is now) in an editor, a right-click has the rest.
                .contextMenu(forSelectionType: String.self) { ids in
                    if let file = files.first(where: { ids.contains($0.id) }) {
                        if file.kind != .deleted {
                            ForEach(Editor.installed.filter { $0.name != "Finder" && !$0.isTerminal }) { editor in
                                Button("Open in \(editor.name)") { editor.open(repo.absolutePath(file.path)) }
                            }
                            Button("Show in Finder") { repo.reveal(file.path) }
                        }
                        Button("Copy path") {
                            Pasteboard.copy(file.path)
                            fileCopies[file.id, default: 0] += 1
                        }
                    }
                } primaryAction: { ids in
                    guard let file = files.first(where: { ids.contains($0.id) }), file.kind != .deleted,
                          let editor = Editor.installed.first(where: { $0.name != "Finder" && !$0.isTerminal }) else { return }
                    editor.open(repo.absolutePath(file.path))
                }
                // Together no wider than the room the window has for this side (`MainLayout.Widths`), and
                // never so wide the diff can't keep its minimum: the split view only shrinks its last pane.
                .frame(minWidth: fileListMin, idealWidth: MainLayout.Widths.ideal(240, fileListMin, fileListMax), maxWidth: fileListMax)
                DiffView(diff: selectedFile == nil ? nil : diff)
                    .frame(minWidth: diffMin, maxWidth: .infinity)
            }
            // This side's own width, set by the window's split view; the panes' minimums fit inside it.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        }
        .task {
            async let text = repo.message(of: commit)
            async let list = repo.files(in: commit)
            message = await text
            files = await list
            if selectedFile == nil { selectedFile = files.first?.id }
        }
        // Also once the files have loaded: when this view is rebuilt (a pane came or went) the file is
        // already selected, so a task keyed on the selection alone ran before the list was there and
        // the diff stayed blank.
        .task(id: [selectedFile ?? "", "\(files.count)"]) {
            guard let file = files.first(where: { $0.id == selectedFile }) else { return }
            let new = await repo.diff(for: file, in: commit)
            // A slow diff of the previously selected file mustn't replace the one now selected.
            guard !Task.isCancelled, selectedFile == file.id else { return }
            diff = new
        }
    }
}
