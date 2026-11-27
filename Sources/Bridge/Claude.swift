import Foundation
import Shared
import SwiftUI

/// Claude Code's own command line, for the features only it has (background sessions, skills, updates).
/// What any coding agent can do goes through `CodingAgents.current` instead (see `Agent`).
enum Claude {
    static var executable: String? { CodingAgents.claudeCode.executable(path: Git.environment["PATH"] ?? "") }
}

/// What the panels need to know about the coding agent in use, as plain values, so rows can be handed
/// it (`RepoRowOptions`) instead of observing anything.
struct AgentInfo: Equatable {
    var name: String
    var isInstalled: Bool
    var capabilities: Set<AgentCapability>

    /// Whether to show what needs `capability`: the agent has to have it, and has to be there to run.
    /// A user without any agent gets no agent buttons at all rather than ones that fail.
    func can(_ capability: AgentCapability) -> Bool { isInstalled && capabilities.contains(capability) }
}

/// Whether the agent is installed and which terminal opens, looked up when the panel opens rather than
/// while views are drawn (finding a command means looking through every folder on the PATH). Publishes
/// only when something changed, so observing it costs nothing the rest of the time.
@MainActor
final class AgentStatus: ObservableObject {
    static let shared = AgentStatus()

    /// Assumed installed until looked up, so the buttons of someone who has it don't blink in at launch.
    @Published private(set) var info = AgentStatus.info(isInstalled: true)
    @Published private(set) var terminalName = Terminals.current?.name ?? "Terminal"
    /// The ids of the agents and terminals found, for the pickers.
    @Published private(set) var installedAgents: Set<String> = []
    @Published private(set) var installedTerminals: [String] = []

    /// The agent picked in Settings: an agent's id, `CodingAgents.automatic` or `CodingAgents.none`.
    @Published var agentChoice = UserDefaults.standard.string(forKey: CodingAgents.preferenceKey) ?? CodingAgents.automatic {
        didSet {
            UserDefaults.standard.set(agentChoice, forKey: CodingAgents.preferenceKey)
            refresh()
        }
    }
    /// The terminal picked in Settings: a terminal's id or `CodingAgents.automatic`.
    @Published var terminalChoice = UserDefaults.standard.string(forKey: Terminals.preferenceKey) ?? CodingAgents.automatic {
        didSet {
            UserDefaults.standard.set(terminalChoice, forKey: Terminals.preferenceKey)
            refresh()
        }
    }

    /// The agent Automatic picks right now, for its label in the pickers.
    var automaticAgentName: String {
        (CodingAgents.all.first { installedAgents.contains($0.id) } ?? CodingAgents.claudeCode).name
    }

    var automaticTerminalName: String {
        installedTerminals.first.flatMap { id in Terminals.all.first { $0.id == id }?.name } ?? "Terminal"
    }

    private init() { refresh() }

    func refresh() {
        let noAgent = agentChoice == CodingAgents.none
        Task {
            let (installed, agents, terminals) = await Task.detached {
                let path = Git.environment["PATH"] ?? ""
                CodingAgents.choose(path: path)
                let agents = Set(CodingAgents.all.filter { $0.executable(path: path) != nil }.map(\.id))
                return (Agent.executable != nil, agents, Terminals.installed.map(\.id))
            }.value
            let info = Self.info(isInstalled: installed && !noAgent)
            if info != self.info { self.info = info }
            if agents != installedAgents { installedAgents = agents }
            if terminals != installedTerminals { installedTerminals = terminals }
            let terminal = Terminals.current?.name ?? "Terminal"
            if terminal != terminalName { terminalName = terminal }
            await checkForProblem(installed: info.isInstalled)
        }
    }

    /// What would make the agent fail, found when the panel opens, so the panel can say so with a way to
    /// fix it before the user clicks something that runs the agent and gets an error instead.
    @Published private(set) var problem: AgentProblem?
    /// A problem dismissed with ×, not shown again until it's another one.
    private var dismissedProblem: AgentProblem?

    var shownProblem: AgentProblem? { problem == dismissedProblem ? nil : problem }

    func dismissProblem() { dismissedProblem = problem }

    /// The models the agent offers the account, for the model picker; nil for an agent Bridge can't
    /// ask (the picker isn't shown then).
    @Published private(set) var models: [AgentModel]?
    /// The model the agent's own config picks; nil is the agent's default.
    @Published private(set) var model: String?

    private func checkForProblem(installed: Bool) async {
        let agent = Agent.current
        let (found, models, model): (AgentProblem?, [AgentModel]?, String?) = await Task.detached {
            guard installed, let executable = Agent.executable else { return (nil, nil, nil) }
            let problem = AgentProblem.check(agent, executable: executable, environment: Git.environment)
            return (problem, agent.availableModels(), agent.configuredModel())
        }.value
        if found != problem { problem = found }
        if models != self.models { self.models = models }
        if model != self.model { self.model = model }
    }

