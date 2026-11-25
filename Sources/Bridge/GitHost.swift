import AppKit
import Foundation
import Shared

/// A repository on a git host that the user can clone, as the host's list gives it.
struct HostedRepo: Identifiable, Hashable {
    /// The full path: owner/name on GitHub, group/subgroup/name on GitLab.
    let name: String
    let isPrivate: Bool
    let description: String?
    let pushedAt: String?

    var id: String { name }
    /// Everything before the name: the account, organization or group (with its subgroups).
    var owner: String { name.split(separator: "/").dropLast().joined(separator: "/") }
    var shortName: String { String(name.split(separator: "/").last ?? "") }
}

/// An open pull request (GitHub) or merge request (GitLab) for a branch.
struct PullRequest: Decodable, Equatable {
    let number: Int
    let url: String
    let isDraft: Bool
}

/// Where repositories are published and cloned from, through the host's own command line, so the
/// user's login there applies and Bridge keeps no tokens. Plain git with an SSH key works without
/// any of this; a host only adds publishing, cloning from a list and pull or merge requests.
protocol GitHost: Sendable {
    /// Stable, for settings.
    var id: String { get }
    var name: String { get }
    /// The command line it's used through, looked up on the user's PATH.
    var commandName: String { get }
    var cliName: String { get }
    /// Folders to look in before PATH (Homebrew's, which a menu bar app's PATH may not have).
    var extraSearchPaths: [String] { get }
    /// Shell lines run in a terminal, since logins ask questions and open the browser.
    var loginCommand: String { get }
    /// Installs the command line and logs in, or nil when it can't be installed from a shell.
    var installCommand: String? { get }
    var installURL: URL { get }
    /// Added to the environment the command line runs in: no prompts (there's no terminal to answer
    /// them in) and no update notices in its output.
    var environment: [String: String] { get }
    @MainActor var logo: NSImage { get }

    /// Where a published repository's page is, shown before publishing ("github.com").
    var webHost: String { get }
    /// "pull request" or "merge request", and how one is numbered ("#12", "!12").
    var changeRequest: String { get }
    var changeRequestShort: String { get }
    var numberPrefix: String { get }

    /// Whether a repository whose web page is `page` is on this host.
    func handles(_ page: URL) -> Bool

    /// Blocking; runs off the main thread.
    func loginState(executable: String, environment: [String: String]) -> CLILogin

    /// The logged-in user's name, or nil when not logged in.
    func currentUser(_ cli: HostCLI) async -> String?
    /// Organizations or groups the user can publish to.
    func groups(_ cli: HostCLI) async -> [String]
    /// What the user can clone, most recently changed first.
    func repositories(_ cli: HostCLI) async throws -> [HostedRepo]
    /// Creates the repository on the host as `owner/name` (`owner` nil for the user's own account),
    /// sets it as `origin` and pushes when there's a commit, like GitHub Desktop's Publish repository.
    func publish(_ cli: HostCLI, in path: String, name: String, description: String, isPrivate: Bool, owner: String?, hasCommit: Bool) async throws
    /// The open pull or merge request for `branch`, or nil.
    func openChangeRequest(_ cli: HostCLI, branch: String, in path: String) async -> PullRequest?
    /// The host's page for proposing `branch` into `target`.
    func newChangeRequestURL(base: URL, from branch: String, into target: String) -> URL?
    /// Arguments that clone `repository` (a full path or a URL) into `path`.
    func cloneArguments(_ repository: String, to path: String) -> [String]
}

