import Shared
import SwiftUI

/// Sets a repository's own start command, for projects whose dev server isn't recognized,
/// like an API folder with a `start.py` that starts several services. Scripts in the folder are one click,
/// and so is picking which app to start in a repository with several.
struct StartCommandEditor: View {
    @FocusState private var commandFocused: Bool
    @ObservedObject var repo: Repository
    /// A page of the menu bar panel (`PanelPage.startCommand`): its header has the title and the way back,
    /// so the form leaves out Cancel, says which repository it's for, and fills the panel's width.
    /// The main window still shows it as a popover.
    var isPage = false
    let dismiss: () -> Void
    @State private var command = ""
    /// The command that was suggested as interactive (`runsInTerminal`).
    @State private var terminalCommand: String?
    @State private var scripts: [String] = []
    /// Folders with an app we know how to start, "" for the root.
    @State private var apps: [String] = []
    @State private var finding: Task<Void, Never>?
    /// What the agent said about the command it found, or why it found none.
    @State private var findResult: (text: String, found: Bool)?
    @State private var findError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No headings over the chips or text above the field: the page's title names the repository, and
            // the chips say what they are (folders with a check on the one in use, script file names).
            if apps.count > 1 {
                FlowLayout(spacing: 4) {
                    ForEach(apps, id: \.self) { folder in
                        let current = repo.customStart == nil && (repo.detectedStartFolder ?? "") == folder
                        Button {
                            repo.startFolder = folder.isEmpty ? nil : folder
                            repo.customStart = nil
                            dismiss()
                        } label: {
                            Label(folder.isEmpty ? "Root" : folder, systemImage: "checkmark")
                                .labelStyle(CheckmarkLabelStyle(checked: current))
                        }
                        .controlSize(.small)
                    }
                }
            }
            // Empty while the agent looks, which the field then says itself (as the commit field does).
            TextField(finding != nil ? "" : repo.detectedStartCommand == nil ? "uv run start.py" : "Detected command", text: $command)
                .onSubmit(save)
                .focused($commandFocused)
                // As the commit message field: "Find with Claude ⇥" in the empty field, and the field shimmers while it looks.
                .claudeWrites(isEmpty: command.isEmpty, isWriting: finding != nil, verb: "Find", working: "is reading the project…",
                              needs: .readsProject, action: find)
                .panelField()
            findNote
            if runsInTerminal {
                Text("Opens in \(Terminals.current?.name ?? "Terminal"), as it asks for input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !scripts.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(scripts, id: \.self) { script in
                        Button(script) { choose(script) }
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                if repo.customStart != nil {
                    Button(repo.detectedStartCommand == nil ? "Remove" : "Use detected") {
                        repo.customStart = nil
                        dismiss()
                    }
                }
                Spacer()
                if !isPage {
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .prominentButton()
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .frame(width: isPage ? nil : 340)
        .frame(maxWidth: isPage ? .infinity : nil, alignment: .leading)
        .onDisappear { finding?.cancel() }
        .focusesWhenShown { commandFocused = true }
        .task {
            command = repo.customStart?.command ?? ""
            terminalCommand = repo.customStart?.inTerminal == true ? repo.customStart?.command : nil
            let path = repo.path
            (scripts, apps) = await Task.detached {
                let atRoot = DevWorkspace.start(in: path, webOnly: true).map { $0.folder == nil } ?? false
                return (Array(DevWorkspace.startScripts(in: path).prefix(8)), (atRoot ? [""] : []) + DevWorkspace.appFolders(in: path).map(\.folder))
            }.value
        }
    }

    /// What the agent said under the field: what its command starts, or (orange) why nothing can start
    /// the project, or (red) why it couldn't look.
    @ViewBuilder private var findNote: some View {
        if let note = findError.map({ (text: $0, color: Color.red) })
            ?? findResult.map({ (text: $0.text, color: $0.found ? Color.secondary : Color.orange) }) {
            Text(note.text)
                .font(.caption)
                .foregroundStyle(note.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The agent in use looks through the project and fills in a command, or says why nothing can start it.
    /// It only reads (`readOnlyArguments`), so nothing is installed or run until the user saves and presses play.
    private func find() {
        findResult = nil
        findError = nil
        let path = repo.path
        let server = repo.server
        // What Bridge would run, and how it ended when it failed, so the agent doesn't hand back the same thing.
        var tried: String?
        if case .exited(let code) = server.state, code != 0, let last = server.command {
            let output = server.lastOutput.components(separatedBy: .newlines).suffix(40).joined(separator: "\n")
            tried = "\(last)\n\nIts last output:\n\(output)"
        }
        finding = Task {
            do {
                let suggestion = try await Agent.findStartCommand(in: path, tried: tried)
                guard !Task.isCancelled else { return }
                // On the shimmer's beat and a few words at a time, as a commit message comes in.
                try? await Task.sleep(for: .seconds(ShimmerText.untilPassEnds()))
                finding = nil
                if let found = suggestion.command, command.isEmpty {
                    terminalCommand = suggestion.inTerminal ? found : nil
                    await PanelMotion.typeOut(found, current: { command }, set: { command = $0 })
                }
                findResult = (suggestion.reason.isEmpty ? (suggestion.command == nil ? "Found no way to start it." : "Found a command.") : suggestion.reason,
                              suggestion.command != nil)
            } catch {
                guard !Task.isCancelled else { return }
                finding = nil
                findError = error.localizedDescription
            }
        }
    }

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only a command known to be interactive opens in a terminal: a script that reads input or draws a
    /// full-screen status (`DevWorkspace.command(forScript:)`), or one the agent said does. Changing the
    /// command drops that, as it's about that command. A switch for it was one more thing to decide, and
    /// whoever chose the command already knew.
    private var runsInTerminal: Bool { terminalCommand != nil && terminalCommand == trimmed }

    private func choose(_ script: String) {
        let suggestion = DevWorkspace.command(forScript: script, in: repo.path)
        command = suggestion.command
        terminalCommand = suggestion.needsTerminal ? suggestion.command : nil
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        repo.customStart = .init(command: trimmed, inTerminal: runsInTerminal)
        dismiss()
    }
}

/// A checkmark in front of the chosen option, and room for one in front of the others so they line up.
private struct CheckmarkLabelStyle: LabelStyle {
    let checked: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.opacity(checked ? 1 : 0)
            configuration.title
        }
    }
}
