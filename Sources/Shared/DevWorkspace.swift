import AppKit

/// Starting work on a project: the coding agent in a terminal, and the command that starts its dev server.
/// Which agent and which terminal is up to `CodingAgents` and `Terminals`; this only puts them together.
public enum DevWorkspace {
    /// Opens a terminal in the project with the coding agent running. A script file instead of scripting
    /// the terminal, so Terminal needs no Automation permission. A `prompt` such as `/monday` is sent
    /// as the agent's first message, which runs a skill just like typing it.
    public static func openAgentInTerminal(_ path: String, prompt: String? = nil) {
        // One file per prompt, so opening two in a row doesn't overwrite the first before the terminal reads it.
        let suffix = prompt.map { "-" + $0.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined().prefix(40) } ?? ""
        runInTerminal(agentCommand(prompt: prompt), in: path, kind: "\(CodingAgents.current.commandName)\(suffix)")
    }

    /// The shell command that starts the coding agent, with the browser when that's turned on and it can.
    public static func agentCommand(prompt: String? = nil) -> String {
        let agent = CodingAgents.current
        var options = AgentOptions.fromDefaults
        options.browser = options.browser && agent.has(.browser)
        return agent.interactiveCommand(prompt: agent.has(.initialPrompt) ? prompt : nil, options: options)
    }

    /// When set in the app's defaults, the agent starts with the browser (Claude's `--chrome`).
    /// Read here rather than passed in, so every agent button and skill chip follows the one toggle.
    /// The key is from when only Claude was supported, kept so the setting carries over.
    public static let agentBrowserKey = "claudeWithChrome"

    /// When set in the app's defaults, Terminal windows opened from here use the "Clear Dark" profile
    /// instead of Terminal's default one. Read by `AppleTerminal`, so every button follows it.
    public static let darkTerminalKey = "darkTerminal"

    /// When set (or never set) in the app's defaults, Rex terminals for a project split its session's window.
    public static let rexSplitKey = "rexSplit"

