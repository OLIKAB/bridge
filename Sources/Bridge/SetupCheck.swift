import AppKit
import Shared
import SwiftUI

/// What Bridge needs from the machine before it's useful: git, a git identity, a GitHub login and Claude Code.
/// Bridge has no logins of its own (it runs the user's `git`, `gh` and `claude`), so a new user otherwise only
/// finds out what's missing from a failed push or a `command not found` in Terminal.
@MainActor
final class SetupCheck: ObservableObject {
    static let shared = SetupCheck()

    enum State: Equatable {
        case checking
        case ok(String)
        case missing(String)
    }

    @Published private(set) var git: State = .checking
    @Published private(set) var identity: State = .checking
    @Published private(set) var gitHub: State = .checking
    /// Only checked when glab is installed: GitHub is the host offered to someone who has neither.
    @Published private(set) var gitLab: State?
    @Published private(set) var claude: State = .checking
    @Published private(set) var hasHomebrew = false
    @Published private(set) var hasGitHubCLI = false
    @Published private(set) var hasClaude = false
    @Published private(set) var isChecking = false

    var allOK: Bool {
        [git, identity, gitHub, claude].allSatisfy { if case .ok = $0 { true } else { false } }
    }

    struct Result: Sendable {
        var git: State
        var identity: State
        var gitHub: State
        var gitLab: State?
        var claude: State
        var hasHomebrew: Bool
        var hasGitHubCLI: Bool
        var hasClaude: Bool
    }

