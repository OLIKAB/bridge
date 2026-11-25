import AppKit
import Shared
import UserNotifications

/// A Claude Code session running in the background (`claude --bg`), as `claude agents` lists it.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable {
        case working, blocked, done, failed, stopped
    }

    /// The short id that `claude attach`, `stop` and `rm` take.
    let id: String
    let sessionId: String
    let cwd: String
    let name: String?
    let state: State
    /// Whether its process is alive. A finished session stays alive (idle) until it's stopped.
    let isRunning: Bool
    let startedAt: Date
    /// When it last changed state (finished, got stuck, failed), from its state file; else when it started.
    var changedAt: Date
    /// From the session's own state file: the prompt it started with, what it's doing or did,
    /// what it needs from the user when blocked, and its summary of the result.
    var intent: String?
    var detail: String?
    var needs: String?
    var result: String?

    var title: String { name ?? intent.map(Self.firstLine) ?? "Claude" }

    /// The most useful line to show under the title.
    var summary: String? { state == .blocked ? needs ?? detail : result ?? detail }

    var stateName: String {
        switch state {
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
    }
}

/// Starts Claude Code sessions in the background with `claude --bg`, so no Terminal window opens,
/// and follows them so the panel can say which are working, which are done and which need an answer.
///
/// Claude Code keeps these sessions itself (a daemon runs them), so they carry on when Bridge quits and
/// `claude agents` and `claude attach` in a terminal see the same ones. Bridge only shells out to the CLI:
/// `claude agents --json` for the list, and each session's `state.json` for the line about what it needs,
/// which the list leaves out. That file is Claude Code's own, so everything read from it is optional.
@MainActor
final class BackgroundClaude: ObservableObject {
    static let shared = BackgroundClaude()

    @Published private(set) var sessions: [ClaudeSession] = []
    /// Sessions being answered, stopped or removed, so their buttons can show it and not be pressed twice.
    @Published private(set) var busy: Set<String> = []
    /// The last action on a session that failed, by session id. Kept here rather than in the view
    /// that started it, so it's still shown after a popover closes or for a context menu action.
    @Published var errors: [String: String] = [:]
    /// Starts under way, as "path\0prompt", so a second click while `claude --bg` is still
    /// starting (the first can take a while to start Claude Code's service) doesn't start the same thing twice.
    @Published private(set) var starting: Set<String> = []

    func isStarting(in path: String) -> Bool {
        starting.contains { $0.hasPrefix(path + "\0") }
    }

    /// Repository folders; only sessions in these show up and send notifications.
    var repoPaths: [String] = [] {
        didSet { if repoPaths != oldValue { reload() } }
    }

    private nonisolated static let jobsFolder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/jobs")
    private var watcher: FileWatcher?
    private var timer: Timer?
    private var isLoading = false
    private var needsReload = false
    /// Each session's state at the last load, to notice when one finishes or gets stuck.
    /// Nil until the first load, so sessions that were already done don't all notify at launch.
    /// Holds every session, not only those in the repositories: one added later would otherwise
    /// notify about all its sessions that were waiting or had failed long ago.
    private var lastStates: [String: ClaudeSession.State]?
    private var askedForNotifications = false
    private let notifications = NotificationHandler()

    private init() {
        UNUserNotificationCenter.current().delegate = notifications
        // Sessions write their state files under ~/.claude/jobs as they go, so a change there is the
        // signal to look again. The timer catches what the watcher can't, like the folder appearing.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        timer?.tolerance = 10
        reload()
    }

    func sessions(in path: String) -> [ClaudeSession] {
        sessions.filter { Self.isInside($0.cwd, path) }
    }

