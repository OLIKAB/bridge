import AppKit
import Shared
import SwiftUI

/// Bridge updating itself from GitHub Releases: a line at the top of the panel says a newer one is out,
/// and Update downloads it, puts it in place of this copy and starts it.
///
/// Releases are tagged `bridge-v<version>` (or `v<version>`) with the .zip from `./build.sh --dist`
/// attached (`./build.sh --release bridge` does both). Sparkle would do this too, but it's a dependency
/// with signing keys of its own; here the download is trusted only when it's signed by the same team
/// as this copy, so only a build signed with the same certificate can replace it. A check that fails
/// (no network, a private repository, GitHub's rate limit) is silent.
@MainActor
final class AppUpdate: ObservableObject {
    static let shared = AppUpdate()

    /// owner/name of the GitHub repository with the releases, from the Info.plist `build.sh` writes
    /// (`UPDATE_REPO`), so the releases can live in a public repository while the code doesn't.
    nonisolated static let repository = Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String ?? "OLIKAB/bridge"
    static let enabledKey = "checksForUpdates"

    struct Release: Equatable {
        let version: String
        let page: URL
        /// The attached Bridge-<version>.zip, or nil when there's only the page to send people to.
        let archive: URL?
    }

    enum Phase: Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase = Phase.idle
    /// Set for a few seconds after a check asked for by hand that found nothing, so it isn't silent.
    @Published private(set) var upToDate = false

    /// The release the user said no to, so it isn't offered every time the panel opens.
    @Published var skipped = UserDefaults.standard.string(forKey: "skippedUpdate") {
        didSet { UserDefaults.standard.set(skipped, forKey: "skippedUpdate") }
    }

    @Published var isEnabled = UserDefaults.standard.object(forKey: AppUpdate.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { lastCheck = nil; checkIfDue() } else { available = nil }
        }
    }

    private var lastCheck: Date?

    var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The release to offer: newer than this one and not skipped.
    var offered: Release? {
        guard let available, available.version != skipped else { return nil }
        return available
    }

    /// At most every six hours, since it runs each time the panel opens. Not when run unbundled
    /// (`swift run`), which has no version to compare with or bundle to replace.
    func checkIfDue() {
        guard isEnabled else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 60 * 60 { return }
        check(byHand: false)
    }

    /// `byHand` (Settings › Check for Bridge updates now) shows the release even if it was skipped,
    /// and says so when there's nothing newer.
    func check(byHand: Bool) {
        guard Bundle.main.bundleIdentifier != nil, phase != .downloading, phase != .installing else { return }
        lastCheck = Date()
        Task {
            let latest = await Self.latestRelease()
            available = latest.flatMap { ClaudeUpdate.isNewer($0.version, than: installed) ? $0 : nil }
            if byHand {
                if let available, available.version == skipped { skipped = nil }
                if available == nil {
                    upToDate = true
                    try? await Task.sleep(for: .seconds(4))
                    upToDate = false
                }
            }
        }
    }

    /// Downloads the release's zip, checks it, and hands over to a script that swaps it in once Bridge
    /// has quit and opens it. Bridge quits the usual way, so dev servers are stopped first.
    func install(_ release: Release) {
        guard let archive = release.archive else {
            NSWorkspace.shared.open(release.page)
            return
        }
        guard phase != .downloading, phase != .installing else { return }
        phase = .downloading
        let current = Bundle.main.bundleURL
        Task {
            do {
                let (download, response) = try await URLSession.shared.download(from: archive)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw GitError(message: "The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                }
                phase = .installing
                let staged = try await Task.detached { try Self.stage(download, version: release.version, replacing: current) }.value
                try Self.swapAfterQuit(current: current, with: staged)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Unzips the download next to nothing of the user's and makes sure it's Bridge, the promised
    /// version, signed (validly) by the same team as this copy. Blocking. Returns the new app.
    nonisolated private static func stage(_ download: URL, version: String, replacing current: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Subprocess.run("/usr/bin/ditto", ["-x", "-k", download.path, folder.path], in: folder.path, environment: nil, timeout: 120)
        guard unzip.succeeded else { throw GitError(message: "Couldn't unpack the update") }
        let new = folder.appendingPathComponent(current.lastPathComponent)
        guard let info = Bundle(url: new)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw GitError(message: "The update isn't \(current.deletingPathExtension().lastPathComponent)")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw GitError(message: "The download is a different version than \(version)")
        }
        let verify = Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path], in: folder.path, environment: nil, timeout: 60)
        guard verify.succeeded else { throw GitError(message: "The update's signature isn't valid") }
        guard let team = teamIdentifier(of: current), teamIdentifier(of: new) == team else {
            throw GitError(message: "The update isn't signed by the same developer as this copy")
        }
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw GitError(message: "Bridge can't write to \(current.deletingLastPathComponent().path)")
        }
        return new
    }

    /// The signing team, from `codesign -dv` ("TeamIdentifier=…", "not set" for ad-hoc signatures).
    nonisolated private static func teamIdentifier(of app: URL) -> String? {
        let result = Subprocess.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], in: "/", environment: nil, timeout: 30)
        let output = result.stdout + result.stderr
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        return team == "not set" ? nil : team
    }

    /// A script, started now and outliving Bridge, that waits for it to quit, moves the old copy aside,
    /// moves the new one in (putting the old one back if that fails) and opens it. The paths go in as
    /// arguments, so nothing needs quoting.
    private static func swapAfterQuit(current: URL, with new: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2.old"
            if mv "$2" "$2.old"; then
                if mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
            fi
            open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "bridge-update", String(ProcessInfo.processInfo.processIdentifier), current.path, new.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The newest published release tagged for Bridge, with its zip.
    nonisolated private static func latestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for release in releases where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true {
            guard let tag = release["tag_name"] as? String,
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:))
            else { continue }
            for prefix in ["bridge-v", "v"] where tag.hasPrefix(prefix) {
                let version = String(tag.dropFirst(prefix.count))
                guard version.first?.isNumber == true else { continue }
                let assets = release["assets"] as? [[String: Any]] ?? []
                let archive = assets.first { ($0["name"] as? String) == "Bridge-\(version).zip" }?["browser_download_url"] as? String
                return Release(version: version, page: page, archive: archive.flatMap(URL.init(string:)))
            }
        }
        return nil
    }
}

/// A line at the top of the panel while a newer Bridge is out: which one, Update, and an × to skip
/// that version; while it downloads and installs, what it's doing; and a moment of "up to date" after
/// a check asked for by hand. Nothing at all otherwise.
struct AppUpdateBar: View {
    @ObservedObject private var update = AppUpdate.shared

    var body: some View {
        if let release = update.offered {
            line {
                switch update.phase {
                case .idle:
                    Text("Bridge \(release.version) is available").foregroundStyle(.secondary)
                    Spacer()
                    Button("Release notes") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(.link)
                    Button(release.archive == nil ? "Download" : "Update") { update.install(release) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    IconButton(systemName: "xmark", help: "Skip this version") { update.skipped = release.version }
                case .downloading, .installing:
                    ProgressView().controlSize(.mini)
                    Text(update.phase == .downloading ? "Downloading Bridge \(release.version)…" : "Installing… Bridge restarts in a moment")
                        .foregroundStyle(.secondary)
                    Spacer()
                case let .failed(message):
                    Text(message).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(.link)
                    Button("Try again") { update.install(release) }
                        .controlSize(.small)
                }
            }
        } else if update.upToDate {
            line {
                Text("Bridge \(update.installed) is the newest version").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6, content: content)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            PanelDivider()
        }
    }
}