extension GitHost {
    func executable(path: String) -> String? {
        let candidates = extraSearchPaths + path.split(separator: ":").map(String.init)
        return candidates.map { "\($0)/\(commandName)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var cli: HostCLI { HostCLI(host: self) }
}

/// A git host's command line, found on the user's PATH and run with the host's environment.
struct HostCLI: Sendable {
    let host: any GitHost
    let executable: String?

    init(host: any GitHost) {
        self.host = host
        executable = host.executable(path: Git.environment["PATH"] ?? "")
    }

    var isInstalled: Bool { executable != nil }

    func run(_ args: [String], in directory: String = NSHomeDirectory(), timeout: TimeInterval = 30) async -> GitResult {
        guard let executable else {
            return GitResult(status: -1, stdout: "", stderr: "The \(host.cliName) isn't installed. Install it, then log in with `\(host.loginCommand)`.")
        }
        let environment = Git.environment.merging(host.environment) { $1 }
        return await Task.detached {
            Git.runSync(executable, args, in: directory, environment: environment, timeout: timeout)
        }.value
    }

    /// Like `run`, but throws the command's own message on failure.
    @discardableResult
    func output(_ args: [String], in directory: String = NSHomeDirectory(), timeout: TimeInterval = 30) async throws -> String {
        let result = await run(args, in: directory, timeout: timeout)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty ? "\(host.commandName) \(args.first ?? "") failed (exit code \(result.status))" : message)
        }
        return result.stdout
    }

    /// `output` parsed as JSON.
    func json(_ args: [String], in directory: String = NSHomeDirectory(), timeout: TimeInterval = 30) async throws -> Any {
        let text = try await output(args, in: directory, timeout: timeout)
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            throw GitError(message: "\(host.commandName) didn't answer with JSON")
        }
        return value
    }
}

/// GitHub, through `gh`.
struct GitHubHost: GitHost {
    let id = "github"
    let name = "GitHub"
    let commandName = "gh"
    let cliName = "GitHub CLI"
    let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    let loginCommand = "gh auth login"
    let installCommand: String? = "brew install gh && gh auth login"
    let installURL = URL(string: "https://cli.github.com")!
    let environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
    @MainActor var logo: NSImage { Logo.github }
    let webHost = "github.com"
    let changeRequest = "pull request"
    let changeRequestShort = "PR"
    let numberPrefix = "#"

    func handles(_ page: URL) -> Bool { page.host?.lowercased() == "github.com" }

