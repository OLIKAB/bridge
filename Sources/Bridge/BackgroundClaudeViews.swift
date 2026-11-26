import Shared
import SwiftUI

/// The background Claude sessions in a repository, under its row in the panel. A click opens the session:
/// what it did or needs, a field to answer it, and Terminal for the rest.
struct ClaudeSessionList: View {
    let sessions: [ClaudeSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sessions) { ClaudeSessionRow(session: $0) }
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    @ObservedObject private var claude = BackgroundClaude.shared
    @State private var hovering = false
    @State private var showDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ClaudeSessionIcon(session: session, isBusy: claude.busy.contains(session.id))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: session.title)
                        .lineLimit(1)
                    // Blocked sessions are never removed by themselves, so show how long one has waited.
                    if session.state == .blocked {
                        Text(verbatim: "· \(session.changedAt.relative)")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if let summary = session.summary {
                    Text(verbatim: summary)
                        .foregroundStyle(session.state == .blocked ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
                if let error = claude.errors[session.id] {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .panelBackground(background)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .onHover { hovering = $0 }
        .panelPopover(isPresented: $showDetail, arrowEdge: .bottom) {
            ClaudeSessionDetail(session: session) { showDetail = false }
        }
        .contextMenu {
            if session.state != .failed {
                Button("Open in Terminal") { claude.openInTerminal(session) }
            }
            // Errors show in the row, from `claude.errors`.
            if session.isRunning {
                Button("Stop") { Task { _ = await claude.stop(session) } }
                    .disabled(claude.busy.contains(session.id))
            }
            Button("Remove") { Task { _ = await claude.remove(session) } }
                .disabled(claude.busy.contains(session.id))
        }
    }

    private var background: AnyShapeStyle {
        if session.state == .blocked {
            return hovering ? AnyShapeStyle(Color.orange.tertiary) : AnyShapeStyle(Color.orange.quaternary)
        }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }
}

private struct ClaudeSessionIcon: View {
    let session: ClaudeSession
    let isBusy: Bool

    var body: some View {
        if isBusy || session.state == .working {
            ProgressView().controlSize(.mini)
        } else {
            switch session.state {
            case .blocked: Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .stopped, .working: Image(systemName: "pause.circle").foregroundStyle(.secondary)
            }
        }
    }
}

/// One session in full, with a field to send it an answer or a follow-up.
private struct ClaudeSessionDetail: View {
    let session: ClaudeSession
    let dismiss: () -> Void
    @ObservedObject private var claude = BackgroundClaude.shared
    @State private var answer = ""
    @State private var cannotReadFolder = false
    @FocusState private var answerFocused: Bool

    /// The latest copy of the session, which keeps changing while the popover is open.
    private var current: ClaudeSession { claude.sessions.first { $0.id == session.id } ?? session }
    private var isBusy: Bool { claude.busy.contains(session.id) }
    private var error: String? { claude.errors[session.id] }

    /// The prompt to start a failed session again with. Claude Code replaces a session's intent with a summary
    /// of the conversation when it compacts it, and that's no prompt to start over with.
    private var retryPrompt: String? {
        guard current.state == .failed, let intent = current.intent,
              !intent.hasPrefix("This session is being continued") else { return nil }
        return intent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ClaudeSessionIcon(session: current, isBusy: isBusy).frame(width: 14, height: 14)
                Text(verbatim: current.title).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                Text(verbatim: current.stateName).font(.caption).foregroundStyle(.secondary)
            }

            if let intent = current.intent, intent != current.title {
                Text(verbatim: intent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let needs = current.needs, current.state == .blocked {
                section("Needs you", needs, tint: .orange)
            } else if let result = current.result {
                section("Result", result, tint: .green)
            }
            if let detail = current.detail, detail != current.needs, detail != current.result {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            // A session that crashed before it started has no conversation to answer or attach to.
            if let retryPrompt {
                Button("Try again") {
                    Task {
                        if await claude.retry(current, prompt: retryPrompt) == nil { dismiss() }
                    }
                }
                .disabled(isBusy)
            } else if current.state == .failed, current.intent == nil {
                Text("It stopped before it got going. Remove it and start a new one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(current.state == .blocked ? "Answer Claude" : "Send a follow-up", text: $answer, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($answerFocused)
                    .onSubmit(send)
                    .panelField()
                Button(action: send) {
                    Image(systemName: "arrow.up").fontWeight(.semibold)
                }
                // As tall as the field's first line, beside it.
                .fieldRowButton(prominent: true)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .panelTooltip("Send (↩)")
            }
            }

            if let error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if isPermissionError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS blocked the folder: allow Bridge in Files and Folders, then stop all background sessions so they restart with access.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Files and Folders settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
            }

            HStack {
                if current.state != .failed {
                    Button("Open in Terminal") {
                        claude.openInTerminal(current)
                        dismiss()
                    }
                }
                Spacer()
                if current.isRunning {
                    Button("Stop") { Task { _ = await claude.stop(current) } }
                        .disabled(isBusy)
                }
                Button("Remove") {
                    Task {
                        if await claude.remove(current) == nil { dismiss() }
                    }
                }
                .disabled(isBusy)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
        .task {
            // A popover's window isn't key on its first frame, so focus set in onAppear is lost.
            try? await Task.sleep(for: .milliseconds(50))
            answerFocused = true
            let cwd = session.cwd
            cannotReadFolder = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: cwd)) == nil }.value
        }
    }

    private func section(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(tint)
            ScrollView {
                Text(verbatim: text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(tint.quinary, in: .rect(cornerRadius: 6))
    }

    /// A session that failed on a folder macOS's privacy settings keep it out of. A session that can't
    /// read its folder dies before it can say why ("exit 1 before init"), so Bridge also tries the folder itself.
    private var isPermissionError: Bool {
        guard current.state == .failed else { return false }
        let text = [current.detail, current.result, error].compactMap { $0 }.joined(separator: " ")
        return cannotReadFolder || text.contains("EPERM") || text.contains("Operation not permitted")
    }

    private var trimmed: String { answer.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && !isBusy }

    private func send() {
        guard canSend else { return }
        let text = trimmed
        Task {
            if await claude.reply(text, to: current) == nil {
                answer = ""
                dismiss()
            }
        }
    }
}

/// Asks what a background Claude session should do in the repository, then starts it.
struct BackgroundClaudeForm: View {
    @ObservedObject var repo: Repository
    let dismiss: () -> Void
    @State private var prompt: String
    @State private var isStarting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(repo: Repository, prompt: String?, dismiss: @escaping () -> Void) {
        self.repo = repo
        self.dismiss = dismiss
        _prompt = State(initialValue: prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: repo.displayName).font(.headline)
            TextField("What should Claude do? A prompt or a skill like /init", text: $prompt, axis: .vertical)
                .lineLimit(3...10)
                .focused($focused)
                .onSubmit(start)
                .panelField()
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }
            HStack(alignment: .top) {
                Text("Runs in auto mode. Bridge tells you when it's done. ⌥↩ new line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: start) {
                    if isStarting { ProgressView().controlSize(.small) } else { Text("Start") }
                }
                .keyboardShortcut(.defaultAction)
                .prominentButton()
                .disabled(trimmed.isEmpty || isStarting)
            }
        }
        .padding(14)
        .frame(width: 400)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func start() {
        guard !trimmed.isEmpty, !isStarting else { return }
        isStarting = true
        error = nil
        Task {
            error = await BackgroundClaude.shared.start(trimmed, in: repo.path)
            isStarting = false
            if error == nil { dismiss() }
        }
    }
}
