import Shared
import SwiftUI

// The pieces of a page where repositories are ticked before something is done to all of them at once:
// Find repositories (`ImportRepositoriesForm`) and Clean up repositories (`CleanUpRepositoriesForm`).
// The same rows on both, so ticking a batch in and ticking a batch out feel like one feature.

/// Where the repositories are (this Mac, a host), styled like a sidebar's section heading, with a
/// spinner while it's loading.
struct ChecklistHeading: View {
    let title: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// A group as it is (or would be) in Bridge: a click opens or folds it, its checkbox ticks all of it
/// (mixed while some are), and how many are ticked shows on the right, so a folded group still says
/// what the page's button does.
struct ChecklistGroupHeader: View {
    let title: String
    let ids: [String]
    let isOpen: Bool
    let toggleOpen: () -> Void
    @Binding var selected: Set<String>
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .disclosureRotation(isOpen)
                .frame(width: 10)
            Toggle(sources: ids.map(binding), isOn: \.self) { Text("All in \(title)") }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(verbatim: title)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(ids.filter(selected.contains).count) of \(ids.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelHighlight(hovering, .quinary)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        // Not animated: the panel's height mustn't be (see MenuPanelList).
        .onTapGesture(perform: toggleOpen)
        .onHover { hovering = $0 }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}

/// A line in place of a section's rows: why there are none, or what to do to get some.
struct ChecklistStatusLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // In line with the heading above.
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
    }
}

/// One repository to tick: a click anywhere on the row ticks it, as in a list of checkboxes in Settings.
/// `trailing` says why it's ticked or not to begin with; `trailingWarns` colors it when it's something
/// that exists only on this Mac, the one place on these pages where something needs you.
struct ChecklistRow<Icon: View>: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String?
    let trailing: String?
    var trailingWarns = false
    @ViewBuilder var icon: Icon
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            icon.frame(width: 16)
            Text(verbatim: title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(verbatim: detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(verbatim: trailing)
                    .font(.caption)
                    .foregroundStyle(trailingWarns ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // Its checkbox under the group's, past the group's chevron.
        .padding(.leading, 6 + 18)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelHighlight(hovering, .quinary)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .onHover { hovering = $0 }
    }
}
