import Shared
import SwiftUI

/// Sets a repository's own start command, for projects whose dev server isn't recognized,
/// like an API folder with a `start.py` that starts several services. Scripts in the folder are one click,
/// and so is picking which app to start in a repository with several.
struct StartCommandEditor: View {
    @FocusState private var commandFocused: Bool
    @ObservedObject var repo: Repository
    let dismiss: () -> Void
    @State private var command = ""
    @State private var inTerminal = false
    @State private var scripts: [String] = []
    /// Folders with an app we know how to start, "" for the root.
    @State private var apps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if apps.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps in this repository").font(.caption).foregroundStyle(.secondary)
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
            }
            TextField(repo.detectedStartCommand == nil ? "uv run start.py" : "Detected command", text: $command)
                .font(.system(.body, design: .monospaced))
                .onSubmit(save)
                .focused($commandFocused)
                .panelField(isFocused: commandFocused)
            if !scripts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scripts in this folder").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(scripts, id: \.self) { script in
                            Button(script) { choose(script) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            PanelSwitch("Run in Terminal", isOn: $inTerminal)
            HStack {
                if repo.customStart != nil {
                    Button(repo.detectedStartCommand == nil ? "Remove" : "Use detected") {
                        repo.customStart = nil
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 340)
        .task {
            command = repo.customStart?.command ?? ""
            inTerminal = repo.customStart?.inTerminal ?? false
            let path = repo.path
            (scripts, apps) = await Task.detached {
                let atRoot = DevWorkspace.start(in: path, webOnly: true).map { $0.folder == nil } ?? false
                return (Array(DevWorkspace.startScripts(in: path).prefix(8)), (atRoot ? [""] : []) + DevWorkspace.appFolders(in: path).map(\.folder))
            }.value
        }
    }

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func choose(_ script: String) {
        let suggestion = DevWorkspace.command(forScript: script, in: repo.path)
        command = suggestion.command
        inTerminal = suggestion.needsTerminal
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        repo.customStart = .init(command: trimmed, inTerminal: inTerminal)
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
