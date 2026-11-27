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

/// Where the agent opens: a terminal, or an editor whose extension takes the agent (VS Code with
/// Claude Code's, `AgentEditors`). Opening the agent is what this pick is mostly for, so it's named
/// for it. Shells and scripts (dev servers' installs, logging in) always need a terminal: the picked
/// one, or the first installed while an editor is picked. Only installed ones can be picked; a picked
/// one that has been removed since falls back to Automatic's.
struct TerminalPicker: View {
    @ObservedObject private var status = AgentStatus.shared

    static var title: String { "Open \(AgentStatus.shared.info.name) in" }

    var body: some View {
        Picker(Self.title, selection: $status.terminalChoice) {
            Text("Automatic (\(status.automaticTerminalName))").tag(CodingAgents.automatic)
            Divider()
            ForEach(status.installedTerminals, id: \.self) { id in
                Text(Terminals.all.first { $0.id == id }?.name ?? id).tag(id)
            }
            if !status.agentEditors.isEmpty {
                Divider()
                ForEach(status.agentEditors, id: \.self) { id in
                    Text(AgentEditors.all.first { $0.id == id }?.name ?? id).tag(id)
                }
            }
            // An editor picked before its extension or the agent changed: still shown, so the picker
            // isn't blank, while the agent opens in Automatic's terminal.
            if let editor = AgentEditors.all.first(where: { $0.id == status.terminalChoice }), !status.agentEditors.contains(editor.id) {
                Text("\(editor.name) (needs Claude Code's extension)").tag(editor.id)
            }
        }
    }
}

/// Every setting of Bridge on one page of the panel (`PanelPage.settings`), from the gear menu on
/// either tab and from the main window. They used to be spread over the Repos tab's gear menu (about
/// twenty lines, the picks hidden in submenus), the Servers tab's and a separate setup page; the gear
/// menus now keep only what's used often in their tab (fetch or refresh, sorting and filters).
///
/// It's also what a new user sees first (`isFirstRun`), with a line saying what it's for and Done.
/// The checklist of what's missing on the machine shows then, and later only while something is
/// missing, so a set-up Mac doesn't get a page of green ticks.
struct SettingsPage: View {
    @ObservedObject var store: RepoStore
    var isFirstRun = false
    let done: () -> Void
    @ObservedObject private var agent = AgentStatus.shared
    @ObservedObject private var update = AppUpdate.shared
    @ObservedObject private var usagePing = UsagePing.shared
    @ObservedObject private var check = SetupCheck.shared

    var body: some View {
        MenuPanelList(maxHeight: 560) {
            VStack(alignment: .leading, spacing: 14) {
                if isFirstRun {
                    Text("Bridge works with the tools you already use. Pick them here, or change them later in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section("Coding agent") {
                    row("Agent") { AgentPicker() }
                    if agent.models != nil {
                        row("Model") { ModelPicker() }
                    }
                    if agent.info.isInstalled {
                        row("Opens in") { TerminalPicker() }
                    }
                    if agent.info.can(.skills) {
                        toggle("Show pinned skills on repositories", $store.showSkills)
                    }
                }
                section("Repositories and servers") {
                    toggle("Fetch every 10 minutes", $store.autoFetch)
                    if let ports = PortModel.shared {
                        ServerToggles(ports: ports)
                    }
                }
                section("Bridge") {
                    toggle("Launch at login", $store.launchAtLogin)
                    toggle("Shortcuts \(HotKey.repos.displayName) and \(HotKey.servers.displayName)", $store.hotKeyOn)
                    row("Check for updates") {
                        HStack(spacing: 8) {
                            Button("Check now") {
                                // The answer comes in the status line, where a notice left standing would hide it.
                                PanelNotice.shared.message = nil
                                update.check(byHand: true)
                            }
                            .controlSize(.small)
                            switchControl($update.isEnabled)
                        }
                    }
                    if UsagePing.endpoint != nil {
                        toggle("Send an anonymous daily count", $usagePing.isEnabled)
                    }
                }
                if isFirstRun || hasMissing {
                    section(isFirstRun ? "Before you start" : "Needs attention", trailing: AnyView(SetupCheckAgainButton())) {
                        SetupCheckRows()
                    }
                }
                HStack {
                    LicenseMenuItem().controlSize(.small)
                    Spacer()
                    if isFirstRun {
                        Button("Done", action: done)
                            .prominentButton()
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            agent.refresh()
            check.run()
        }
    }

    /// Something the checklist would show a fix for; still checking counts as nothing missing, so the
    /// section doesn't flash in while the checks run.
    private var hasMissing: Bool {
        [check.git, check.identity, check.gitHub, check.claude].contains { if case .missing = $0 { true } else { false } }
    }

    /// A heading in the sidebar's style (sentence case, grey), the rows under it.
    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        SettingsRow(title: title, control: control())
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        SettingsRow(title: title) { switchControl(isOn) }
    }

    /// Shown first once, to a new user: someone who already has repositories in Bridge has set it up.
    static let shownKey = "setupShown"
}

/// A setting's name on the left and its control on the right, as in System Settings.
private struct SettingsRow<Control: View>: View {
    let title: String
    let control: Control

    init(title: String, control: Control) {
        self.title = title
        self.control = control
    }

    init(title: String, @ViewBuilder control: () -> Control) {
        self.init(title: title, control: control())
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            control
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// A small switch with no label of its own: the row says what it is.
private func switchControl(_ isOn: Binding<Bool>) -> some View {
    Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
}

/// The Servers tab's settings, observing its model only here.
private struct ServerToggles: View {
    @ObservedObject var ports: PortModel

    var body: some View {
        SettingsRow(title: "Start servers in the background") { switchControl($ports.runInBackground) }
        SettingsRow(title: "Notify about new and stopped servers") { switchControl($ports.notificationsOn) }
    }
}
