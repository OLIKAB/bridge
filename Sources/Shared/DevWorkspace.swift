import AppKit

/// Starting work on a project: the coding agent in a terminal, and the command that starts its dev server.
/// Which agent and which terminal is up to `CodingAgents` and `Terminals`; this only puts them together.
public enum DevWorkspace {
    /// Opens a terminal in the project with the coding agent running. A script file instead of scripting
    /// the terminal, so Terminal needs no Automation permission. A `prompt` such as `/monday` is sent
    /// as the agent's first message, which runs a skill just like typing it.
    public static func openAgentInTerminal(_ path: String, prompt: String? = nil) {
        // One file per prompt, so opening two in a row doesn't overwrite the first before the terminal reads it.
        let suffix = prompt.map { "-" + $0.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined().prefix(40) } ?? ""
        runInTerminal(agentCommand(prompt: prompt), in: path, kind: "\(CodingAgents.current.commandName)\(suffix)")
    }

    /// The shell command that starts the coding agent, with the browser when that's turned on and it can.
    public static func agentCommand(prompt: String? = nil) -> String {
        let agent = CodingAgents.current
        var options = AgentOptions.fromDefaults
        options.browser = options.browser && agent.has(.browser)
        return agent.interactiveCommand(prompt: agent.has(.initialPrompt) ? prompt : nil, options: options)
    }

    /// When set in the app's defaults, the agent starts with the browser (Claude's `--chrome`).
    /// Read here rather than passed in, so every agent button and skill chip follows the one toggle.
    /// The key is from when only Claude was supported, kept so the setting carries over.
    public static let agentBrowserKey = "claudeWithChrome"

    /// When set in the app's defaults, Terminal windows opened from here use the "Clear Dark" profile
    /// instead of Terminal's default one. Read by `AppleTerminal`, so every button follows it.
    public static let darkTerminalKey = "darkTerminal"

    /// When set (or never set) in the app's defaults, Rex terminals for a project split its session's window.
    public static let rexSplitKey = "rexSplit"

