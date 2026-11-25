import Foundation
import Shared

struct DockerContainer {
    let name: String
    let image: String
    let hostPorts: Set<Int>

    /// postgres:16 → PostgreSQL logo, bitnami/redis → Redis, otherwise Docker.
    var framework: Framework {
        let base = image.split(separator: "/").last.map { String($0.split(separator: ":").first ?? "") } ?? image
        switch base {
        case "postgres", "postgis": return .postgres
        case "mysql", "mariadb": return .mysql
        case "redis": return .redis
        case "mongo": return .mongodb
        case "elasticsearch": return .elasticsearch
        case "rabbitmq": return .rabbitmq
        default: return .docker
        }
    }
}

enum Docker {
    /// Docker's CLI from wherever the container runtime put it (Docker Desktop, OrbStack, Rancher
    /// Desktop, Homebrew for Colima), or Podman's, which takes the same `ps`, `stop`, `start` and
    /// `restart` with the same `--format` fields.
    static let cli: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "\(home)/.rd/bin/docker",
            "/opt/homebrew/bin/podman",
            "/usr/local/bin/podman",
            "/opt/podman/bin/podman",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func runningContainers() -> [DockerContainer] {
        guard let cli else { return [] }
        let output = PortScanner.run(cli, ["ps", "--format", "{{.Names}}|{{.Image}}|{{.Ports}}"])
        let portPattern = try! NSRegularExpression(pattern: #":(\d+)->"#)

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            let ports = portPattern.matches(in: parts[2], range: NSRange(parts[2].startIndex..., in: parts[2]))
                .compactMap { Range($0.range(at: 1), in: parts[2]).flatMap { Int(parts[2][$0]) } }
            return DockerContainer(name: parts[0], image: parts[1], hostPorts: Set(ports))
        }
    }

    /// Nil if it worked, otherwise what went wrong.
    @discardableResult
    static func run(_ action: String, container: String) -> String? {
        guard let cli else { return "Couldn't find the docker command" }
        return PortScanner.perform(cli, [action, container])
    }
}
