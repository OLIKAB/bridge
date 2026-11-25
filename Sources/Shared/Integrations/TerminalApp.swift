import AppKit

/// A terminal app Bridge opens shells and scripts in. Bridge writes what should run to an executable
/// script (see `DevWorkspace.runInTerminal`), so each terminal only has to know how to run a file:
/// that keeps the user's login shell and its config (nvm, pyenv, …) whichever terminal it is.
public protocol TerminalApp: Sendable {
    /// Stable, for settings.
    var id: String { get }
    var name: String { get }
    var bundleId: String { get }
    /// Shell lines put at the top of every script run in it, after the `cd`.
    func scriptPrelude() -> String
    /// Runs the executable script at `file` in a new tab or window in `folder`. `session` names the
    /// group the tab belongs in, for terminals that have them. False when nothing could be opened.
    @discardableResult
    func run(scriptAt file: URL, in folder: String, session: String?) -> Bool
    /// Opens a plain shell in `folder`.
    func openShell(in folder: String)
}

extension TerminalApp {
    public var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
    public var isInstalled: Bool { appURL != nil }

    public func scriptPrelude() -> String { "" }

    public func openShell(in folder: String) {
        DevWorkspace.runInTerminal("", in: folder, kind: "terminal")
    }
}

/// macOS's own Terminal. It runs .command files when they're opened with it, which needs no Automation
/// permission, unlike scripting it.
public struct AppleTerminal: TerminalApp {
    public init() {}

    public let id = "terminal"
    public let name = "Terminal"
    public let bundleId = "com.apple.Terminal"

    static let darkProfile = "Clear Dark"
    private var isDark: Bool { UserDefaults.standard.bool(forKey: DevWorkspace.darkTerminalKey) }

