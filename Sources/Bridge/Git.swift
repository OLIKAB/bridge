import Foundation
import Shared

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { status == 0 }
}

/// Runs the `git` command line, so the user's SSH keys, credential helpers, hooks and config all apply.
enum Git {
    static let executable: String = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }()

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH, but hooks (husky, lint-staged) and helpers (gpg, git-lfs) need the user's.
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = loginShellPath().map { "\($0):\(fallback)" } ?? fallback
        // Never wait for a password on a terminal that doesn't exist.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Background status checks shouldn't take index.lock and get in the way of the user's own git commands.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }()

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__BRIDGE_PATH__"
        let output = runSync(shell, ["-ilc", "printf '\(marker)%s' \"$PATH\""], in: NSHomeDirectory(), environment: nil, timeout: 5).stdout
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Local git commands (status, branches, diffs), a few at a time. With nearly a hundred repositories,
    /// opening the panel started some 350 at once, which held up the machine and everything Bridge was
    /// waiting on; queued, they finish about as fast and the rest of the app keeps moving.
    static let localQueue = limitedQueue("Bridge.git", 8)

    /// The git hosts' command lines (`gh pr view` for each repository at launch), a few at a time.
    static let hostQueue = limitedQueue("Bridge.host", 4)

    private static func limitedQueue(_ name: String, _ limit: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = limit
        queue.qualityOfService = .userInitiated
        return queue
    }

    /// Commands that talk to a remote, which can take minutes and would hold the local queue's places.
    private static let networkCommands: Set<String> = ["fetch", "pull", "push", "clone", "ls-remote", "submodule"]

    /// Runs git in `directory`. Network commands get a longer timeout.
    static func run(_ args: [String], in directory: String, timeout: TimeInterval = 30) async -> GitResult {
        let fullArgs = ["-c", "core.quotepath=false", "-c", "color.ui=false"] + args
        let isNetwork = args.contains { networkCommands.contains($0) }
        return await runOffThread(executable, fullArgs, in: directory, environment: environment, timeout: timeout,
                                  queue: isNetwork ? nil : localQueue)
    }

    /// Blocking work that goes with reading a repository (walking its folders), in the local queue.
    static func offThread<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            localQueue.addOperation { continuation.resume(returning: work()) }
        }
    }

    /// Runs a command on a thread of its own, never on Swift's shared pool of threads: a blocking
    /// process there (`gh pr view` for each of many repositories) leaves no threads for anything else
    /// the app is waiting on. In `queue` when given, to run only a few at a time.
    static func runOffThread(_ path: String, _ args: [String], in directory: String, environment: [String: String]?,
                             timeout: TimeInterval, queue: OperationQueue?) async -> GitResult {
        await withCheckedContinuation { continuation in
            let work: @Sendable () -> Void = { continuation.resume(returning: runSync(path, args, in: directory, environment: environment, timeout: timeout)) }
            if let queue {
                queue.addOperation(work)
            } else {
                DispatchQueue.global(qos: .userInitiated).async(execute: work)
            }
        }
    }

    /// Like `run`, but throws git's own error message on failure.
    @discardableResult
    static func output(_ args: [String], in directory: String, timeout: TimeInterval = 30) async throws -> String {
        let result = await run(args, in: directory, timeout: timeout)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty ? "git \(args.first ?? "") failed (exit code \(result.status))" : message)
        }
        return result.stdout
    }

    static func runSync(_ path: String, _ args: [String], in directory: String, environment: [String: String]?, timeout: TimeInterval) -> GitResult {
        let result = Subprocess.run(path, args, in: directory, environment: environment, timeout: timeout)
        var stderr = result.stderr
        if result.timedOut && stderr.isEmpty {
            stderr = "git timed out after \(Int(timeout)) seconds"
        }
        return GitResult(status: result.timedOut ? -1 : result.status, stdout: result.stdout, stderr: stderr)
    }
}
