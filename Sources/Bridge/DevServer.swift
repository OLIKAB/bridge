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

    func start(_ command: String) {
        guard !isRunning else { return }
        url = nil
        do {
            let files = FileManager.default
            try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The last run's output is kept next to it: starting again after a crash would otherwise wipe out why it crashed.
            let previous = logURL.deletingPathExtension().appendingPathExtension("previous.log")
            try? files.removeItem(at: previous)
            try? files.moveItem(at: logURL, to: previous)
            files.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            pid = try spawn(command, log: log)
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
        state = wasStopped ? .stopped : .exited(code)
        pid = 0
        url = nil
    }

    // MARK: Process

    private func spawn(_ command: String, log: FileHandle) throws -> pid_t {
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
        environment.removeValue(forKey: "GIT_OPTIONAL_LOCKS")
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
            if let url = lines.dropLast().lazy.compactMap(Self.localURL).first {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self?.isRunning == true, self?.url == nil { self?.url = url }
                    }
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

/// Output that hasn't ended its line yet. Only the pipe's reading handler touches it, one call at a time.
private final class PartialLine: @unchecked Sendable {
    var text = ""
}