    /// Opens the terminal in a folder (or a file's folder), the way that terminal does it best
    /// (`TerminalApp.openShell`).
    public static func openTerminal(_ path: String) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        let folder = isFolder.boolValue ? path : (path as NSString).deletingLastPathComponent
        Terminals.current?.openShell(in: folder)
    }

    /// Runs a command in a new terminal tab or window, for scripts that need a real terminal (curses
    /// screens, prompts). The tab stays in the project with a shell once the command ends.
    /// `rexSession` overrides the session the path would get in terminals that group tabs (Rex), for a
    /// folder that isn't the project's yet.
    public static func runInTerminal(_ command: String, in path: String, kind: String = "start", rexSession: String? = nil) {
        guard let terminal = Terminals.current else { return }
        let script = """
            #!/bin/zsh -l
            cd \(quoted(path)) || exit 1
            \(terminal.scriptPrelude())
            clear
            \(command)
            exec ${SHELL:-/bin/zsh} -l

            """
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge/Terminal", isDirectory: true)
        // "/" has no folder name to go by, and a slash in the file name would make it a path.
        let name = path == "/" ? "root" : (path as NSString).lastPathComponent
        let file = folder.appendingPathComponent("\(name)-\(kind).command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return
        }
        terminal.run(scriptAt: file, in: path, session: rexSession)
    }

    /// The project's dev command: a package.json script with the package manager from its lockfile
    /// (installing dependencies first when they're missing), or a common default.
    /// `webOnly` leaves out commands that usually aren't a web server, like `cargo run`.
    public static func startCommand(in path: String, webOnly: Bool = false) -> String? {
        start(in: path, webOnly: webOnly)?.command
    }

    /// The dev command and the folder it runs from (nil for the root). A project with nothing to start at
    /// its root, like a repo with the app in `nuxt/frontend`, gets the nearest subfolder that has one.
    /// `folder` is the user's pick among several apps; it's ignored once that folder no longer has a command.
    public static func start(in path: String, webOnly: Bool = false, folder: String? = nil) -> (folder: String?, command: String)? {
        if let folder, !folder.isEmpty, let command = startCommand(atRoot: (path as NSString).appendingPathComponent(folder), repoRoot: path, webOnly: true) {
            return (folder, "cd \(quoted(folder)) && \(command)")
        }
        if let command = startCommand(atRoot: path, repoRoot: path, webOnly: webOnly) { return (nil, command) }
        guard let app = appFolders(in: path, stopAtFirstLevel: true).first else { return nil }
        return (app.folder, "cd \(quoted(app.folder)) && \(app.command)")
    }

    /// Subfolders (a few levels down) with a dev command we recognize, for repos with several apps.
    /// Shallowest first, and on the same level names that usually hold the app. An app folder isn't searched
    /// further, and dependency and build folders are skipped, as they're full of package.json files.
    /// `stopAtFirstLevel` ends the search at the first level with a match, when only the best one is needed.
    public static func appFolders(in path: String, maxDepth: Int = 3, stopAtFirstLevel: Bool = false) -> [(folder: String, command: String)] {
        let fm = FileManager.default
        let skipped: Set<String> = ["node_modules", "vendor", "dist", "build", "out", "target", "venv", "env", "__pycache__", "Pods", "DerivedData"]
        let preferred = ["frontend", "web", "app", "client", "site", "www"]
        func rank(_ folder: String) -> Int { preferred.firstIndex(of: (folder as NSString).lastPathComponent.lowercased()) ?? preferred.count }
        var apps: [(folder: String, command: String)] = []
        var level = [""]
        for _ in 0..<maxDepth {
            var next: [String] = []
            for relative in level {
                let full = relative.isEmpty ? path : (path as NSString).appendingPathComponent(relative)
                let children = ((try? fm.contentsOfDirectory(atPath: full)) ?? []).filter { name in
                    var isDirectory: ObjCBool = false
                    return !name.hasPrefix(".") && !skipped.contains(name)
                        && fm.fileExists(atPath: (full as NSString).appendingPathComponent(name), isDirectory: &isDirectory) && isDirectory.boolValue
                }
                next += children.map { relative.isEmpty ? $0 : (relative as NSString).appendingPathComponent($0) }
            }
            var found: [(folder: String, command: String)] = []
            next = next.filter { folder in
                guard let command = startCommand(atRoot: (path as NSString).appendingPathComponent(folder), repoRoot: path, webOnly: true) else { return true }
                found.append((folder, command))
                return false
            }
            apps += found.sorted { (rank($0.folder), $0.folder.lowercased()) < (rank($1.folder), $1.folder.lowercased()) }
            if stopAtFirstLevel && !apps.isEmpty { break }
            level = next
        }
        return apps
    }

    /// `repoRoot` is the folder the search started from: an app in a subfolder may be installed from there (workspaces).
    private static func startCommand(atRoot path: String, repoRoot: String, webOnly: Bool) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(name)) }

        if let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any],
           let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) {
            let setup = nodeSetup(app: path, repoRoot: repoRoot)
            let manager = setup.manager
            let run = manager == "yarn" ? "yarn \(script)" : "\(manager) run \(script)"
            // In a workspace the lockfile and node_modules are in an ancestor folder; the install runs from there
            // (in a subshell, so the start command still runs in the app's folder).
            let up = setup.levelsUp == 0 ? "" : String(repeating: "../", count: setup.levelsUp)
            let installIn = setup.levelsUp == 0 ? "\(manager) install" : "(cd \(up) && \(manager) install)"
            let install = "\(say("Dependencies are missing or out of date, running \(manager) install (this can take a minute)…")) && \(installIn)"
            let current = dependenciesCurrent(manager: manager, berry: setup.berry, prefix: up, appPackageJSON: setup.levelsUp > 0,
                                              has: { fm.fileExists(atPath: (setup.folder as NSString).appendingPathComponent($0)) })
            return "{ \(current) || { \(install); }; } && \(say(run)) && \(run)"
        }
        let command: String? =
            has("manage.py") ? "python3 manage.py runserver"
            : has("bin/rails") ? "bin/rails server"
            : has("artisan") ? "php artisan serve"
            : has("docker-compose.yml") || has("compose.yaml") || has("compose.yml") ? "docker compose up"
            : webOnly ? nil
            : has("Cargo.toml") ? "cargo run"
            : has("go.mod") ? "go run ."
            : has("Package.swift") ? "swift run"
            : nil
        return command.map { "\(say($0)) && \($0)" }
    }

    /// A shell test for whether node_modules is a finished install of the current package.json and lockfile.
    /// A bare node_modules folder isn't enough: a fresh clone has none, and an interrupted install leaves one
    /// without the tools (nuxt, vite, concurrently …). Each package manager writes a marker file when it finishes.
    /// `prefix` leads from the app's folder to the folder that was installed in (empty, or "../../"), where the marker,
    /// the lockfile and the root package.json are; `appPackageJSON` adds the app's own package.json to the check then.
    /// `has` looks in the install folder.
    private static func dependenciesCurrent(manager: String, berry: Bool, prefix: String, appPackageJSON: Bool, has: (String) -> Bool) -> String {
        let marker: String
        let lockfile: String
        switch manager {
        case "pnpm": (marker, lockfile) = ("node_modules/.modules.yaml", "pnpm-lock.yaml")
        case "yarn": (marker, lockfile) = (berry ? "node_modules/.yarn-state.yml" : "node_modules/.yarn-integrity", "yarn.lock")
        case "npm": (marker, lockfile) = ("node_modules/.package-lock.json", "package-lock.json")
        // bun has no marker, but its install takes well under a second when nothing changed.
        default: return "false"
        }
        let mtime = { (file: String) in "$(stat -f %m \(file))" }
        let marked = prefix + marker
        // The install rewrites the lockfile in the same moment as the marker, hence the slack.
        let lockfileCovered = has(lockfile) ? " && [ \(mtime(prefix + lockfile)) -le $(( \(mtime(marked)) + 2 )) ]" : ""
        let appCovered = appPackageJSON ? " && [ \(mtime("package.json")) -le \(mtime(marked)) ]" : ""
        return "{ [ -e \(marked) ] && [ \(mtime(prefix + "package.json")) -le \(mtime(marked)) ]\(appCovered)\(lockfileCovered); }"
    }

    /// Which package manager an app uses and where it installs from. The `packageManager` field in package.json
    /// (like "pnpm@9.1.0") comes first, in the app's folder and then each folder above it; without one, the nearest
    /// folder with a lockfile decides, so an app with a lockfile of its own isn't taken over by one in the root.
    /// Nothing is searched above `repoRoot`. The install folder is the nearest one with the manager's lockfile
    /// (or the one with the field, or the app itself, when there is none); npm is the last resort.
    private static func nodeSetup(app: String, repoRoot: String) -> (manager: String, folder: String, levelsUp: Int, berry: Bool) {
        let fm = FileManager.default
        let app = (app as NSString).standardizingPath
        let root = (repoRoot as NSString).standardizingPath
        var folders = [app]
        if app.hasPrefix(root + "/") {
            var folder = app
            while folder != root {
                folder = (folder as NSString).deletingLastPathComponent
                folders.append(folder)
            }
        }
        func has(_ name: String, in folder: String) -> Bool { fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }
        let lockfiles: [(manager: String, names: [String])] = [("pnpm", ["pnpm-lock.yaml"]), ("yarn", ["yarn.lock"]), ("bun", ["bun.lockb", "bun.lock"]), ("npm", ["package-lock.json"])]
        func result(_ manager: String, _ folder: String, berry: Bool) -> (manager: String, folder: String, levelsUp: Int, berry: Bool) {
            (manager, folder, folders.firstIndex(of: folder) ?? 0, berry)
        }

        for folder in folders {
            guard let data = fm.contents(atPath: (folder as NSString).appendingPathComponent("package.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let field = json["packageManager"] as? String else { continue }
            let parts = field.split(separator: "@", maxSplits: 1).map(String.init)
            guard let manager = parts.first, lockfiles.contains(where: { $0.manager == manager }) else { continue }
            let names = lockfiles.first { $0.manager == manager }?.names ?? []
            let installFolder = folders.first { folder in names.contains { has($0, in: folder) } } ?? folder
            let major = parts.count > 1 ? Int(parts[1].prefix { $0.isNumber }) : nil
            return result(manager, installFolder, berry: manager == "yarn" && ((major ?? 1) >= 2 || has(".yarnrc.yml", in: installFolder)))
        }
        for folder in folders {
            if let manager = lockfiles.first(where: { $0.names.contains { has($0, in: folder) } })?.manager {
                return result(manager, folder, berry: manager == "yarn" && has(".yarnrc.yml", in: folder))
            }
        }
        return result("npm", app, berry: false)
    }

    /// A script in the project folder that could start it, for projects with no command we recognize
    /// (like a `start.py` that starts several services). Likely names first.
    public static func startScripts(in path: String) -> [String] {
        let fm = FileManager.default
        let extensions: Set<String> = ["py", "sh", "zsh", "bash", "command", "js", "mjs"]
        let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            let full = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard !name.hasPrefix("."), fm.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return extensions.contains(ext) || (ext.isEmpty && fm.isExecutableFile(atPath: full))
        }
        let likely = ["start", "run", "dev", "serve", "up", "launch"]
        func rank(_ name: String) -> Int {
            let base = (name as NSString).deletingPathExtension.lowercased()
            return likely.firstIndex(where: { base.hasPrefix($0) }) ?? likely.count
        }
        return names.sorted { (rank($0), $0.lowercased()) < (rank($1), $1.lowercased()) }
    }

    /// How to run a script found by `startScripts`, and whether it looks like it needs a terminal.
    /// Python scripts with inline dependencies (`# /// script`) or in a uv project run with uv.
    public static func command(forScript name: String, in path: String) -> (command: String, needsTerminal: Bool) {
        let fm = FileManager.default
        let full = (path as NSString).appendingPathComponent(name)
        let text = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
        let file = quoted(name)
        let local = fm.isExecutableFile(atPath: full) ? "./" + file : nil
        let command: String
        switch (name as NSString).pathExtension.lowercased() {
        case "py":
            let uv = text.contains("# /// script") || fm.fileExists(atPath: (path as NSString).appendingPathComponent("uv.lock"))
            command = uv ? "uv run \(file)" : "python3 \(file)"
        case "js", "mjs": command = "node \(file)"
        case "zsh": command = local ?? "zsh \(file)"
        case "bash": command = local ?? "bash \(file)"
        case "sh", "command": command = local ?? "sh \(file)"
        default: command = local ?? "./" + file
        }
        // Full-screen and interactive scripts can't run with their output going to a log file.
        let interactive = ["import curses", "from curses", "textual", "input(", "\nread "]
        return (command, interactive.contains { text.contains($0) })
    }

    /// A command that first prints itself, as the detected ones do.
    public static func announced(_ command: String) -> String {
        "\(say(command)) && \(command)"
    }

    public static func quoted(_ text: String) -> String {
        guard text.contains(where: { !($0.isLetter || $0.isNumber || "._-/".contains($0)) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell command that prints a status line, so a silent install or build doesn't look stuck.
    public static func say(_ message: String) -> String {
        let quoted = "\u{1B}[2m▸ \(message)\u{1B}[0m".replacingOccurrences(of: "'", with: "'\\''")
        return "printf '%s\\n' '\(quoted)'"
    }
}
