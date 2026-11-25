import Foundation

struct FileChange: Identifiable, Hashable {
    enum Kind {
        case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted
    }

    enum Staging {
        case none, partial, all
    }

    let path: String
    let originalPath: String?
    /// The X and Y columns of `git status`: changes in the index, and in the working tree.
    let index: Character
    let worktree: Character
    var id: String { path }

    var isUntracked: Bool { index == "?" }
    var isConflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }

    var kind: Kind {
        if isUntracked { return .untracked }
        if isConflicted { return .conflicted }
        switch index != "." ? index : worktree {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return .modified
        }
    }

    var staging: Staging {
        if isUntracked || isConflicted || index == "." { return .none }
        return worktree == "." ? .all : .partial
    }

    var fileName: String { (path as NSString).lastPathComponent }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct RepoStatus: Equatable {
    /// nil when HEAD is detached.
    var branch: String?
    /// nil before the first commit.
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [FileChange] = []

    var stagedCount: Int { files.filter { $0.staging != .none }.count }
    var conflictCount: Int { files.filter(\.isConflicted).count }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parse(_ text: String) -> RepoStatus {
        var status = RepoStatus()
        var tokens = text.split(separator: "\0").map(String.init)[...]
        while let token = tokens.popFirst() {
            let fields = { (count: Int) in token.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init) }
            switch token.first {
            case "#":
                let parts = fields(3)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.head = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.upstream = parts[2]
                case "branch.ab":
                    let ab = parts[2].split(separator: " ")
                    if ab.count == 2 {
                        status.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            case "1":
                let parts = fields(9)
                guard parts.count == 9 else { continue }
                status.files.append(FileChange(path: parts[8], originalPath: nil, xy: parts[1]))
            case "2":
                // Renames and copies: the original path follows as its own NUL-separated token.
                let parts = fields(10)
                guard parts.count == 10 else { continue }
                status.files.append(FileChange(path: parts[9], originalPath: tokens.popFirst(), xy: parts[1]))
            case "u":
                let parts = fields(11)
                guard parts.count == 11 else { continue }
                status.files.append(FileChange(path: parts[10], originalPath: nil, xy: parts[1]))
            case "?":
                status.files.append(FileChange(path: String(token.dropFirst(2)), originalPath: nil, xy: "??"))
            default:
                break
            }
        }
        status.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }
}

private extension FileChange {
    init(path: String, originalPath: String?, xy: String) {
        let chars = Array(xy)
        self.init(path: path, originalPath: originalPath, index: chars.first ?? ".", worktree: chars.count > 1 ? chars[1] : ".")
    }
}

struct Commit: Identifiable, Hashable {
    let sha: String
    let shortSha: String
    let author: String
    let email: String
    let date: Date
    let parents: [String]
    /// Branches and tags pointing at this commit, e.g. ["HEAD -> main", "origin/main", "tag: v1.0"].
    let refs: [String]
    let subject: String
    var id: String { sha }

    static let logFormat = "--format=%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%D%x1f%s%x1e"

    static func parseLog(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8 else { return nil }
            return Commit(
                sha: f[0], shortSha: f[1], author: f[2], email: f[3],
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                parents: f[5].split(separator: " ").map(String.init),
                refs: f[6].isEmpty ? [] : f[6].components(separatedBy: ", "),
                subject: f[7]
            )
        }
    }
}

struct Branch: Identifiable, Hashable {
    let name: String
    let isRemote: Bool
    let upstream: String?
    let date: Date
    var id: String { (isRemote ? "remote/" : "local/") + name }

    /// "origin/feature/x" → "feature/x"
    var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    static let refFormat = "--format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)"

    static func parse(_ text: String) -> [Branch] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, !f[0].hasSuffix("/HEAD") else { return nil }
            return Branch(
                name: f[1],
                isRemote: f[0].hasPrefix("refs/remotes/"),
                upstream: f[2].isEmpty ? nil : f[2],
                date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0)
            )
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind {
        case context, added, removed, hunk, note
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

struct FileDiff {
    var lines: [DiffLine] = []
    var isBinary = false

    var isEmpty: Bool { lines.isEmpty && !isBinary }

    /// Parses unified diff output for a single file.
    static func parse(_ text: String) -> FileDiff {
        var diff = FileDiff()
        var oldLine = 0, newLine = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: "\t", with: "    ")
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -12,7 +12,9 @@ func name()
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                diff.append(.hunk, line, nil, nil)
            } else if !inHunk {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
            } else if line.hasPrefix("+") {
                diff.append(.added, String(line.dropFirst()), nil, newLine)
                newLine += 1
            } else if line.hasPrefix("-") {
                diff.append(.removed, String(line.dropFirst()), oldLine, nil)
                oldLine += 1
            } else if line.hasPrefix(" ") {
                diff.append(.context, String(line.dropFirst()), oldLine, newLine)
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                diff.append(.note, line, nil, nil)
            } else if line.hasPrefix("diff --git") {
                // A second file (e.g. a commit diff with several files); only one is expected here.
                inHunk = false
            }
        }
        return diff
    }

    private mutating func append(_ kind: DiffLine.Kind, _ text: String, _ old: Int?, _ new: Int?) {
        lines.append(DiffLine(id: lines.count, kind: kind, text: text, oldNumber: old, newNumber: new))
    }
}

/// A file touched by a commit, from `git show --name-status`.
struct CommitFile: Identifiable, Hashable {
    let path: String
    let originalPath: String?
    let kind: FileChange.Kind
    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    /// Parses `--name-status -z`: "M\0path\0", "R100\0old\0new\0".
    static func parse(_ text: String) -> [CommitFile] {
        var tokens = text.split(separator: "\0").map(String.init)[...]
        var files: [CommitFile] = []
        while let code = tokens.popFirst()?.trimmingCharacters(in: .whitespacesAndNewlines), let letter = code.first {
            if letter == "R" || letter == "C" {
                guard let old = tokens.popFirst(), let new = tokens.popFirst() else { break }
                files.append(CommitFile(path: new, originalPath: old, kind: letter == "R" ? .renamed : .copied))
            } else {
                guard let path = tokens.popFirst() else { break }
                let kind: FileChange.Kind = switch letter {
                case "A": .added
                case "D": .deleted
                case "T": .typeChanged
                default: .modified
                }
                files.append(CommitFile(path: path, originalPath: nil, kind: kind))
            }
        }
        return files
    }
}

/// A merge, rebase or similar that has stopped halfway, usually because of conflicts.
enum RepoOperation: String {
    case merge = "Merge"
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case revert = "Revert"

    var abortArgs: [String] {
        switch self {
        case .merge: ["merge", "--abort"]
        case .rebase: ["rebase", "--abort"]
        case .cherryPick: ["cherry-pick", "--abort"]
        case .revert: ["revert", "--abort"]
        }
    }

    var continueArgs: [String] {
        switch self {
        case .merge: ["commit", "--no-edit"]
        case .rebase: ["rebase", "--continue"]
        case .cherryPick: ["cherry-pick", "--continue"]
        case .revert: ["revert", "--continue"]
        }
    }

    static func detect(gitDir: String) -> RepoOperation? {
        let exists = { FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent($0)) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }
}
