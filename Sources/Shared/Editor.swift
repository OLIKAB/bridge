import AppKit
import SwiftUI

/// Where an app is installed, as NSWorkspace says, remembered for half a minute. Menus and rows ask
/// for every editor and terminal each time they're drawn (a row's context menu is built with the
/// row), and each answer is a Launch Services lookup: a list of repositories redrawn spent a good
/// part of its time there. An app installed or removed shows within half a minute.
public enum InstalledApps {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (url: URL?, at: Date)] = [:]

    public static func url(for bundleId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[bundleId], Date().timeIntervalSince(entry.at) < 30 { return entry.url }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        cache[bundleId] = (url, Date())
        return url
    }
}

public struct Editor: Identifiable {
    public let name: String
    public let bundleId: String
    public var id: String { bundleId }

    /// Apps that open a folder as it is. Terminals aren't listed here: they come from `Terminals`.
    /// Only the installed ones show, so the list can be long. JetBrains IDEs each have their own id
    /// (and Community editions another), so every one that opens a project folder is listed.
    public static let all = [
        Editor(name: "Finder", bundleId: "com.apple.finder"),
        Editor(name: "VS Code", bundleId: "com.microsoft.VSCode"),
        Editor(name: "VS Code Insiders", bundleId: "com.microsoft.VSCodeInsiders"),
        Editor(name: "VSCodium", bundleId: "com.vscodium"),
        Editor(name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", bundleId: "com.exafunction.windsurf"),
        Editor(name: "Zed", bundleId: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleId: "com.apple.dt.Xcode"),
        Editor(name: "Sublime Text", bundleId: "com.sublimetext.4"),
        Editor(name: "Nova", bundleId: "com.panic.Nova"),
        Editor(name: "IntelliJ IDEA", bundleId: "com.jetbrains.intellij"),
        Editor(name: "IntelliJ IDEA CE", bundleId: "com.jetbrains.intellij.ce"),
        Editor(name: "WebStorm", bundleId: "com.jetbrains.WebStorm"),
        Editor(name: "PyCharm", bundleId: "com.jetbrains.pycharm"),
        Editor(name: "PyCharm CE", bundleId: "com.jetbrains.pycharm.ce"),
        Editor(name: "PhpStorm", bundleId: "com.jetbrains.PhpStorm"),
        Editor(name: "GoLand", bundleId: "com.jetbrains.goland"),
        Editor(name: "RubyMine", bundleId: "com.jetbrains.rubymine"),
        Editor(name: "RustRover", bundleId: "com.jetbrains.rustrover"),
        Editor(name: "Android Studio", bundleId: "com.google.android.studio"),
    ]

    /// Every app a folder can be opened in, the same list wherever "Open in" shows: Finder, the
    /// editors and every installed terminal, Bridge's own terminal first among them. Only listing the
    /// terminal Bridge runs agents in left out the others.
    public static var installed: [Editor] {
        let editors = all.filter { InstalledApps.url(for: $0.bundleId) != nil }
        let current = Terminals.current?.bundleId
        let terminals = Terminals.installed
            .sorted { ($0.bundleId == current ? 0 : 1) < ($1.bundleId == current ? 0 : 1) }
            .map { Editor(name: $0.name, bundleId: $0.bundleId) }
        return editors + terminals
    }

    /// The apps a single file opens in: editors only, as Finder and terminals would only open its folder.
    public static var forFiles: [Editor] {
        installed.filter { $0.name != "Finder" && !$0.isTerminal }
    }

    public var isTerminal: Bool { Terminals.contains(bundleId: bundleId) }

    /// The app's own icon, from where it's installed.
    public var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    public func open(_ path: String) {
        if isTerminal { return DevWorkspace.openTerminal(path, in: Terminals.all.first { $0.bundleId == bundleId }) }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Pops a native menu at the mouse, so the folder button can look like the other icon buttons.
public enum EditorMenu {
    private final class Item: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func run() { handler() }
    }

    @MainActor public static func show(for path: String) {
        let menu = NSMenu()
        // A file goes to the editors only; a folder to the whole "Open in" list.
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        for editor in isFolder.boolValue ? Editor.installed : Editor.forFiles {
            menu.addItem(Item("Open in \(editor.name)") { editor.open(path) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Quiet monochrome icon button; it only takes on its tint while hovered.
public struct IconButton: View {
    let systemName: String
    /// Drawn instead of the symbol, for logos SF Symbols doesn't have.
    var image: NSImage?
    let help: String
    var hoverTint: Color = .primary
    /// Slightly stronger ink when the icon represents an "on" state (e.g. a favorite).
    var isActive = false
    /// Drawn in `hoverTint` on a faint tinted background, for a button that will do something
    /// out of the ordinary when clicked (e.g. run a prompt).
    var isHighlighted = false
    /// A small image in the lower right corner of `image`, for a variant of the usual action.
    var badge: NSImage?
    let action: () -> Void

    @State private var hovering = false

    public init(systemName: String, help: String, hoverTint: Color = .primary, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.hoverTint = hoverTint
        self.isActive = isActive
        self.action = action
    }

    public init(image: NSImage, help: String, hoverTint: Color = .primary, isHighlighted: Bool = false, badge: NSImage? = nil, action: @escaping () -> Void) {
        self.init(systemName: "", help: help, hoverTint: hoverTint, action: action)
        self.image = image
        self.isHighlighted = isHighlighted
        self.badge = badge
    }

    /// An icon button with no bezel at rest and the panels' shared fill under the pointer and while
    /// pressed (`PanelButtonStyle`); the glyph takes `hoverTint`. A highlighted one keeps the tint.
    public var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    // App icons have a margin around the artwork, so they need more room than a glyph.
                    let size: CGFloat = image.isTemplate ? 13 : 17
                    Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge {
                                Image(nsImage: badge).resizable().scaledToFit().frame(width: 10, height: 10)
                                    .offset(x: 4, y: 3)
                            }
                        }
                } else {
                    // A button whose symbol changes with what it does (play to stop as a server starts)
                    // turns one into the other as macOS's own symbols do, so the click shows it was taken
                    // while the work behind it takes its time. Scoped to the glyph, in its fixed frame,
                    // so nothing around it is animated. Reduce Motion makes it a plain crossfade.
                    Image(systemName: systemName)
                        .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                        .animation(PanelMotion.arrive, value: systemName)
                }
            }
                .foregroundStyle(hovering || isHighlighted ? AnyShapeStyle(hoverTint) : isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.panel)
        .onHover { hovering = $0 }
        .panelTooltip(help)
        // An icon has no words for VoiceOver; the tooltip's first line says what the button does.
        .accessibilityLabel(String(help.split(separator: "\n").first ?? Substring(help)))
    }
}

public enum Logo {
    @MainActor private static var bundledCache: [String: NSImage] = [:]

    /// A Simple Icons logo from the app's `Logos` folder (`Resources/Logos/<slug>.svg`) as a template
    /// image, or the SF Symbol `fallback` when it isn't there (`swift run` has no bundle to look in).
    @MainActor public static func bundled(_ slug: String, fallback: String) -> NSImage {
        if let cached = bundledCache[slug] { return cached }
        if let url = Bundle.main.url(forResource: slug, withExtension: "svg", subdirectory: "Logos"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            bundledCache[slug] = image
            return image
        }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage()
    }

    /// Google Chrome's own app icon, or nil when Chrome isn't installed.
    @MainActor public static let chrome: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.google.Chrome")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    /// The Claude mark, from Simple Icons, as a template image that takes the surrounding color.
    @MainActor public static let claude: NSImage = {
        let svg = #"<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/></svg>"#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// The GitHub mark, from Simple Icons, as a template image like `claude`, so a button that goes to
    /// GitHub says where it goes rather than just "a web page".
    @MainActor public static let github: NSImage = {
        let svg = #"<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>"#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
