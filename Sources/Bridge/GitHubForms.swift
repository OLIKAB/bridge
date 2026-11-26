import AppKit
import Shared
import SwiftUI

/// Shown in place of a host form's fields until its command line is installed and logged in.
private struct HostLoginNotice: View {
    @ObservedObject var account: HostAccount
    let message: String

    var body: some View {
        let host = account.host
        VStack(alignment: .leading, spacing: 8) {
            Text(message).foregroundStyle(.secondary)
            Text("Bridge uses the \(host.cliName)'s login, so log in there once, then check again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(HostCLI(host: host).isInstalled ? "Log in to \(host.name)…" : "Install \(host.cliName) and log in…") {
                    HostLogin.logIn(to: host)
                }
                Button("Check again") { account.load(force: true) }
            }
        }
    }
}

/// The host part of a repository's right-click menu, in the panel and the window's sidebar.
struct GitHubMenuItems: View {
    @ObservedObject var repo: Repository
    let publish: () -> Void

    var body: some View {
        if repo.remote == nil {
            // Named after the host when there's only one to publish to.
            let hosts = GitHosts.available
            Button(hosts.count == 1 ? "Publish to \(hosts[0].name)…" : "Publish…", action: publish)
        }
        if let page = repo.webPage {
            Button(repo.host.map { "View on \($0.name)" } ?? "View on the web") { NSWorkspace.shared.open(page) }
        }
        if let host = repo.host {
            if let pr = repo.pullRequest, let url = URL(string: pr.url) {
                Button("View \(host.changeRequest) \(host.numberPrefix)\(pr.number)") { NSWorkspace.shared.open(url) }
            } else if repo.canCreatePullRequest {
                Button("Create \(host.changeRequest)") { Task { await repo.createPullRequest() } }
            }
        }
    }
}

/// GitHub Desktop's Publish repository: puts a local-only repository on GitHub or GitLab. With both
/// command lines installed, a picker says which; otherwise it's the one that is (GitHub when neither).
struct PublishRepositoryForm: View {
    @ObservedObject var repo: Repository
    let dismiss: () -> Void
    @State private var hostID = GitHosts.available[0].id

    private var hosts: [any GitHost] { GitHosts.available }
    private var host: any GitHost { hosts.first { $0.id == hostID } ?? hosts[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Publish repository").font(.headline)
                Spacer()
                if hosts.count > 1 {
                    Picker("Publish to", selection: $hostID) {
                        ForEach(hosts.map(\.id), id: \.self) { id in
                            Text(hosts.first { $0.id == id }?.name ?? id).tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            // A pane per host, so each keeps its own account (and what was typed is kept across a switch).
            PublishRepositoryPane(repo: repo, account: HostAccount.shared(for: host), dismiss: dismiss)
                .id(hostID)
        }
        .padding(12)
        .frame(width: 360)
    }
}

private struct PublishRepositoryPane: View {
    @FocusState private var focus: String?
    @ObservedObject var repo: Repository
    @ObservedObject var account: HostAccount
    let dismiss: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true
    /// "" is the user's own account.
    @State private var owner = ""
    @State private var isPublishing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch account.state {
            case .unknown, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your \(account.host.name) login…").foregroundStyle(.secondary)
                }
            case let .loggedOut(message):
                HostLoginNotice(account: account, message: message)
            case let .loggedIn(login):
                fields(login: login)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Publish", action: publish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.login == nil || slug.isEmpty || isPublishing)
            }
        }
        .onAppear {
            name = repo.name
            account.load()
        }
    }

    @ViewBuilder
    private func fields(login: String) -> some View {
        // A native form, labels right-aligned in a column, like the new project form.
        Form {
            // Labelled by hand: a field in the panels' style is a plain one, which a form doesn't label.
            LabeledContent("Name") {
                TextField("Name", text: $name).labelsHidden().onSubmit(publish)
                    .focused($focus, equals: "name")
                    .panelField()
            }
            LabeledContent("Description") {
                TextField("Description", text: $description, prompt: Text("Optional")).labelsHidden().onSubmit(publish)
                    .focused($focus, equals: "description")
                    .panelField()
            }
            if !account.organizations.isEmpty {
                Picker("Owner", selection: $owner) {
                    Text(verbatim: login).tag("")
                    Divider()
                    ForEach(account.organizations, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .fixedSize()
            }
        }
        PanelSwitch("Keep this code private", isOn: $isPrivate)
        Text(verbatim: "\(account.host.webHost)/\(owner.isEmpty ? login : owner)/\(slug.isEmpty ? "…" : slug)" + (repo.status?.head == nil ? ". There are no commits yet, so nothing is pushed." : ""))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if isPublishing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Publishing…").foregroundStyle(.secondary)
            }
        }
    }

    /// The hosts turn anything but letters, digits, `-`, `_` and `.` into dashes; this does the same up front.
    private var slug: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(trimmed.unicodeScalars.map { $0.isASCII && allowed.contains($0) ? Character($0) : "-" })
    }

    private func publish() {
        guard account.login != nil, !slug.isEmpty, !isPublishing else { return }
        isPublishing = true
        Task {
            // A failure shows as the repository's error, like any other git command.
            await repo.publish(to: account.host, name: slug, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                               isPrivate: isPrivate, owner: owner.isEmpty ? nil : owner)
            isPublishing = false
            dismiss()
        }
    }
}

/// GitHub Desktop's Clone repository: the user's repositories on each host whose command line is
/// installed (GitHub when none is), or any URL.
struct CloneRepositoryForm: View {
    @FocusState private var focus: String?

