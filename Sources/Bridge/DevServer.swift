import AppKit
import CryptoKit
import Darwin
import Shared

/// A repository's start command running in the background, without a terminal.
/// It gets its own process group, so stopping it also stops what it started (npm → vite, concurrently → both servers).
@MainActor
final class DevServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case running
        case stopping
        case exited(Int32)
    }

    @Published private(set) var state = State.stopped
    /// The first local address the server printed, like http://localhost:5173/.
    @Published private(set) var url: URL?
    /// What the server is doing while it hasn't printed an address yet ("Installing…", "Building 42%"), read from
    /// its output. A first start can spend minutes installing and compiling, and a bare "Starting…" looked stuck.
    @Published private(set) var phase: String?
    /// When the last start began, for the time shown beside the phase.
    private(set) var startedAt = Date()
    /// Why the last start ended with an error, when its output says (`StartFailure`).
    @Published private(set) var failure: StartFailure?
    /// The last start's command and whether it was told to reinstall, to try again with.
    private(set) var command: String?
    private var reinstalled = false
    /// The current run is the build step (`DevWorkspace.StartPlan.build`), not the server: it ends by itself,
    /// and ending well means the app can start.
    @Published private(set) var isBuilding = false
    /// Whether the build step's output is there, from the repository's detection and from a build that just
    /// succeeded. True for apps without a build step.
    @Published private(set) var isBuilt = true
    private var builtAt = Date.distantPast

    /// From the repository's detection. Not while building, and not just after a build: a detection that read
    /// the folder before the build finished would take back the play button the build just brought.
    func setBuilt(_ built: Bool) {
        guard !(isBuilding && isRunning), built || Date().timeIntervalSince(builtAt) > 10, built != isBuilt else { return }
        isBuilt = built
    }

    /// Runs the build step in the background, the way `start` runs the server.
    func build(_ command: String) {
        start(command, building: true)
    }
    /// A server for this repository started elsewhere, like `npm run dev` in a terminal.
    @Published private(set) var external: ExternalServer?

    let logURL: URL
    private let path: String
    private var pid: pid_t = 0
    /// The process group of the last start. Kept after the leader exits, since children (node, vite) can outlive it
    /// and still hold the port; that's what the forced stop goes after.
    private var group: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var output: FileHandle?

    init(path: String) {
        self.path = path
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bridge", isDirectory: true)
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        logURL = folder.appendingPathComponent("\((path as NSString).lastPathComponent)-\(hash).log")
    }

    var isRunning: Bool { state == .running || state == .stopping }
    /// Running here or elsewhere, for the indicator in the sidebar.
    var isActive: Bool { isRunning || external != nil }

    /// Set by `ExternalServers.scan`. Ignored while Bridge runs its own, which listens from the same folder.
    func setExternal(_ server: ExternalServer?) {
        let server = isRunning ? nil : server
        if server != external { external = server }
    }

    /// Stops a server started elsewhere. The terminal's job is its process group, so npm and what it started stop together;
    /// a process that isn't in a job of its own (its group is the whole session) is stopped alone, so its shell survives.
    func stopExternal() {
        guard let external else { return }
        if external.group > 1, external.group != getpgrp(), external.group != getsid(external.pid) {
            kill(-external.group, SIGTERM)
            Self.forceAfterGrace(-external.group)
        } else {
            kill(external.pid, SIGTERM)
            Self.forceAfterGrace(external.pid)
        }
    }

    /// How long a server gets to stop on SIGTERM before it's killed.
    private static let grace: TimeInterval = 5

    /// Kills `target` (a pid, or a negative group id) with SIGKILL after the grace period if it still exists.
    /// A pid can't be reused while its process group lives, and five seconds is too short for it to wrap otherwise.
    private static func forceAfterGrace(_ target: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
            if kill(target, 0) == 0 { kill(target, SIGKILL) }
        }
    }

    /// Whether a start that failed on something missing can be tried again with a reinstall: only Bridge's own
    /// commands know how to install (a user's own command is left as it is).
    var canReinstall: Bool { command?.contains(DevWorkspace.reinstallVariable) == true }

    /// `reinstall` installs the dependencies even when they look current, for a start that failed on a missing module.
    func start(_ command: String, reinstall: Bool = false, building: Bool = false) {
        guard !isRunning else { return }
        url = nil
        phase = reinstall ? "Installing…" : building ? "Building…" : nil
        failure = nil
        self.command = command
        reinstalled = reinstall
        isBuilding = building
        startedAt = Date()
        do {
            let files = FileManager.default
            try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The last run's output is kept next to it: starting again after a crash would otherwise wipe out why it crashed.
            let previous = logURL.deletingPathExtension().appendingPathExtension("previous.log")
            try? files.removeItem(at: previous)
            try? files.moveItem(at: logURL, to: previous)
            files.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            pid = try spawn(command, log: log, reinstall: reinstall, building: building)
            group = pid
        } catch {
            state = .exited(-1)
            try? "Couldn't start \(command): \(error.localizedDescription)\n".write(to: logURL, atomically: true, encoding: .utf8)
            return
        }
        state = .running

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.didExit() }
        }
        source.resume()
        exitSource = source
    }

    func stop() {
        guard state == .running else { return }
        state = .stopping
        kill(-group, SIGTERM)
        // Dev servers usually stop at once; force the ones that don't. The leader (zsh) is often gone by then
        // while its children ignore SIGTERM, so this goes by the group and not by state. A new start has a group
        // of its own, which this id never matches.
        Self.forceAfterGrace(-group)
    }

    /// When a repository is removed: stop its server, and kill it if it ignores that.
    func terminate() {
        guard isRunning else { return }
        kill(-group, SIGTERM)
        Self.forceAfterGrace(-group)
    }

    /// When Bridge quits: SIGTERM to every server, then a short wait (at most `limit` seconds in all, not per server)
    /// and SIGKILL for the groups that are still there, since nothing runs after the app is gone.
    static func terminateAll(_ servers: [DevServer], limit: TimeInterval = 1.5) {
        let groups = servers.filter(\.isRunning).map(\.group)
        groups.forEach { kill(-$0, SIGTERM) }
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline, groups.contains(where: { kill(-$0, 0) == 0 }) {
            usleep(50_000)
        }
        for group in groups where kill(-group, 0) == 0 { kill(-group, SIGKILL) }
    }

    func showOutput() {
        NSWorkspace.shared.open(logURL)
    }

    private func didExit() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        exitSource?.cancel()
        exitSource = nil
        // The pipe's handler stays: it reads what the dying shell and its children wrote last (the error that
        // explains the exit) up to EOF, when every writer is gone. Dropping the pipe here would lose that
        // and give children that live on a broken pipe.
        output = nil
        let wasStopped = state == .stopping
        // Exit code, or the negative signal number when it was killed.
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        pid = 0
        guard !wasStopped, code != 0 else {
            if isBuilding, !wasStopped {
                isBuilt = true
                builtAt = Date()
            }
            // A build that went through ends as stopped: nothing is wrong, and the play button is what comes next.
            finish(wasStopped || isBuilding ? .stopped : .exited(code))
            return
        }
        // The error that explains the exit may still be on its way through the pipe into the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.pid == 0 else { return }
            // Stopped by hand in the meantime: that's the end of it.
            guard self.state == .running else {
                if self.state == .stopping { self.finish(.stopped) }
                return
            }
            let failure = StartFailure(log: Self.tail(of: self.logURL))
            // A fresh clone or a stale install that the checks missed: install and go again, once, so play just works.
            if failure?.kind == .missingDependencies, !self.reinstalled, self.canReinstall, let command = self.command {
                self.state = .stopped
                self.start(command, reinstall: true, building: self.isBuilding)
                return
            }
            // The build it serves is gone (deleted, or never made): the build button comes back.
            if failure?.kind == .needsBuild {
                self.isBuilt = false
                self.builtAt = .distantPast
            }
            self.finish(.exited(code))
            self.failure = failure
        }
    }

    private func finish(_ state: State) {
        self.state = state
        isBuilding = false
        url = nil
        phase = nil
    }

    /// The end of the last run's output, where the error is.
    var lastOutput: String { Self.tail(of: logURL) }

    /// The end of a log, where the error is.
    private static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: Process

    private func spawn(_ command: String, log: FileHandle, reinstall: Bool, building: Bool) throws -> pid_t {
        let pipe = Pipe()
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group to stop the whole tree; close every other descriptor Bridge has open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addchdir_np(&actions, path)

        var environment = Git.environment
        // The output goes to a log file, not a terminal.
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        // Python holds back what it prints to a pipe until a few kilobytes gather, so Django's address never came.
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "GIT_OPTIONAL_LOCKS")
        if reinstall { environment[DevWorkspace.reinstallVariable] = "1" }
        // A login shell, so version managers (nvm, pyenv …) set up the same tools as in Terminal.
        let argv = ["/bin/zsh", "-l", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
        try? pipe.fileHandleForWriting.close()
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }

        let pending = PartialLine()
        // A build has no address to find, and an address it mentions ("deploy to http://localhost…") isn't a server.
        pending.isBuild = building
        // Held by its own handler until EOF, so letting go of `output` doesn't close the pipe early.
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { [weak self] _ in
            let data = reading.availableData
            guard !data.isEmpty else {
                reading.readabilityHandler = nil
                try? log.close()
                return
            }
            // Strip what color codes slip through, so the log reads well and addresses can be found.
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            // The throwing write: the old one raises an Objective-C exception on a full disk, which crashes Bridge.
            try? log.write(contentsOf: Data(text.utf8))
            pending.text += text
            // Progress bars (npm install, webpack) redraw a line with \r and never send \n.
            let lines = pending.text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            // An unfinished rest that keeps growing is cut to its end, where the next part of the line will join it.
            pending.text = String((lines.last ?? "").suffix(4096))
            guard !pending.isReady else { return }
            let finished = lines.dropLast()
            if !pending.isBuild, let url = finished.lazy.compactMap(Self.localURL).first ?? finished.lazy.compactMap(Self.listeningURL).first {
                pending.isReady = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning, self.url == nil else { return }
                        self.url = url
                        self.phase = nil
                    }
                }
                return
            }
            // The newest phase in this chunk, with the unfinished rest counted too: a progress bar's line never ends.
            guard let phase = lines.reversed().lazy.compactMap(StartPhase.init(line:)).first?.label,
                  phase != pending.phase else { return }
            // Webpack's percentage and pnpm's counts change many times a second; a few updates a second read as progress.
            let now = Date()
            guard pending.phase?.prefix(4) != phase.prefix(4) || now.timeIntervalSince(pending.sentAt) > 0.3 else { return }
            pending.phase = phase
            pending.sentAt = now
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state == .running, self.url == nil else { return }
                    self.phase = phase
                }
            }
        }
        output = pipe.fileHandleForReading
        return pid
    }

    /// "  ➜  Local:   http://localhost:5173/" → http://localhost:5173/
    nonisolated private static func localURL(in line: String) -> URL? {
        guard let range = line.range(of: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s,)'"]*"#, options: .regularExpression) else {
            return nil
        }
        // 0.0.0.0 means every interface; the browser needs a real one.
        let address = line[range].replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(of: "[::]", with: "localhost")
        return URL(string: address)
    }

    /// "Listening on port 3000", "Listening and serving HTTP on :8080" (Gin), "Tomcat started on port 8080" (Spring),
    /// "Running MyAppWeb.Endpoint … at 127.0.0.1:4000 (http)" (Phoenix) → http://localhost:3000/. Servers often say
    /// where they listen without a URL, and stayed at "Starting…" for good.
    nonisolated private static func listeningURL(in line: String) -> URL? {
        for regex in listeningPatterns {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), let port = Int(line[range]), port < 65536 else { continue }
            return URL(string: "http://localhost:\(port)/")
        }
        return nil
    }

    nonisolated private static let listeningPatterns = [
        #"(?i)\blisten\w*\b.*?(?:port\s+|:)(\d{2,5})\b"#,
        #"(?i)\bstarted on port\(?s?\)?:?\s*(\d{2,5})\b"#,
        #"(?i)\b(?:running|serving|available)\b.*\bat\s+(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

/// What a starting dev server is busy with, recognized from a line of its output. Only common phrasings of the
/// tools Bridge starts (npm, pnpm, yarn, bun, uv, pip, bundler, Vite, webpack, Next, Nuxt, Cargo, Go, SwiftPM,
/// Docker Compose, Django, Rails); a line that says nothing recognizable leaves the last phase standing.
/// Labels are a word or two, as they sit in a row beside the repository's name.
struct StartPhase {
    let label: String

    init?(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        let lower = line.lowercased()
        // Bridge's own status lines (`DevWorkspace.say`): the install step, then the command that starts the app.
        if line.hasPrefix("▸ ") {
            label = lower.contains(" install") ? "Installing…" : lower.contains("waiting") ? "Waiting…" : "Starting…"
            return
        }
        // webpack's "42% building 120/300 modules", Nuxt's and others' bars ending in a percentage.
        if let percent = Self.percent(in: lower), lower.contains("build") || lower.contains("compil") || lower.hasPrefix("\(percent)%") {
            label = "Building \(percent)%"
            return
        }
        // An error can mention anything ("Failed to compile"); it isn't a phase, and the row shows the exit.
        if lower.contains("error") || lower.contains("failed") { return nil }
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        if has("added ", "packages: +", "progress: resolved", "resolving", "fetching packages", "linking dependencies",
               "installing", "npm warn", "resolved ", "prepared ", "bundle install", "fetching gem", "lockfile", "collecting ", "restor", "deps.get", "resolving dependencies") {
            label = "Installing…"
        } else if has("downloading", "downloaded", "pulling", "updating crates.io", "fetching ", "cloning") {
            label = "Downloading…"
        } else if has("pre-bundling", "optimiz", "new dependencies") {
            label = "Optimizing…"
        } else if has("compiling", "compiled") {
            label = "Compiling…"
        } else if has("building", "build started", "bundling", "transforming", "linking ") {
            label = "Building…"
        } else if has("migrat") {
            label = "Migrating…"
        } else if has("performing system checks", "checking") {
            label = "Checking…"
        } else if has("waiting for") {
            label = "Waiting…"
        } else if has("container", "creating", "starting", "booting") {
            label = "Starting…"
        } else {
            return nil
        }
    }

    private static func percent(in line: String) -> Int? {
        guard let range = line.range(of: #"\b\d{1,3}%"#, options: .regularExpression),
              let value = Int(line[range].dropLast()), value <= 100 else { return nil }
        return value
    }
}

/// A process listening on a port whose working directory is inside a repository.
struct ExternalServer: Equatable {
    let pid: pid_t
    let group: pid_t
    let ports: [Int]

    var url: URL? { ports.first.flatMap { URL(string: "http://localhost:\($0)/") } }
}

enum ExternalServers {
    /// Finds servers listening from inside one of `paths`, keyed by the innermost path (repos can be nested).
    /// Ephemeral ports are left out: those are rarely dev servers, more often debuggers or a CLI's sign-in callback.
    /// Blocking, call off the main thread.
    static func scan(_ paths: [String]) -> [String: ExternalServer] {
        let own = getpid()
        var found: [String: ExternalServer] = [:]
        for pid in NativeProcess.allPids() where pid != own {
            guard let cwd = NativeProcess.workingDirectory(of: pid),
                  let path = paths.filter({ cwd == $0 || cwd.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { continue }
            let ports = NativeProcess.listeningPorts(of: pid).filter { $0 < 49152 }.sorted()
            guard !ports.isEmpty, let info = NativeProcess.bsdInfo(of: pid) else { continue }
            // Several processes (concurrently → web and api): keep the one with the lowest port.
            if let existing = found[path], existing.ports[0] < ports[0] { continue }
            found[path] = ExternalServer(pid: pid, group: info.group, ports: ports)
        }
        return found
    }
}

/// Why a dev server stopped with an error, read from the end of its output, in a few words for its row.
/// Only causes with a clear message and something to do about them; anything else leaves the row's warning
/// sign and the output to say what happened.
struct StartFailure: Equatable {
    enum Kind: Equatable {
        /// A module, package, gem or the project's own tool (vite, nuxt) isn't installed: a reinstall fixes it.
        case missingDependencies
        /// A program the command needs isn't on the machine (pnpm, python3, composer, docker).
        case missingTool
        case portInUse
        case dockerNotRunning
        case nodeVersion
        /// The code has errors the compiler stopped at. Never reinstalled for: that changes nothing.
        case compileError
        /// The server is there to serve a build that hasn't been made (`next start` with no `.next`).
        case needsBuild
        /// It wanted to ask something or draw a full-screen screen, which a log file can't do.
        case needsTerminal
    }

    let kind: Kind
    /// "Dependencies missing", "Port 3000 in use".
    let summary: String

    init?(log: String) {
        // From the end: the last error is the one that stopped it.
        let lines = log.components(separatedBy: CharacterSet(charactersIn: "\r\n")).suffix(80).reversed()
        for line in lines {
            if let found = Self.classify(line) {
                (kind, summary) = found
                return
            }
        }
        return nil
    }

    /// The tools a start command calls itself: these missing is the machine's setup, not the project's.
    private static let tools: Set<String> = ["npm", "npx", "node", "pnpm", "yarn", "bun", "python", "python3", "pip", "uv", "poetry",
                                             "ruby", "bundle", "php", "composer", "docker", "cargo", "go", "swift", "corepack",
                                             "java", "mvn", "gradle", "dotnet", "mix", "elixir"]

    private static func classify(_ line: String) -> (Kind, String)? {
        let lower = line.lowercased()
        // Before the missing modules: "Cannot find module '/app/dist/server.js'" is a build not made, not an install.
        if lower.contains("could not find a production build") || lower.contains("run `next build`")
            || lower.range(of: #"cannot find module '[^']*/(dist|build|\.output|out|lib)/"#, options: .regularExpression) != nil {
            return (.needsBuild, "Needs a build")
        }
        // Its input is /dev/null: Python's input() hits EOF, curses and docker -it find no terminal.
        if lower.contains("not a tty") || lower.contains("inappropriate ioctl for device") || lower.contains("eoferror: eof when reading a line")
            || lower.contains("_curses.error") || lower.contains("raw mode is not supported") {
            return (.needsTerminal, "Needs a terminal")
        }
        if lower.contains("unable to locate a java runtime") || lower.contains("java_home is not set") {
            return (.missingTool, "Java isn't installed")
        }
        // rustc, Go, swiftc, javac, Maven, Gradle, dotnet, mix and tsc each end a failed compile their own way.
        let compile = ["error: could not compile", "compilation failed", "compilation error", "build failed", "error: emit-module",
                       "failed to compile", "compilation_error", "execution failed for task ':compile"]
        if compile.contains(where: lower.contains)
            || lower.range(of: #"\.(go|swift|java|kt|cs|ex|ts|tsx|rs):\d+:\d+:? *(error|undefined|cannot|syntax)"#, options: .regularExpression) != nil
            || lower.range(of: #"\berror (ts|cs)\d{3,5}\b"#, options: .regularExpression) != nil {
            // A compile stopped by a missing package is still an install's to fix ("error TS2307: Cannot find module 'zod'").
            if lower.contains("cannot find module") || lower.contains("could not resolve") { return (.missingDependencies, "Dependencies missing") }
            return (.compileError, "Doesn't compile")
        }
        // zsh: "command not found: vite" / sh: "vite: command not found"
        if lower.contains("command not found") {
            let name = line.range(of: #"command not found: *(\S+)"#, options: .regularExpression)
                .map { String(line[$0].split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
                ?? line.range(of: #"(\S+): command not found"#, options: .regularExpression)
                    .map { String(line[$0].split(separator: ":").dropLast().last ?? "").trimmingCharacters(in: .whitespaces) }
            if let name, tools.contains(name) { return (.missingTool, "\(name) isn't installed") }
            return (.missingDependencies, "Dependencies missing")
        }
        let missing = ["cannot find module", "err_module_not_found", "cannot find package", "modulenotfounderror", "no module named",
                       "could not find gem", "gemnotfound", "run `bundle install`", "vendor/autoload.php", "err_pnpm_recursive_exec_first_fail"]
        if missing.contains(where: lower.contains) { return (.missingDependencies, "Dependencies missing") }
        if lower.contains("eaddrinuse") || lower.contains("address already in use") || lower.range(of: #"port \d+ is (already )?in use"#, options: .regularExpression) != nil {
            let port = line.range(of: #"(?<=:|port )\d{2,5}"#, options: .regularExpression).map { String(line[$0]) }
            return (.portInUse, port.map { "Port \($0) in use" } ?? "Port in use")
        }
        if lower.contains("cannot connect to the docker daemon") || lower.contains("is the docker daemon running") {
            return (.dockerNotRunning, "Docker isn't running")
        }
        if lower.contains("unsupported engine") || lower.contains("engine \"node\" is incompatible") || lower.range(of: #"requires node(\.js)? (version )?[>=v~^]*\d"#, options: .regularExpression) != nil {
            return (.nodeVersion, "Needs another Node version")
        }
        return nil
    }
}

/// Output that hasn't ended its line yet. Only the pipe's reading handler touches it, one call at a time.
private final class PartialLine: @unchecked Sendable {
    var text = ""
    /// The last phase sent to the main thread, and when.
    var phase: String?
    var sentAt = Date.distantPast
    /// Set once an address was found: what the server prints after that isn't a start phase.
    var isReady = false
    /// The build step, which has no address to look for.
    var isBuild = false
}