    /// Opens the terminal in a folder (or a file's folder), the way that terminal does it best
    /// (`TerminalApp.openShell`).
    public static func openTerminal(_ path: String) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        let folder = isFolder.boolValue ? path : (path as NSString).deletingLastPathComponent
        Terminals.current?.openShell(in: folder)
    }

    /// Runs a command in a new terminal tab or window, for scripts that need a real terminal (curses
    /// screens, prompts). The tab stays in the project with a shell once the command ends.
    /// `rexSession` overrides the session the path would get in terminals that group tabs (Rex), for a
    /// folder that isn't the project's yet.
    public static func runInTerminal(_ command: String, in path: String, kind: String = "start", rexSession: String? = nil) {
        guard let terminal = Terminals.current else { return }
        let script = """
            #!/bin/zsh -l
            cd \(quoted(path)) || exit 1
            \(terminal.scriptPrelude())
            clear
            \(command)
            exec ${SHELL:-/bin/zsh} -l

            """
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge/Terminal", isDirectory: true)
        // "/" has no folder name to go by, and a slash in the file name would make it a path.
        let name = path == "/" ? "root" : (path as NSString).lastPathComponent
        let file = folder.appendingPathComponent("\(name)-\(kind).command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return
        }
        terminal.run(scriptAt: file, in: path, session: rexSession)
    }

    /// The project's dev command: a package.json script with the package manager from its lockfile
    /// (installing dependencies first when they're missing), or a common default.
    /// `webOnly` leaves out commands that usually aren't a web server, like `cargo run`.
    public static func startCommand(in path: String, webOnly: Bool = false) -> String? {
        start(in: path, webOnly: webOnly)?.command
    }

    /// The dev command and the folder it runs from (nil for the root). A project with nothing to start at
    /// its root, like a repo with the app in `nuxt/frontend`, gets the nearest subfolder that has one.
    /// `folder` is the user's pick among several apps; it's ignored once that folder no longer has a command.
    public static func start(in path: String, webOnly: Bool = false, folder: String? = nil) -> (folder: String?, command: String)? {
        plan(in: path, webOnly: webOnly, folder: folder).map { ($0.folder, $0.command) }
    }

    /// How to start a project, and for one that has to be built before it can start (a Rust or Spring server,
    /// a Node app whose `start` serves `dist/`) the command that builds it and whether that was done.
    public struct StartPlan: Equatable, Sendable {
        /// The subfolder the app is in, nil for the root.
        public let folder: String?
        public let command: String
        /// Runs from the same folder as `command`, with the same install check before it.
        public let build: String?
        /// Whether what `build` makes is there. Always true without a build step.
        public let isBuilt: Bool
    }

    /// `start(in:)` with the build step (`StartPlan`).
    public static func plan(in path: String, webOnly: Bool = false, folder: String? = nil) -> StartPlan? {
        func plan(_ folder: String?, _ app: App) -> StartPlan {
            let root = folder.map { (path as NSString).appendingPathComponent($0) } ?? path
            let cd = folder.map { "cd \(quoted($0)) && " } ?? ""
            return StartPlan(folder: folder, command: cd + app.command, build: app.build.map { cd + $0 },
                             isBuilt: app.build == nil || isBuilt(app.outputs, in: root, repoRoot: path))
        }
        if let folder, !folder.isEmpty, let app = app(atRoot: (path as NSString).appendingPathComponent(folder), repoRoot: path, webOnly: true) {
            return plan(folder, app)
        }
        if let app = app(atRoot: path, repoRoot: path, webOnly: webOnly) { return plan(nil, app) }
        guard let found = appFolders(in: path, stopAtFirstLevel: true).first,
              let app = app(atRoot: (path as NSString).appendingPathComponent(found.folder), repoRoot: path, webOnly: true) else { return nil }
        return plan(found.folder, app)
    }

    /// A build's output in the app's folder or one above it in the repository (a Cargo workspace keeps `target` at its root).
    private static func isBuilt(_ outputs: [String], in folder: String, repoRoot: String) -> Bool {
        let fm = FileManager.default
        var folder = (folder as NSString).standardizingPath
        let root = (repoRoot as NSString).standardizingPath
        while true {
            if outputs.contains(where: { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }) { return true }
            guard folder.hasPrefix(root + "/") else { return false }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// What a folder's app is started with, and built with when it has to be built first: `outputs` are the
    /// folders the build makes, any of which counts as built.
    private struct App {
        var command: String
        var build: String?
        var outputs: [String] = []
    }

    /// Subfolders (a few levels down) with a dev command we recognize, for repos with several apps.
    /// Shallowest first, and on the same level names that usually hold the app. An app folder isn't searched
    /// further, and dependency and build folders are skipped, as they're full of package.json files.
    /// `stopAtFirstLevel` ends the search at the first level with a match, when only the best one is needed.
    public static func appFolders(in path: String, maxDepth: Int = 3, stopAtFirstLevel: Bool = false) -> [(folder: String, command: String)] {
        let fm = FileManager.default
        let skipped: Set<String> = ["node_modules", "vendor", "dist", "build", "out", "target", "venv", "env", "__pycache__", "Pods", "DerivedData",
                                    "bin", "obj", "_build", "deps"]
        let preferred = ["frontend", "web", "app", "client", "site", "www"]
        func rank(_ folder: String) -> Int { preferred.firstIndex(of: (folder as NSString).lastPathComponent.lowercased()) ?? preferred.count }
        var apps: [(folder: String, command: String)] = []
        var level = [""]
        for _ in 0..<maxDepth {
            var next: [String] = []
            for relative in level {
                let full = relative.isEmpty ? path : (path as NSString).appendingPathComponent(relative)
                let children = ((try? fm.contentsOfDirectory(atPath: full)) ?? []).filter { name in
                    var isDirectory: ObjCBool = false
                    return !name.hasPrefix(".") && !skipped.contains(name)
                        && fm.fileExists(atPath: (full as NSString).appendingPathComponent(name), isDirectory: &isDirectory) && isDirectory.boolValue
                }
                next += children.map { relative.isEmpty ? $0 : (relative as NSString).appendingPathComponent($0) }
            }
            var found: [(folder: String, command: String)] = []
            next = next.filter { folder in
                guard let command = startCommand(atRoot: (path as NSString).appendingPathComponent(folder), repoRoot: path, webOnly: true) else { return true }
                found.append((folder, command))
                return false
            }
            apps += found.sorted { (rank($0.folder), $0.folder.lowercased()) < (rank($1.folder), $1.folder.lowercased()) }
            if stopAtFirstLevel && !apps.isEmpty { break }
            level = next
        }
        return apps
    }

    private static func startCommand(atRoot path: String, repoRoot: String, webOnly: Bool) -> String? {
        app(atRoot: path, repoRoot: repoRoot, webOnly: webOnly)?.command
    }

    /// `repoRoot` is the folder the search started from: an app in a subfolder may be installed from there (workspaces).
    private static func app(atRoot path: String, repoRoot: String, webOnly: Bool) -> App? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(name)) }
        func text(_ name: String) -> String { (try? String(contentsOfFile: (path as NSString).appendingPathComponent(name), encoding: .utf8)) ?? "" }

        if let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any],
           let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) {
            let setup = nodeSetup(app: path, repoRoot: repoRoot)
            let manager = setup.manager
            let run = manager == "yarn" ? "yarn \(script)" : "\(manager) run \(script)"
            // In a workspace the lockfile and node_modules are in an ancestor folder; the install runs from there
            // (in a subshell, so the start command still runs in the app's folder).
            let up = setup.levelsUp == 0 ? "" : String(repeating: "../", count: setup.levelsUp)
            // pnpm 11 and later stop the install on dependencies' build scripts it wasn't told to allow (esbuild's, in
            // every Vite project); as a warning again, the install finishes and the scripts still don't run.
            // On a reinstall, pnpm, bun and yarn 1 have to be told to look at node_modules: they trust their own
            // record of the last install and answer "Already up to date" over a package that's gone. npm looks anyway.
            let force = "${\(reinstallVariable):+\(manager == "yarn" ? (setup.berry ? "" : "--check-files") : "--force")}"
            let installCommand = switch manager {
            case "pnpm": "pnpm install --config.strict-dep-builds=false \(force)"
            case "npm": "npm install"
            case "yarn" where setup.berry: "yarn install"
            default: "\(manager) install \(force)"
            }
            let installIn = setup.levelsUp == 0 ? installCommand : "(cd \(up) && \(installCommand))"
            let install = "\(say("Dependencies are missing or out of date, running \(manager) install (this can take a minute)…")) && \(installIn)"
            let current = dependenciesCurrent(manager: manager, berry: setup.berry, prefix: up, appPackageJSON: setup.levelsUp > 0,
                                              has: { fm.fileExists(atPath: (setup.folder as NSString).appendingPathComponent($0)) })
            let versionFile = [path, setup.folder].contains { folder in
                [".nvmrc", ".node-version"].contains { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
            }
            let prepare = (versionFile ? nodeVersion + " && " : "") + packageManagerFallback(manager) + unlessReinstalling(current, else: install) + " && "
            var app = App(command: prepare + announced(run))
            // A `start` that serves what `build` made (next start, node dist/server.js) fails on a fresh clone with
            // "Cannot find module", which no install fixes. A `start` that is a dev server itself (react-scripts start) has no build step.
            if script != "dev", scripts["build"] != nil, let outputs = nodeOutputs(serving: scripts[script] as? String ?? "") {
                app.build = prepare + announced(manager == "yarn" ? "yarn build" : "\(manager) run build")
                app.outputs = outputs
            }
            return app
        }
        if has("manage.py") {
            let python = pythonSetup(in: path)
            return App(command: python.setup + announced("\(python.run) manage.py runserver"))
        }
        if has("bin/rails") {
            let bundle = has("Gemfile") ? unlessReinstalling("bundle check >/dev/null 2>&1",
                                                            else: "\(say("Gems are missing or out of date, running bundle install…")) && bundle install") + " && " : ""
            return App(command: bundle + announced("bin/rails server"))
        }
        if has("artisan") {
            var setup = ""
            if has("composer.json") {
                let lockCovered = has("composer.lock") ? " && [ $(stat -f %m composer.lock) -le $(stat -f %m vendor/composer/installed.json) ]" : ""
                setup += unlessReinstalling("{ [ -e vendor/autoload.php ]\(lockCovered); }",
                                            else: "\(say("Dependencies are missing or out of date, running composer install…")) && composer install") + " && "
            }
            // Laravel answers every request with an error until there's a .env with an APP_KEY; its README's first steps.
            if has(".env.example") {
                setup += "{ [ -e .env ] || { \(say("Creating .env from .env.example")) && cp .env.example .env && php artisan key:generate; }; } && "
            }
            return App(command: setup + announced("php artisan serve"))
        }
        // Compiled servers, before compose: their compose file is usually the database beside them, not the app.
        // Each tool fetches its dependencies and compiles as part of running; the build step only does that
        // without starting, so the first long compile is something the user asked for and watched, not a stuck start.
        if has("mix.exs"), text("mix.exs").contains(":phoenix") {
            let deps = "mix deps.get && "
            return App(command: deps + announced("mix phx.server"), build: deps + announced("mix compile"), outputs: ["_build/dev"])
        }
        if has("pom.xml"), text("pom.xml").contains("spring-boot") {
            let maven = has("mvnw") ? "sh ./mvnw" : "mvn"
            return App(command: announced("\(maven) spring-boot:run"), build: announced("\(maven) compile"), outputs: ["target/classes"])
        }
        if let gradle = ["build.gradle.kts", "build.gradle"].first(where: has).map(text),
           let task = gradle.contains("org.springframework.boot") ? "bootRun" : gradle.contains("io.ktor") ? "run" : nil {
            let wrapper = has("gradlew") ? "sh ./gradlew" : "gradle"
            return App(command: announced("\(wrapper) \(task)"), build: announced("\(wrapper) classes"), outputs: ["build/classes"])
        }
        if let project = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).first(where: { $0.hasSuffix(".csproj") }),
           text(project).contains("Microsoft.NET.Sdk.Web") {
            return App(command: announced("dotnet run"), build: announced("dotnet build"), outputs: ["bin/Debug"])
        }
        let cargo = has("Cargo.toml") ? text("Cargo.toml") : nil
        if let cargo, !webOnly || cargo.range(of: #"(?m)^\s*(axum|actix-web|rocket|warp|poem|leptos|salvo|tide|loco-rs)\s*="#, options: .regularExpression) != nil {
            return App(command: announced("cargo run"), build: announced("cargo build"), outputs: ["target/debug"])
        }
        let swiftPackage = has("Package.swift") ? text("Package.swift") : nil
        if let swiftPackage, !webOnly || ["vapor/vapor", "hummingbird-project/hummingbird"].contains(where: swiftPackage.contains) {
            return App(command: announced("swift run"), build: announced("swift build"), outputs: [".build/debug"])
        }
        // Go compiles in seconds and keeps no build folder to tell a build by, so it starts without a build step.
        if has("go.mod"), !webOnly
            || ["gin-gonic/gin", "labstack/echo", "gofiber/fiber", "go-chi/chi", "gorilla/mux", "beego"].contains(where: text("go.mod").contains)
            || text("main.go").contains("ListenAndServe") {
            return App(command: announced("go run ."))
        }
        if has("docker-compose.yml") || has("compose.yaml") || has("compose.yml") {
            return App(command: dockerRunning + " && " + announced("docker compose up"))
        }
        return nil
    }

    /// What a Node app's `start` script serves, when it's a build's output rather than a dev server:
    /// nil for "vite", "react-scripts start", "nodemon src" and the like, which need no build first.
    private static func nodeOutputs(serving script: String) -> [String]? {
        let script = script.lowercased()
        if script.contains("next start") { return [".next"] }
        if script.contains("nuxt start") || script.contains("nuxt preview") || script.contains(".output/") { return [".output"] }
        if script.contains("vite preview") || script.contains("astro preview") { return ["dist"] }
        if script.contains("remix-serve") || script.contains("react-router-serve") { return ["build"] }
        if script.contains("ng serve") || script.contains("--watch") { return nil }
        // node dist/index.js, serve -s build, http-server ./out
        guard let range = script.range(of: #"(^|[\s/'"])(dist|build|out|lib)/"#, options: .regularExpression)
                ?? script.range(of: #"\s(\./)?(dist|build|out)(\s|$)"#, options: .regularExpression) else { return nil }
        let folder = script[range].trimmingCharacters(in: CharacterSet(charactersIn: " ./'\""))
        return [folder]
    }

    /// The environment variable that makes a start command install its dependencies even when they look current.
    /// Bridge sets it to try again after a start failed on something missing (`DevServer.start(_:reinstall:)`);
    /// its presence in a command also says the command knows how to install.
    public static let reinstallVariable = "BRIDGE_REINSTALL"

    /// `check` decides whether `install` is needed, unless a reinstall was asked for.
    private static func unlessReinstalling(_ check: String, else install: String) -> String {
        "{ { [ -z \"$\(reinstallVariable)\" ] && \(check); } || { \(install); }; }"
    }

    /// Switches to the Node version a project names in .nvmrc or .node-version, installing it if needed, with fnm
    /// or nvm. Both are usually set up in .zshrc, which a login shell running a command doesn't read, so the
    /// project got whatever Node was first on the path. Without either, nothing changes.
    private static let nodeVersion = """
        { if command -v fnm >/dev/null; then eval "$(fnm env --shell zsh)" && fnm use --install-if-missing --silent-if-unchanged; \
        elif [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && { nvm use >/dev/null 2>&1 || nvm install; }; \
        fi; true; }
        """

    /// A project on pnpm, yarn or bun shouldn't need it installed first: without it, the command goes through
    /// Corepack (which comes with Node and fetches the version package.json asks for), or npx where it's gone.
    private static func packageManagerFallback(_ manager: String) -> String {
        guard manager != "npm" else { return "" }
        return "{ command -v \(manager) >/dev/null || \(manager)() { if command -v corepack >/dev/null; then COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack \(manager) \"$@\"; else npx --yes \(manager) \"$@\"; fi; }; } && "
    }

    /// Docker Desktop opened and waited for (up to two minutes) when it isn't running, rather than compose
    /// failing at once with "Cannot connect to the Docker daemon".
    private static let dockerRunning = """
        { docker info >/dev/null 2>&1 || { open -ga Docker 2>/dev/null; \(say("Waiting for Docker to start…")); \
        n=0; until docker info >/dev/null 2>&1 || [ $n -ge 120 ]; do sleep 1; n=$((n+1)); done; }; }
        """

    /// How a Django project's Python is set up and run: uv and Poetry install from their lockfiles themselves;
    /// a requirements.txt gets a virtual environment (the project's own .venv or venv, or a new .venv) with the
    /// requirements installed whenever they're newer than the last install. Anything else runs on an existing
    /// virtual environment, or the system's python3.
    private static func pythonSetup(in path: String) -> (setup: String, run: String) {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(name)) }
        if has("uv.lock") { return ("", "uv run python") }
        if has("poetry.lock") { return ("poetry install --quiet && ", "poetry run python") }
        let venv = [".venv", "venv"].first { has("\($0)/pyvenv.cfg") }
        guard has("requirements.txt") else { return ("", venv.map { "\($0)/bin/python" } ?? "python3") }
        let env = venv ?? ".venv"
        let marker = "\(env)/.bridge-installed"
        // A virtual environment points at the Python it was made with, which a Homebrew upgrade can remove.
        let works = "{ [ -x \(env)/bin/python ] && \(env)/bin/python -c '' 2>/dev/null; }"
        let current = "{ \(works) && [ -e \(marker) ] && [ $(stat -f %m requirements.txt) -le $(stat -f %m \(marker)) ]; }"
        let install = "\(say("Setting up \(env) and installing requirements.txt (this can take a minute)…")) && { \(works) || python3 -m venv --clear \(env); } && \(env)/bin/python -m pip install -r requirements.txt && touch \(marker)"
        return (unlessReinstalling(current, else: install) + " && ", "\(env)/bin/python")
    }

    /// A shell test for whether node_modules is a finished install of the current package.json and lockfile.
    /// A bare node_modules folder isn't enough: a fresh clone has none, and an interrupted install leaves one
    /// without the tools (nuxt, vite, concurrently …). Each package manager writes a marker file when it finishes.
    /// `prefix` leads from the app's folder to the folder that was installed in (empty, or "../../"), where the marker,
    /// the lockfile and the root package.json are; `appPackageJSON` adds the app's own package.json to the check then.
    /// `has` looks in the install folder.
    private static func dependenciesCurrent(manager: String, berry: Bool, prefix: String, appPackageJSON: Bool, has: (String) -> Bool) -> String {
        let marker: String
        let lockfile: String
        switch manager {
        case "pnpm": (marker, lockfile) = ("node_modules/.modules.yaml", "pnpm-lock.yaml")
        case "yarn": (marker, lockfile) = (berry ? "node_modules/.yarn-state.yml" : "node_modules/.yarn-integrity", "yarn.lock")
        case "npm": (marker, lockfile) = ("node_modules/.package-lock.json", "package-lock.json")
        // bun has no marker, but its install takes well under a second when nothing changed.
        default: return "false"
        }
        let mtime = { (file: String) in "$(stat -f %m \(file))" }
        let marked = prefix + marker
        // The install rewrites the lockfile in the same moment as the marker, hence the slack.
        let lockfileCovered = has(lockfile) ? " && [ \(mtime(prefix + lockfile)) -le $(( \(mtime(marked)) + 2 )) ]" : ""
        let appCovered = appPackageJSON ? " && [ \(mtime("package.json")) -le \(mtime(marked)) ]" : ""
        return "{ [ -e \(marked) ] && [ \(mtime(prefix + "package.json")) -le \(mtime(marked)) ]\(appCovered)\(lockfileCovered); }"
    }

    /// Which package manager an app uses and where it installs from. The `packageManager` field in package.json
    /// (like "pnpm@9.1.0") comes first, in the app's folder and then each folder above it; without one, the nearest
    /// folder with a lockfile decides, so an app with a lockfile of its own isn't taken over by one in the root.
    /// Nothing is searched above `repoRoot`. The install folder is the nearest one with the manager's lockfile
    /// (or the one with the field, or the app itself, when there is none); npm is the last resort.
    private static func nodeSetup(app: String, repoRoot: String) -> (manager: String, folder: String, levelsUp: Int, berry: Bool) {
        let fm = FileManager.default
        let app = (app as NSString).standardizingPath
        let root = (repoRoot as NSString).standardizingPath
        var folders = [app]
        if app.hasPrefix(root + "/") {
            var folder = app
            while folder != root {
                folder = (folder as NSString).deletingLastPathComponent
                folders.append(folder)
            }
        }
        func has(_ name: String, in folder: String) -> Bool { fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }
        let lockfiles: [(manager: String, names: [String])] = [("pnpm", ["pnpm-lock.yaml"]), ("yarn", ["yarn.lock"]), ("bun", ["bun.lockb", "bun.lock"]), ("npm", ["package-lock.json"])]
        func result(_ manager: String, _ folder: String, berry: Bool) -> (manager: String, folder: String, levelsUp: Int, berry: Bool) {
            (manager, folder, folders.firstIndex(of: folder) ?? 0, berry)
        }

        for folder in folders {
            guard let data = fm.contents(atPath: (folder as NSString).appendingPathComponent("package.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let field = json["packageManager"] as? String else { continue }
            let parts = field.split(separator: "@", maxSplits: 1).map(String.init)
            guard let manager = parts.first, lockfiles.contains(where: { $0.manager == manager }) else { continue }
            let names = lockfiles.first { $0.manager == manager }?.names ?? []
            let installFolder = folders.first { folder in names.contains { has($0, in: folder) } } ?? folder
            let major = parts.count > 1 ? Int(parts[1].prefix { $0.isNumber }) : nil
            return result(manager, installFolder, berry: manager == "yarn" && ((major ?? 1) >= 2 || has(".yarnrc.yml", in: installFolder)))
        }
        for folder in folders {
            if let manager = lockfiles.first(where: { $0.names.contains { has($0, in: folder) } })?.manager {
                return result(manager, folder, berry: manager == "yarn" && has(".yarnrc.yml", in: folder))
            }
        }
        return result("npm", app, berry: false)
    }

    /// A script in the project folder that could start it, for projects with no command we recognize
    /// (like a `start.py` that starts several services). Likely names first.
    public static func startScripts(in path: String) -> [String] {
        let fm = FileManager.default
        let extensions: Set<String> = ["py", "sh", "zsh", "bash", "command", "js", "mjs"]
        let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            let full = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard !name.hasPrefix("."), fm.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return extensions.contains(ext) || (ext.isEmpty && fm.isExecutableFile(atPath: full))
        }
        let likely = ["start", "run", "dev", "serve", "up", "launch"]
        func rank(_ name: String) -> Int {
            let base = (name as NSString).deletingPathExtension.lowercased()
            return likely.firstIndex(where: { base.hasPrefix($0) }) ?? likely.count
        }
        return names.sorted { (rank($0), $0.lowercased()) < (rank($1), $1.lowercased()) }
    }

    /// How to run a script found by `startScripts`, and whether it looks like it needs a terminal.
    /// Python scripts with inline dependencies (`# /// script`) or in a uv project run with uv.
    public static func command(forScript name: String, in path: String) -> (command: String, needsTerminal: Bool) {
        let fm = FileManager.default
        let full = (path as NSString).appendingPathComponent(name)
        let text = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
        let file = quoted(name)
        let local = fm.isExecutableFile(atPath: full) ? "./" + file : nil
        let command: String
        switch (name as NSString).pathExtension.lowercased() {
        case "py":
            let uv = text.contains("# /// script") || fm.fileExists(atPath: (path as NSString).appendingPathComponent("uv.lock"))
            command = uv ? "uv run \(file)" : "python3 \(file)"
        case "js", "mjs": command = "node \(file)"
        case "zsh": command = local ?? "zsh \(file)"
        case "bash": command = local ?? "bash \(file)"
        case "sh", "command": command = local ?? "sh \(file)"
        default: command = local ?? "./" + file
        }
        // Full-screen and interactive scripts can't run with their output going to a log file.
        let interactive = ["import curses", "from curses", "textual", "input(", "\nread "]
        return (command, interactive.contains { text.contains($0) })
    }

    /// A command that first prints itself, as the detected ones do.
    public static func announced(_ command: String) -> String {
        "\(say(command)) && \(command)"
    }

    public static func quoted(_ text: String) -> String {
        guard text.contains(where: { !($0.isLetter || $0.isNumber || "._-/".contains($0)) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell command that prints a status line, so a silent install or build doesn't look stuck.
    public static func say(_ message: String) -> String {
        let quoted = "\u{1B}[2m▸ \(message)\u{1B}[0m".replacingOccurrences(of: "'", with: "'\\''")
        return "printf '%s\\n' '\(quoted)'"
    }
}
