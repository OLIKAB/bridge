import AppKit
import Combine
import Shared
import SwiftUI

/// Processes listening on local ports (the Servers tab). Settings are prefixed with `servers.`, since they
/// were once a separate app's and some names (`notifications`) would mean something else next to the repositories'.
@MainActor
final class PortModel: ObservableObject {
    /// The app's one model, for the Settings page in the Repos tab, which holds the servers' settings too.
    private(set) static weak var shared: PortModel?

    @Published var processes: [ListeningProcess] = []
    @Published var showAll = UserDefaults.standard.bool(forKey: "servers.showAll") {
        didSet { UserDefaults.standard.set(showAll, forKey: "servers.showAll") }
    }
    @Published var notificationsOn = UserDefaults.standard.object(forKey: "servers.notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsOn, forKey: "servers.notifications")
            if notificationsOn { Notifier.requestPermission() }
        }
    }
    @Published var showUsageGraphs = UserDefaults.standard.object(forKey: "servers.showUsageGraphs") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showUsageGraphs, forKey: "servers.showUsageGraphs") }
    }
    @Published var showTopConsumers = UserDefaults.standard.object(forKey: "servers.showTopConsumers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTopConsumers, forKey: "servers.showTopConsumers") }
    }
    @Published var runInBackground = UserDefaults.standard.bool(forKey: "servers.runInBackground") {
        didSet { UserDefaults.standard.set(runInBackground, forKey: "servers.runInBackground") }
    }
    @Published var favorites = FavoriteStore.load() {
        didSet { FavoriteStore.save(favorites) }
    }
    /// Not published: the scan every five seconds would otherwise redraw the whole tab twice more each
    /// time and blink the refresh button into a spinner. Only a refresh asked for by hand shows one.
    private var isScanning = false
    @Published private(set) var isRefreshingByHand = false
    /// Last 5 minutes of total dev-server usage, one sample per scan.
    @Published var usageHistory: [UsageSample] = []
    let colorSlots = ColorSlots()
    /// Row ids being restarted, and favorite keys being started.
    @Published var busy: Set<String> = []
    /// Why the last restart, start or stop didn't work.
    @Published var lastError: String?

    /// The newest scan and usage, published to the tab (`processes`, `usageHistory`) only while it shows
    /// in an open panel, and the moment it comes into view. Published every five seconds with new CPU
    /// figures, they had the Servers tab redraw every row, 45–90 ms on the main thread each time, while
    /// the panel was closed or showing Repos, and clicks waiting behind that felt slow.
    private var latest: [ListeningProcess] = []
    private var usage: [UsageSample] = []
    private var visibility: [NSObjectProtocol] = []
    private var tabChange: AnyCancellable?

    private var isShown: Bool {
        PanelState.shared.tab == .servers && PanelState.shared.window?.isVisible == true
    }

    private func publishIfShown() {
        guard isShown else { return }
        if processes != latest { processes = latest }
        if usageHistory.count != usage.count || usageHistory.last?.date != usage.last?.date { usageHistory = usage }
    }

    /// Ids we stopped ourselves, so their disappearance isn't reported as a crash.
    private var expectedGone: Set<String> = []
    private var hasScanned = false
    private var timer: Timer?
    /// A refresh asked for while a scan was running (after a stop, restart or start), done once it's finished
    /// instead of being dropped.
    private var pendingRefresh = false
    /// When the running scan started, so one that hangs can be given up on.
    private var scanStarted: Date?
    /// Counts scans, so a scan given up on that finishes late can't overwrite a newer one's result.
    private var scanCount = 0
    /// Counts stops. A scan that started before one may still list the stopped process.
    private var stopCount = 0

    var visibleProcesses: [ListeningProcess] {
        let visible = showAll ? processes : processes.filter { !$0.isSystem }
        let favoriteKeys = Set(favorites.map(\.key))
        // Stable partition: favorites first, otherwise sorted by port.
        return visible.filter { favoriteKeys.contains($0.favoriteKey) } + visible.filter { !favoriteKeys.contains($0.favoriteKey) }
    }

    var stoppedFavorites: [Favorite] {
        let running = Set(processes.map(\.favoriteKey))
        return favorites.filter { !running.contains($0.key) }
    }

    /// Servers stopped from Bridge in this session that aren't favorites, so the next thing a user tries
    /// after stopping one, starting it again, has somewhere to happen: before, the row was simply gone.
    /// Kept until it runs again, is starred, or is dismissed; not saved, a few at most.
    @Published private(set) var recentlyStopped: [Favorite] = []

    /// Stopped favorites, then servers just stopped, as rows with a start button.
    var stoppedServers: [Favorite] {
        let running = Set(processes.map(\.favoriteKey))
        let favoriteKeys = Set(favorites.map(\.key))
        return stoppedFavorites + recentlyStopped.filter { !running.contains($0.key) && !favoriteKeys.contains($0.key) }
    }

    func isFavorite(_ favorite: Favorite) -> Bool {
        favorites.contains { $0.key == favorite.key }
    }

    /// Stars a server that was just stopped, so it stays in the list for good.
    func keep(_ favorite: Favorite) {
        recentlyStopped.removeAll { $0.key == favorite.key }
        if !isFavorite(favorite) { favorites.append(favorite) }
    }

    func dismiss(_ favorite: Favorite) {
        recentlyStopped.removeAll { $0.key == favorite.key }
    }

    /// When processes started listening, for the ones found since the previous scan. Not published:
    /// read by a row as it appears, which happens on the same change.
    private var startedListening: [String: Date] = [:]

    /// Whether the process began answering a moment ago, so its row should mark it. Only within the
    /// first couple of seconds, so opening the panel later doesn't replay it.
    func justStartedListening(_ process: ListeningProcess) -> Bool {
        startedListening[process.id].map { Date().timeIntervalSince($0) < 2.5 } ?? false
    }

    /// When a server was stopped from Bridge, for its "Stopped just now" row to fade into its dimmed
    /// look rather than appear in it.
    private(set) var stoppedAt: [String: Date] = [:]

    func justStopped(_ favorite: Favorite) -> Bool {
        stoppedAt[favorite.key].map { Date().timeIntervalSince($0) < 2.5 } ?? false
    }

    private func rememberStopped(_ favorite: Favorite) {
        stoppedAt[favorite.key] = Date()
        guard favorite.launch != nil, !isFavorite(favorite) else { return }
        recentlyStopped.removeAll { $0.key == favorite.key }
        recentlyStopped.insert(favorite, at: 0)
        if recentlyStopped.count > 5 { recentlyStopped.removeLast() }
    }

    init() {
        Self.shared = self
        if notificationsOn { Notifier.requestPermission() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Lets macOS coalesce wake-ups with other timers to save energy.
        timer?.tolerance = 1
        // The panel opening takes the keyboard; switching to the tab is the other way it comes into view.
        visibility.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishIfShown() }
        })
        tabChange = PanelState.shared.$tab.sink { [weak self] _ in
            // `tab` is set after its publisher fires.
            DispatchQueue.main.async { self?.publishIfShown() }
        }
    }

    func refreshByHand() {
        isRefreshingByHand = true
        refresh()
    }

    func refresh() {
        // A scan only shells out to `docker ps`, which has a time limit, so it shouldn't take more than
        // seconds. Should one hang anyway, it's left behind after 30 seconds so the tab doesn't freeze.
        if isScanning, let scanStarted, Date().timeIntervalSince(scanStarted) < 30 {
            pendingRefresh = true
            return
        }
        isScanning = true
        scanStarted = Date()
        scanCount += 1
        let scan = scanCount, stops = stopCount
        Task.detached {
            let result = PortScanner.scan()
            await MainActor.run { self.finishScan(scan, stops: stops, result: result) }
        }
    }

    private func finishScan(_ scan: Int, stops: Int, result: [ListeningProcess]) {
        guard scan == scanCount else { return }
        isScanning = false
        if isRefreshingByHand { isRefreshingByHand = false }
        scanStarted = nil
        var result = result
        if stops == stopCount {
            // Stopped ids that a scan started after the stop no longer finds are gone for good; forget
            // them, so a later process with the same id (a container started again) is reported if it crashes.
            expectedGone.formIntersection(result.map(\.id))
        } else {
            // Read before a stop, so it can still have the stopped process in it. Leave that out
            // rather than show the row again, and look again.
            result.removeAll { expectedGone.contains($0.id) }
            pendingRefresh = true
        }
        notifyChanges(from: latest, to: result)
        if hasScanned {
            // Listening since the last scan: the moment a server becomes reachable, which its row marks
            // once. Not on the first scan, where everything is "new".
            let before = Set(latest.map(\.id))
            let now = Date()
            for process in result where !before.contains(process.id) { startedListening[process.id] = now }
        }
        startedListening = startedListening.filter { Date().timeIntervalSince($0.value) < 10 }
        latest = result
        recordUsage(result)
        // The first scan always, so the tab has something the first time it's built.
        if !hasScanned { processes = latest }
        publishIfShown()
        hasScanned = true
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        }
    }

    private func recordUsage(_ processes: [ListeningProcess]) {
        let dev = processes.filter { !$0.isSystem }
        // Docker container rows share the backend's pid, so count each pid once.
        var seen = Set<Int32>()
        let unique = dev.filter { seen.insert($0.pid).inserted }
        usage.append(UsageSample(
            date: Date(),
            cpu: unique.compactMap(\.cpu).reduce(0, +),
            memory: unique.compactMap(\.memory).reduce(0, +)
        ))
        let cutoff = Date().addingTimeInterval(-5 * 60)
        usage.removeAll { $0.date < cutoff }
    }

    private func notifyChanges(from old: [ListeningProcess], to new: [ListeningProcess]) {
        let oldById = Dictionary(old.filter { !$0.isSystem }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newById = Dictionary(new.filter { !$0.isSystem }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gone = Set(oldById.keys).subtracting(newById.keys)
        defer { expectedGone.subtract(gone) }

        guard hasScanned, notificationsOn else { return }
        // A stopped process that takes a moment to exit can show up again in between; it isn't new.
        for (id, process) in newById where oldById[id] == nil && !expectedGone.contains(id) {
            Notifier.send(title: "New server: \(process.title)", body: portList(process.ports))
        }
        for id in gone where !expectedGone.contains(id) {
            let process = oldById[id]!
            Notifier.send(title: "\(process.title) stopped", body: "\(portList(process.ports)) is no longer running")
        }
    }

    private func portList(_ ports: [Int]) -> String {
        ports.map { "localhost:\($0)" }.joined(separator: ", ")
    }

    func stop(_ process: ListeningProcess, force: Bool = false) {
        // Without a container, a Docker row's pid is Docker Desktop's backend, which runs every container.
        if process.framework == .docker && process.container == nil {
            lastError = "Stop Docker containers one by one, or quit Docker Desktop"
            return
        }
        // A dev server that isn't a favorite is remembered with how to start it, read before it's stopped
        // (the plan walks its live process tree), so it can be started again from its row.
        let remember = !process.isSystem && !isFavorite(process)
        if let container = process.container {
            if remember { rememberStopped(Favorite(process: process, plan: .docker(container: container))) }
            Task.detached {
                if let error = Docker.run("stop", container: container) {
                    await MainActor.run {
                        self.lastError = error
                        // Still running, so a crash later on should be reported after all.
                        self.expectedGone.remove(process.id)
                        self.refresh()
                    }
                }
            }
        } else if PortScanner.isStillRunning(process) {
            if remember {
                Task.detached {
                    let favorite = Favorite(process: process, plan: Restarter.plan(for: process))
                    PortScanner.kill(process.pid, force: force)
                    await MainActor.run { self.rememberStopped(favorite) }
                }
            } else {
                PortScanner.kill(process.pid, force: force)
            }
        } else {
            // The row was out of date and the pid may belong to another process by now: leave it alone.
            refresh()
            return
        }
        expectedGone.insert(process.id)
        stopCount += 1
        processes.removeAll { $0.id == process.id }
        latest.removeAll { $0.id == process.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func restart(_ process: ListeningProcess) {
        busy.insert(process.id)
        expectedGone.insert(process.id)
        Task.detached {
            // The row was out of date if its pid now belongs to another process: don't signal that one.
            let current = process.container != nil || PortScanner.isStillRunning(process)
            let error = current ? Restarter.restart(Restarter.plan(for: process), listeningPid: process.pid) : nil
            // Give the server a moment to start listening again.
            if current && error == nil { try? await Task.sleep(for: .seconds(3)) }
            // A container keeps its id across a restart, and a restart that failed before stopping
            // anything leaves the process running: either way a crash from here on should be reported.
            let stillHere = process.container != nil || PortScanner.isStillRunning(process)
            await MainActor.run {
                self.busy.remove(process.id)
                self.lastError = error
                if stillHere { self.expectedGone.remove(process.id) }
                self.refresh()
            }
        }
    }

    func isFavorite(_ process: ListeningProcess) -> Bool {
        favorites.contains { $0.key == process.favoriteKey }
    }

    func toggleFavorite(_ process: ListeningProcess) {
        if isFavorite(process) {
            favorites.removeAll { $0.key == process.favoriteKey }
            return
        }
        Task.detached {
            let favorite = Favorite(process: process, plan: Restarter.plan(for: process))
            await MainActor.run { self.favorites.append(favorite) }
        }
    }

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.key == favorite.key }
    }

    /// Opens the server's first port in the browser, what a double-click on its row is expected to do.
    func open(_ process: ListeningProcess) {
        guard let port = process.ports.first, let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(_ favorite: Favorite) {
        busy.insert(favorite.key)
        Task.detached {
            let error = favorite.start()
            if error == nil { try? await Task.sleep(for: .seconds(4)) }
            await MainActor.run {
                self.busy.remove(favorite.key)
                self.lastError = error
                self.refresh()
            }
        }
    }
}
