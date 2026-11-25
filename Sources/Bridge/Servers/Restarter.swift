import AppKit
import Foundation
import Shared

/// How a listening process can be started again.
enum RestartPlan {
    /// Kill `pids`, then rerun `command` in `cwd`, in a terminal window or in the background.
    case terminal(command: String, cwd: String, pids: [Int32], title: String)
    /// Managed by `brew services`.
    case brew(formula: String)
    case docker(container: String)
    case unsupported(reason: String)
}

struct LaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Restarter {
    /// Processes that just start the real server (`npm run dev` → `sh -c nuxt dev` → `node nuxt`).
    /// We walk up through these to find the command the user actually typed.
    private static let launchers: Set<String> = [
        "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "node", "sh",
        "uv", "uvx", "poetry", "pipenv", "nodemon", "turbo", "concurrently", "make",
        "python", "python3", "ruby", "bundle", "cargo", "go", "php",
    ]

    static func plan(for process: ListeningProcess) -> RestartPlan {
        if let container = process.container {
            return .docker(container: container)
        }
        if process.isSystem || process.framework == .docker {
            return .unsupported(reason: "Apps and system processes can't be restarted")
        }
        if let formula = brewFormula(for: process.executable) {
            return .brew(formula: formula)
        }

        // Chain from the listening process up to the command that was typed.
        var chain: [Int32] = [process.pid]
        var root = process.pid
        while let next = NativeProcess.bsdInfo(of: root)?.parent, next > 1,
              let arguments = NativeProcess.arguments(of: next), launchers.contains(programName(arguments)) {
            chain.append(next)
            root = next
        }

        guard let arguments = NativeProcess.arguments(of: root), let command = shellCommand(arguments),
              let cwd = NativeProcess.workingDirectory(of: root) else {
            return .unsupported(reason: "Couldn't find the command the process was started with")
        }
        return .terminal(command: command, cwd: cwd, pids: Array(Set(chain + descendants(of: root))), title: process.title)
    }

    /// Runs the plan. Blocking, call off the main thread. Returns what went wrong, if anything.
    static func restart(_ plan: RestartPlan, listeningPid: Int32) -> String? {
        switch plan {
        case let .brew(formula):
            return PortScanner.perform(brewPath, ["services", "restart", formula])

        case let .docker(container):
            return Docker.run("restart", container: container)

        case let .terminal(command, cwd, pids, title):
            // Get the new start ready first: a restart that can't start again shouldn't stop the server.
            let start: () throws -> Void
            do {
                start = try prepareLaunch(command: command, cwd: cwd, title: title)
            } catch {
                return "Didn't restart \(title): \(error.localizedDescription)"
            }
            pids.forEach { PortScanner.kill($0) }
            // Wait for the port to be released before starting again.
            for _ in 0..<50 where isAlive(listeningPid) { usleep(100_000) }
            pids.filter(isAlive).forEach { PortScanner.kill($0, force: true) }
            usleep(300_000)
            do {
                try start()
                return nil
            } catch {
                return "Stopped \(title), but couldn't start it again: \(error.localizedDescription)"
            }

        case let .unsupported(reason):
            return reason
        }
    }

    /// Set in settings: start commands without opening a terminal window.
    /// The key has the `servers.` prefix like the rest of the Servers tab's settings (see `PortModel`).
    static var runsInBackground: Bool { UserDefaults.standard.bool(forKey: "servers.runInBackground") }

    /// Blocking. Returns what went wrong, if anything.
    static func launch(command: String, cwd: String, title: String) -> String? {
        do {
            try prepareLaunch(command: command, cwd: cwd, title: title)()
            return nil
        } catch {
            return "Couldn't start \(title): \(error.localizedDescription)"
        }
    }

