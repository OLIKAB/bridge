import AppKit
import SwiftUI

/// What a coding agent's command line can do beyond starting a session in a terminal. Bridge is meant
/// to show a feature only when the agent in use has it, so someone using another agent than Claude Code
/// doesn't get buttons that fail with `command not found`.
public enum AgentCapability: Sendable, Hashable {
    /// Starts an interactive session with a first message (the panel's prompt field). Without it the
    /// agent only opens, so the prompt field isn't shown rather than dropping what was typed.
    case initialPrompt
    /// Answers one prompt without a terminal and exits (used to write commit messages).
    case headless
    /// Answers one prompt without a terminal after reading the project, without changing anything in it
    /// (used to find a start command, `readOnlyArguments`).
    case readsProject
    /// Runs sessions in the background that can be listed and answered later (`claude --bg`).
    case background
    /// Has skills or slash commands on disk that can be pinned to a repository.
    case skills
    /// Can drive the user's browser (`claude --chrome`).
    case browser
    /// Reports how much of the plan's usage is left.
    case usage
    /// Can update itself, and Bridge can tell when a newer version exists.
    case selfUpdate
}

/// How the agent is started, from the panel's switches.
public struct AgentOptions: Sendable {
    public var browser: Bool

    public init(browser: Bool = false) {
        self.browser = browser
    }

    /// The switches as the user left them. Read from the defaults rather than passed in, so every
    /// button and skill chip follows the one toggle.
    public static var fromDefaults: AgentOptions {
        AgentOptions(browser: UserDefaults.standard.bool(forKey: DevWorkspace.agentBrowserKey))
    }
}

/// Whether a command line (an agent's, a git host's) is logged in, as far as it can tell.
public enum CLILogin: Sendable, Equatable {
    case loggedIn(account: String?)
    case loggedOut
    /// The tool has no way to ask, so Bridge doesn't claim either.
    case unknown
}

/// A coding agent Bridge starts through its command line, so the user's own login, config and
/// plugins apply. Each agent says what it can do (`capabilities`); Bridge builds on that rather
/// than on any one agent's flags.
public protocol CodingAgent: Sendable {
    /// Stable, for settings.
    var id: String { get }
    var name: String { get }
    /// What buttons call it: "Open Claude", "Write with Claude".
    var shortName: String { get }
    /// The command it's run as, looked up on the user's PATH.
    var commandName: String { get }
    /// Folders to look in before PATH, for installers that don't put the command on it.
    var extraSearchPaths: [String] { get }
    var capabilities: Set<AgentCapability> { get }
    @MainActor var logo: NSImage { get }
    /// The agent's own color, for its buttons under the pointer and while they'll run a prompt.
    @MainActor var tint: Color { get }

    /// The shell line that starts an interactive session, with `prompt` as its first message.
    func interactiveCommand(prompt: String?, options: AgentOptions) -> String
    /// Arguments that answer `prompt` without a terminal and exit, or nil without `.headless`.
    func headlessArguments(prompt: String) -> [String]?
    /// Arguments that answer `prompt` after looking through the project in the working directory, with
    /// reading tools only: no edits, and no commands beyond looking (which, ls). Nil without `.readsProject`.
    func readOnlyArguments(prompt: String) -> [String]?

    /// The shell line that logs in, run in a terminal since logins ask questions and open the browser.
    var loginCommand: String? { get }
    /// The shell line that installs the agent and logs in, or nil when there's only a web page.
    var installCommand: String? { get }
    var installURL: URL? { get }
    /// Blocking; runs off the main thread.
    func loginState(executable: String, environment: [String: String]) -> CLILogin

    /// The model the user's own config picks, or nil when it leaves it to the agent.
    func configuredModel() -> String?
    /// The models the logged-in account can use, best first, or nil when the agent can't tell.
    func availableModels() -> [AgentModel]?
    /// Makes `model` the one the user's config picks; nil leaves it to the agent's default.
    func useModel(_ model: String?) throws
}

