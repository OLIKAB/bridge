import AppKit

/// An editor the coding agent can open in instead of a terminal: Claude Code's VS Code extension
/// takes `vscode://anthropic.claude-code/open?prompt=…` and opens a Claude Code tab in the focused
/// window, so Bridge opens the project folder first and the link right after. Only Claude Code has
/// such an extension, and only VS Code's link is documented (code.claude.com/docs/en/vs-code), so
/// forks like Cursor aren't listed: they register their own URL schemes, and whether the extension's
/// handler answers there is untested.
public struct AgentEditor: Sendable {
    /// Stored in the terminal pick (`Terminals.preferenceKey`), which `Terminals.current` doesn't
    /// recognize, so shells and scripts still go to the first installed terminal.
    public let id: String
    public let name: String
    public let bundleId: String
    let scheme: String
    /// Where the editor keeps its extensions, to tell whether Claude Code's is installed.
    let extensionsFolder: String

    public static let vsCode = AgentEditor(id: "vscode", name: "VS Code", bundleId: "com.microsoft.VSCode",
                                           scheme: "vscode", extensionsFolder: ".vscode/extensions")

    public var isInstalled: Bool { InstalledApps.url(for: bundleId) != nil }

    /// Whether Claude Code's extension is in the editor's extensions folder.
    public var hasAgentExtension: Bool {
        let folder = (NSHomeDirectory() as NSString).appendingPathComponent(extensionsFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { $0.hasPrefix("anthropic.claude-code-") }
    }

    /// Opens `folder` in the editor, then a Claude Code tab there with `prompt` filled in (not sent:
    /// the extension leaves it to the user). The link goes to the focused window, so it waits for the
    /// folder's window, longer when the editor has to start. `/` is the panel's prompt without a
    /// project, which only opens the tab.
    public func open(folder: String, prompt: String?) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        if let prompt, !prompt.isEmpty { components.queryItems = [URLQueryItem(name: "prompt", value: prompt)] }
        guard let link = components.url else { return }
        guard folder != "/", let app = InstalledApps.url(for: bundleId) else {
            NSWorkspace.shared.open(link)
            return
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasRunning ? 0.8 : 3)) {
                NSWorkspace.shared.open(link)
            }
        }
    }
}

public enum AgentEditors {
    public static let all = [AgentEditor.vsCode]

    /// The editors the agent in use can open in right now.
    public static var available: [AgentEditor] {
        guard CodingAgents.current.id == CodingAgents.claudeCode.id else { return [] }
        return all.filter { $0.isInstalled && $0.hasAgentExtension }
    }

    /// The editor picked for the agent, while it can still take it; nil means a terminal.
    public static var current: AgentEditor? {
        let choice = UserDefaults.standard.string(forKey: Terminals.preferenceKey)
        return available.first { $0.id == choice }
    }
}
