import Shared
import SwiftUI

/// Which coding agent Bridge's buttons start. Every agent Bridge knows is listed, the ones not found
/// marked as such: picking one of those makes the setup checklist offer to install it. "None" leaves
/// out everything that has to do with an agent, for someone who only wants git and servers.
struct AgentPicker: View {
    @ObservedObject private var status = AgentStatus.shared

    var body: some View {
        Picker("Coding agent", selection: $status.agentChoice) {
            Text("Automatic (\(status.automaticAgentName))").tag(CodingAgents.automatic)
            Divider()
            ForEach(CodingAgents.all.map(\.id), id: \.self) { id in
                let name = CodingAgents.agent(id: id)?.name ?? id
                Text(status.installedAgents.contains(id) ? name : "\(name) (not installed)").tag(id)
            }
            Divider()
            Text("None").tag(CodingAgents.none)
        }
    }
}

/// Which terminal Bridge opens shells, scripts and the agent in. Only installed ones can be picked;
/// a picked one that has been removed since falls back to Automatic's.
struct TerminalPicker: View {
    @ObservedObject private var status = AgentStatus.shared

    var body: some View {
        Picker("Terminal", selection: $status.terminalChoice) {
            Text("Automatic (\(status.automaticTerminalName))").tag(CodingAgents.automatic)
            Divider()
            ForEach(status.installedTerminals, id: \.self) { id in
                Text(Terminals.all.first { $0.id == id }?.name ?? id).tag(id)
            }
        }
    }
}

/// The page that opens the first time the panel opens with nothing in it, and from Settings: which
/// agent and terminal to use, then what's missing on the machine, each with its fix. Bridge was made
/// around one person's tools, and a new user otherwise found out what it expected from failures.
struct SetupPage: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bridge works with the tools you already use. Pick them here, or change them later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                AgentPicker()
                ModelPicker()
                TerminalPicker()
            }
            PanelDivider(subtle: true)
            HStack {
                Text("Before you start").font(.headline)
                Spacer()
                SetupCheckAgainButton()
            }
            SetupCheckRows()
            HStack {
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { AgentStatus.shared.refresh() }
    }

    /// Shown once, to a new user: someone who already has repositories in Bridge has set it up.
    static let shownKey = "setupShown"
}