/// A model an agent offers, as its config names it and as people do.
public struct AgentModel: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
}

/// Something in the agent's own setup that would make what Bridge asks of it fail, found when the
/// panel opens rather than as an error after a click.
public enum AgentProblem: Sendable, Equatable {
    case loggedOut
    /// The config picks a model the account can't use (one that's been retired, say).
    case unavailableModel(configured: String, available: [AgentModel])

    /// Looks for problems in the order they'd show: logged out first, as nothing else works then.
    /// Blocking; runs off the main thread.
    public static func check(_ agent: any CodingAgent, executable: String, environment: [String: String]) -> AgentProblem? {
        if agent.loginState(executable: executable, environment: environment) == .loggedOut { return .loggedOut }
        if let model = agent.configuredModel(), let available = agent.availableModels(), !available.isEmpty,
           !available.contains(where: { $0.id == model }) {
            return .unavailableModel(configured: model, available: available)
        }
        return nil
    }
}

extension CodingAgent {
    public func has(_ capability: AgentCapability) -> Bool { capabilities.contains(capability) }

    // Agents whose config and model list Bridge doesn't read: no model check, nothing to switch.
    public func configuredModel() -> String? { nil }
    public func availableModels() -> [AgentModel]? { nil }
    public func useModel(_ model: String?) throws {}

    /// Whether a failed run's output says the login is missing or no longer works. Asking up front
    /// isn't enough: `codex login status` says "Logged in" with a token that can no longer be refreshed,
    /// and only the run itself then fails (401). So Bridge reads the failure, and offers to log in
    /// rather than showing the agent's log lines.
    public func isLoginFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        return [
            "401 unauthorized", "unauthorized", "sign in again", "log in again", "login again",
            "not logged in", "please log in", "please login", "please run /login", "run /login",
            "invalid api key", "authentication failed", "authentication required", "login required",
            "token could not be refreshed", "token has expired", "token expired", "invalid_grant",
        ].contains { text.contains($0) }
    }

    /// Where the command is installed, or nil. `path` is the user's PATH (from their login shell,
    /// as a menu bar app's own PATH has none of what their shell config adds).
    public func executable(path: String) -> String? {
        let candidates = extraSearchPaths + path.split(separator: ":").map(String.init)
        return candidates.map { "\($0)/\(commandName)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Claude Code (`claude`).
public struct ClaudeCode: CodingAgent {
    public init() {}

    public let id = "claude-code"
    public let name = "Claude Code"
    public let shortName = "Claude"
    public let commandName = "claude"
    public var extraSearchPaths: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "\(home)/.claude/local"]
    }
    public let capabilities: Set<AgentCapability> = [.initialPrompt, .headless, .readsProject, .background, .skills, .browser, .usage, .selfUpdate]
    @MainActor public var logo: NSImage { Logo.claude }
    @MainActor public var tint: Color { Color(red: 0.85, green: 0.47, blue: 0.34) }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String {
        commandName + (options.browser ? " --chrome" : "") + (prompt.map { " " + DevWorkspace.quoted($0) } ?? "")
    }

    /// Haiku, no tools and no saved session: it only has to read the prompt and answer.
    public func headlessArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--model", "haiku", "--tools", "", "--no-session-persistence"]
    }

    /// Sonnet, with the reading tools and Bash only for `which` and `ls`: in print mode a tool that isn't
    /// allowed is refused rather than asked about, so nothing can be installed, run or changed.
    public func readOnlyArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--model", "sonnet", "--tools", "Read,Glob,Grep,Bash",
         "--allowedTools", "Read,Glob,Grep,Bash(which:*),Bash(ls:*)", "--no-session-persistence"]
    }

    public let loginCommand: String? = "claude auth login"
    /// The native installer puts claude in ~/.local/bin, which the terminal's PATH may not have yet.
    public let installCommand: String? = "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude auth login"
    public let installURL: URL? = URL(string: "https://claude.com/product/claude-code")

    /// `claude auth status` prints JSON with `loggedIn` and `email`.
    public func loginState(executable: String, environment: [String: String]) -> CLILogin {
        let output = Subprocess.run(executable, ["auth", "status"], in: NSHomeDirectory(), environment: environment, timeout: 15).stdout
        let json = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        guard json?["loggedIn"] as? Bool == true else { return .loggedOut }
        return .loggedIn(account: json?["email"] as? String)
    }
}

