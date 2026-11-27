import CoreServices
import Foundation

/// Calls `onChange` (on the main queue, coalesced) when anything under `path` changes,
/// ignoring build output and dependency folders that dev servers rewrite constantly.
///
/// Every watcher shares one FSEvents stream (`FileWatchHub`). A stream each, with WatchRoot to notice
/// the folder itself being renamed, kept every folder above each repository open as well: with nearly
/// a hundred repositories that was some 800 open files, past the 256 an app started from Finder may
/// have, and the app crashed. A renamed or moved repository is now found when it's next read
/// (`Repository.load` notices the folder is gone), which happens each time the panel opens.
final class FileWatcher {
    fileprivate static let ignoredComponents: Set<String> = [
        "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".cache", ".parcel-cache",
        "__pycache__", ".venv", ".pytest_cache", ".mypy_cache", ".build", "DerivedData",
        // Build output and tool caches. Not `build`, which is source in some repositories.
        "dist", ".output", "coverage", "target", ".gradle", ".angular", ".expo", ".vercel", ".netlify",
    ]

    private let id = UUID()

    /// `matching`, when given, narrows which changed paths count.
    init(path: String, matching: ((String) -> Bool)? = nil, onChange: @escaping () -> Void) {
        FileWatchHub.shared.add(id, path: path, matching: matching, onChange: onChange)
    }

    deinit {
        FileWatchHub.shared.remove(id)
    }

    fileprivate static func isRelevant(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains(where: { ignoredComponents.contains(String($0)) }) { return false }
        // Inside .git only refs, HEAD, the index and merge/rebase state matter; objects are written on every fetch and commit anyway.
        if let git = components.firstIndex(of: ".git"), git + 1 < components.count {
            let inner = components[git + 1]
            return !["objects", "logs", "hooks", "lfs"].contains(String(inner)) && !path.hasSuffix(".lock")
        }
        return true
    }
}

/// The one FSEvents stream over every watched folder, made again (shortly after, so adding dozens of
/// repositories makes it once) whenever a folder is added or removed. Everything here runs on `queue`;
/// the callbacks go to the main queue.
private final class FileWatchHub: @unchecked Sendable {
    static let shared = FileWatchHub()

    private struct Registration {
        /// As given, and with links resolved, which is what the stream watches and FSEvents reports.
        let path: String
        let resolved: String
        let matching: ((String) -> Bool)?
        let onChange: () -> Void

        func covers(_ changed: String) -> Bool {
            [path, resolved].contains { changed == $0 || changed.hasPrefix($0 + "/") }
        }
    }

    private let queue = DispatchQueue(label: "Bridge.FileWatcher")
    private var registrations: [UUID: Registration] = [:]
    private var stream: FSEventStreamRef?
    private var rebuildScheduled = false

    func add(_ id: UUID, path: String, matching: ((String) -> Bool)?, onChange: @escaping () -> Void) {
        // Resolving the path opens the folder, which can wait on macOS's privacy prompt (e.g. for
        // ~/Documents); that must not block the main thread.
        queue.async { [self] in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            registrations[id] = Registration(path: path, resolved: resolved, matching: matching, onChange: onChange)
            scheduleRebuild()
        }
    }

    func remove(_ id: UUID) {
        queue.async { [self] in
            guard registrations.removeValue(forKey: id) != nil else { return }
            scheduleRebuild()
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        queue.asyncAfter(deadline: .now() + 0.3) { [self] in
            rebuildScheduled = false
            rebuild()
        }
    }

    private func rebuild() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let paths = Array(Set(registrations.values.map(\.resolved)))
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let hub = Unmanaged<FileWatchHub>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            hub.deliver(Array(paths.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// On `queue`: tells each watcher whose folder one of `paths` is in, once per batch.
    private func deliver(_ paths: [String]) {
        let changed = paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter(FileWatcher.isRelevant)
        guard !changed.isEmpty else { return }
        let hits = registrations.values.filter { registration in
            changed.contains { registration.covers($0) && registration.matching?($0) != false }
        }.map(\.onChange)
        guard !hits.isEmpty else { return }
        DispatchQueue.main.async { hits.forEach { $0() } }
    }
}
