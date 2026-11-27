import AppKit
import Shared
import SwiftUI

/// What a new project starts from: an empty repository, or a framework's own create command.
enum ProjectTemplate: String, CaseIterable, Identifiable {
    case none, nuxt, next, viteReact, viteVue, viteSvelte, sveltekit, astro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .nuxt: "Nuxt"
        case .next: "Next.js"
        case .viteReact: "Vite + React"
        case .viteVue: "Vite + Vue"
        case .viteSvelte: "Vite + Svelte"
        case .sveltekit: "SvelteKit"
        case .astro: "Astro"
        }
    }

    var framework: Framework? {
        switch self {
        case .none: nil
        case .nuxt: .nuxt
        case .next: .next
        case .viteReact: .react
        case .viteVue: .vue
        case .viteSvelte, .sveltekit: .svelte
        case .astro: .astro
        }
    }

    /// The framework's official create command, run in the parent folder. Flags skip the questions
    /// that have an obvious answer; the ones that remain are answered in Terminal. Where the tool
    /// can't be told which package manager to use, it doesn't install and `install` runs afterwards.
    func createCommand(name: String, packageManager: String) -> String? {
        let name = DevWorkspace.quoted(name)
        switch self {
        case .none: return nil
        case .nuxt: return "npx --yes nuxi@latest init \(name) --packageManager \(packageManager) --gitInit"
        case .next: return "npx --yes create-next-app@latest \(name) --yes --use-\(packageManager)"
        case .viteReact: return "npx --yes create-vite@latest \(name) --template react-ts --no-immediate"
        case .viteVue: return "npx --yes create-vite@latest \(name) --template vue-ts --no-immediate"
        case .viteSvelte: return "npx --yes create-vite@latest \(name) --template svelte-ts --no-immediate"
        case .sveltekit: return "npx --yes sv create \(name) --template minimal --types ts --no-add-ons --no-install"
        case .astro: return "npx --yes create-astro@latest \(name) --template basics --no-install --no-git --yes"
        }
    }
}

/// Command-line tools the new project form offers, found once through a login shell so the
/// user's PATH (Homebrew, ~/.bun, pnpm's home) applies, as it will in Terminal.
@MainActor
final class ProjectTools: ObservableObject {
    static let shared = ProjectTools()
    @Published private(set) var packageManagers = ["npm"]
    @Published private(set) var hasGitHubCLI = false
    private var didLook = false

    func look() {
        guard !didLook else { return }
        didLook = true
        Task {
            let found = await Task.detached { () -> Set<String> in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "for t in npm pnpm yarn bun gh; do command -v $t >/dev/null && echo $t; done"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return [] }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
            }.value
            let managers = ["npm", "pnpm", "yarn", "bun"].filter(found.contains)
            if !managers.isEmpty { packageManagers = managers }
            hasGitHubCLI = found.contains("gh")
        }
    }
}

/// The form behind the panel's + button: a name, where it goes, and optionally a framework to start from.
struct NewProjectForm: View {
    @FocusState private var nameFocused: Bool
    @ObservedObject var store: RepoStore
    /// A page of the menu bar panel (`PanelPage`): its header has the title and the way back, so the
    /// form leaves out its own title and Cancel, and fills the panel's width.
    var isPage = false
    let dismiss: () -> Void
    @ObservedObject private var tools = ProjectTools.shared
    @State private var isCreating = false
    @State private var name = ""
    @State private var folder = ""
    @State private var template = ProjectTemplate(rawValue: UserDefaults.standard.string(forKey: "newProjectTemplate") ?? "") ?? .none
    @State private var packageManager = UserDefaults.standard.string(forKey: "newProjectPackageManager") ?? "npm"
    @State private var openClaude = UserDefaults.standard.object(forKey: "newProjectOpensClaude") as? Bool ?? true
    @State private var gitHub = false
    @State private var error: String?
    @ObservedObject private var agent = AgentStatus.shared

