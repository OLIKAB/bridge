import Foundation
import Shared
import SwiftUI

/// Whether the coding agent in use is its newest release, and updating it in the background. For any
/// agent with `.selfUpdate` (Claude Code, Codex, Gemini CLI, Copilot CLI), shown in the status line.
///
/// Both the newest version and how to update come from how the copy was installed, read from where its
/// command really is (`Installation`). A Homebrew copy is compared with Homebrew's own version, which
/// is often hours behind npm, so an update is only offered once Homebrew has it (offering npm's ended
/// in "isn't available through Homebrew yet" after the click), and updated with `brew upgrade`. Any
/// other copy is compared with npm, where every release is published, and updated with the agent's own
/// command (`claude update`, `codex update`), or with npm for an npm copy of an agent without one.
@MainActor
final class AgentUpdate: ObservableObject {
    static let shared = AgentUpdate()

    /// The agent the figures below are for (`CodingAgent.name`), so a switch of agent in Settings
    /// doesn't offer the old one's update under the new one's name until the next check.
    @Published private(set) var name: String?
    @Published private(set) var installed: String?
    @Published private(set) var latest: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var error: String?
    /// Published for the line's spinner while a check runs.
    @Published private(set) var isChecking = false
    /// Whether Bridge knows how to update this copy. One from an unknown installer of an agent without
    /// an update command of its own (Gemini CLI, say) gets no button that couldn't work.
    @Published private(set) var canUpdate = false

    private var checkedAgent: String?
    private var lastCheck: Date?
    /// A release the updater couldn't install yet (Homebrew a little behind, a release not out
    /// everywhere), so the button doesn't keep offering an update that does nothing.
    private var unavailable: String?

    var needsUpdate: Bool {
        guard canUpdate, let installed, let latest, latest != unavailable else { return false }
        return Self.isNewer(latest, than: installed)
    }

    /// Checks at most every 30 minutes, since it runs each time the panel opens, and at once for an
    /// agent other than the one checked last.
    func checkIfDue() {
        if Agent.current.id != checkedAgent {
            lastCheck = nil
        } else if let lastCheck, Date().timeIntervalSince(lastCheck) < 30 * 60 {
            return
        }
        Task { await check() }
    }

    func check() async {
        guard !isChecking, !isUpdating else { return }
        let agent = Agent.current
        if agent.id != checkedAgent {
            // Nothing of the previous agent's carries over.
            name = agent.name
            installed = nil
            latest = nil
            error = nil
            unavailable = nil
            canUpdate = false
            checkedAgent = agent.id
        }
        guard agent.has(.selfUpdate), let updates = agent.updates, let executable = Agent.executable else {
            installed = nil
            return
        }
        isChecking = true
        defer { isChecking = false }
        lastCheck = Date()
        let installation = await Git.offThread { Installation(of: executable) }
        async let installed = Self.installedVersion(executable)
        async let latest = Self.latestVersion(installation, npmPackage: updates.npmPackage)
        let (i, l) = await (installed, latest)
        // The agent may have been switched while this ran.
        guard agent.id == checkedAgent else { return }
        self.installed = i
        if let l { self.latest = l }
        canUpdate = installation.updateCommand(executable: executable, updates: updates) != nil
    }

    func update() {
        let agent = Agent.current
        guard !isUpdating, agent.id == checkedAgent, let updates = agent.updates, let executable = Agent.executable else { return }
        isUpdating = true
        error = nil
        let before = installed
        let target = latest
        Task {
            let installation = await Git.offThread { Installation(of: executable) }
            guard let (path, args) = installation.updateCommand(executable: executable, updates: updates) else {
                isUpdating = false
                return
            }
            let result = await Self.run(path, args, timeout: 600)
            installed = await Self.installedVersion(executable)
            isUpdating = false
            let output = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let lastLine = output.flatMap { $0.split(separator: "\n").last.map(String.init) }
            if !result.succeeded {
                error = lastLine ?? "Update failed (exit code \(result.status))"
            } else if let installed, let target, Self.isNewer(target, than: installed), installed == before {
                // The updater didn't have it yet after all: stop offering it, quietly. A red "isn't
                // available yet" after the click only told the user the button had been for nothing.
                unavailable = target
            }
        }
    }

