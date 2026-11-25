import AppKit
import Shared
import SwiftUI

/// The changed files, with a checkbox per file for staging, and the commit box below.
struct ChangesView: View {
    @ObservedObject var repo: Repository
    @EnvironmentObject private var state: ViewState
    @State private var pendingDiscard: [FileChange] = []
    /// Copies of each file's path, for the "Copied" confirmation on its row.
    @State private var copies: [String: Int] = [:]

    private var files: [FileChange] { repo.status?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if let operation = repo.operation {
                OperationBanner(repo: repo, operation: operation)
                Divider()
            }

            if files.isEmpty {
                ContentUnavailableView("No local changes", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Only the checkbox for all files: the tab above already says how many changed.
                HStack(spacing: 8) {
                    StageCheckbox(staging: overallStaging,
                                  help: overallStaging == .all ? "Unstage all" : "Stage all",
                                  label: "All files staged") {
                        Task { await repo.setStaged(files, overallStaging != .all) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()

                List(selection: $state.files) {
                    ForEach(files) { file in
                        FileRow(file: file) {
                            Task { await repo.setStaged([file], file.staging != .all) }
                        }
                        .copiedConfirmation(copies[file.id] ?? 0)
                        .tag(file.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { ids in
                    let selected = files.filter { ids.contains($0.id) }
                    if !selected.isEmpty { menu(for: selected) }
                } primaryAction: { ids in
                    // A double-click opens the file in an editor; Rex and Terminal would only open its folder.
                    if let first = ids.first, let editor = Editor.installed.first(where: { $0.name != "Finder" && !$0.isTerminal }) {
                        editor.open(repo.absolutePath(first))
                    }
                }
                // Space stages or unstages the selected files and Delete asks to discard them, as in GitHub Desktop.
                .onKeyPress(.space) {
                    let selected = selectedFiles.filter { !$0.isConflicted }
                    guard !selected.isEmpty else { return .ignored }
                    let anyUnstaged = selected.contains { $0.staging != .all }
                    Task { await repo.setStaged(selected, anyUnstaged) }
                    return .handled
                }
                .onDeleteCommand {
                    if !selectedFiles.isEmpty { pendingDiscard = selectedFiles }
                }
                // ⌘C copies the selected files' paths, one per line, as Finder and Xcode copy what's selected.
                .onCopyCommand {
                    for file in selectedFiles { copies[file.id, default: 0] += 1 }
                    let paths = selectedFiles.map(\.path)
                    return paths.isEmpty ? [] : [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
                }
            }

            Divider()
            CommitBox(repo: repo)
        }
        .confirmationDialog(
            pendingDiscard.count == 1 ? "Discard changes to \(pendingDiscard[0].fileName)?" : "Discard changes to \(pendingDiscard.count) files?",
            isPresented: Binding(get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } })
        ) {
            Button("Discard changes", role: .destructive) {
                let files = pendingDiscard
                pendingDiscard = []
                Task { await repo.discard(files) }
            }
        } message: {
            Text("The current contents are moved to the Trash, so you can get them back from there.")
        }
    }

    private var selectedFiles: [FileChange] { files.filter { state.files.contains($0.id) } }

    private var overallStaging: FileChange.Staging {
        let staged = files.map(\.staging)
        if staged.allSatisfy({ $0 == .all }) { return .all }
        if staged.allSatisfy({ $0 == .none }) { return .none }
        return .partial
    }

    @ViewBuilder
    private func menu(for selected: [FileChange]) -> some View {
        let anyUnstaged = selected.contains { $0.staging != .all }
        // The shortcuts are shown for discovery; they work in the list without the menu (see `body`).
        Button(anyUnstaged ? "Stage" : "Unstage") { Task { await repo.setStaged(selected, anyUnstaged) } }
            .keyboardShortcut(.space, modifiers: [])
        Button(selected.count == 1 ? "Discard changes…" : "Discard \(selected.count) changes…") { pendingDiscard = selected }
            .keyboardShortcut(.delete, modifiers: [])
        // New files that shouldn't be committed (build output, a local .env) are the usual reason to
        // right-click one; GitHub Desktop offers the same two.
        if selected.allSatisfy(\.isUntracked) {
            Divider()
            Button(selected.count == 1 ? "Ignore file" : "Ignore \(selected.count) files") {
                ignore(selected.map { "/" + Self.escapedForGitignore($0.path) })
            }
            if selected.count == 1, let ext = selected.first.map({ ($0.fileName as NSString).pathExtension }), !ext.isEmpty {
                Button("Ignore all .\(ext) files") { ignore(["*." + Self.escapedForGitignore(ext)]) }
            }
        }
        Divider()
        if selected.count == 1, let file = selected.first {
            ForEach(Editor.installed.filter { $0.name != "Finder" && !$0.isTerminal }) { editor in
                Button("Open in \(editor.name)") { editor.open(repo.absolutePath(file.path)) }
            }
            Button("Show in Finder") { repo.reveal(file.path) }
            Button("Copy path") {
                Pasteboard.copy(file.path)
                copies[file.id, default: 0] += 1
            }
            .keyboardShortcut("c", modifiers: .command)
        }
    }

    /// Adds patterns to the repository's .gitignore (creating it), on a line each, then looks again.
    private func ignore(_ patterns: [String]) {
        let url = URL(fileURLWithPath: repo.absolutePath(".gitignore"))
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += patterns.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            repo.error = "Couldn't update .gitignore: \(error.localizedDescription)"
        }
        state.files = []
        repo.refresh()
    }

    /// A leading # or ! and the glob characters mean something in .gitignore; a file named with them is escaped.
    private static func escapedForGitignore(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if let first = escaped.first, first == "#" || first == "!" { escaped.insert("\\", at: escaped.startIndex) }
        return escaped
    }
}

private struct OperationBanner: View {
    @ObservedObject var repo: Repository
    let operation: RepoOperation

    var body: some View {
        let conflicts = repo.status?.conflictCount ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Label("\(operation.rawValue) in progress", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(conflicts > 0
                 ? "Resolve \(conflicts == 1 ? "1 conflicted file" : "\(conflicts) conflicted files") in your editor, then stage them."
                 : "All conflicts are resolved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Abort \(operation.rawValue.lowercased())") { Task { await repo.abortOperation() } }
                Button("Continue") { Task { await repo.continueOperation() } }
                    .disabled(conflicts > 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.quinary)
    }
}

struct StageCheckbox: View {
    let staging: FileChange.Staging
    /// The tooltip for the checkbox over all files, instead of Stage/Unstage.
    var help: String? = nil
    var label = "Staged"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: staging == .all ? "checkmark.square.fill" : staging == .partial ? "minus.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(staging == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .panelTooltip(help ?? (staging == .all ? "Unstage (Space)" : "Stage (Space)"))
        // A checkbox to VoiceOver too, with the partly staged state the symbol shows.
        .accessibilityLabel(label)
        .accessibilityValue(staging == .all ? "On" : staging == .partial ? "Partly" : "Off")
    }
}

private struct FileRow: View {
    let file: FileChange
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if file.isConflicted {
                Image(systemName: "square").foregroundStyle(.tertiary).font(.system(size: 14))
            } else {
                StageCheckbox(staging: file.staging, action: toggle)
            }
            PathLabel(directory: file.directory, fileName: file.fileName)
            Spacer(minLength: 4)
            KindBadge(kind: file.kind)
        }
        .padding(.vertical, 1)
    }
}

/// "src/components/" dimmed, then "Button.tsx", truncating the folder first.
struct PathLabel: View {
    let directory: String
    let fileName: String

    var body: some View {
        // The folder truncates from the front, but only while there's room for "…/" and a bit of it:
        // squeezed further it showed a clipped first letter before the name, so then it's left out.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                // Roughly the folder's own width when that's less, so a short one ("ui/") leaves no gap.
                let least = min(24, CGFloat(directory.count) * 5)
                folder.frame(minWidth: least, idealWidth: least, alignment: .trailing)
                name
            }
            name
        }
        .font(.callout)
    }

