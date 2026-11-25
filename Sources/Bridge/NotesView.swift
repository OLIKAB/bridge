import SwiftUI

/// A scratch pad per repository, shown as a pane beside changes and history.
struct NotesView: View {
    @ObservedObject var repo: Repository

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notes").font(.headline).padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            TextEditor(text: $repo.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .overlay(alignment: .topLeading) {
                    // TextEditor has no placeholder of its own.
                    if repo.notes.isEmpty {
                        Text("To-dos, ideas, how to run it…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
