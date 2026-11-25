import Foundation
import Shared

struct ListeningProcess: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let ports: [Int]
    let command: String
    let executable: String
    let cwd: String?
    /// Nearest folder (from cwd and up) that has a package.json, otherwise cwd.
    let projectRoot: String?
    let packageName: String?
    let framework: Framework?
    let uptime: TimeInterval?
    let cpu: Double?
    /// Resident memory in MB.
    let memory: Double?
    /// Set when this row is a Docker container (pid is then Docker's backend).
    var container: String? = nil
    /// When the process started. With the pid it tells this process apart from a later one the pid is reused for.
    var started: Date? = nil

    var id: String { container.map { "docker:\($0)" } ?? "\(pid)" }

    /// Stable across restarts, used to match favorites.
    var favoriteKey: String {
        if let container { return "docker:\(container)" }
        if let projectRoot, projectRoot != "/" { return projectRoot }
        return "cmd:\(command)"
    }

    var title: String {
        if let container { return container }
        if framework?.category == .database { return framework!.title }
        if let packageName { return packageName }
        if let projectRoot, projectRoot != "/" { return URL(fileURLWithPath: projectRoot).lastPathComponent }
        return name
    }

    var isDatabase: Bool { framework?.category == .database }

    var isSystem: Bool {
        if framework != nil { return false }
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]
        if systemPrefixes.contains(where: executable.hasPrefix) { return true }
        // Regular GUI apps (Spotify, VS Code helpers, etc.)
        return executable.contains(".app/Contents")
    }

    var uptimeText: String? {
        guard let uptime else { return nil }
        let minutes = Int(uptime) / 60
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min"
        case ..<(60 * 24): return "\(minutes / 60) h \(minutes % 60) min"
        default: return "\(minutes / (60 * 24)) d"
        }
    }

    var memoryText: String? {
        guard let memory else { return nil }
        return memory >= 1024 ? String(format: "%.1f GB", memory / 1024) : "\(Int(memory)) MB"
    }
}

enum PortScanner {
    private static let cpuSampler = CPUSampler()

    static func scan() -> [ListeningProcess] {
        var portsByPid: [Int32: Set<Int>] = [:]
        for pid in NativeProcess.allPids() {
            let ports = NativeProcess.listeningPorts(of: pid)
            if !ports.isEmpty { portsByPid[pid] = ports }
        }
        cpuSampler.forget(except: Set(portsByPid.keys))

        let now = Date()
        let processes = portsByPid.map { pid, ports in
            let name = NativeProcess.name(of: pid) ?? "?"
            let command = NativeProcess.commandLine(of: pid) ?? name
            let cwd = NativeProcess.workingDirectory(of: pid)
            let package = cwd.flatMap(PackageCache.lookup)
            let started = NativeProcess.bsdInfo(of: pid)?.started
            return ListeningProcess(
                pid: pid,
                name: name,
                ports: ports.sorted(),
                command: command,
                executable: NativeProcess.executablePath(of: pid) ?? "",
                cwd: cwd,
                projectRoot: package?.root ?? cwd,
                packageName: package?.name,
                framework: Framework.detect(command: command, processName: name, dependencies: package?.dependencies ?? []),
                uptime: started.map { now.timeIntervalSince($0) },
                cpu: cpuSampler.percent(pid: pid, cpuTime: NativeProcess.cpuTime(of: pid)),
                memory: NativeProcess.footprint(of: pid),
                started: started
            )
        }

        return splitDockerContainers(processes)
            .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    /// Docker publishes every container port from one backend process; show one row per container.
    private static func splitDockerContainers(_ processes: [ListeningProcess]) -> [ListeningProcess] {
        guard processes.contains(where: { $0.framework == .docker }) else { return processes }
        let containers = Docker.runningContainers()
        guard !containers.isEmpty else { return processes }

        return processes.flatMap { process -> [ListeningProcess] in
            guard process.framework == .docker else { return [process] }
            var rows: [ListeningProcess] = []
            var remaining = Set(process.ports)
            for container in containers where !container.hostPorts.isDisjoint(with: remaining) {
                let ports = container.hostPorts.intersection(remaining)
                remaining.subtract(ports)
                rows.append(ListeningProcess(
                    pid: process.pid, name: container.image, ports: ports.sorted(),
                    command: "docker: \(container.image)", executable: process.executable,
                    cwd: nil, projectRoot: nil, packageName: nil, framework: container.framework,
                    uptime: nil, cpu: nil, memory: nil, container: container.name, started: process.started
                ))
            }
            if !remaining.isEmpty {
                rows.append(ListeningProcess(
                    pid: process.pid, name: process.name, ports: remaining.sorted(), command: process.command,
                    executable: process.executable, cwd: process.cwd, projectRoot: process.projectRoot,
                    packageName: process.packageName, framework: process.framework, uptime: process.uptime,
                    cpu: process.cpu, memory: process.memory, started: process.started
                ))
            }
            return rows
        }
    }

    /// Whether the row's pid still belongs to the process the scan saw. The row can be minutes old
    /// when a button is pressed, and by then the server may have exited and its pid gone to another process.
    static func isStillRunning(_ process: ListeningProcess) -> Bool {
        guard let now = NativeProcess.bsdInfo(of: process.pid) else { return false }
        guard let started = process.started else { return true }
        return abs(now.started.timeIntervalSince(started)) < 0.001
    }

    static func kill(_ pid: Int32, force: Bool = false) {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM)
    }

    /// Blocking. The time limit keeps a hung tool (`docker ps` while Docker Desktop is starting or
    /// stuck) from stalling scans for good, as a new scan only starts once the last one is done.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        Subprocess.run(path, args, timeout: timeout).stdout
    }

    /// Like `run`, for commands that change something: nil if it worked, otherwise what went wrong.
    static func perform(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String? {
        let result = Subprocess.run(path, args, timeout: timeout)
        if result.timedOut { return "\(URL(fileURLWithPath: path).lastPathComponent) \(args.first ?? "") didn't finish within \(Int(timeout)) seconds" }
        guard !result.succeeded else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "\(URL(fileURLWithPath: path).lastPathComponent) \(args.first ?? "") failed (exit code \(result.status))" : message
    }
}

/// package.json lookups, cached for a minute so each scan doesn't re-read every project's file.
enum PackageCache {
    struct Package {
        let root: String
        let name: String?
        let dependencies: Set<String>
    }

    private static var cache: [String: (package: Package?, at: Date)] = [:]
    private static let lock = NSLock()

    static func lookup(_ directory: String) -> Package? {
        lock.lock()
        if let hit = cache[directory], Date().timeIntervalSince(hit.at) < 60 {
            lock.unlock()
            return hit.package
        }
        lock.unlock()
        let package = find(from: directory)
        lock.lock()
        cache[directory] = (package, Date())
        lock.unlock()
        return package
    }

    /// Walks up from `directory` (max a few levels, never above home) looking for package.json.
    private static func find(from directory: String) -> Package? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var url = URL(fileURLWithPath: directory)
        for _ in 0..<5 {
            guard url.path.hasPrefix(home), url.path != home else { return nil }
            let file = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var deps = Set<String>()
                for key in ["dependencies", "devDependencies"] {
                    if let dict = json[key] as? [String: Any] { deps.formUnion(dict.keys) }
                }
                return Package(root: url.path, name: json["name"] as? String, dependencies: deps)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