    private static func isInside(_ cwd: String, _ path: String) -> Bool {
        cwd == path || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    // MARK: Loading

    /// Loads the list again, at most every couple of seconds however often it's asked:
    /// a working session touches its files many times a second.
    func reload() {
        if isLoading {
            needsReload = true
            return
        }
        isLoading = true
        watchJobsFolder()
        Task {
            repeat {
                needsReload = false
                if let loaded = await Task.detached(operation: { Self.load() }).value {
                    apply(loaded)
                }
                try? await Task.sleep(for: .seconds(2))
            } while needsReload
            isLoading = false
        }
    }

    /// The folder only exists once Claude Code has run a background session, so this is tried on every load.
    private func watchJobsFolder() {
        guard watcher == nil, FileManager.default.fileExists(atPath: Self.jobsFolder) else { return }
        // Only the state files: a working session writes its timeline and temporary files many times
        // a second, and each load runs `claude agents`, which costs real CPU time.
        watcher = FileWatcher(path: Self.jobsFolder, matching: { $0.hasSuffix("/state.json") }) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    private func apply(_ loaded: [ClaudeSession]) {
        let mine = loaded
            .filter { session in repoPaths.contains { Self.isInside(session.cwd, $0) } }
            .sorted { $0.startedAt > $1.startedAt }
        // Sessions started from Terminal never go through `start`, which is where permission was asked for.
        if !mine.isEmpty, !askedForNotifications {
            askedForNotifications = true
            Notifier.requestPermission()
        }
        if let lastStates {
            for session in mine where lastStates[session.id] != session.state {
                notify(session, was: lastStates[session.id])
            }
        }
        lastStates = Dictionary(loaded.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        if mine != sessions { sessions = mine }
        let ids = Set(loaded.map(\.id))
        if errors.keys.contains(where: { !ids.contains($0) }) { errors = errors.filter { ids.contains($0.key) } }
        tidyUp(mine)
    }

    // MARK: Tidying up

    /// A finished session keeps an idle Claude process alive, which holds memory and keeps Claude Code's
    /// background service running. After this long it's stopped; answering it wakes it again.
    private static let stopIdleAfter: TimeInterval = 30 * 60
    /// Finished and failed sessions are removed (`claude rm`) after this long. Their conversations stay,
    /// so `claude --resume` still finds them. Blocked ones are left alone: they're waiting for an answer.
    private static let removeFinishedAfter: TimeInterval = 24 * 60 * 60
    /// Sessions already being tidied, so a slow `claude stop` isn't started again on the next load.
    private var tidying: Set<String> = []

    private func tidyUp(_ sessions: [ClaudeSession]) {
        let now = Date()
        for session in sessions where !busy.contains(session.id) && !tidying.contains(session.id) {
            let age = now.timeIntervalSince(session.changedAt)
            let finished = [.done, .failed, .stopped].contains(session.state)
            if finished, age > Self.removeFinishedAfter {
                tidying.insert(session.id)
                // One that fails stays in `tidying`, so it isn't tried again on every load until Bridge restarts.
                Task {
                    if await remove(session) == nil { tidying.remove(session.id) }
                }
            } else if session.state == .done, session.isRunning, age > Self.stopIdleAfter {
                tidying.insert(session.id)
                Task {
                    if await stop(session) == nil { tidying.remove(session.id) }
                }
            }
        }
    }

    private func notify(_ session: ClaudeSession, was old: ClaudeSession.State?) {
        let repo = repoPaths.filter { Self.isInside(session.cwd, $0) }.max { $0.count < $1.count }
        let folder = ((repo ?? session.cwd) as NSString).lastPathComponent
        let body = session.summary.map { "\(folder): \($0)" } ?? folder
        switch session.state {
        case .blocked:
            Notifier.send(title: "Claude needs you: \(session.title)", body: body, userInfo: ["claudeSession": session.id])
        case .done where old != nil:
            Notifier.send(title: "Claude is done: \(session.title)", body: body, userInfo: ["claudeSession": session.id])
        case .failed:
            Notifier.send(title: "Claude stopped with an error: \(session.title)", body: body, userInfo: ["claudeSession": session.id])
        default:
            break
        }
    }

    /// Blocking. Nil when the list couldn't be read, so a hiccup doesn't empty the panel.
    private nonisolated static func load() -> [ClaudeSession]? {
        guard let result = run(["agents", "--json", "--all"], in: NSHomeDirectory(), timeout: 15), result.succeeded,
              let list = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard entry["kind"] as? String == "background",
                  let id = entry["id"] as? String, let sessionId = entry["sessionId"] as? String,
                  let cwd = entry["cwd"] as? String else { return nil }
            let isRunning = entry["pid"] != nil
            let file = (jobsFolder as NSString).appendingPathComponent("\(id)/state.json")
            let details = (try? Data(contentsOf: URL(fileURLWithPath: file)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            func text(_ value: Any?) -> String? {
                (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let started = (entry["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // The latest of the two: a later touch only postpones tidying up, never brings it forward.
            let changed = [details["lastTerminalAt"], details["updatedAt"]].compactMap { ($0 as? String).flatMap(iso.date) }.max()
            return ClaudeSession(
                id: id, sessionId: sessionId, cwd: cwd, name: text(entry["name"]),
                state: state(entry["state"] as? String ?? details["state"] as? String, isRunning: isRunning),
                isRunning: isRunning, startedAt: started, changedAt: max(changed ?? started, started),
                intent: text(details["intent"]), detail: text(details["detail"]), needs: text(details["needs"]),
                result: text((details["output"] as? [String: Any])?["result"])
            )
        }
    }

    private nonisolated static func state(_ raw: String?, isRunning: Bool) -> ClaudeSession.State {
        switch raw {
        case "working", "queued": .working
        case "blocked", "needs_input", "waiting": .blocked
        case "done", "idle": .done
        case "failed", "errored", "crashed": .failed
        case "stopped", "exited": .stopped
        default: isRunning ? .working : .stopped
        }
    }

    // MARK: Actions

    /// Starts a session in `path`. Auto mode, so it gets on with the work and only stops for what's risky;
    /// Claude Code saves the flags with the session, so they apply again when it's resumed with an answer.
    /// Returns an error message.
    func start(_ prompt: String, in path: String) async -> String? {
        let key = path + "\0" + prompt
        guard !starting.contains(key) else { return nil }
        starting.insert(key)
        defer { starting.remove(key) }
        Notifier.requestPermission()
        var args = ["--bg", "--permission-mode", "auto"]
        if UserDefaults.standard.bool(forKey: DevWorkspace.agentBrowserKey) { args.append("--chrome") }
        // After `--`, so a prompt that starts with a dash isn't read as an option.
        let error = await runReportingError(args + ["--", prompt], in: path)
        reload()
        return error
    }

    /// Sends an answer as the session's next message. Claude Code has no way to type into a session
    /// that's running in the background, so it's stopped and then resumed in the background with the
    /// answer; it keeps its id and conversation. Resuming one that's still running would start a copy
    /// instead, and stopping takes a moment, so this waits until it's gone. Returns an error message.
    func reply(_ text: String, to session: ClaudeSession) async -> String? {
        await perform(on: session) {
            Notifier.requestPermission()
            if session.isRunning {
                if let error = await runReportingError(["stop", session.id], in: session.cwd) { return error }
                // Only a list that was actually read and shows the session stopped will do: a failed
                // read, or giving up after the wait, would resume it while it runs and start a copy.
                var stopped = false
                for _ in 0..<20 {
                    if let list = await Task.detached(operation: { Self.load() }).value,
                       list.first(where: { $0.id == session.id })?.isRunning != true {
                        stopped = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard stopped else { return "The session didn't stop, so the answer wasn't sent. Try again in a moment." }
            }
            return await runReportingError(["--bg", "--resume", session.sessionId, "--", text], in: session.cwd)
        }
    }

    /// Starts a fresh session with a failed one's prompt, and takes the failed one off the list once that worked.
    func retry(_ session: ClaudeSession, prompt: String) async -> String? {
        await perform(on: session) {
            if let error = await start(prompt, in: session.cwd) { return error }
            if let error = await runReportingError(["rm", session.id], in: session.cwd) {
                return "Started again, but couldn't remove the failed session: \(error)"
            }
            sessions.removeAll { $0.id == session.id }
            return nil
        }
    }

    func stop(_ session: ClaudeSession) async -> String? {
        await perform(on: session) {
            await runReportingError(["stop", session.id], in: session.cwd)
        }
    }

    /// Takes the session off the list (`claude rm`). Its conversation is kept, so `claude --resume` still finds it.
    func remove(_ session: ClaudeSession) async -> String? {
        await perform(on: session) {
            if session.isRunning, let error = await runReportingError(["stop", session.id], in: session.cwd) { return error }
            if let error = await runReportingError(["rm", session.id], in: session.cwd) { return error }
            sessions.removeAll { $0.id == session.id }
            return nil
        }
    }

    /// One action at a time per session: removing one while an answer to it is under way would have the
    /// answer bring it back. The outcome goes to `errors`, where the row and the popover show it.
    private func perform(on session: ClaudeSession, _ action: () async -> String?) async -> String? {
        guard !busy.contains(session.id) else { return nil }
        busy.insert(session.id)
        errors[session.id] = nil
        let error = await action()
        busy.remove(session.id)
        errors[session.id] = error
        reload()
        return error
    }

    /// Opens the session in Terminal, where it can be followed and answered like any Claude session,
    /// permission prompts included.
    func openInTerminal(_ session: ClaudeSession) {
        DevWorkspace.runInTerminal("claude attach \(session.id)", in: session.cwd, kind: "claude-\(session.id)")
    }

    // MARK: Running the CLI

    private func runReportingError(_ args: [String], in directory: String) async -> String? {
        let result = await Task.detached { Self.run(args, in: directory, timeout: 60) }.value
        guard let result else { return "Couldn't find the claude command. Install Claude Code and run `claude` once to log in." }
        guard !result.succeeded else { return nil }
        let message = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return message ?? (result.timedOut ? "claude timed out" : "claude failed (exit code \(result.status))")
    }

    /// Blocking. Nil when the claude command isn't installed.
    private nonisolated static func run(_ args: [String], in directory: String, timeout: TimeInterval) -> Subprocess.Result? {
        guard let executable = Claude.executable else { return nil }
        return Subprocess.run(executable, args, in: directory, environment: environment, timeout: timeout)
    }

    /// The user's PATH like git gets, without git's settings for Bridge's own status checks: the first
    /// `claude --bg` starts Claude Code's daemon, and the sessions it runs may inherit this environment.
    private nonisolated static let environment: [String: String] = {
        var env = Git.environment
        env["GIT_TERMINAL_PROMPT"] = nil
        env["GIT_OPTIONAL_LOCKS"] = nil
        return env
    }()
}

/// Clicking a notification about a session opens the panel on the Repos tab, where the session is.
/// Only opens it: toggling would close a panel that's already open.
private final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["claudeSession"] != nil else { return }
        await MainActor.run {
            PanelState.shared.tab = .repos
            if PanelState.shared.window?.isVisible != true { MenuBarPanel.toggle() }
        }
    }

    /// Shown also while Bridge's window is in front, which otherwise swallows them.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
