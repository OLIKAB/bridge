import Foundation

/// Runs a command line tool and collects its output, with a time limit.
public enum Subprocess {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
        public var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Blocking, call off the main thread. On timeout the process is terminated (killed if it ignores
    /// that for 2 seconds) and `timedOut` is set.
    public static func run(
        _ path: String, _ args: [String], in directory: String? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let stdout = PipeReader(out), stderr = PipeReader(err)
        do {
            try process.run()
        } catch {
            stdout.stop()
            stderr.stop()
            return Result(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let timedOut = Flag()
        let pid = process.processIdentifier
        let exited = DispatchSemaphore(value: 0)
        // A tool can ignore SIGTERM (`docker ps` while Docker Desktop is starting does), and then
        // waiting for it would hang the caller for good. So it gets a short grace period, then SIGKILL,
        // which can't be ignored. The pid is only signalled while it's still running, so it's still ours.
        // Output keeps being read by the PipeReaders meanwhile, so a full pipe can't block the exit.
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        exited.signal()
        killer.cancel()

        let deadline = DispatchTime.now() + 1
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.collected(by: deadline), as: UTF8.self),
            stderr: String(decoding: stderr.collected(by: deadline), as: UTF8.self),
            timedOut: timedOut.isSet
        )
    }
}

/// Collects a pipe's output as it arrives, so neither pipe can fill up and block the process.
/// Reading to end of file instead would also wait for everything that inherited the pipe, like an
/// ssh ControlPersist master or a server a git hook started in the background, which can outlive
/// the process by minutes or forever.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stop()
                finished.signal()
            } else {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    /// Once the process has exited: what it wrote, waiting until `deadline` for the last of it.
    func collected(by deadline: DispatchTime) -> Data {
        if finished.wait(timeout: deadline) == .timedOut { stop() }
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
