import Shared
import SwiftUI
import UniformTypeIdentifiers

/// Named groups shared by the Repos and Servers tabs, like a client or a product with several repositories.
/// A repository is put in a group by hand; a server is in the group of the repository it runs from (its
/// project folder is in it), unless it was put in another group itself, which is how a database or a
/// Docker container that belongs to no repository gets into one.
///
/// Kept here rather than on `Repository` because the Servers tab needs every repository's group without
/// knowing about the repositories. A group exists while something is in it, like a tab group in Chrome,
/// so there's no empty group to find and delete.
@MainActor
final class RepoGroups: ObservableObject {
    static let shared = RepoGroups()

    /// In the order they're shown.
    @Published private(set) var names: [String] = UserDefaults.standard.stringArray(forKey: "groups") ?? [] {
        didSet { UserDefaults.standard.set(names, forKey: "groups") }
    }
    /// Repository path → group.
    @Published private(set) var repos: [String: String] = UserDefaults.standard.dictionary(forKey: "repositoryGroups") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(repos, forKey: "repositoryGroups") }
    }
    /// Server `favoriteKey` → group, for servers moved out of their repository's group. An empty
    /// name keeps a server out of the group its repository is in.
    @Published private(set) var servers: [String: String] = UserDefaults.standard.dictionary(forKey: "servers.groups") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(servers, forKey: "servers.groups") }
    }
    /// Collapsed sections, separately per tab, since a collapsed client in Repos says nothing about its servers.
    @Published private(set) var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups") }
    }

    /// Off shows the lists without sections, as before groups, while keeping every group as it is.
    /// One setting for both tabs and the main window, since they show the same groups.
    @Published var showsGroups = UserDefaults.standard.object(forKey: "showGroups") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsGroups, forKey: "showGroups") }
    }

    private init() {}

    // MARK: Membership

    func group(ofRepo path: String) -> String? { repos[path] }

    func setGroup(_ name: String?, ofRepo path: String) {
        let name = name.flatMap(Self.cleaned)
        if let name, !names.contains(name) { names.append(name) }
        repos[path] = name
        prune()
    }

    /// The group a server is in: its own, or else that of the repository its project folder is in.
    func group(ofServer key: String, projectRoot: String?) -> String? {
        if let own = servers[key] { return own.isEmpty ? nil : own }
        return inheritedGroup(projectRoot: projectRoot)
    }

    /// The group of the deepest repository containing `projectRoot`, so a server in a monorepo's
    /// `frontend` folder is in the monorepo's group.
    func inheritedGroup(projectRoot: String?) -> String? {
        guard let root = projectRoot, root != "/" else { return nil }
        return repos
            .filter { root == $0.key || root.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    func setGroup(_ name: String?, ofServer key: String, projectRoot: String?) {
        let name = name.flatMap(Self.cleaned)
        if let name, !names.contains(name) { names.append(name) }
        // Only what differs from the repository's group is stored, so moving the repository later takes the server along.
        servers[key] = name == inheritedGroup(projectRoot: projectRoot) ? nil : name ?? ""
        prune()
    }

    /// Carries a moved repository's group over to its new path.
    func moveRepo(from old: String, to new: String) {
        guard let name = repos.removeValue(forKey: old) else { return }
        repos[new] = name
    }

    func forgetRepo(_ path: String) {
        forgetRepos([path])
    }

    /// Takes repositories out of their groups at once, so a cleanup of dozens saves and prunes once.
    func forgetRepos(_ paths: Set<String>) {
        let kept = repos.filter { !paths.contains($0.key) }
        guard kept.count != repos.count else { return }
        repos = kept
        prune()
    }

    /// What removing repositories takes away from the groups (their membership, and groups that are
    /// pruned with their fold state), so an undo can put it back as it was rather than appending
    /// the groups at the end, unfolded.
    struct Snapshot {
        fileprivate let names: [String]
        fileprivate let repos: [String: String]
        fileprivate let collapsed: Set<String>
    }

    func snapshot(ofRepos paths: some Sequence<String>) -> Snapshot {
        Snapshot(names: names, repos: Dictionary(paths.compactMap { path in repos[path].map { (path, $0) } }, uniquingKeysWith: { first, _ in first }),
                 collapsed: collapsed)
    }

    /// Puts back the groups of `paths` (those that did come back) as `snapshot` had them.
    func restore(_ snapshot: Snapshot, for paths: Set<String>) {
        let memberships = snapshot.repos.filter { paths.contains($0.key) }
        let gone = snapshot.names.filter { !names.contains($0) && memberships.values.contains($0) }
        var restored = names
        for name in gone {
            // Just after the nearest group before it that's still there, or first.
            let index = snapshot.names.firstIndex(of: name) ?? 0
            let before = snapshot.names[..<index].last(where: restored.contains)
            restored.insert(name, at: before.flatMap(restored.firstIndex).map { $0 + 1 } ?? 0)
        }
        names = restored
        repos.merge(memberships) { _, before in before }
        collapsed.formUnion(snapshot.collapsed.filter { key in gone.contains { name in PanelTab.allCases.contains { key == collapseKey(name, $0) } } })
    }

    // MARK: Groups

    func rename(_ old: String, to new: String) {
        guard let new = Self.cleaned(new), new != old, let index = names.firstIndex(of: old) else { return }
        // Renaming onto an existing group merges the two.
        if names.contains(new) { names.remove(at: index) } else { names[index] = new }
        repos = repos.mapValues { $0 == old ? new : $0 }
        servers = servers.mapValues { $0 == old ? new : $0 }
        collapsed = Set(collapsed.map { key in
            for tab in PanelTab.allCases where key == collapseKey(old, tab) { return collapseKey(new, tab) }
            return key
        })
    }

    /// Takes everything out of the group; nothing else is touched.
    func ungroup(_ name: String) {
        repos = repos.filter { $0.value != name }
        servers = servers.filter { $0.value != name }
        prune()
    }

    func move(_ name: String, by offset: Int) {
        guard let index = names.firstIndex(of: name), names.indices.contains(index + offset) else { return }
        names.swapAt(index, index + offset)
    }

    func isCollapsed(_ name: String?, in tab: PanelTab) -> Bool { collapsed.contains(collapseKey(name, tab)) }

    func toggleCollapsed(_ name: String?, in tab: PanelTab) {
        let key = collapseKey(name, tab)
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// nil is the section of everything not in a group.
    private func collapseKey(_ name: String?, _ tab: PanelTab) -> String { "\(tab.rawValue):\(name ?? "")" }

    /// Drops groups nothing is in any more, and their collapsed state.
    private func prune() {
        let used = Set(repos.values).union(servers.values)
        let gone = names.filter { !used.contains($0) }
        guard !gone.isEmpty else { return }
        names.removeAll { gone.contains($0) }
        collapsed = collapsed.filter { key in !gone.contains { name in PanelTab.allCases.contains { key == collapseKey(name, $0) } } }
    }

    private static func cleaned(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Splits `items` into sections in the groups' order, leaving out empty groups. Without any groups
    /// it's one untitled section, so the list looks as it did before groups. The ungrouped section
    /// comes last, and only when something is in it: an empty "Other 0" was clutter. With everything
    /// grouped, a row is taken out of its group from its right-click menu (Group → Remove from …).
    func sections<Item>(_ items: [Item], group: (Item) -> String?) -> [GroupSection<Item>] {
        guard showsGroups, !names.isEmpty else { return [GroupSection(name: nil, items: items, isOnly: true)] }
        var byGroup: [String: [Item]] = [:]
        var rest: [Item] = []
        for item in items {
            if let name = group(item), names.contains(name) { byGroup[name, default: []].append(item) } else { rest.append(item) }
        }
        return names.compactMap { name in byGroup[name].map { GroupSection(name: name, items: $0, isOnly: false) } }
            + (rest.isEmpty ? [] : [GroupSection(name: nil, items: rest, isOnly: false)])
    }

    // MARK: Dragging

    /// Drag targets under the pointer per section ("" for the ungrouped one). Counted, since moving
    /// between two rows of a section can report entering the next before leaving the last.
    @Published private var dropHover: [String: Int] = [:]

    func isDropTarget(_ group: String?) -> Bool { dropHover[group ?? "", default: 0] > 0 }

    func setHovering(_ group: String?, _ hovering: Bool) {
        let key = group ?? ""
        dropHover[key] = max(0, dropHover[key, default: 0] + (hovering ? 1 : -1))
    }

    /// After a drop: rows that move to another section are rebuilt there and never report the drag leaving them.
    func clearDropHover() {
        dropHover = [:]
    }

    /// Puts dragged repositories or servers in `group` (nil takes them out of theirs).
    fileprivate func drop(_ items: [GroupDragItem], into group: String?) -> Bool {
        guard !items.isEmpty else { return false }
        // Rows that move to another section are rebuilt there and never report the drag leaving them.
        dropHover = [:]
        for item in items {
            switch item.kind {
            case .repo: setGroup(group, ofRepo: item.key)
            case .server: setGroup(group, ofServer: item.key, projectRoot: item.projectRoot)
            }
        }
        return true
    }
}

extension UTType {
    /// Bridge's own type, so a row dropped on a text field (the commit message, Claude's prompt)
    /// isn't pasted into it as text.
    static let bridgeGroupItem = UTType(exportedAs: "com.olikab.bridge.group-item")
}

/// A repository (by path) or server (by `favoriteKey`) being dragged to another group.
struct GroupDragItem: Codable, Transferable {
    enum Kind: String, Codable {
        case repo, server
    }

    let kind: Kind
    let key: String
    var projectRoot: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bridgeGroupItem)
    }
}

extension View {
    /// A row of `section` that can be dragged into another group and takes rows dropped on it into its
    /// own. Without any groups (`isOnly`) there's nowhere to drag to, so it's left as it is.
    @ViewBuilder
    func groupRow<Item>(_ item: GroupDragItem, title: String, in section: GroupSection<Item>) -> some View {
        if section.isOnly {
            self
        } else {
            groupDraggable(item, title: title).groupDropTarget(section.name, kind: item.kind)
        }
    }

    /// Lets the row be dragged into another group, showing its name under the pointer.
    func groupDraggable(_ item: GroupDragItem, title: String) -> some View {
        draggable(item) {
            Text(verbatim: title)
                .font(.system(.body, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
        }
    }

    /// Takes rows of `kind` dropped here into `group`. A section's header and each of its rows are
    /// targets, and the whole section lights up while something is over any of them.
    func groupDropTarget(_ group: String?, kind: GroupDragItem.Kind) -> some View {
        modifier(GroupDropTarget(group: group, kind: kind))
    }
}

private struct GroupDropTarget: ViewModifier {
    let group: String?
    let kind: GroupDragItem.Kind
    @ObservedObject private var groups = RepoGroups.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if groups.isDropTarget(group) {
                    Color.accentColor.opacity(0.14).allowsHitTesting(false)
                }
            }
            .dropDestination(for: GroupDragItem.self) { items, _ in
                // A repository row's drag (`RepoDrag`) ends here too when dropped on a header.
                RepoDrag.shared.dragging = nil
                RepoDrag.shared.clear()
                return groups.drop(items.filter { $0.kind == kind }, into: group)
            } isTargeted: { groups.setHovering(group, $0) }
    }
}

struct GroupSection<Item> {
    /// nil for what isn't in a group.
    let name: String?
    let items: [Item]
    /// No groups exist, so no header is shown.
    let isOnly: Bool

    var id: String { name.map { "group:" + $0 } ?? "ungrouped" }
    var title: String { name ?? "Other" }
}

/// A section's header in the panel: click to fold it away. While folded, what's inside is summed
/// up on the right, so a folded group still tells you whether something there needs attention.
struct GroupHeader<Summary: View, Menu: View>: View {
    let section: String?
    let title: String
    /// Not shown (the summary says what matters), but VoiceOver reads it with the title.
    let count: Int
    let tab: PanelTab
    @ViewBuilder var summary: Summary
    @ViewBuilder var menu: Menu
    @ObservedObject private var groups = RepoGroups.shared
    @State private var hovering = false
    @State private var renaming = false

    init(section: String?, title: String, count: Int, tab: PanelTab, @ViewBuilder summary: () -> Summary, @ViewBuilder menu: () -> Menu) {
        self.section = section
        self.title = title
        self.count = count
        self.tab = tab
        self.summary = summary()
        self.menu = menu()
    }

    var body: some View {
        let isCollapsed = groups.isCollapsed(section, in: tab)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .disclosureRotation(!isCollapsed)
                .frame(width: 10)
            // Styled like a sidebar's section heading rather than a bar of its own.
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            // Only while folded: an open group's rows already show the same, and the sum beside
            // them only repeats it.
            if isCollapsed {
                summary
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // The right-click menu, findable: an ellipsis under the pointer. Always laid out (only
            // faded in), and no taller than the title, so hovering doesn't move or grow the header.
            // Only on groups: the ungrouped section's menu can be empty, and an ellipsis opening nothing is worse than none.
            if section != nil {
                // SwiftUI's, not the `Menu` this view is generic over.
                SwiftUI.Menu { menuItems } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 16, height: 14)
                    .opacity(hovering ? 1 : 0)
                    .panelTooltip("Actions for \(title)")
                    .accessibilityLabel("Actions for \(title)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelHighlight(hovering, .quinary)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .contentShape(Rectangle())
        // Not animated: MenuBarExtra resizes its window in steps of its own, and an animated change
        // of the content's height left the panel the wrong size.
        .onTapGesture { groups.toggleCollapsed(section, in: tab) }
        .onHover { hovering = $0 }
        .groupDropTarget(section, kind: tab == .repos ? .repo : .server)
        .panelPopover(isPresented: $renaming, arrowEdge: .bottom) {
            if let section {
                GroupNameForm(title: "Rename group", initial: section, action: "Rename") { name in
                    groups.rename(section, to: name)
                    renaming = false
                }
            }
        }
        .contextMenu { menuItems }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityHint(isCollapsed ? "Shows the group" : "Hides the group")
    }

    @ViewBuilder private var menuItems: some View {
        menu
        if let section {
            Divider()
            Button("Rename…") { renaming = true }
            if groups.names.first != section { Button("Move up") { groups.move(section, by: -1) } }
            if groups.names.last != section { Button("Move down") { groups.move(section, by: 1) } }
            Divider()
            Button("Ungroup") { groups.ungroup(section) }
        }
    }
}

/// The context menu entry for putting a repository or server in a group.
struct GroupMenu: View {
    let current: String?
    let set: (String?) -> Void
    let newGroup: () -> Void
    @ObservedObject private var groups = RepoGroups.shared

    var body: some View {
        Menu("Group") {
            ForEach(groups.names, id: \.self) { name in
                Toggle(isOn: Binding(get: { current == name }, set: { _ in set(name) })) { Text(verbatim: name) }
            }
            if !groups.names.isEmpty { Divider() }
            Button("New group…", action: newGroup)
            if current != nil { Button("Remove from \(current!)") { set(nil) } }
        }
    }
}

/// Asks for a group's name; for a new group and for renaming one.
struct GroupNameForm: View {
    let title: String
    var initial = ""
    let action: String
    let done: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    @ObservedObject private var groups = RepoGroups.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .focused($focused)
                .onSubmit(submit)
                .panelField()
            if groups.names.contains(trimmed) && trimmed != initial {
                Text(initial.isEmpty ? "Goes into the existing group \(trimmed)" : "Merges into the existing group \(trimmed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .prominentButton()
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .task {
            name = initial
            // A popover's window isn't key on its first frame, so focus set in onAppear is lost.
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        done(trimmed)
    }
}