    /// Puts a failed update's message away; it stayed until the next update otherwise.
    func dismissError() {
        error = nil
    }

    /// How a copy of an agent was installed, from where its command leads: Homebrew keeps casks in
    /// `Caskroom/<cask>/` and formulae in `Cellar/<formula>/`, and npm puts global packages in
    /// `<prefix>/lib/node_modules/`, next to that prefix's own `bin/npm`.
    enum Installation {
        case cask(String)
        case formula(String)
        case npm(npm: String)
        /// The agent's own installer, or one Bridge doesn't know.
        case other

        /// Blocking: resolves symlinks.
        init(of executable: String) {
            let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            let parts = path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "Caskroom"), i + 1 < parts.count {
                self = .cask(parts[i + 1])
            } else if let i = parts.firstIndex(of: "Cellar"), i + 1 < parts.count {
                self = .formula(parts[i + 1])
            } else if let range = path.range(of: "/lib/node_modules/") {
                let npm = String(path[..<range.lowerBound]) + "/bin/npm"
                self = FileManager.default.isExecutableFile(atPath: npm) ? .npm(npm: npm) : .other
            } else {
                self = .other
            }
        }

        private static var brew: String? {
            ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)
        }

        /// What updates this copy, or nil when Bridge doesn't know how.
        func updateCommand(executable: String, updates: AgentUpdates) -> (String, [String])? {
            switch self {
            // For a Homebrew copy `claude update` only prints "To update, run: brew upgrade …" and
            // exits 0, so it looked like it worked while nothing changed. Homebrew is run instead.
            case let .cask(cask): return Self.brew.map { ($0, ["upgrade", "--cask", cask]) }
            case let .formula(formula): return Self.brew.map { ($0, ["upgrade", formula]) }
            case let .npm(npm):
                if let own = updates.selfUpdateArguments { return (executable, own) }
                return (npm, ["install", "-g", "\(updates.npmPackage)@latest"])
            case .other:
                return updates.selfUpdateArguments.map { (executable, $0) }
            }
        }
    }

    /// The first version number in `--version`'s output: "2.1.332 (Claude Code)", "codex-cli 0.172.0".
    private static func installedVersion(_ executable: String) async -> String? {
        let result = await run(executable, ["--version"], timeout: 15)
        return (result.stdout + "\n" + result.stderr).firstMatch(of: #/\d+(?:\.\d+)+/#).map { String($0.0) }
    }

    /// The newest version this copy can update to (see the type's comment).
    private static func latestVersion(_ installation: Installation, npmPackage: String) async -> String? {
        switch installation {
        case let .cask(cask):
            // "2.1.331" or "2.1.331,<build>" for casks that carry more than the version.
            return await json("https://formulae.brew.sh/api/cask/\(cask).json")
                .flatMap { $0["version"] as? String }
                .flatMap { $0.split(separator: ",").first.map(String.init) }
        case let .formula(formula):
            return await json("https://formulae.brew.sh/api/formula/\(formula).json")
                .flatMap { ($0["versions"] as? [String: Any])?["stable"] as? String }
        case .npm, .other:
            return await json("https://registry.npmjs.org/\(npmPackage)/latest").flatMap { $0["version"] as? String }
        }
    }

    private static func json(_ address: String) async -> [String: Any]? {
        guard let url = URL(string: address),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func run(_ executable: String, _ args: [String], timeout: TimeInterval) async -> GitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Git.runSync(executable, args, in: NSHomeDirectory(), environment: Git.environment, timeout: timeout))
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
