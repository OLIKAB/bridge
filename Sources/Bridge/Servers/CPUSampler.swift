import Foundation

/// Turns cumulative CPU time into a current percentage by comparing consecutive scans.
final class CPUSampler {
    private var last: [Int32: (cpu: Double, at: Double)] = [:]
    private let lock = NSLock()

    func percent(pid: Int32, cpuTime: Double?) -> Double? {
        guard let cpuTime else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let previous = last[pid]
        last[pid] = (cpuTime, now)
        guard let previous, now > previous.at else { return nil }
        return max(0, (cpuTime - previous.cpu) / (now - previous.at) * 100)
    }

    func forget(except pids: Set<Int32>) {
        lock.lock()
        last = last.filter { pids.contains($0.key) }
        lock.unlock()
    }
}