    /// `gh auth status` succeeds when logged in and names the account ("Logged in to github.com account …").
    func loginState(executable: String, environment: [String: String]) -> CLILogin {
        let status = Subprocess.run(executable, ["auth", "status", "--hostname", "github.com"], in: NSHomeDirectory(), environment: environment, timeout: 10)
        guard status.succeeded else { return .loggedOut }
        let output = status.stdout + status.stderr
        let account = output.range(of: #"account (\S+)"#, options: .regularExpression).map { String(output[$0].dropFirst(8)) }
        return .loggedIn(account: account)
    }

    func currentUser(_ cli: HostCLI) async -> String? {
        let login = (try? await cli.output(["api", "user", "--jq", ".login"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return login?.isEmpty == false ? login : nil
    }

    /// Needs the read:org scope, which `gh auth login` asks for; without it there's just the personal account.
    func groups(_ cli: HostCLI) async -> [String] {
        let output = (try? await cli.output(["api", "user/orgs", "--paginate", "--jq", ".[].login"])) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    /// Every repository the user owns, collaborates on or can see through an organization, most recently pushed first.
    func repositories(_ cli: HostCLI) async throws -> [HostedRepo] {
        let output = try await cli.output([
            "api", "--paginate", "user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
            "--jq", ".[] | {name: .full_name, isPrivate: .private, description: .description, pushedAt: .pushed_at}",
        ], timeout: 90)
        return output.split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = json["name"] as? String else { return nil }
            return HostedRepo(name: name, isPrivate: json["isPrivate"] as? Bool ?? false,
                              description: json["description"] as? String, pushedAt: json["pushedAt"] as? String)
        }
    }

    /// `gh repo create --source .` creates it, sets the remote and (with `--push`) pushes, all in one.
    func publish(_ cli: HostCLI, in path: String, name: String, description: String, isPrivate: Bool, owner: String?, hasCommit: Bool) async throws {
        var args = ["repo", "create", owner.map { "\($0)/\(name)" } ?? name,
                    isPrivate ? "--private" : "--public", "--source", ".", "--remote", "origin"]
        if !description.isEmpty { args += ["--description", description] }
        if hasCommit { args.append("--push") }
        try await cli.output(args, in: path, timeout: 300)
    }

    /// The newest pull request for the branch, whatever its state; only an open one counts.
    func openChangeRequest(_ cli: HostCLI, branch: String, in path: String) async -> PullRequest? {
        let result = await cli.run(["pr", "view", branch, "--json", "number,url,isDraft,state"], in: path)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["state"] as? String == "OPEN"
        else { return nil }
        return try? JSONDecoder().decode(PullRequest.self, from: data)
    }

    /// The compare page GitHub opens a new pull request from, as GitHub Desktop does.
    func newChangeRequestURL(base: URL, from branch: String, into target: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let from = branch.addingPercentEncoding(withAllowedCharacters: allowed),
              let into = target.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base.absoluteString + "/compare/\(into)...\(from)?expand=1")
    }

    /// gh sets up a fork's `upstream` remote too.
    func cloneArguments(_ repository: String, to path: String) -> [String] { ["repo", "clone", repository, path] }
}

/// GitLab, through `glab`. gitlab.com, or a self-hosted instance glab is set up for (`GITLAB_HOST` or
/// its config): outside a repository glab talks to that, which is where the account and lists come from.
struct GitLabHost: GitHost {
    let id = "gitlab"
    let name = "GitLab"
    let commandName = "glab"
    let cliName = "GitLab CLI"
    let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    let loginCommand = "glab auth login"
    let installCommand: String? = "brew install glab && glab auth login"
    let installURL = URL(string: "https://gitlab.com/gitlab-org/cli")!
    let environment = [
        "GLAB_NO_PROMPT": "true", "GLAB_CHECK_UPDATE": "false", "GLAB_SHOW_WHATS_NEW": "false",
        "GLAB_SEND_TELEMETRY": "false", "GLAB_NOTIFY_SKILL_UPDATES": "false", "NO_COLOR": "1", "GLAB_PAGER": "cat",
    ]
    @MainActor var logo: NSImage { Logo.bundled("gitlab", fallback: "globe") }
    let webHost = "gitlab.com"
    let changeRequest = "merge request"
    let changeRequestShort = "MR"
    let numberPrefix = "!"

    /// gitlab.com, and self-hosted instances, which nearly always have "gitlab" in their host name.
    func handles(_ page: URL) -> Bool { page.host?.lowercased().contains("gitlab") == true }

    /// `glab auth status --output json` lists each host with `state` ("success" or "error") and `user`.
    /// It exits non-zero when one fails but still prints the JSON, so the JSON decides.
    func loginState(executable: String, environment: [String: String]) -> CLILogin {
        let status = Subprocess.run(executable, ["auth", "status", "--output", "json"], in: NSHomeDirectory(), environment: environment, timeout: 10)
        let json = (try? JSONSerialization.jsonObject(with: Data(status.stdout.utf8))) as? [String: Any]
        let hosts = json?["hosts"] as? [[String: Any]] ?? []
        guard let host = hosts.first(where: { $0["state"] as? String == "success" }) else { return .loggedOut }
        return .loggedIn(account: host["user"] as? String)
    }

    func currentUser(_ cli: HostCLI) async -> String? {
        (try? await cli.json(["api", "user"]) as? [String: Any])?["username"] as? String
    }

    /// Groups where the user is at least a Developer (access level 30), so they can create projects there.
    func groups(_ cli: HostCLI) async -> [String] {
        let groups = (try? await cli.json(["api", "groups?min_access_level=30&per_page=100"])) as? [[String: Any]] ?? []
        return groups.compactMap { $0["full_path"] as? String }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Projects the user is a member of, directly or through a group, most recently active first.
    /// The first 100: the API's page size, and more than fit in the list anyway.
    func repositories(_ cli: HostCLI) async throws -> [HostedRepo] {
        let projects = try await cli.json(["api", "projects?membership=true&order_by=last_activity_at&per_page=100"], timeout: 90) as? [[String: Any]] ?? []
        return projects.compactMap { project in
            guard let path = project["path_with_namespace"] as? String else { return nil }
            return HostedRepo(name: path, isPrivate: project["visibility"] as? String != "public",
                              description: project["description"] as? String, pushedAt: project["last_activity_at"] as? String)
        }
    }

    /// `glab repo create <name>` only creates the project: it neither adds a remote nor pushes. So the
    /// project's clone URL is looked up (SSH or HTTPS, as glab is set up for) and the rest done with git.
    func publish(_ cli: HostCLI, in path: String, name: String, description: String, isPrivate: Bool, owner: String?, hasCommit: Bool) async throws {
        var args = ["repo", "create", name, isPrivate ? "--private" : "--public"]
        if !description.isEmpty { args += ["--description", description] }
        if let owner { args += ["--group", owner] }
        try await cli.output(args, in: path, timeout: 120)

        var namespace = owner
        if namespace == nil { namespace = await currentUser(cli) }
        guard let namespace else {
            throw GitError(message: "Created the project on GitLab, but couldn't tell whose it is to add it as origin.")
        }
        let fullPath = "\(namespace)/\(name)"
        guard let encoded = fullPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return }
        let project = try await cli.json(["api", "projects/\(encoded)"], in: path) as? [String: Any]
        let usesHTTPS = (try? await cli.output(["config", "get", "git_protocol"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https"
        guard let url = project?[usesHTTPS ? "http_url_to_repo" : "ssh_url_to_repo"] as? String else {
            throw GitError(message: "Created \(fullPath) on GitLab, but couldn't find its URL to add as origin.")
        }
        _ = try await Git.output(["remote", "add", "origin", url], in: path)
        if hasCommit { _ = try await Git.output(["push", "--set-upstream", "origin", "HEAD"], in: path, timeout: 300) }
    }

    /// Open merge requests from `branch` (`glab mr list` lists only open ones), as the API gives them.
    func openChangeRequest(_ cli: HostCLI, branch: String, in path: String) async -> PullRequest? {
        guard let requests = try? await cli.json(["mr", "list", "--source-branch", branch, "--output", "json"], in: path) as? [[String: Any]],
              let request = requests.first,
              let number = request["iid"] as? Int, let url = request["web_url"] as? String
        else { return nil }
        return PullRequest(number: number, url: url, isDraft: request["draft"] as? Bool ?? false)
    }

    /// GitLab's page for a new merge request, with both branches filled in, as glab itself opens it.
    func newChangeRequestURL(base: URL, from branch: String, into target: String) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("-/merge_requests/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "merge_request[source_branch]", value: branch),
            URLQueryItem(name: "merge_request[target_branch]", value: target),
        ]
        return components?.url
    }

    func cloneArguments(_ repository: String, to path: String) -> [String] { ["repo", "clone", repository, path] }
}

enum GitHosts {
    static let gitHub = GitHubHost()
    static let gitLab = GitLabHost()

    /// Every host Bridge knows.
    static let all: [any GitHost] = [gitHub, gitLab]

    /// The host a repository with this web page is on, or nil for anywhere else (Bitbucket, a server of one's own).
    static func host(for page: URL?) -> (any GitHost)? {
        guard let page else { return nil }
        return all.first { $0.handles(page) }
    }

    /// The hosts whose command line is installed, for Publish and Clone; GitHub when there's none,
    /// so those forms can say how to get it.
    static var available: [any GitHost] {
        let installed = all.filter { HostCLI(host: $0).isInstalled }
        return installed.isEmpty ? [gitHub] : installed
    }
}