/// Where the curl installers and Homebrew put commands; a menu bar app's PATH has none of them and
/// the user's shell config may not either until a new terminal is opened.
private let commonBins: [String] = {
    let home = NSHomeDirectory()
    return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
}()

/// A shell line that runs `command` with `prompt` quoted as one argument.
private func withPrompt(_ command: String, _ prompt: String?) -> String {
    command + (prompt.map { " " + DevWorkspace.quoted($0) } ?? "")
}

/// OpenAI's Codex CLI (`codex`). `codex exec` prints only the final message on stdout (progress goes
/// to stderr) and runs in a read-only sandbox by default, which is what a commit message needs.
/// Its skills are invoked as `$name`, not `/name`, so pinning them isn't offered yet.
public struct Codex: CodingAgent {
    public init() {}

    public let id = "codex"
    public let name = "Codex"
    public let shortName = "Codex"
    public let commandName = "codex"
    public var extraSearchPaths: [String] { commonBins }
    public let capabilities: Set<AgentCapability> = [.initialPrompt, .headless, .readsProject]
    @MainActor public var logo: NSImage { Logo.bundled("openai", fallback: "terminal") }
    @MainActor public var tint: Color { .primary }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String {
        withPrompt(commandName, prompt)
    }

    /// Low reasoning effort, as Claude Code's message is written by Haiku: a user's config may ask for
    /// `xhigh` for their own sessions, which made a commit message take minutes.
    public func headlessArguments(prompt: String) -> [String]? {
        ["exec", "--skip-git-repo-check", "--ephemeral", "--color", "never", "-c", "model_reasoning_effort=\"low\"", prompt]
    }

    /// The read-only sandbox, named rather than left to the user's config: its commands can look, not write.
    public func readOnlyArguments(prompt: String) -> [String]? {
        ["exec", "--skip-git-repo-check", "--ephemeral", "--color", "never", "--sandbox", "read-only",
         "-c", "model_reasoning_effort=\"medium\"", prompt]
    }

    /// Logs out first: with a token that can't be refreshed Codex asks to "log out and sign in again",
    /// and logging out when there's no login does nothing.
    public let loginCommand: String? = "codex logout >/dev/null 2>&1; codex login"
    public let installCommand: String? = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    public let installURL: URL? = URL(string: "https://github.com/openai/codex")

    /// `codex login status` exits 0 when logged in.
    public func loginState(executable: String, environment: [String: String]) -> CLILogin {
        Subprocess.run(executable, ["login", "status"], in: NSHomeDirectory(), environment: environment, timeout: 15).succeeded
            ? .loggedIn(account: nil) : .loggedOut
    }

    private var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }
    private var configFile: URL { home.appendingPathComponent("config.toml") }

    /// The lines of config.toml before its first `[table]`, where a top-level `model = "…"` is.
    private func topLevelModelLine(in lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            if trimmed.firstMatch(of: #/^model\s*=/#) != nil { return i }
        }
        return nil
    }

    public func configuredModel() -> String? {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let i = topLevelModelLine(in: lines),
              let match = lines[i].firstMatch(of: #/=\s*"([^"]+)"/#) else { return nil }
        return String(match.1)
    }

    /// From models_cache.json, which Codex fetches for the logged-in account: the models it lists in
    /// its own picker (`visibility` "list"), in its order (`priority`).
    public func availableModels() -> [AgentModel]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let id = model["slug"] as? String else { return nil }
                return AgentModel(id: id, name: model["display_name"] as? String ?? id)
            }
    }

    /// Changes only the `model` line (adds one at the top, or removes it for Codex's default), leaving
    /// the rest of the user's config, comments and all, as it was.
    public func useModel(_ model: String?) throws {
        let text = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let existing = topLevelModelLine(in: lines)
        switch (model, existing) {
        case let (model?, i?): lines[i] = "model = \"\(model)\""
        case let (model?, nil): lines.insert("model = \"\(model)\"", at: 0)
        case let (nil, i?): lines.remove(at: i)
        case (nil, nil): return
        }
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        // An atomic write makes a new file with default permissions; Codex keeps its config private (0600).
        let permissions = (try? fm.attributesOfItem(atPath: configFile.path))?[.posixPermissions] ?? 0o600
        try lines.joined(separator: "\n").write(to: configFile, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: configFile.path)
    }
}