    private var folder: some View {
        Text(verbatim: directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
    }

    private var name: some View {
        Text(verbatim: fileName).lineLimit(1).truncationMode(.middle).layoutPriority(1)
    }
}

struct KindBadge: View {
    let kind: FileChange.Kind

    var body: some View {
        let (symbol, color, help): (String, Color, String) = switch kind {
        case .added: ("plus.square.fill", .green, "Added")
        case .untracked: ("plus.square.fill", .green, "New file")
        case .modified: ("pencil.circle.fill", .orange, "Modified")
        case .deleted: ("minus.square.fill", .red, "Deleted")
        case .renamed: ("arrow.right.square.fill", .blue, "Renamed")
        case .copied: ("doc.on.doc.fill", .blue, "Copied")
        case .typeChanged: ("t.square.fill", .purple, "Type changed")
        case .conflicted: ("exclamationmark.triangle.fill", .red, "Conflicted")
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.system(size: 12))
            .accessibilityLabel(help)
    }
}

private struct CommitBox: View {
    @ObservedObject var repo: Repository
    @EnvironmentObject private var state: ViewState
    @State private var isSuggesting = false
    @FocusState private var descriptionFocused: Bool
    @FocusState private var summaryFocused: Bool
    @ObservedObject private var keys = ModifierKeys.shared

