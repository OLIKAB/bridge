import Foundation
import Shared

/// A pinned project that stays at the top and can be started when it isn't running.
struct Favorite: Codable, Identifiable, Hashable {
    enum Launch: Codable, Hashable {
        case terminal(command: String, cwd: String)
        case brew(formula: String)
        case docker(container: String)
    }

    /// Matches `ListeningProcess.favoriteKey`.
    let key: String
    let title: String
    let framework: Framework?
    let ports: [Int]
    let launch: Launch?

    var id: String { key }

    init(process: ListeningProcess, plan: RestartPlan) {
        key = process.favoriteKey
        title = process.title
        framework = process.framework
        ports = process.ports
        switch plan {
        case let .terminal(command, cwd, _, _): launch = .terminal(command: command, cwd: cwd)
        case let .brew(formula): launch = .brew(formula: formula)
        case let .docker(container): launch = .docker(container: container)
        case .unsupported: launch = nil
        }
    }

    /// Blocking, call off the main thread. Returns what went wrong, if anything.
    func start() -> String? {
        switch launch {
        case let .terminal(command, cwd):
            return Restarter.launch(command: command, cwd: cwd, title: title)
        case let .brew(formula):
            return PortScanner.perform(Restarter.brewPath, ["services", "start", formula])
        case let .docker(container):
            return Docker.run("start", container: container)
        case nil:
            return "Bridge doesn't know how to start \(title)"
        }
    }
}

enum FavoriteStore {
    private static let defaultsKey = "servers.favorites"

    /// One by one, so a favorite this version can't read (saved by a newer one, or from before a change
    /// to its fields) is skipped rather than taking the whole list with it at the next save.
    static func load() -> [Favorite] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let items = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return items.compactMap(\.favorite)
    }

    private struct Lenient: Decodable {
        let favorite: Favorite?
        init(from decoder: Decoder) throws {
            favorite = try? Favorite(from: decoder)
        }
    }

    static func save(_ favorites: [Favorite]) {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
