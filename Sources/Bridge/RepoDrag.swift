import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A repository row being dragged in the panel, to another group or to another place in the list.
/// Kept here because a drop target can't read what's being dragged until it's dropped, and the rows
/// need to know while it's over them: to show where it would land, or why it can't go there.
@MainActor
final class RepoDrag: ObservableObject {
    static let shared = RepoDrag()

    /// Set when a drag starts. Not published: only read by the drop targets.
    var dragging: Repository?
    /// The row it would land beside, and on which side, while that's allowed.
    @Published var insertion: (path: String, after: Bool)?
    /// The row it's over and why it can't move there, while it can't.
    @Published var blocked: (path: String, reason: String)?

    func clear(_ path: String? = nil) {
        if path == nil || insertion?.path == path { insertion = nil }
        if path == nil || blocked?.path == path { blocked = nil }
    }
}

extension View {
    /// A repository row that can be dragged, by pressing and holding it, into another group (dropped on
    /// a row or header there) and to another place among the repositories the sorting puts beside it.
    /// `group` is the row's section, and `groupsShown` whether the list is in sections at all.
    func repoDragRow(_ repo: Repository, group: String?, groupsShown: Bool, store: RepoStore) -> some View {
        modifier(RepoDragRow(repo: repo, group: group, groupsShown: groupsShown, store: store, rowState: ExpandedRepo.shared.row(repo.path)))
    }
}

private struct RepoDragRow: ViewModifier {
    let repo: Repository
    let group: String?
    let groupsShown: Bool
    let store: RepoStore
    /// Whether the row is open, which is when it can't be dragged; the row's own state rather than the
    /// list's, so opening a row doesn't redraw the list (see `ExpandedRepo.Row`).
    @ObservedObject var rowState: ExpandedRepo.Row
    private var isDraggable: Bool { !rowState.isExpanded }
    @ObservedObject private var drag = RepoDrag.shared
    @ObservedObject private var groups = RepoGroups.shared
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, new in height = new }
                }
            }
            // An open row has a text field, where dragging selects text instead.
            .modifier(Draggable(repo: repo, isOn: isDraggable))
            .onDrop(of: [.bridgeGroupItem], delegate: RepoDropDelegate(target: repo, group: group, groupsShown: groupsShown, store: store, height: height))
            .overlay {
                // The whole section lights up while a row from another group is over any of it.
                if groupsShown && groups.isDropTarget(group) {
                    Color.accentColor.opacity(0.14).allowsHitTesting(false)
                }
            }
            .overlay(alignment: drag.insertion?.after == true ? .bottom : .top) {
                if drag.insertion?.path == repo.path {
                    // Where it lands: a thin line between the rows, as in Finder's sidebar.
                    Capsule().fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                        .offset(y: drag.insertion?.after == true ? 1 : -1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if let blocked = drag.blocked, blocked.path == repo.path {
                    BlockedHint(reason: blocked.reason, color: repo.color?.color)
                        .padding(.trailing, 14)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: drag.blocked?.path)
    }
}

/// Starts the drag. `.onDrag` rather than `.draggable`, as only it says when a drag starts.
private struct Draggable: ViewModifier {
    let repo: Repository
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.onDrag {
                RepoDrag.shared.dragging = repo
                let provider = NSItemProvider()
                let data = try? JSONEncoder().encode(GroupDragItem(kind: .repo, key: repo.path))
                provider.registerDataRepresentation(forTypeIdentifier: UTType.bridgeGroupItem.identifier, visibility: .ownProcess) { done in
                    done(data, nil)
                    return nil
                }
                return provider
            } preview: {
                Text(verbatim: repo.displayName)
                    .font(.system(.body, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
            }
        } else {
            content
        }
    }
}

/// Why a row can't go where it's held, on the row under it: small, in a capsule, with the color it's
/// limited to. The pointer also shows macOS's "not allowed" sign.
private struct BlockedHint: View {
    let reason: String
    let color: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "nosign")
                .foregroundStyle(.secondary)
            Text(reason)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassCapsule()
        .fixedSize()
    }
}

private struct RepoDropDelegate: DropDelegate {
    let target: Repository
    let group: String?
    let groupsShown: Bool
    let store: RepoStore
    let height: CGFloat

    private var drag: RepoDrag { RepoDrag.shared }

    /// Whether the drop moves the dragged repository into this row's group.
    private func changesGroup(_ dragged: Repository) -> Bool {
        groupsShown && RepoGroups.shared.group(ofRepo: dragged.path) != group
    }

    func validateDrop(info: DropInfo) -> Bool { drag.dragging != nil }

    func dropEntered(info: DropInfo) {
        if let dragged = drag.dragging, changesGroup(dragged) { RepoGroups.shared.setHovering(group, true) }
    }

    func dropExited(info: DropInfo) {
        if let dragged = drag.dragging, changesGroup(dragged) { RepoGroups.shared.setHovering(group, false) }
        drag.clear(target.path)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragged = drag.dragging, dragged !== target else {
            drag.clear(target.path)
            return DropProposal(operation: .move)
        }
        let blocker = store.reorderBlocker(dragged, nextTo: target)
        // Into another group it can always go; it then takes its place there by the sorting.
        if let blocker, !changesGroup(dragged) {
            drag.insertion = nil
            drag.blocked = (target.path, blocker)
            return DropProposal(operation: .forbidden)
        }
        drag.blocked = nil
        drag.insertion = blocker == nil ? (target.path, info.location.y > height / 2) : nil
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            drag.clear()
            drag.dragging = nil
            RepoGroups.shared.clearDropHover()
        }
        guard let dragged = drag.dragging, dragged !== target else { return false }
        let movesGroup = changesGroup(dragged)
        let canReorder = store.reorderBlocker(dragged, nextTo: target) == nil
        if movesGroup { RepoGroups.shared.setGroup(group, ofRepo: dragged.path) }
        if canReorder { store.move(dragged, nextTo: target, after: info.location.y > height / 2) }
        return movesGroup || canReorder
    }
}