    private var summary: String { state.summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Commit & Push unless ⌥ is held or there's nowhere to push, like the quick commit in the menu bar panel.
    private var pushes: Bool { repo.remote != nil && !keys.option }

    private var title: String {
        let status = repo.status
        let staged = status?.stagedCount ?? 0
        let branch = status?.branch ?? "HEAD"
        let verb = pushes ? "Commit & Push" : "Commit"
        if staged == 0 {
            let all = status?.files.count ?? 0
            return all == 1 ? "\(verb) 1 file to \(branch)" : "\(verb) all \(all) files to \(branch)"
        }
        return staged == 1 ? "\(verb) 1 file to \(branch)" : "\(verb) \(staged) files to \(branch)"
    }

    private var disabledReason: String? {
        guard let status = repo.status else { return "" }
        if status.files.isEmpty && repo.operation == nil { return "No changes to commit" }
        if status.conflictCount > 0 { return "Resolve conflicts first" }
        if summary.isEmpty { return "Write a summary" }
        return nil
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(isSuggesting ? "" : "Summary", text: $state.summary)
                // Return goes on to the description, the next thing to write; ⌘↩ commits from either.
                .onSubmit { descriptionFocused = true }
                .focused($summaryFocused)
                .claudeWrites(isEmpty: state.summary.isEmpty, isWriting: isSuggesting,
                              enabled: repo.status?.files.isEmpty == false, action: suggest)
                .panelField(isFocused: summaryFocused)
            if repo.needsAgentLogin {
                AgentLoginNotice(message: "\(Agent.current.shortName) needs you to log in again.",
                                 dismiss: { repo.needsAgentLogin = false },
                                 done: { repo.needsAgentLogin = false; suggest() })
            }
            // A native multi-line field, the same look as the summary above it, growing with the text up
            // to a limit; it replaced a TextEditor with a drawn border and a placeholder laid over it.
            // In a multi-line TextField ⌥↩ makes a new line (Return ends editing).
            TextField("Description", text: $state.description, axis: .vertical)
                .lineLimit(3...8)
                .focused($descriptionFocused)
                .panelField(isFocused: descriptionFocused)

            Button(action: commit) {
                if repo.activity == .committing || repo.activity == .pushing {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text(title).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(disabledReason != nil || repo.activity != nil)
        }
        .padding(12)
    }

    private func suggest() {
        isSuggesting = true
        Task {
            if let message = await repo.suggestCommitMessage() {
                // The shimmer's light finishes its pass, and the message comes in on the beat after it.
                if state.summary.isEmpty { try? await Task.sleep(for: .seconds(ShimmerText.untilPassEnds())) }
                isSuggesting = false
                // Someone who started typing meanwhile keeps their own message.
                guard state.summary.isEmpty else { return }
                // Written in a few words at a time, the summary and then the description.
                state.description = ""
                await PanelMotion.typeOut(message.summary, current: { state.summary }, set: { state.summary = $0 })
                await PanelMotion.typeOut(message.description, current: { state.description }, set: { state.description = $0 })
            }
            isSuggesting = false
        }
    }

    private func commit() {
        guard disabledReason == nil else { return }
        let summary = self.summary
        let description = state.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let andPush = pushes
        Task {
            guard await repo.commit(summary: summary, description: description) else { return }
            state.summary = ""
            state.description = ""
            if andPush { await repo.push() }
        }
    }
}

/// The diff of the selected changed file, or a summary when nothing is selected.
struct ChangesDetail: View {
    @ObservedObject var repo: Repository
    @EnvironmentObject private var state: ViewState
    @State private var diff: FileDiff?

    private var selected: FileChange? {
        guard state.files.count == 1, let id = state.files.first else { return nil }
        return repo.status?.files.first { $0.id == id }
    }

    var body: some View {
        if let file = selected {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    KindBadge(kind: file.kind)
                    Text(verbatim: file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer()
                    IconButton(systemName: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                        EditorMenu.show(for: repo.absolutePath(file.path))
                    }
                    IconButton(systemName: "folder", help: "Show in Finder") { repo.reveal(file.path) }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Divider()
                DiffView(diff: diff)
            }
            // Reload when the file is changed on disk, too.
            .task(id: "\(file.id)|\(repo.revision)") {
                let new = await repo.diff(for: file)
                // A slow diff of the previously selected file mustn't replace the one now selected.
                guard !Task.isCancelled, selected?.id == file.id else { return }
                diff = new
            }
        } else {
            NoSelection(repo: repo, count: state.files.count)
        }
    }
}

private struct NoSelection: View {
    @ObservedObject var repo: Repository
    let count: Int

    var body: some View {
        if count > 1 {
            Placeholder(title: "\(count) files selected", detail: "Press Space to stage or unstage them, Delete to discard them, or right-click for more.", systemImage: "doc.on.doc") { EmptyView() }
        } else if repo.hasChanges {
            Placeholder(title: "Select a file", systemImage: "doc.text.magnifyingglass") { EmptyView() }
        } else {
            // Publish, push and pull request are in the top bar already, so only the editor is offered here.
            Placeholder(title: "No local changes", systemImage: "checkmark.circle") {
                // One button for the first editor and a menu for the rest, rather than a button per app.
                let editors = Editor.installed.filter { $0.name != "Finder" }
                if let first = editors.first {
                    Menu("Open in \(first.name)") {
                        ForEach(Editor.installed) { editor in
                            Button("Open in \(editor.name)") { editor.open(repo.path) }
                        }
                    } primaryAction: {
                        first.open(repo.path)
                    }
                    .fixedSize()
                }
            }
        }
    }
}
