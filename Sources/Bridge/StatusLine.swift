import AppKit
import Shared
import SwiftUI

/// What the last thing done in the panel came to (adding, finding or cleaning up repositories), said
/// in the status line until dismissed or replaced. Shared rather than the Repos tab's own, so it shows
/// where everything else the panel has to say does.
@MainActor
final class PanelNotice: ObservableObject {
    static let shared = PanelNotice()
    @Published var message: String?
    private init() {}
}

/// The one line at the top of the panel, on both tabs. At rest, with Claude Code, it shows how much
/// usage is left, with the logo that checks for an update; otherwise the one thing most worth saying:
///
/// 1. Bridge downloading or installing an update: it quits in a moment, and nothing else matters then.
/// 2. Repositories just removed, with Undo (or why an undo couldn't put everything back): the one
///    thing that can't wait, as Undo goes after ten minutes, and it answers the user's last click.
/// 3. "Bridge is the newest version", for four seconds after a check asked for in Settings.
/// 4. An update that failed (Bridge's, then the agent's), with Try again and ×.
/// 5. What the last action came to (`PanelNotice`), with ×.
/// 6. The agent updating (`AgentUpdate`): work the user started, but it needs nothing from them and
///    runs on behind a message that arrives meanwhile; how it ended shows at 4 or not at all.
/// 7. The agent's setup would make it fail (logged out, a model the account can't use), with the fix
///    and ×: it stands until fixed, so it gives way to anything that answers a click.
/// 8. At rest: Claude's usage, and an update on offer (Bridge's before the agent's: Claude Code comes
///    out nearly every day and would otherwise keep Bridge's from ever showing). An agent that
///    doesn't report usage has nothing to say at rest, so its line shows only with an update.
///
/// The rule behind the order: what answers the user's own last click first, then work going on, then
/// what stands until it's dealt with, then offers. Everything above 8 that stays has a ×, so nothing
/// left standing can keep what's below it out of sight. A line each (Bridge's update, Claude Code's,
/// the notice, the undo, the agent's problem) stacked up to five over the list, in two places.
struct StatusLine: View {
    /// Not observed: it changes with every repository's every change. For Undo, and to leave out the
    /// agent's problem before there are repositories (the setup page deals with the agent then).
    let store: RepoStore
    @ObservedObject private var app = AppUpdate.shared
    @ObservedObject private var update = AgentUpdate.shared
    @ObservedObject private var agent = AgentStatus.shared
    @ObservedObject private var removal = RepoRemoval.shared
    @ObservedObject private var notice = PanelNotice.shared
    @State private var usage = ClaudeUsage.load()

    /// The update's figures are for the agent in use, and it's one Bridge keeps up to date.
    private var tracksAgent: Bool {
        update.installed != nil && update.name == agent.info.name && agent.info.can(.selfUpdate)
    }
    /// Claude Code, whose usage makes the line worth showing at rest.
    private var showsUsage: Bool { tracksAgent && agent.info.can(.usage) }
    private var agentName: String { update.name ?? agent.info.name }

    /// Which of the lines above shows, so a new one can come in as itself: each is its own view
    /// (`.id`), and `revealsGently` fades it in as it appears. A notice carries its text, so one notice
    /// replacing another comes in too. Only opacity and a 4 pt settle: the line's height (and with it
    /// the panel's) changes at once, as `MenuBarExtra` needs. Going away is immediate.
    private enum Kind: Hashable {
        case installing, removal, upToDate, appFailed, agentFailed, notice(String), agentUpdating, problem, atRest
    }

    private var kind: Kind? {
        if app.offered != nil, app.phase != .idle { return .installing }
        if removal.last != nil || removal.failure != nil { return .removal }
        if app.upToDate { return .upToDate }
        if app.offered != nil, case .failed = app.phase { return .appFailed }
        if update.error != nil, tracksAgent { return .agentFailed }
        if let text = notice.message { return .notice(text) }
        if update.isUpdating, tracksAgent { return .agentUpdating }
        if agent.shownProblem != nil, !store.repos.isEmpty { return .problem }
        if showsUsage || app.offered != nil || (tracksAgent && update.needsUpdate) { return .atRest }
        return nil
    }