    /// Writes the pick into the agent's own config (nil: back to its default), then looks again, which
    /// also clears a notice about the old model. Returns the error to show, if it couldn't.
    @discardableResult
    func useModel(_ id: String?) -> String? {
        do {
            try Agent.current.useModel(id)
            model = id
            refresh()
            return nil
        } catch {
            return "Couldn't change \(Agent.current.shortName)'s config: \(error.localizedDescription)"
        }
    }

    private static func info(isInstalled: Bool) -> AgentInfo {
        let agent = Agent.current
        return AgentInfo(name: agent.shortName, isInstalled: isInstalled, capabilities: agent.capabilities)
    }
}

/// Runs the coding agent in use through its command line, so it uses whatever account the user is logged in with there.
enum Agent {
    static var current: any CodingAgent { CodingAgents.current }

    static var executable: String? { current.executable(path: Git.environment["PATH"] ?? "") }

    /// Keeps the prompt well within the argument size limit.
    private static let maxDiffLength = 60_000

    private static let instructions = """
        Write a git commit message for the changes below. \
        Reply with only the message: a summary line in the imperative mood of at most 72 characters, \
        then optionally a blank line and a short description of what changed and why. \
        No quotes, no Markdown code fences, no preamble.
        """

    static func commitMessage(for diff: String, in directory: String) async throws -> (summary: String, description: String) {
        let agent = current
        guard let executable else {
            throw GitError(message: "Couldn't find the \(agent.commandName) command. Install \(agent.name) and run `\(agent.commandName)` once to log in.")
        }
        var diff = diff
        if diff.count > maxDiffLength { diff = String(diff.prefix(maxDiffLength)) + "\n… (diff truncated)" }
        let prompt = "\(instructions)\n\n\(diff)"
        guard let args = agent.headlessArguments(prompt: prompt) else {
            throw GitError(message: "\(agent.name) can't write commit messages from Bridge.")
        }
        let output = try await run(executable, args, prompt: prompt, in: directory, timeout: 120)
        let lines = output.components(separatedBy: "\n")
        let summary = lines[0].trimmingCharacters(in: .whitespaces)
        let description = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, description)
    }

    /// What the agent found for starting a project: a command, or why there's none.
    struct StartSuggestion: Equatable {
        let command: String?
        /// Interactive (prompts, a full-screen status) and so has to run in a terminal.
        let inTerminal: Bool
        /// One sentence: what the command does, or why nothing will start.
        let reason: String
    }

    /// Has the agent look through the project and work out the command that starts it, read-only
    /// (`readOnlyArguments`). `tried` is what Bridge would run and how its last start ended, so the agent
    /// doesn't suggest the same thing again or can say why it fails.
    static func findStartCommand(in directory: String, tried: String?) async throws -> StartSuggestion {
        let agent = current
        guard let executable else {
            throw GitError(message: "Couldn't find the \(agent.commandName) command. Install \(agent.name) and run `\(agent.commandName)` once to log in.")
        }
        let prompt = """
            Look through the project in the current directory and work out the one shell command that starts it \
            for local development (its dev server, or the app itself if it isn't a web app). \
            Read the README, package and build files and scripts; use `which` to check that the tools it needs are installed.

            The command runs from this directory in a fresh, non-interactive zsh login shell, with its output going to a log file. \
            If it needs dependencies installed first, include that step with && (like `npm install && npm run dev`). \
            If the app is in a subfolder, start with `cd <folder> &&`. Never use sudo, never delete anything, \
            and don't include steps that need secrets or accounts the project doesn't already have.

            If nothing can start it on this machine (a tool it needs isn't installed, it's a library with nothing to run, \
            it needs credentials that aren't there), give no command and say why, with what would fix it.
            \(tried.map { "\nBridge already tried this, and it didn't work:\n\($0)\n" } ?? "")
            Reply with only a JSON object, no Markdown fences and nothing else:
            {"command": "<the command, or null>", "terminal": <true only if it asks questions or draws a full-screen interface>, \
            "reason": "<one short sentence in English: what it starts, or why nothing can>"}
            """
        guard let args = agent.readOnlyArguments(prompt: prompt) else {
            throw GitError(message: "\(agent.name) can't look through projects from Bridge.")
        }
        let output = try await run(executable, args, prompt: prompt, in: directory, timeout: 300)
        // The object, wherever it is: some agents add a line before it or fence it anyway.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any] else {
            throw GitError(message: "\(agent.shortName) didn't answer with a command: \(output.prefix(200))")
        }
        let command = (json["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return StartSuggestion(command: command?.isEmpty == false ? command : nil, inTerminal: json["terminal"] as? Bool ?? false,
                               reason: (json["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Runs the agent without a terminal and returns what it printed, or throws what went wrong in words
    /// (a login problem as `AgentLoginError`).
    private static func run(_ executable: String, _ args: [String], prompt: String, in directory: String, timeout: TimeInterval) async throws -> String {
        let agent = current
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Git.runSync(executable, args, in: directory, environment: Git.environment, timeout: timeout))
            }
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !output.isEmpty else {
            // Codex repeats the prompt in its output, diff and all, so a diff that mentions logging in
            // (this very code did) read as a login failure. Only what the agent said itself counts.
            let said = [result.stderr, result.stdout].map { ownLines($0, prompt: prompt) }
            if agent.isLoginFailure(said.joined(separator: "\n")) { throw AgentLoginError(agent: agent) }
            // Logged out, Codex doesn't say so: it fails on whatever comes first (an unsupported model
            // from the user's config, say). So a failure also asks the agent, and a plain "not logged
            // in" there is the thing to fix first.
            let login = await Task.detached { agent.loginState(executable: executable, environment: Git.environment) }.value
            if login == .loggedOut { throw AgentLoginError(agent: agent) }
            let message = said.map(readable).first { !$0.isEmpty }
            throw GitError(message: message ?? "\(agent.commandName) failed (exit code \(result.status))")
        }
        return output
    }

    /// An agent's error output as something to read: without its log lines' timestamps, levels and
    /// module names (`2026-11-25T14:41:11Z ERROR codex_login::auth::manager: …`), without notes that
    /// aren't the error ("Reading additional input from stdin..."), and each message once.
    /// When it has lines that say they're errors (`ERROR: …`), only those: Codex prints a header of its
    /// settings (workdir, model, sandbox, …) before them that isn't what went wrong.
    private static func readable(_ output: String) -> String {
        let logPrefix = #/^\d{4}-\d{2}-\d{2}T\S+\s+(ERROR|WARN|INFO|DEBUG)\s+[\w:]+:\s*/#
        var seen = Set<String>()
        let lines = output.components(separatedBy: .newlines)
            .map { $0.replacing(logPrefix, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Reading additional input from stdin") && seen.insert($0).inserted }
        let errors = lines.filter { $0.lowercased().hasPrefix("error") }
            .map { $0.replacing(#/^(?i:error):\s*/#, with: "") }
        return (errors.isEmpty ? lines : errors).joined(separator: "\n")
    }

    /// `output` without the lines that are the prompt repeated back.
    private static func ownLines(_ output: String, prompt: String) -> String {
        output.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count < 3 || !prompt.contains(trimmed)
        }.joined(separator: "\n")
    }
}

/// The agent is logged out: what happened in plain words and the one thing to do about it, at the top
/// of the panel when it opens (`AgentProblemNotice`) and in a row whose commit message failed on it.
/// The login opens in a terminal, as logins ask questions and open the browser. The login itself ends
/// in the browser and the terminal, so without more the panel gave no sign it had worked: the notice
/// waits, says so when the login is seen to have gone through, and then calls `done` (which writes the
/// message again in a row, so it shimmers into the field as usual).
struct AgentLoginNotice: View {
    var message: String
    let dismiss: () -> Void
    let done: () -> Void

    private enum Phase { case needsLogin, waiting, loggedIn }
    @State private var phase = Phase.needsLogin
    @State private var loginStarted = ContinuousClock.now

    /// How long Bridge watches for the login before leaving it to "Try again".
    private static let watchLimit: Duration = .seconds(300)

    var body: some View {
        let agent = Agent.current
        HStack(spacing: 6) {
            switch phase {
            case .needsLogin:
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Log in…") {
                    DevWorkspace.runInTerminal(agent.loginCommand ?? agent.commandName, in: NSHomeDirectory(), kind: "setup")
                    loginStarted = .now
                    phase = .waiting
                }
                .glassButtons()
                .controlSize(.small)
            case .waiting:
                ProgressView().controlSize(.mini)
                Text("Log in in \(AgentStatus.shared.terminalName), then come back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Try again", action: done)
                    .glassButtons()
                    .controlSize(.small)
            case .loggedIn:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Logged in to \(agent.shortName).")
                Spacer(minLength: 0)
            }
            if phase != .loggedIn {
                IconButton(systemName: "xmark", help: "Dismiss", action: dismiss)
            }
        }
        .font(.caption)
        .task(id: phase) {
            guard phase == .waiting else { return }
            if await watchForLogin(agent) { await confirm() }
        }
    }

    /// Asks the agent every two seconds whether it's logged in. A status that says "logged in" isn't
    /// enough on its own: Codex says so with a token that can no longer be refreshed, which is how the
    /// notice came up. Its login command logs out first, though, so a logged-out answer followed by a
    /// logged-in one is a login that went through. The panel usually closes while the user is in the
    /// terminal and the browser, which stops this, and the logged-out moment can pass unseen; so after
    /// the first few seconds (by then the terminal has logged out) logged in is taken as it is. If that
    /// login is still the stale one, writing the message fails again and the notice comes back.
    /// Agents that can't be asked (`.unknown`) are left to "Try again".
    private func watchForLogin(_ agent: any CodingAgent) async -> Bool {
        guard let executable = Agent.executable else { return false }
        let deadline = loginStarted + Self.watchLimit
        var sawLoggedOut = false
        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            let state = await Task.detached { agent.loginState(executable: executable, environment: Git.environment) }.value
            let terminalHadTime = ContinuousClock.now - loginStarted > .seconds(15)
            switch state {
            case .loggedOut: sawLoggedOut = true
            case .loggedIn where sawLoggedOut || terminalHadTime: return !Task.isCancelled
            case .unknown: return false
            default: break
            }
        }
        return false
    }

    /// Shows that the login worked for a moment, then goes on.
    private func confirm() async {
        phase = .loggedIn
        try? await Task.sleep(for: .seconds(1.5))
        done()
    }
}

/// At the top of the Repos tab when the agent's own setup would make it fail (`AgentStatus.problem`,
/// checked as the panel opens), with the fix a click or two away, so the user isn't first told by an
/// error after clicking something.
struct AgentProblemNotice: View {
    @ObservedObject var status = AgentStatus.shared

    var body: some View {
        if let problem = status.shownProblem {
            let agent = Agent.current
            Group {
                switch problem {
                case .loggedOut:
                    AgentLoginNotice(message: "\(agent.shortName) isn't logged in.",
                                     dismiss: status.dismissProblem, done: status.refresh)
                case let .unavailableModel(configured, available):
                    AgentModelNotice(configured: configured, available: available)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .revealsGently()
            PanelDivider()
        }
    }
}

/// The agent's config picks a model the account can't use (Codex with a retired one fails every run
/// with "model is not supported"). Switching writes the pick into the agent's own config, the same
/// setting its own model picker changes, so the agent in a terminal is fixed too.
private struct AgentModelNotice: View {
    let configured: String
    let available: [AgentModel]
    @State private var switchedTo: AgentModel?
    @State private var failure: String?

    var body: some View {
        let agent = Agent.current
        HStack(spacing: 6) {
            if let switchedTo {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(agent.shortName) now uses \(switchedTo.name).")
                Spacer(minLength: 0)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure ?? "\(agent.shortName) is set to \(configured), which your account can't use.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu("Switch model") {
                    ForEach(Array(available.enumerated()), id: \.element) { index, model in
                        Button(index == 0 ? "\(model.name) (recommended)" : model.name) { use(model) }
                    }
                }
                .menuStyle(.button)
                .glassButtons()
                .controlSize(.small)
                .fixedSize()
                IconButton(systemName: "xmark", help: "Dismiss") { AgentStatus.shared.dismissProblem() }
            }
        }
        .font(.caption)
    }

    /// The confirmation shows for a moment before the notice goes, as the refresh that clears it would
    /// otherwise take it away the instant the pick was made.
    private func use(_ model: AgentModel) {
        do {
            try Agent.current.useModel(model.id)
            switchedTo = model
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                AgentStatus.shared.refresh()
            }
        } catch {
            failure = "Couldn't change \(Agent.current.shortName)'s config: \(error.localizedDescription)"
        }
    }
}

/// Which model the agent uses, in Settings and on the setup page: the agent's own default or one of
/// the models it offers the account. Written into the agent's config, so its sessions in a terminal
/// use it too, not only what Bridge runs. A configured model the account can't use is still listed,
/// marked, so the picker shows what's actually set.
struct ModelPicker: View {
    @ObservedObject private var status = AgentStatus.shared

    var body: some View {
        if let models = status.models {
            Picker("Model", selection: Binding(get: { status.model ?? "" },
                                               set: { status.useModel($0.isEmpty ? nil : $0) })) {
                Text("\(status.info.name)'s default").tag("")
                Divider()
                ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                if let model = status.model, !models.contains(where: { $0.id == model }) {
                    Text("\(model) (not available)").tag(model)
                }
            }
        }
    }
}

/// The agent's login is missing or has run out. Shown as a request to log in with a button for it, not
/// as an error, since nothing is wrong with the repository and one login fixes it.
struct AgentLoginError: LocalizedError {
    let agent: any CodingAgent
    var errorDescription: String? { "\(agent.shortName) needs you to log in again." }
}
