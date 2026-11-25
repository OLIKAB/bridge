import AppKit
import SwiftUI

public struct Framework: Hashable, Codable {
    public enum Category: Codable { case server, database, runtime, app }

    public let title: String
    /// Simple Icons slug, matches Resources/Logos/<slug>.svg
    public let logo: String
    /// Brand color, nil for black logos so they follow light/dark mode.
    public let hex: String?
    public let category: Category

    public var color: Color {
        guard let hex, let value = Int(hex, radix: 16) else { return .primary }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Loaded once per logo; views re-render every scan.
    @MainActor private static var imageCache: [String: NSImage] = [:]

    @MainActor public var image: NSImage? {
        if let cached = Self.imageCache[logo] { return cached }
        guard let url = Bundle.main.url(forResource: logo, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        Self.imageCache[logo] = image
        return image
    }

    public static let postgres = Framework(title: "PostgreSQL", logo: "postgresql", hex: "4169E1", category: .database)
    public static let mysql = Framework(title: "MySQL", logo: "mysql", hex: "4479A1", category: .database)
    public static let redis = Framework(title: "Redis", logo: "redis", hex: "FF4438", category: .database)
    public static let mongodb = Framework(title: "MongoDB", logo: "mongodb", hex: "47A248", category: .database)
    public static let elasticsearch = Framework(title: "Elasticsearch", logo: "elasticsearch", hex: "005571", category: .database)
    public static let rabbitmq = Framework(title: "RabbitMQ", logo: "rabbitmq", hex: "FF6600", category: .database)
    public static let docker = Framework(title: "Docker", logo: "docker", hex: "2496ED", category: .server)

    public static let nuxt = Framework(title: "Nuxt", logo: "nuxt", hex: "00DC82", category: .server)
    public static let next = Framework(title: "Next.js", logo: "nextdotjs", hex: nil, category: .server)
    public static let vite = Framework(title: "Vite", logo: "vite", hex: "9135FF", category: .server)
    public static let vue = Framework(title: "Vue", logo: "vuedotjs", hex: "4FC08D", category: .server)
    public static let react = Framework(title: "React", logo: "react", hex: "61DAFB", category: .server)
    public static let angular = Framework(title: "Angular", logo: "angular", hex: "DD0031", category: .server)
    public static let svelte = Framework(title: "SvelteKit", logo: "svelte", hex: "FF3E00", category: .server)
    public static let astro = Framework(title: "Astro", logo: "astro", hex: "BC52EE", category: .server)
    public static let remix = Framework(title: "Remix", logo: "remix", hex: nil, category: .server)
    public static let express = Framework(title: "Express", logo: "express", hex: nil, category: .server)
    public static let nest = Framework(title: "NestJS", logo: "nestjs", hex: "E0234E", category: .server)
    public static let storybook = Framework(title: "Storybook", logo: "storybook", hex: "FF4785", category: .server)
    public static let gatsby = Framework(title: "Gatsby", logo: "gatsby", hex: "663399", category: .server)
    public static let webpack = Framework(title: "Webpack", logo: "webpack", hex: "8DD6F9", category: .server)
    public static let django = Framework(title: "Django", logo: "django", hex: "44B78B", category: .server)
    public static let flask = Framework(title: "Flask", logo: "flask", hex: "3BABC3", category: .server)
    public static let fastapi = Framework(title: "FastAPI", logo: "fastapi", hex: "009688", category: .server)
    public static let rails = Framework(title: "Rails", logo: "rubyonrails", hex: "D30001", category: .server)
    public static let laravel = Framework(title: "Laravel", logo: "laravel", hex: "FF2D20", category: .server)
    public static let spring = Framework(title: "Spring", logo: "spring", hex: "6DB33F", category: .server)

    public static let xcode = Framework(title: "Apple app", logo: "appstore", hex: "0D96F6", category: .app)
    public static let swift = Framework(title: "Swift", logo: "swift", hex: "F05138", category: .app)
    public static let flutter = Framework(title: "Flutter", logo: "flutter", hex: "02569B", category: .app)
    public static let android = Framework(title: "Android", logo: "android", hex: "3DDC84", category: .app)
    public static let electron = Framework(title: "Electron", logo: "electron", hex: "47848F", category: .app)
    public static let expo = Framework(title: "Expo", logo: "expo", hex: nil, category: .app)

    public static let node = Framework(title: "Node.js", logo: "nodedotjs", hex: "5FA04E", category: .runtime)
    public static let bun = Framework(title: "Bun", logo: "bun", hex: nil, category: .runtime)
    public static let deno = Framework(title: "Deno", logo: "deno", hex: nil, category: .runtime)
    public static let python = Framework(title: "Python", logo: "python", hex: "3776AB", category: .runtime)
    public static let ruby = Framework(title: "Ruby", logo: "ruby", hex: "CC342D", category: .runtime)
    public static let php = Framework(title: "PHP", logo: "php", hex: "777BB4", category: .runtime)
    public static let go = Framework(title: "Go", logo: "go", hex: "00ADD8", category: .runtime)
    public static let rust = Framework(title: "Rust", logo: "rust", hex: nil, category: .runtime)

    /// Matched against the words of the command line (split on spaces and slashes).
    private static let commandTokens: [(Framework, Set<String>)] = [
        (.postgres, ["postgres", "postmaster"]),
        (.mysql, ["mysqld", "mariadbd"]),
        (.redis, ["redis-server"]),
        (.mongodb, ["mongod"]),
        (.elasticsearch, ["elasticsearch"]),
        (.rabbitmq, ["rabbitmq-server"]),
        // The processes that publish container ports on the Mac: Docker Desktop's, Podman machine's
        // gvproxy, and Lima's (Colima, Rancher Desktop).
        (.docker, ["com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "gvproxy", "limactl"]),
        (.nuxt, ["nuxt", "nuxi"]),
        (.next, ["next", "next-server"]),
        (.astro, ["astro"]),
        (.remix, ["remix", "remix-serve"]),
        (.storybook, ["storybook", "start-storybook"]),
        (.gatsby, ["gatsby"]),
        (.angular, ["ng"]),
        (.nest, ["nest"]),
        (.vite, ["vite"]),
        (.webpack, ["webpack", "webpack-dev-server"]),
        (.django, ["manage.py", "django-admin"]),
        (.flask, ["flask"]),
        (.fastapi, ["uvicorn", "fastapi"]),
        (.rails, ["rails", "puma"]),
        (.laravel, ["artisan"]),
    ]

    /// Checked in order, so meta-frameworks win over the libraries they build on.
    private static let packageDependencies: [(Framework, String)] = [
        (.nuxt, "nuxt"), (.next, "next"), (.astro, "astro"), (.remix, "@remix-run/dev"),
        (.svelte, "@sveltejs/kit"), (.angular, "@angular/core"), (.nest, "@nestjs/core"),
        (.gatsby, "gatsby"), (.storybook, "storybook"), (.vite, "vite"), (.react, "react-scripts"),
        (.express, "express"), (.vue, "vue"), (.react, "react"),
    ]

    /// Matched as a prefix of the lowercased process name (python3.12, node22, ...).
    private static let runtimes: [(Framework, String)] = [
        (.node, "node"), (.bun, "bun"), (.deno, "deno"),
        (.python, "python"), (.ruby, "ruby"), (.php, "php"),
    ]

    public static func detect(command: String, processName: String, dependencies: Set<String>) -> Framework? {
        let tokens = Set(command.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init))

        if let match = commandTokens.first(where: { !$0.1.isDisjoint(with: tokens) }) {
            return match.0
        }
        if let match = packageDependencies.first(where: { dependencies.contains($0.1) }) {
            return match.0
        }
        let name = processName.lowercased()
        if let match = runtimes.first(where: { name.hasPrefix($0.1) }) {
            return match.0
        }
        return nil
    }

    /// The project's framework from the files in it, for a folder that isn't running. Native apps first,
    /// since an Xcode or Android project often carries a package.json for tooling.
    public static func detect(projectAt path: String) -> Framework? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let names = Set((try? fm.contentsOfDirectory(atPath: path)) ?? [])
        func text(_ name: String) -> String { names.contains(name) ? (try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)) ?? "" : "" }

        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .xcode }
        if names.contains("pubspec.yaml") { return .flutter }
        if names.contains("AndroidManifest.xml") || text("build.gradle").contains("com.android") || text("build.gradle.kts").contains("com.android")
            || text("settings.gradle").contains("android") || text("settings.gradle.kts").contains("android") { return .android }

        if names.contains("package.json"),
           let data = try? Data(contentsOf: url.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let deps = ["dependencies", "devDependencies"].reduce(into: Set<String>()) { all, key in
                if let section = json[key] as? [String: Any] { all.formUnion(section.keys) }
            }
            if deps.contains("electron") { return .electron }
            if deps.contains("expo") || deps.contains("react-native") { return .expo }
            if let match = packageDependencies.first(where: { deps.contains($0.1) }) { return match.0 }
            if names.contains("bun.lockb") || names.contains("bun.lock") { return .bun }
            return .node
        }
        if names.contains("Package.swift") { return .swift }

        if names.contains("manage.py") { return .django }
        let python = text("pyproject.toml") + text("requirements.txt") + text("Pipfile")
        if !python.isEmpty {
            let lower = python.lowercased()
            if lower.contains("django") { return .django }
            if lower.contains("fastapi") { return .fastapi }
            if lower.contains("flask") { return .flask }
            return .python
        }
        if names.contains("artisan") || text("composer.json").contains("laravel/framework") { return .laravel }
        if names.contains("composer.json") { return .php }
        if names.contains("Gemfile") { return text("Gemfile").contains("rails") ? .rails : .ruby }
        if names.contains("go.mod") { return .go }
        if names.contains("Cargo.toml") { return .rust }
        if (text("pom.xml") + text("build.gradle") + text("build.gradle.kts")).contains("springframework") { return .spring }
        if names.contains("deno.json") || names.contains("deno.jsonc") { return .deno }
        if names.contains(where: { ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "Dockerfile"].contains($0) }) { return .docker }
        return nil
    }
}

public struct FrameworkLogo: View {
    let framework: Framework?
    var size: CGFloat = 22

    public init(framework: Framework?, size: CGFloat = 22) {
        self.framework = framework
        self.size = size
    }

    public var body: some View {
        Group {
            if let framework, let image = framework.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(framework.color)
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
    }
}