/// Google's Gemini CLI (`gemini`). `-i` runs the first prompt and stays interactive; `-p` answers and
/// exits. It has no login command (the first run offers to sign in) and no way to ask whether it's
/// logged in.
public struct GeminiCLI: CodingAgent {
    public init() {}

    public let id = "gemini"
    public let name = "Gemini CLI"
    public let shortName = "Gemini"
    public let commandName = "gemini"
    public var extraSearchPaths: [String] { commonBins }
    public let capabilities: Set<AgentCapability> = [.initialPrompt, .headless, .readsProject]
    @MainActor public var logo: NSImage { Logo.bundled("googlegemini", fallback: "sparkle") }
    @MainActor public var tint: Color { Color(red: 0.26, green: 0.52, blue: 0.96) }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String {
        prompt.map { "\(commandName) -i \(DevWorkspace.quoted($0))" } ?? commandName
    }

    public func headlessArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--output-format", "text"]
    }

    /// Without a terminal it has no one to ask, so the tools that need approval (shell, edits) aren't offered;
    /// reading files and listing folders are.
    public func readOnlyArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--output-format", "text"]
    }

    public let loginCommand: String? = "gemini"
    public let installCommand: String? = "npm install -g @google/gemini-cli && gemini"
    public let installURL: URL? = URL(string: "https://geminicli.com")

    public func loginState(executable: String, environment: [String: String]) -> CLILogin { .unknown }
}

/// Cursor's CLI. Run as `cursor-agent`, an alias Cursor keeps for `agent`, because Grok's CLI also
/// installs a command called `agent`. `--mode ask` answers without editing anything.
public struct CursorAgent: CodingAgent {
    public init() {}

    public let id = "cursor"
    public let name = "Cursor CLI"
    public let shortName = "Cursor"
    public let commandName = "cursor-agent"
    public var extraSearchPaths: [String] { commonBins }
    public let capabilities: Set<AgentCapability> = [.initialPrompt, .headless, .readsProject]
    @MainActor public var logo: NSImage { Logo.bundled("cursor", fallback: "cursorarrow") }
    @MainActor public var tint: Color { .primary }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String {
        withPrompt(commandName, prompt)
    }

    public func headlessArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--output-format", "text", "--mode", "ask", "--trust"]
    }

    /// Ask mode reads the project and answers, without editing.
    public func readOnlyArguments(prompt: String) -> [String]? {
        ["-p", prompt, "--output-format", "text", "--mode", "ask", "--trust"]
    }

    public let loginCommand: String? = "cursor-agent login"
    public let installCommand: String? = "curl https://cursor.com/install -fsS | bash && ~/.local/bin/cursor-agent login"
    public let installURL: URL? = URL(string: "https://cursor.com/cli")

    /// `cursor-agent status` exists, but what it prints and exits with when logged out isn't documented.
    public func loginState(executable: String, environment: [String: String]) -> CLILogin { .unknown }
}

/// GitHub's Copilot CLI (`copilot`). `-p` with `-s` prints only the answer, and without permission
/// flags anything that needs approval is denied, so it can't change files while writing a message.
public struct CopilotCLI: CodingAgent {
    public init() {}