    /// Does everything that can fail before the command runs (folder check, log file or script),
    /// and returns what starts it.
    static func prepareLaunch(command: String, cwd: String, title: String) throws -> () throws -> Void {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
            throw LaunchError(message: "the folder \(cwd) no longer exists")
        }
        return runsInBackground
            ? try prepareBackground(command: command, cwd: cwd, title: title)
            : try prepareTerminal(command: command, cwd: cwd, title: title)
    }

    /// Output from servers started in the background, one file per project.
    static func logFile(title: String) -> URL {
        let name = title.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Bridge/Servers/\(name).log")
    }

    /// Runs the command in a login shell (so nvm, pyenv, ... still work) with its output in `logFile`.
    /// The shell execs the command, so it isn't a child of the terminal and keeps running if we quit.
    ///
    /// The log is appended to, not emptied: this runs before a restart stops the old server, and the
    /// old run's last lines are what explains a crash. Both runs write with O_APPEND, so lines from the
    /// old server's last moments land after each other instead of on top of the new ones. A log past
    /// 10 MB is moved aside to `.old` first so it can't grow forever.
    private static func prepareBackground(command: String, cwd: String, title: String) throws -> () throws -> Void {
        let log = logFile(title: title)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 10_000_000 {
            let old = log.appendingPathExtension("old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: log, to: old)
        }
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw LaunchError(message: "couldn't open the log \(log.path): \(String(cString: strerror(errno)))")
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-il", "-c", "cd \(shellQuote(cwd)) || exit 1; exec \(command)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        return {
            defer { try? output.close() }
            let time = Date().formatted(date: .numeric, time: .standard)
            try? output.write(contentsOf: Data("\n──── \(time): \(command) (in \(cwd))\n".utf8))
            try process.run()
        }
    }

    /// A self-deleting .command file opens in the user's default terminal and loads their
    /// shell config (nvm, pyenv, ...), without needing Apple Events permissions.
    private static func prepareTerminal(command: String, cwd: String, title: String) throws -> () throws -> Void {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        #!\(shell) -il
        rm -f "$0"
        printf '\\e]0;%s\\a' \(shellQuote("\(title) (Bridge)"))
        cd \(shellQuote(cwd)) || exit 1
        printf '▶ %s\\n' \(shellQuote(command))
        \(command)
        """
        // Named after the server rather than unique: Warp keeps a Tab Config per script name, so unique
        // names would leave one behind in its + menu for every restart.
        let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-restart-\(slug).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return {
            // Terminals that don't run .command files when opened (Rex) run the script their own way.
            if let terminal = Terminals.current, !(terminal is AppleTerminal) {
                terminal.run(scriptAt: file, in: cwd, session: nil)
                return
            }
            let opened = DispatchQueue.main.sync { NSWorkspace.shared.open(file) }
            if !opened {
                try? FileManager.default.removeItem(at: file)
                throw LaunchError(message: "no app opened the .command file (is a terminal app installed?)")
            }
        }
    }

    static var brewPath: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
    }

    /// /opt/homebrew/opt/postgresql@15/bin/postgres → postgresql@15
    private static func brewFormula(for executable: String) -> String? {
        for prefix in ["/opt/homebrew/opt/", "/usr/local/opt/"] where executable.hasPrefix(prefix) {
            return executable.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }
        return nil
    }

    private static func descendants(of root: Int32) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for line in PortScanner.run("/bin/ps", ["-A", "-o", "pid=", "-o", "ppid="]).split(separator: "\n") {
            let parts = line.split(separator: " ").compactMap { Int32($0) }
            if parts.count == 2 { children[parts[1], default: []].append(parts[0]) }
        }
        var result: [Int32] = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            result.append(pid)
            queue += children[pid] ?? []
        }
        return result
    }

    /// argv as a line for the shell to run again. Each argument is quoted, so a path with spaces or
    /// quotes in it stays one argument (`ps` joins them with spaces, and splitting that again broke
    /// such paths, after the old server had already been stopped).
    ///
    /// Node tools retitle themselves (npm sets `process.title`), which overwrites argv in place:
    /// argv[0] becomes the whole title, "npm run dev", and the other arguments are left empty. That
    /// title is already a command line, so it's used as is; quoting it would ask for a program
    /// named "npm run dev".
    static func shellCommand(_ arguments: [String]) -> String? {
        guard let first = arguments.first, !first.isEmpty else { return nil }
        if arguments.dropFirst().allSatisfy(\.isEmpty), first.contains(" "), !FileManager.default.fileExists(atPath: first) {
            return first
        }
        let rest = arguments.dropFirst().allSatisfy(\.isEmpty) ? [] : Array(arguments.dropFirst())
        return ([first] + rest).map(shellQuote).joined(separator: " ")
    }

    /// ["/usr/bin/python3.12", "-m", ...] → "python3", a retitled ["npm run dev", ""] → "npm"
    private static func programName(_ arguments: [String]) -> String {
        let argv0 = arguments.first ?? ""
        let first = FileManager.default.fileExists(atPath: argv0) ? argv0 : argv0.split(separator: " ").first.map(String.init) ?? ""
        let name = URL(fileURLWithPath: first).lastPathComponent
        if name.hasPrefix("python") { return name.hasPrefix("python3") ? "python3" : "python" }
        return name
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
