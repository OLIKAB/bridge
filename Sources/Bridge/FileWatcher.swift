import CoreServices
import Foundation

/// Calls `onChange` (on the main queue, coalesced) when anything under `path` changes,
/// ignoring build output and dependency folders that dev servers rewrite constantly.
final class FileWatcher {
    private static let ignoredComponents: Set<String> = [
        "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".cache", ".parcel-cache",
        "__pycache__", ".venv", ".pytest_cache", ".mypy_cache", ".build", "DerivedData",
        // Build output and tool caches. Not `build`, which is source in some repositories.
        "dist", ".output", "coverage", "target", ".gradle", ".angular", ".expo", ".vercel", ".netlify",
    ]

    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let matching: ((String) -> Bool)?

    private let queue = DispatchQueue(label: "Bridge.FileWatcher")

    /// `matching`, when given, narrows which changed paths count.
    init(path: String, matching: ((String) -> Bool)? = nil, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.matching = matching
        // Creating the stream opens the folder, which can wait on macOS's privacy prompt
        // (e.g. for ~/Documents); that must not block the main thread.
        queue.async { [self] in start(path) }
    }

    private func start(_ path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if paths.prefix(count).contains(where: { FileWatcher.isRelevant($0) && watcher.matching?($0) != false }) { watcher.onChange() }
        }
        // WatchRoot reports the folder itself being renamed or moved, so the repository can follow it.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    // The pending start() holds a strong reference, so deinit always runs after it.
    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static func isRelevant(_ path: String) -> Bool {
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