    public let id = "copilot"
    public let name = "Copilot CLI"
    public let shortName = "Copilot"
    public let commandName = "copilot"
    public var extraSearchPaths: [String] { commonBins }
    public let capabilities: Set<AgentCapability> = [.initialPrompt, .headless, .readsProject]
    @MainActor public var logo: NSImage { Logo.bundled("githubcopilot", fallback: "person.2") }
    @MainActor public var tint: Color { .primary }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String {
        prompt.map { "\(commandName) -i \(DevWorkspace.quoted($0))" } ?? commandName
    }

    public func headlessArguments(prompt: String) -> [String]? {
        ["-p", prompt, "-s", "--no-ask-user"]
    }

    /// Reading the working directory needs no approval; anything that would (shell, edits) is denied without permission flags.
    public func readOnlyArguments(prompt: String) -> [String]? {
        ["-p", prompt, "-s", "--no-ask-user"]
    }

    public let loginCommand: String? = "copilot login"
    public let installCommand: String? = "curl -fsSL https://gh.io/copilot-install | bash && ~/.local/bin/copilot login"
    public let installURL: URL? = URL(string: "https://github.com/features/copilot/cli")

    public func loginState(executable: String, environment: [String: String]) -> CLILogin { .unknown }
}

/// OpenCode (`opencode`). Only opened, without the prompt: its full-screen app has no documented way
/// to start with one. `opencode run` has no documented way to keep it from using tools, so it doesn't
/// write commit messages either.
public struct OpenCode: CodingAgent {
    public init() {}

    public let id = "opencode"
    public let name = "OpenCode"
    public let shortName = "OpenCode"
    public let commandName = "opencode"
    public var extraSearchPaths: [String] { ["\(NSHomeDirectory())/.opencode/bin"] + commonBins }
    public let capabilities: Set<AgentCapability> = []
    @MainActor public var logo: NSImage { Logo.bundled("opencode", fallback: "chevron.left.forwardslash.chevron.right") }
    @MainActor public var tint: Color { .primary }

    public func interactiveCommand(prompt: String?, options: AgentOptions) -> String { commandName }
    public func headlessArguments(prompt: String) -> [String]? { nil }
    public func readOnlyArguments(prompt: String) -> [String]? { nil }

    public let loginCommand: String? = "opencode auth login"
    public let installCommand: String? = "curl -fsSL https://opencode.ai/v2/install | bash"
    public let installURL: URL? = URL(string: "https://opencode.ai")

    public func loginState(executable: String, environment: [String: String]) -> CLILogin { .unknown }
}

public enum CodingAgents {
    public static let claudeCode = ClaudeCode()

    /// Every agent Bridge knows how to start, in the order one is picked when the user hasn't chosen.
    public static let all: [any CodingAgent] = [claudeCode, Codex(), CursorAgent(), GeminiCLI(), CopilotCLI(), OpenCode()]

    private static let lock = NSLock()
    private static var chosen: any CodingAgent = claudeCode

    /// The user's pick in the app's defaults: an agent's `id`, `none` for no agent at all, or nothing
    /// (or `auto`) to use the first one installed.
    public static let preferenceKey = "agent"
    public static let automatic = "auto"
    public static let none = "none"

    public static func agent(id: String) -> (any CodingAgent)? { all.first { $0.id == id } }

    /// The agent Bridge's buttons start (see `choose`). Claude Code until then and when none is
    /// installed, so the setup checklist suggests it.
    public static var current: any CodingAgent {
        lock.lock()
        defer { lock.unlock() }
        return chosen
    }

    /// Picks the agent: the one the user chose, even when it isn't installed yet (so the checklist
    /// offers to install that one rather than another), otherwise the first one installed on `path`
    /// (the user's PATH). Blocking: looks through the PATH's folders, so it runs off the main thread.
    public static func choose(path: String) {
        let preference = UserDefaults.standard.string(forKey: preferenceKey) ?? automatic
        let agent = agent(id: preference) ?? all.first { $0.executable(path: path) != nil } ?? claudeCode
        lock.lock()
        chosen = agent
        lock.unlock()
    }
}
