import Foundation

/// A Claude Code skill or slash command found on disk, offered when pinning one to a repository.
struct ClaudeSkill: Identifiable, Hashable {
    let name: String
    let description: String
    /// From the repository's own `.claude` folder rather than the user's or a plugin's.
    var isProject = false
    var id: String { name }
}

enum ClaudeSkills {
    /// The repository's own skills and commands (listed first), the user's, and those from installed plugins
    /// (namespaced as `plugin:name`, which is how Claude Code invokes them).
    static func available(in path: String) -> [ClaudeSkill] {
        let home = NSHomeDirectory() + "/.claude"
        // The repository's own come first, so they win over a user skill with the same name.
        var found = (skills(in: path + "/.claude/skills") + commands(in: path + "/.claude/commands"))
            .map { ClaudeSkill(name: $0.name, description: $0.description, isProject: true) }
        found += skills(in: home + "/skills")
        found += commands(in: home + "/commands")
        // Skills synced from claude.ai sit one folder deeper, per account.
        for folder in subfolders(of: home + "/skills/synced") {
            found += skills(in: folder)
        }
        for (plugin, installPath) in installedPlugins(home: home) {
            found += (skills(in: installPath + "/skills") + commands(in: installPath + "/commands"))
                .map { ClaudeSkill(name: "\(plugin):\($0.name)", description: $0.description) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.name).inserted }
            .sorted { ($0.isProject ? 0 : 1, $0.name) < ($1.isProject ? 0 : 1, $1.name) }
    }

    private static func skills(in folder: String) -> [ClaudeSkill] {
        subfolders(of: folder).compactMap { dir in
            guard let text = try? String(contentsOfFile: dir + "/SKILL.md", encoding: .utf8) else { return nil }
            let meta = frontMatter(text)
            return ClaudeSkill(name: meta["name"] ?? (dir as NSString).lastPathComponent, description: meta["description"] ?? "")
        }
    }

    private static func commands(in folder: String) -> [ClaudeSkill] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return files.filter { $0.hasSuffix(".md") }.map { file in
            let text = (try? String(contentsOfFile: folder + "/" + file, encoding: .utf8)) ?? ""
            return ClaudeSkill(name: String(file.dropLast(3)), description: frontMatter(text)["description"] ?? "")
        }
    }

    private static func subfolders(of folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.map { folder + "/" + $0 }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Plugin name (the part before `@marketplace`) and where its current version is installed.
    private static func installedPlugins(home: String) -> [(String, String)] {
        guard let data = FileManager.default.contents(atPath: home + "/plugins/installed_plugins.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [[String: Any]]] else { return [] }
        return plugins.compactMap { key, installs in
            guard let path = installs.first?["installPath"] as? String else { return nil }
            return (String(key.split(separator: "@")[0]), path)
        }
    }

    /// The `key: value` lines between the leading `---` fences; enough for name and description.
    private static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[String(line[..<colon])] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return result
    }
}
