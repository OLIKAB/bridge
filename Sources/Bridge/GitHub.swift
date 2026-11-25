import AppKit
import Foundation
import Shared

/// Logging in to a git host happens in its own command line, in a terminal, since it asks questions
/// and opens the browser. Without the command line and without Homebrew to install it, its download
/// page instead.
enum HostLogin {
    static func logIn(to host: any GitHost) {
        let installed = HostCLI(host: host).isInstalled
        let hasHomebrew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(where: FileManager.default.isExecutableFile)
        if !installed, !hasHomebrew || host.installCommand == nil {
            NSWorkspace.shared.open(host.installURL)
            return
        }
        let command = installed ? host.loginCommand : host.installCommand ?? host.loginCommand
        DevWorkspace.runInTerminal(command, in: NSHomeDirectory(), kind: "\(host.commandName)-login")
    }
}

/// Who's logged in to a git host, their organizations or groups and the repositories they can clone,
/// loaded once when a form needs them and kept for the session (reloaded from the forms). One per host.
@MainActor
final class HostAccount: ObservableObject {
    private static var accounts: [String: HostAccount] = [:]

    static func shared(for host: any GitHost) -> HostAccount {
        if let account = accounts[host.id] { return account }
        let account = HostAccount(host: host)
        accounts[host.id] = account
        return account
    }

    enum State: Equatable {
        case unknown, loading, loggedOut(String), loggedIn(String)
    }

    let host: any GitHost
    @Published private(set) var state = State.unknown
    @Published private(set) var organizations: [String] = []
    @Published private(set) var repos: [HostedRepo] = []
    @Published private(set) var isLoadingRepos = false
    @Published private(set) var reposError: String?

    private init(host: any GitHost) {
        self.host = host
    }

    var login: String? {
        if case let .loggedIn(login) = state { return login }
        return nil
    }

    func load(force: Bool = false) {
        guard force || state == .unknown || { if case .loggedOut = state { true } else { false } }() else { return }
        state = .loading
        let host = host
        Task {
            let cli = await Task.detached { HostCLI(host: host) }.value
            guard let login = await host.currentUser(cli) else {
                state = .loggedOut(cli.isInstalled ? "You're not logged in to \(host.name)." : "The \(host.cliName) isn't installed.")
                return
            }
            state = .loggedIn(login)
            organizations = await host.groups(cli).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    func loadRepos(force: Bool = false) {
        guard !isLoadingRepos, force || repos.isEmpty else { return }
        isLoadingRepos = true
        reposError = nil
        let host = host
        Task {
            let cli = await Task.detached { HostCLI(host: host) }.value
            do {
                repos = try await host.repositories(cli)
            } catch {
                reposError = error.localizedDescription
            }
            isLoadingRepos = false
        }
    }
}
