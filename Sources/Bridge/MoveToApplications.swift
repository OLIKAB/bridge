import AppKit
import Shared

/// Offers to move Bridge into Applications when it's started from the disk image or Downloads.
/// Left there, it runs from a read-only, randomised copy (App Translocation) or a disk image that gets ejected,
/// and the login item points at a path that's gone after the next restart.
@MainActor
enum MoveToApplications {
    private static let suppressKey = "moveToApplicationsSuppressed"

    /// True when Bridge is about to quit and start again from Applications.
    static func offerIfNeeded() -> Bool {
        let running = Bundle.main.bundlePath
        // `swift run` has no bundle, and a copy in an Applications folder is already where it belongs.
        guard running.hasSuffix(".app"), !isInApplications(running),
              !UserDefaults.standard.bool(forKey: suppressKey) else { return false }
        let original = originalPath(of: running) ?? running
        let fromDiskImage = original.hasPrefix("/Volumes/")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Bridge to Applications?"
        alert.informativeText = fromDiskImage
            ? "Bridge is running from the disk image. In Applications it keeps working after the disk image is ejected, and can start when you log in."
            : "Bridge is running from \((original as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")). In Applications it's found by Spotlight and Launchpad, and starts reliably when you log in."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        guard answer == .alertFirstButtonReturn else { return false }

        do {
            try move(from: running, original: original, fromDiskImage: fromDiskImage)
            return true
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move Bridge"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag Bridge into the Applications folder in Finder instead."
            failed.runModal()
            return false
        }
    }

    private static func isInApplications(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private static func move(from running: String, original: String, fromDiskImage: Bool) throws {
        let files = FileManager.default
        let destination = "/Applications/" + (running as NSString).lastPathComponent

        if files.fileExists(atPath: destination) {
            // An older Bridge may still be running from there; it has to quit before it's replaced.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.bundleURL?.path == destination {
                app.terminate()
            }
            try files.trashItem(at: URL(fileURLWithPath: destination), resultingItemURL: nil)
        }
        try files.copyItem(atPath: running, toPath: destination)
        // The user has already chosen to open this copy, so Gatekeeper doesn't need to ask again from the new place.
        try Process.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", destination]).waitUntilExit()

        // The login item was registered for the copy that's running now; let the moved one register itself.
        if LoginItem.isEnabled {
            LoginItem.set(false)
            UserDefaults.standard.removeObject(forKey: "didSetUpLoginItem")
        }
        // A downloaded copy would be left behind as a second Bridge; the disk image is read-only and ejected below.
        if !fromDiskImage, !original.contains("/AppTranslocation/") {
            try? files.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: nil)
        }

        // Start the moved copy once this one has quit, and eject the disk image it came from.
        let volume = fromDiskImage ? "/Volumes/" + (original.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "") : nil
        let detach = volume.map { "hdiutil detach -quiet \(quoted($0)) || true;" } ?? ""
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; \(detach) open \(quoted(destination))"
        try Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        NSApp.terminate(nil)
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where a translocated app really is (Downloads, the disk image), or nil when it isn't translocated.
    /// `SecTranslocateCreateOriginalPathForURL` is in Security but not in its public headers, so it's looked up at runtime.
    private static func originalPath(of path: String) -> String? {
        guard path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Function.self)
        guard let url = function(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (url as URL).path
    }
}
