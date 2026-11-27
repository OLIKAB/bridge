import Foundation
import Shared
import SwiftUI

/// Whether the installed Claude Code is the newest release, and updating it in the background.
///
/// The newest version comes from where the installed copy updates from: Homebrew's cask for a cask
/// install, npm (where every release is published) otherwise. Updating runs `brew upgrade --cask` or
/// `claude update`.
@MainActor
final class ClaudeUpdate: ObservableObject {
    static let shared = ClaudeUpdate()

    @Published private(set) var installed: String?
    @Published private(set) var latest: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var error: String?

    private var lastCheck: Date?
    /// Published for the bar's spinner while a check asked for by hand runs.
    @Published private(set) var isChecking = false
    /// A release `claude update` couldn't install yet. Homebrew's cask can be a few hours behind npm,
    /// and the button shouldn't keep offering an update that does nothing.
    private var unavailable: String?

    var needsUpdate: Bool {
        guard let installed, let latest, latest != unavailable else { return false }
        return Self.isNewer(latest, than: installed)
    }

    /// Checks at most every 30 minutes, since it runs each time the panel opens.
    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 30 * 60 { return }
        Task { await check() }
    }

    func check() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }
        lastCheck = Date()
        async let installed = Self.installedVersion()
        async let latest = Self.latestVersion(cask: Claude.executable.flatMap(Self.cask))
        let (i, l) = await (installed, latest)
        self.installed = i
        if let l { self.latest = l }
    }

    func update() {
        guard !isUpdating, let executable = Claude.executable else { return }
        isUpdating = true
        error = nil
        let before = installed
        let target = latest
        Task {
            // For a Homebrew install `claude update` only prints "To update, run: brew upgrade …" and exits 0,
            // so it looked like it worked while nothing changed. Run Homebrew ourselves then.
            let (path, args) = Self.updateCommand(for: executable)
            let result = await Self.run(path, args, timeout: 600)
            installed = await Self.installedVersion()
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

    /// `brew upgrade --cask <cask>` when the `claude` found is a Homebrew cask, otherwise `claude update`.
    private nonisolated static func updateCommand(for executable: String) -> (String, [String]) {
        if let cask = cask(of: executable),
           let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            return (brew, ["upgrade", "--cask", cask])
        }
        return (executable, ["update"])
    }

    /// The Homebrew cask the `claude` found was installed from, if it was.
    private nonisolated static func cask(of executable: String) -> String? {
        let parts = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "Caskroom"), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    private static func installedVersion() async -> String? {
        guard let executable = Claude.executable else { return nil }
        let result = await run(executable, ["--version"], timeout: 15)
        // "2.1.328 (Claude Code)"
        return result.stdout.split(separator: " ").first.map(String.init).flatMap { $0.first?.isNumber == true ? $0 : nil }
    }

    /// The newest version the installed copy can update to: the cask's for a Homebrew install, which is
    /// often hours behind npm, so an update is only offered once Homebrew has it (offering npm's
    /// version ended in "isn't available through Homebrew yet" after the click); npm's otherwise.
    private static func latestVersion(cask: String?) async -> String? {
        if let cask, let version = await jsonVersion("https://formulae.brew.sh/api/cask/\(cask).json") {
            // "2.1.331" or "2.1.331,<build>" for casks that carry more than the version.
            return version.split(separator: ",").first.map(String.init)
        }
        return await jsonVersion("https://registry.npmjs.org/@anthropic-ai/claude-code/latest")
    }

    private static func jsonVersion(_ address: String) async -> String? {
        guard let url = URL(string: address),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
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

/// How much of the plan's usage limits is left, as last seen by Claude Code.
///
/// There is no command that prints this, and the usage API needs Claude Code's login from the keychain.
/// Instead Claude Code's status line script (`~/.claude/statusline.sh`) is given the limits with every
/// update and saves them to `~/.claude/rate-limits.json`, so the numbers are as fresh as the last session.
struct ClaudeUsage {
    struct Window {
        let usedPercentage: Double
        let resetsAt: Date

        /// Once the window has reset, nothing of the new one has been used until a session says otherwise.
        var leftPercentage: Int {
            resetsAt < Date() ? 100 : max(0, 100 - Int(usedPercentage.rounded()))
        }
    }

    let session: Window?
    let week: Window?

    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/rate-limits.json")

    static func load() -> ClaudeUsage? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = json[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let usage = ClaudeUsage(session: window("five_hour"), week: window("seven_day"))
        return usage.session == nil && usage.week == nil ? nil : usage
    }
}

/// The line at the very top of the panel: usage left, and on the right something only when there is
/// something to say (an update, a check or update running, a failure). Being up to date needs no words.
///
/// Only for an agent that can update itself (`.selfUpdate`), and the usage only for one that reports it
/// (`.usage`) and has reported it (`ClaudeUsage.file` is written by the user's own status line script,
/// so most people won't have it).
struct ClaudeUpdateBar: View {
    @ObservedObject private var update = ClaudeUpdate.shared
    @ObservedObject private var agent = AgentStatus.shared
    @State private var usage = ClaudeUsage.load()

    var body: some View {
        if update.installed != nil, agent.info.can(.selfUpdate) {
            HStack(spacing: 6) {
                // The logo stands for Claude Code and checks for a newer one when clicked, since that is
                // what people click when they want to make sure. The negative padding gives the hover
                // fill room without making the line taller.
                Button { Task { await update.check() } } label: {
                    Image(nsImage: Logo.claude)
                        .resizable()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
                .buttonStyle(.panel)
                .padding(-3)
                .disabled(update.isChecking || update.isUpdating)
                .panelTooltip("Claude Code \(update.installed ?? ""). Click to check for updates")
                if let usage, agent.info.can(.usage) {
                    Divider().frame(height: 10)
                    UsageLeft(usage: usage)
                }
                Spacer()
                if update.isUpdating {
                    ProgressView().controlSize(.mini)
                    Text("Updating…").foregroundStyle(.secondary)
                } else if let error = update.error {
                    Text(error).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
                    Button { update.update() } label: {
                        Image(systemName: "arrow.clockwise").padding(3)
                    }
                    .buttonStyle(.panel)
                    .padding(-3)
                    .panelTooltip("Retry")
                } else if update.needsUpdate {
                    Button("Update to \(update.latest ?? "")") { update.update() }
                        .controlSize(.small)
                        .prominentButton()
                } else if update.isChecking {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onAppear { usage = ClaudeUsage.load() }
            // The panel stays in memory while closed, so reread when it opens again.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                usage = ClaudeUsage.load()
            }
            PanelDivider()
        }
    }
}

/// "session 77% · week 59%" left. Turns orange under 20% and red under 5%.
private struct UsageLeft: View {
    let usage: ClaudeUsage

    var body: some View {
        HStack(spacing: 4) {
            if let session = usage.session {
                part("session", session)
            }
            if usage.session != nil, usage.week != nil {
                Text("·").foregroundStyle(.tertiary)
            }
            if let week = usage.week {
                part("week", week)
            }
        }
    }

    private func part(_ name: String, _ window: ClaudeUsage.Window) -> some View {
        let left = window.leftPercentage
        return Text("\(name) \(left)%")
            .monospacedDigit()
            .foregroundStyle(left < 5 ? AnyShapeStyle(.red) : left < 20 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }
}