    var body: some View {
        // Glass buttons in a line wait for the fade to end (`hiddenWhileFadingIn`), as they draw black
        // while partly transparent.
        lines
            .arrives()
            .id(kind)
            .onAppear { usage = ClaudeUsage.load() }
            // The panel stays in memory while closed, so reread when it opens again.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                usage = ClaudeUsage.load()
            }
    }

    @ViewBuilder
    private var lines: some View {
        Group {
            if let release = app.offered, app.phase != .idle {
                line {
                    ProgressView().controlSize(.mini)
                    Text(app.phase == .downloading ? "Downloading Bridge \(release.version)…"
                                                   : "Installing Bridge \(release.version)… it restarts in a moment")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else if let text = removal.last.map(removal.summary) ?? removal.failure {
                line {
                    message(text)
                    if removal.last != nil {
                        Button("Undo") { removal.undo(store) }
                            .buttonStyle(.link)
                    }
                    IconButton(systemName: "xmark", help: "Dismiss") { removal.dismiss() }
                }
            } else if app.upToDate {
                line {
                    Text("Bridge \(app.installed) is the newest version").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else if let release = app.offered, case let .failed(error) = app.phase {
                line {
                    failure(error)
                    Button("Download") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(.link)
                    Button("Try again") { app.install(release) }
                        .controlSize(.small)
                        .hiddenWhileFadingIn()
                    IconButton(systemName: "xmark", help: "Dismiss") { app.dismissFailure() }
                }
            } else if let error = update.error, tracksAgent {
                line {
                    failure("Couldn't update \(agentName): \(error)")
                    IconButton(systemName: "arrow.clockwise", help: "Retry") { update.update() }
                    IconButton(systemName: "xmark", help: "Dismiss") { update.dismissError() }
                }
            } else if let text = notice.message {
                line {
                    message(text)
                    IconButton(systemName: "xmark", help: "Dismiss") { notice.message = nil }
                }
            } else if update.isUpdating, tracksAgent {
                line {
                    ProgressView().controlSize(.mini)
                    Text("Updating \(agentName)…").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else if let problem = agent.shownProblem, !store.repos.isEmpty {
                line {
                    AgentProblemNotice(problem: problem)
                }
            } else if showsUsage || app.offered != nil || (tracksAgent && update.needsUpdate) {
                line {
                    atRest
                }
            }
        }
    }

    /// On the left Claude's usage, Bridge's update or the agent's; on the right the update on offer
    /// (Bridge's first) or a check running.
    @ViewBuilder
    private var atRest: some View {
        if showsUsage {
            agentLogo
            if let usage {
                Divider().frame(height: 10)
                UsageLeft(usage: usage)
            }
        } else if let release = app.offered {
            Text("Bridge \(release.version) is available").foregroundStyle(.secondary)
        } else if tracksAgent, update.needsUpdate {
            agentLogo
            Text("\(agentName) \(update.latest ?? "") is available").foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if let release = app.offered {
            Button("Release notes") { NSWorkspace.shared.open(release.page) }
                .buttonStyle(.link)
            Button(release.archive == nil ? "Download Bridge \(release.version)" : "Update Bridge to \(release.version)") {
                app.install(release)
            }
            .controlSize(.small)
            .prominentButton()
            IconButton(systemName: "xmark", help: "Skip this version") { app.skipped = release.version }
        } else if tracksAgent, update.needsUpdate {
            // The version is on the left when there's no usage there to say it beside.
            Button(showsUsage ? "Update \(agentName) to \(update.latest ?? "")" : "Update \(agentName)") { update.update() }
                .controlSize(.small)
                .prominentButton()
        } else if showsUsage, update.isChecking {
            ProgressView().controlSize(.mini)
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    /// The agent's logo, which checks for a newer version when clicked, since that is what people click
    /// when they want to make sure. The negative padding gives the hover fill room without making the
    /// line taller.
    private var agentLogo: some View {
        Button { Task { await update.check() } } label: {
            Image(nsImage: Agent.current.logo)
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
                .padding(3)
        }
        .buttonStyle(.panel)
        .padding(-3)
        .disabled(update.isChecking)
        .panelTooltip("\(agentName) \(update.installed ?? ""). Click to check for updates")
    }

    private func message(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func failure(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
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

/// "session 77% · week 59%" left. Turns orange under 20% and red under 5%.
private struct UsageLeft: View {
    let usage: ClaudeUsage

    var body: some View {
        HStack(spacing: 4) {
            if let session = usage.session {
                part("session", session)
            }
            if usage.session != nil, usage.week != nil {
                Text("·").foregroundStyle(.tertiary)
            }
            if let week = usage.week {
                part("week", week)
            }
        }
    }

    private func part(_ name: String, _ window: ClaudeUsage.Window) -> some View {
        let left = window.leftPercentage
        return Text("\(name) \(left)%")
            .monospacedDigit()
            .foregroundStyle(left < 5 ? AnyShapeStyle(.red) : left < 20 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }
}