    /// The switch is on and there's an agent to open; without one the switch isn't shown.
    private var opensAgent: Bool { openClaude && agent.info.isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isPage {
                Text("New project").font(.headline)
            }
            // A native form: labels right-aligned in a column, like the system's own dialogs, with its
            // switches as rows below it.
            Form {
                // Labelled by hand: a field in the panels' style is a plain one, which a form doesn't label.
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text("my-app"))
                        .labelsHidden()
                        .onSubmit(create)
                        .focused($nameFocused)
                        .panelField()
                }
                LabeledContent("Location") {
                    HStack {
                        Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Change…", action: chooseFolder).controlSize(.small)
                    }
                }
                LabeledContent("Framework") {
                    HStack(spacing: 6) {
                        Picker("Framework", selection: $template) {
                            ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let framework = template.framework {
                            FrameworkLogo(framework: framework, size: 16)
                        }
                    }
                }
                if template != .none {
                    Picker("Packages", selection: $packageManager) {
                        ForEach(tools.packageManagers, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
            }
            // Below the form, not in it: see `PanelSwitch`.
            VStack(spacing: 6) {
                if agent.info.isInstalled {
                    PanelSwitch("Open \(Agent.current.name) when done", isOn: $openClaude)
                }
                if tools.hasGitHubCLI {
                    PanelSwitch("Create private GitHub repository", isOn: $gitHub)
                }
            }
            // What Create will do, step by step, so nothing that happens after it is a surprise.
            Text(whatHappens)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if !isPage {
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                }
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .prominentButton()
                    .disabled(slug.isEmpty || isCreating)
            }
        }
        .padding(12)
        .frame(width: isPage ? nil : 340)
        .frame(maxWidth: isPage ? .infinity : nil, alignment: .leading)
        .onAppear {
            folder = store.newProjectFolder
            tools.look()
        }
        .focusesWhenShown { nameFocused = true }
        .onChange(of: tools.packageManagers) {
            if !tools.packageManagers.contains(packageManager) { packageManager = tools.packageManagers[0] }
        }
        .onChange(of: name) { error = nil }
    }

    /// The name as a folder and package name: lowercase, dashes for spaces, nothing a package manager rejects.
    private var slug: String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }.map(Character.init))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }

    private func chooseFolder() {
        if let path = store.chooseFolder(message: "Choose where to create the project") {
            folder = path
            store.newProjectFolder = path
        }
    }

    private func create() {
        guard !slug.isEmpty else { return }
        let path = (folder as NSString).appendingPathComponent(slug)
        guard !FileManager.default.fileExists(atPath: path) else {
            error = "\((path as NSString).abbreviatingWithTildeInPath) already exists"
            return
        }
        UserDefaults.standard.set(template.rawValue, forKey: "newProjectTemplate")
        UserDefaults.standard.set(packageManager, forKey: "newProjectPackageManager")
        UserDefaults.standard.set(openClaude, forKey: "newProjectOpensClaude")
        let opening = opensAgent
        let prompt = opening ? store.pendingClaudePrompt : nil
        isCreating = true
        Task {
            error = await store.createProject(at: path, template: template, packageManager: packageManager,
                                              openClaude: opening, prompt: prompt, gitHub: gitHub)
            isCreating = false
            if error == nil { dismiss() }
        }
    }

    private var whatHappens: String {
        // As `RepoStore.createProject` does it: an empty repository is made right here, anything more
        // runs in a terminal, where its progress can be followed.
        let name = slug.isEmpty ? "the folder" : slug
        var steps = template == .none
            ? ["Creates \(name) with an empty git repository"]
            : ["Runs \(template.title)'s setup for \(name)", "installs the packages with \(packageManager)", "makes the first commit"]
        if gitHub { steps.append("creates a private GitHub repository for it") }
        if opensAgent { steps.append("opens \(Agent.current.name) in it") }
        let sentence = steps.count > 1 ? steps.dropLast().joined(separator: ", ") + " and " + steps.last! : steps[0]
        let inTerminal = template != .none || gitHub
        return sentence + (inTerminal
            ? ", in \(agent.terminalName). It shows at the top of the list until it's ready."
            : ". It's added to the list right away.")
    }
}

/// A project being set up in Terminal, or being cloned; it joins the list once its repository exists.
struct SettingUpRow: View {
    let path: String
    var verb = "Setting up"
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(verb) \((path as NSString).lastPathComponent)…")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let cancel {
                IconButton(systemName: "xmark", help: "Stop waiting for it", action: cancel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Usually shown just as the panel comes back from the form: settling in draws the eye to it.
        .revealsGently()
    }
}