    @ObservedObject var store: RepoStore
    /// A page of the menu bar panel (`PanelPage`), whose header has the title and the way back.
    var isPage = false
    let dismiss: () -> Void
    /// A host's id, or "url".
    @State private var source = GitHosts.available[0].id
    @State private var selected: String?
    @State private var url = ""
    @State private var folder = ""
    @State private var error: String?

    private static let urlSource = "url"
    private var hosts: [any GitHost] { GitHosts.available }
    private var host: (any GitHost)? { hosts.first { $0.id == source } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isPage {
                Text("Clone repository").font(.headline)
            }
            Picker("", selection: $source) {
                ForEach(hosts.map(\.id), id: \.self) { id in
                    Text(hosts.first { $0.id == id }?.name ?? id).tag(id)
                }
                Text("URL").tag(Self.urlSource)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let host {
                HostedRepoList(store: store, account: HostAccount.shared(for: host), selected: $selected, focus: $focus, clone: clone)
                    .id(host.id)
            } else {
                TextField("https://github.com/owner/repo or owner/repo", text: $url)
                    .onSubmit(clone)
                    .focused($focus, equals: "url")
                    .panelField()
            }

            LabeledContent("Into") {
                HStack {
                    Text(verbatim: destination.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? (folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Change…", action: chooseFolder).controlSize(.small)
                }
            }
            if let error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                // What Clone does, and where to see it happen.
                if isPage {
                    Text("It shows at the top of the list while it's cloning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if !isPage {
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                }
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(repository == nil)
            }
        }
        .padding(12)
        .frame(width: isPage ? nil : 420)
        .frame(maxWidth: isPage ? .infinity : nil, alignment: .leading)
        .onAppear {
            folder = store.newProjectFolder
            focus = host == nil ? "url" : "filter"
        }
        .onChange(of: source) {
            selected = nil
            focus = host == nil ? "url" : "filter"
        }
        .onChange(of: selected) { error = nil }
        .onChange(of: url) { error = nil }
    }

    /// What to clone: the full path from the list, or the URL as typed.
    private var repository: String? {
        if host != nil { return selected }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The folder the clone goes in: named after the repository, in the chosen folder.
    private var destination: String? {
        guard let repository else { return nil }
        var name = repository.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? repository
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty else { return nil }
        return (folder as NSString).appendingPathComponent(name)
    }

    private func chooseFolder() {
        if let path = store.chooseFolder(message: "Choose where to clone the repository") {
            folder = path
            store.newProjectFolder = path
        }
    }

    private func clone() {
        guard let repository, let destination else { return }
        guard !FileManager.default.fileExists(atPath: destination) else {
            error = "\((destination as NSString).abbreviatingWithTildeInPath) already exists"
            return
        }
        let host = host
        // The panel shows it as cloning meanwhile, and a failure as an alert, since a big clone
        // can take longer than anyone keeps a form open.
        dismiss()
        Task {
            if let message = await store.clone(repository, to: destination, host: host) {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn't clone \(repository)"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}

/// A host's repositories to pick one from, grouped by owner: the user's own first, then each
/// organization's or group's, each in the order last changed.
private struct HostedRepoList: View {
    @ObservedObject var store: RepoStore
    @ObservedObject var account: HostAccount
    @Binding var selected: String?
    var focus: FocusState<String?>.Binding
    let clone: () -> Void
    @State private var filter = ""

    var body: some View {
        Group {
            switch account.state {
            case .unknown, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your \(account.host.name) login…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            case let .loggedOut(message):
                HostLoginNotice(account: account, message: message)
            case .loggedIn:
                list
            }
        }
        .onAppear {
            account.load()
            if account.login != nil { account.loadRepos() }
        }
        .onChange(of: account.state) {
            if account.login != nil { account.loadRepos() }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Filter your repositories", text: $filter, prompt: Text("Filter, or double-click one to clone it"))
                    .focused(focus, equals: "filter")
                    .panelField()
                if account.isLoadingRepos {
                    ProgressView().controlSize(.small).frame(width: PanelMetrics.fieldHeight + 4, height: PanelMetrics.fieldHeight)
                } else {
                    Button { account.loadRepos(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .fieldRowButton()
                        .panelTooltip("Reload the list")
                        .accessibilityLabel("Reload the list")
                }
            }
            if let reposError = account.reposError {
                Text(verbatim: reposError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            List(selection: $selected) {
                ForEach(groups, id: \.owner) { group in
                    Section(group.owner) {
                        ForEach(group.repos) { repo in
                            HStack(spacing: 6) {
                                Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(verbatim: repo.shortName).lineLimit(1)
                                Spacer(minLength: 4)
                                if store.repos.contains(where: { $0.hostedName?.caseInsensitiveCompare(repo.name) == .orderedSame }) {
                                    Text("In Bridge").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .tag(repo.name)
                        }
                    }
                }
            }
            // Double-clicking a repository clones it, like opening an item in a Finder list.
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { names in
                if let name = names.first {
                    selected = name
                    clone()
                }
            })
            .listStyle(.bordered)
            .frame(height: 260)
        }
    }

    private var groups: [(owner: String, repos: [HostedRepo])] {
        let matching = account.repos.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        var order: [String] = []
        var byOwner: [String: [HostedRepo]] = [:]
        for repo in matching {
            if byOwner[repo.owner] == nil { order.append(repo.owner) }
            byOwner[repo.owner, default: []].append(repo)
        }
        let login = account.login
        order.sort { a, b in
            if (a == login) != (b == login) { return a == login }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return order.map { ($0, byOwner[$0] ?? []) }
    }
}