    func run() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await Task.detached { Self.check() }.value
            git = result.git
            identity = result.identity
            gitHub = result.gitHub
            gitLab = result.gitLab
            claude = result.claude
            hasHomebrew = result.hasHomebrew
            hasGitHubCLI = result.hasGitHubCLI
            hasClaude = result.hasClaude
            isChecking = false
        }
    }

    /// Blocking; runs off the main thread.
    nonisolated private static func check() -> Result {
        let home = NSHomeDirectory()
        let env = Git.environment
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        func find(_ tool: String, extra: [String] = []) -> String? {
            (extra + paths).map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Subprocess.Result {
            Subprocess.run(path, args, in: home, environment: env, timeout: timeout)
        }

        // /usr/bin/git is only a stub until the Command Line Tools are installed; running it would pop up
        // the install dialog, so ask xcode-select instead.
        let git: State
        let gitWorks: Bool
        if Git.executable != "/usr/bin/git" || run("/usr/bin/xcode-select", ["-p"]).succeeded {
            let version = run(Git.executable, ["--version"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            gitWorks = !version.isEmpty
            git = gitWorks ? .ok(version) : .missing("git didn't run")
        } else {
            gitWorks = false
            git = .missing("The Command Line Tools aren't installed")
        }

        let identity: State
        if gitWorks {
            let name = run(Git.executable, ["config", "--global", "user.name"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = run(Git.executable, ["config", "--global", "user.email"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            identity = name.isEmpty || email.isEmpty ? .missing("Commits need a name and an email") : .ok("\(name) <\(email)>")
        } else {
            identity = .missing("Needs git first")
        }

        func state(_ login: CLILogin, loggedOut: String) -> State {
            switch login {
            case .loggedIn(let account): .ok(account.map { "Logged in as \($0)" } ?? "Logged in")
            case .loggedOut: .missing(loggedOut)
            case .unknown: .ok("Installed")
            }
        }

        let host = GitHosts.gitHub
        let gh = host.executable(path: env["PATH"] ?? "")
        let gitHub: State = gh.map { state(host.loginState(executable: $0, environment: env), loggedOut: "The \(host.cliName) isn't logged in") }
            ?? .missing("\(host.cliName) not installed, an SSH key on \(host.name) works too")

        let lab = GitHosts.gitLab
        let gitLab: State? = lab.executable(path: env["PATH"] ?? "").map {
            state(lab.loginState(executable: $0, environment: lab.environment.merging(env) { a, _ in a }), loggedOut: "The \(lab.cliName) isn't logged in")
        }

        let agent = Agent.current
        let claudePath = agent.executable(path: env["PATH"] ?? "")
        let claude: State = claudePath.map { state(agent.loginState(executable: $0, environment: env), loggedOut: "\(agent.name) isn't logged in") }
            ?? .missing("\(agent.name) isn't installed")

        return Result(
            git: git, identity: identity, gitHub: gitHub, gitLab: gitLab, claude: claude,
            hasHomebrew: find("brew", extra: ["/opt/homebrew/bin", "/usr/local/bin"]) != nil,
            hasGitHubCLI: gh != nil, hasClaude: claudePath != nil)
    }

    /// Saves the global git identity from the form in the checklist.
    func saveIdentity(name: String, email: String) async -> String? {
        let home = NSHomeDirectory()
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let result = await Git.run(["config", "--global", key, value], in: home)
            if !result.succeeded { return result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        run()
        return nil
    }
}

/// The checklist on the main window's empty state.
struct SetupChecklist: View {
    @ObservedObject private var check = SetupCheck.shared

    /// In a native GroupBox, which draws the box the system's way instead of a hand-made rounded fill.
    var body: some View {
        GroupBox {
            SetupCheckRows()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Before you start").font(.headline)
                Spacer()
                SetupCheckAgainButton()
            }
        }
        .frame(width: 520)
    }
}

/// A spinner while the checks run, otherwise a button to run them again.
struct SetupCheckAgainButton: View {
    @ObservedObject private var check = SetupCheck.shared

    var body: some View {
        if check.isChecking {
            ProgressView().controlSize(.small)
        } else {
            Button("Check again") { check.run() }.controlSize(.small)
        }
    }
}

/// What Bridge needs from the machine, one row each, with a way to fix each one that's missing. Only
/// the coding agent picked in Settings is checked, and none when "None" is picked.
struct SetupCheckRows: View {
    @FocusState private var identityFocus: String?
    @ObservedObject private var check = SetupCheck.shared
    @ObservedObject private var agentStatus = AgentStatus.shared
    @State private var name = ""
    @State private var email = ""
    @State private var identityError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            checks
        }
        .onAppear { check.run() }
        // Logging in happens in a terminal; check again when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check.run() }
        // Another agent picked: check that one instead.
        .onChange(of: agentStatus.info) { check.run() }
    }

    @ViewBuilder private var checks: some View {

            row("Git", check.git) {
                Button("Install Command Line Tools") { terminal("xcode-select --install") }
            }
            row("Name and email for commits", check.identity) {
                if case .ok = check.git {
                    HStack {
                        TextField("Name", text: $name)
                            .focused($identityFocus, equals: "name")
                            .panelField()
                        TextField("Email", text: $email)
                            .focused($identityFocus, equals: "email")
                            .panelField()
                        Button("Save") {
                            Task { identityError = await check.saveIdentity(name: name, email: email) }
                        }
                        // The regular size of a field's line, not `.small`: small fields beside small buttons
                        // were the only field line in the app that didn't match the others.
                        .fieldRowButton(prominent: true)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
                    }
                    if let identityError {
                        Text(identityError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            let host = GitHosts.gitHub
            row(host.name, check.gitHub) {
                if check.hasGitHubCLI {
                    Button("Log in to \(host.name)…") { terminal(host.loginCommand) }
                } else if check.hasHomebrew, let install = host.installCommand {
                    Button("Install \(host.cliName) and log in…") { terminal(install) }
                } else {
                    Button("Get the \(host.cliName)…") { NSWorkspace.shared.open(host.installURL) }
                }
            }
            if let gitLab = check.gitLab {
                // Only there when glab is, so it's always a login that's missing.
                row(GitHosts.gitLab.name, gitLab) {
                    Button("Log in to GitLab…") { terminal(GitHosts.gitLab.loginCommand) }
                }
            }
            let agent = Agent.current
            if agentStatus.agentChoice != CodingAgents.none {
            row(agent.name, check.claude) {
                if check.hasClaude, let login = agent.loginCommand {
                    Button("Log in to \(agent.name)…") { terminal(login) }
                } else if !check.hasClaude, let install = agent.installCommand {
                    Button("Install \(agent.name) and log in…") { terminal(install) }
                } else if !check.hasClaude, let url = agent.installURL {
                    Button("Get \(agent.name)…") { NSWorkspace.shared.open(url) }
                }
            }
            }
    }

    @ViewBuilder
    private func row<Fix: View>(_ title: String, _ state: SetupCheck.State, @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch state {
            case .checking:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .accessibilityValue(isOK(state) ? "Done" : "Needs attention")
                switch state {
                case .checking:
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                case .ok(let detail):
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .missing(let detail):
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    fix().controlSize(.small)
                }
            }
        }
    }

    private func isOK(_ state: SetupCheck.State) -> Bool {
        if case .ok = state { true } else { false }
    }

    private func terminal(_ command: String) {
        DevWorkspace.runInTerminal(command, in: NSHomeDirectory(), kind: "setup")
    }
}
