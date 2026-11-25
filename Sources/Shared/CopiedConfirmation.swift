import AppKit
import SwiftUI

public enum Pasteboard {
    /// Puts `text` on the general pasteboard, replacing what was there.
    @MainActor
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

public extension View {
    /// A small "✓ Copied" on this view for a moment each time `trigger` changes: confirmation right
    /// where the copy was asked for (the row a context menu came from, the SHA that was clicked),
    /// rather than nothing at all, which left people copying twice to be sure. Laid over the view, so
    /// nothing moves; it fades in and away again after 1.2 s.
    func copiedConfirmation(_ trigger: Int, alignment: Alignment = .trailing) -> some View {
        modifier(CopiedConfirmation(trigger: trigger, alignment: alignment))
    }
}

private struct CopiedConfirmation: ViewModifier {
    let trigger: Int
    let alignment: Alignment
    @State private var isShown = false
    @State private var hiding: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isShown {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassCapsule()
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: trigger) {
                // Only `isShown` changes in these transactions, so only the confirmation animates.
                withAnimation(.easeOut(duration: 0.15)) { isShown = true }
                hiding?.cancel()
                hiding = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.25)) { isShown = false }
                }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
    }
}
