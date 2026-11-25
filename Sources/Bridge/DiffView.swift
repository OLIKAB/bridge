import SwiftUI

/// A unified diff with old and new line numbers. Long lines wrap rather than scroll sideways.
struct DiffView: View {
    let diff: FileDiff?
    @State private var showAll = false

    /// Rendering stays fast up to a few thousand lines; beyond that it waits to be asked.
    private static let limit = 3000

    var body: some View {
        if let diff {
            if diff.isBinary {
                message("Binary file – no diff to show")
            } else if diff.isEmpty {
                message("No changes to the contents (only the file mode, or an empty file)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(showAll ? diff.lines[...] : diff.lines.prefix(Self.limit)) { line in
                            DiffLineRow(line: line)
                        }
                        if !showAll && diff.lines.count > Self.limit {
                            Button("Show all \(diff.lines.count) lines") { showAll = true }
                                .padding(12)
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .frame(width: 16)
                .foregroundStyle(signColor)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 3 : 0)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var signColor: Color {
        line.kind == .added ? .green : .red
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        case .hunk: Color.accentColor.opacity(0.08)
        case .context, .note: .clear
        }
    }
}