    public func scriptPrelude() -> String {
        isDark ? Self.switchProfile(to: Self.darkProfile) : ""
    }

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool {
        guard let appURL else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Opening the folder with Terminal is quickest, but only a script can switch the profile.
    public func openShell(in folder: String) {
        if isDark { return DevWorkspace.runInTerminal("", in: folder, kind: "terminal") }
        guard let appURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shell lines that give this script's own Terminal tab another profile. Terminal can't be told which
    /// profile a .command file opens in, so the tab switches itself once it runs: found by its tty, since
    /// another window may be in front by then. Terminal scripting itself needs no Automation permission.
    private static func switchProfile(to profile: String) -> String {
        """
        osascript - "$(tty)" >/dev/null 2>&1 <<'APPLESCRIPT'
        on run argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is item 1 of argv then set current settings of t to settings set "\(profile)"
                    end repeat
                end repeat
            end tell
        end run
        APPLESCRIPT
        """
    }
}

/// Rex, a Ghostty-based terminal with sessions: each project's terminals go in a session named after it.
public struct Rex: TerminalApp {
    public init() {}

    public let id = "rex"
    public let name = "Rex"
    public let bundleId = "com.superlogical.rex"

    /// Rex doesn't run .command files (opening one only opens its folder), so the script is run through
    /// its AppleScript `run command`, which costs a one-time Automation prompt.
    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool {
        guard isInstalled else { return false }
        run(DevWorkspace.quoted(file.path), in: folder, session: session)
        return true
    }

    /// Opens a new Rex tab in `folder` running `command`. osascript instead of NSAppleScript, so the
    /// panel never waits on Rex launching, and with the strings passed as arguments so nothing needs escaping.
    ///
    /// Without `in`, Rex puts the tab in whichever session it shows, so every project's terminals would
    /// pile up in one session. The tab goes to the session named after the project instead (see
    /// `session(for:)`), which is created on first use; folders outside a project use the shown one.
    ///
    /// With `DevWorkspace.rexSplitKey` on (the default), a project that already has a session gets a split
    /// pane next to the focused one instead of a tab, so its terminals sit side by side. AppleScript can
    /// only make tabs, so that goes through the `rex` CLI inside Rex's bundle; if the CLI is missing or
    /// fails, a tab it is.
    public func run(_ command: String, in folder: String, session: String? = nil) {
        guard let appURL else { return }
        let name = session ?? Self.session(for: folder) ?? ""
        let split = UserDefaults.standard.object(forKey: DevWorkspace.rexSplitKey) as? Bool ?? true
        let cli = appURL.appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
        guard split, !name.isEmpty, FileManager.default.isExecutableFile(atPath: cli.path) else {
            return script(command, in: folder, session: name)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let id = Self.sessionID(named: name, cli: cli),
                  Self.run(cli, ["split", "-s", id, "-c", folder, "--shell=none", "--", "/bin/sh", "-c", command]) == 0
            else { return script(command, in: folder, session: name) }
            script(nil, in: folder, session: name)
        }
    }

    /// The id of the local Rex session labelled `name`, matched without regard to case like AppleScript does.
    private static func sessionID(named name: String, cli: URL) -> String? {
        var output = Data()
        guard run(cli, ["ls", "--json"], output: &output) == 0,
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]]
        else { return nil }
        return sessions.first { ($0["label"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["session_id"] as? String
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> Int32 {
        var ignored = Data()
        return run(executable, arguments, output: &ignored)
    }

    private static func run(_ executable: URL, _ arguments: [String], output: inout Data) -> Int32 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        // Read before waiting, so a full pipe can't block the process.
        output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The AppleScript side: a new tab in the named session (created if missing), or in the shown session
    /// when `session` is empty. With a nil command it only brings Rex forward showing the session.
    private func script(_ command: String?, in folder: String, session name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "set {cmd, dir, nm} to {item 1 of argv, item 2 of argv, item 3 of argv}",
            "-e", "tell application id \"\(bundleId)\"",
            "-e", "activate",
            "-e", "if cmd is \"\" then",
            "-e", "show nm",
            "-e", "return",
            "-e", "end if",
            "-e", "if nm is \"\" then",
            "-e", "run command cmd at dir",
            "-e", "return",
            "-e", "end if",
            "-e", "repeat with s in sessions",
            "-e", "if remote of s is false and name of s is nm then",
            "-e", "set target to contents of s",
            "-e", "run command cmd in target at dir",
            "-e", "show target",
            "-e", "return",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "new session named nm at dir running cmd",
            "-e", "end tell",
            "-e", "end run",
            command ?? "", folder, name,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// The Rex session a folder's terminals belong in: named after the repository the folder is in (so a
    /// subfolder app or a server started deeper in the repo lands with the rest), or after the folder itself.
    /// Home and "/" belong to no project and get nil.
    static func session(for folder: String) -> String? {
        let home = NSHomeDirectory()
        let start = (folder as NSString).standardizingPath
        guard start != home, start != "/" else { return nil }
        var dir = start
        while dir != home, dir != "/", !dir.isEmpty {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return (dir as NSString).lastPathComponent
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return (start as NSString).lastPathComponent
    }
}

/// Opens `url` (a script or a folder) with the terminal's app, as a double-click in Finder would. For
/// terminals that run script files they're given, which needs no Automation permission.
private func open(_ url: URL, with terminal: some TerminalApp) -> Bool {
    guard let appURL = terminal.appURL else { return false }
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    return true
}

/// Starts the terminal's own command line, for terminals that take what to run as arguments. Not waited
/// for: when the terminal isn't running yet, this process becomes it.
private func launch(_ executable: URL, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return (try? process.run()) != nil
}

/// iTerm2 runs a script file it's opened with (after asking once "OK to run?", which can be turned
/// off for good in that dialog) and opens a folder as a session in it.
public struct ITerm: TerminalApp {
    public init() {}

    public let id = "iterm"
    public let name = "iTerm"
    public let bundleId = "com.googlecode.iterm2"

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool { open(file, with: self) }

    public func openShell(in folder: String) { _ = open(URL(fileURLWithPath: folder), with: self) }
}

/// Ghostty runs a script file it's opened with, but always asks first: its author keeps that dialog on
/// purpose, as running files unasked is a way in for attacks. Its other ways need Automation permission
/// or start a separate copy of the app each time.
public struct Ghostty: TerminalApp {
    public init() {}

    public let id = "ghostty"
    public let name = "Ghostty"
    public let bundleId = "com.mitchellh.ghostty"

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool { open(file, with: self) }

    public func openShell(in folder: String) { _ = open(URL(fileURLWithPath: folder), with: self) }
}

/// Warp doesn't run script files it's opened with, and its URLs only open folders. What it does run is
/// a Tab Config, a TOML file in ~/.warp/tab_configs, opened by its file name through a `warp://` URL.
/// One per script, named after it, so the file is there already from the second time on: whether Warp
/// sees a file that was written a moment before the URL opens isn't documented, hence the short wait.
public struct Warp: TerminalApp {
    public init() {}

    public let id = "warp"
    public let name = "Warp"
    public let bundleId = "dev.warp.Warp-Stable"

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool {
        guard isInstalled else { return false }
        let stem = "bridge_" + file.deletingPathExtension().lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let configs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".warp/tab_configs", isDirectory: true)
        let config = configs.appendingPathComponent("\(stem).toml")
        let toml = """
            name = \(Self.tomlString("Bridge: \(file.deletingPathExtension().lastPathComponent)"))

            [[panes]]
            id = "main"
            type = "terminal"
            directory = \(Self.tomlString(folder))
            commands = [\(Self.tomlString(DevWorkspace.quoted(file.path)))]

            """
        let existed = (try? String(contentsOf: config, encoding: .utf8)) == toml
        do {
            try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
            if !existed { try toml.write(to: config, atomically: true, encoding: .utf8) }
        } catch {
            return false
        }
        guard let url = URL(string: "warp://tab_config/\(stem)") else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (existed ? 0 : 0.5)) { NSWorkspace.shared.open(url) }
        return true
    }

    public func openShell(in folder: String) {
        var components = URLComponents(string: "warp://action/new_tab")
        components?.queryItems = [URLQueryItem(name: "path", value: folder)]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    /// A TOML basic string: quoted, with backslashes and quotes escaped.
    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// WezTerm takes what to run on its own command line (`wezterm start`), which hands it to the running
/// app or starts it.
public struct WezTerm: TerminalApp {
    public init() {}

    public let id = "wezterm"
    public let name = "WezTerm"
    public let bundleId = "com.github.wez.wezterm"

    private var cli: URL? { appURL?.appendingPathComponent("Contents/MacOS/wezterm") }

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool {
        guard let cli else { return false }
        return launch(cli, ["start", "--cwd", folder, "--", file.path])
    }

    public func openShell(in folder: String) {
        guard let cli else { return }
        _ = launch(cli, ["start", "--cwd", folder])
    }
}

/// Kitty takes what to run on its command line; `--single-instance` opens it in the running app as a
/// new window. Opening a script file with it asks for confirmation, so its command line it is.
public struct Kitty: TerminalApp {
    public init() {}

    public let id = "kitty"
    public let name = "kitty"
    public let bundleId = "net.kovidgoyal.kitty"

    private var cli: URL? { appURL?.appendingPathComponent("Contents/MacOS/kitty") }

    @discardableResult
    public func run(scriptAt file: URL, in folder: String, session: String?) -> Bool {
        guard let cli else { return false }
        return launch(cli, ["--single-instance", "--directory", folder, file.path])
    }

    public func openShell(in folder: String) {
        guard let cli else { return }
        _ = launch(cli, ["--single-instance", "--directory", folder])
    }
}

public enum Terminals {
    /// Every terminal Bridge can open, in the order it prefers them when the user hasn't picked one:
    /// someone who installed another terminal most likely uses it rather than macOS's own.
    public static let all: [any TerminalApp] = [Rex(), ITerm(), Ghostty(), Warp(), WezTerm(), Kitty(), AppleTerminal()]

    /// The user's pick in the app's defaults: a terminal's `id`, or nothing (or `auto`) for the first installed.
    public static let preferenceKey = "terminal"

    /// The terminal Bridge opens: the one the user chose while it's installed, otherwise the first one installed.
    public static var current: (any TerminalApp)? {
        let preference = UserDefaults.standard.string(forKey: preferenceKey)
        if let chosen = all.first(where: { $0.id == preference }), chosen.isInstalled { return chosen }
        return all.first { $0.isInstalled }
    }

    public static var installed: [any TerminalApp] { all.filter(\.isInstalled) }

    /// Whether `bundleId` is one of the terminals, so "Open in" menus can leave terminals out.
    public static func contains(bundleId: String) -> Bool { all.contains { $0.bundleId == bundleId } }
}
