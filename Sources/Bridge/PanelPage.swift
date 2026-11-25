import Shared
import SwiftUI

/// A form shown as a page of the menu bar panel, in place of the list, the way Control Center opens
/// Wi-Fi or Bluetooth in its own panel rather than in a window over it. A popover from a menu bar panel
/// is a window over a window: it could open off screen, and Esc and focus went to the wrong one.
enum PanelPage: Hashable {
    case newProject, clone, setup

    var title: String {
        switch self {
        case .newProject: "New project"
        case .clone: "Clone repository"
        case .setup: "Set up Bridge"
        }
    }
}

/// The top of a page: back to the list on the left, where Control Center's back arrow is, and the
/// page's title in the middle. It takes the place of the tabs, so it's clear the list is one step back.
struct PanelPageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Repos")
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            }
            .buttonStyle(.panel)
            // Esc goes back too, as it backs out of everything else in the panel.
            .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .overlay {
            Text(title)
                .font(.headline)
                .allowsHitTesting(false)
        }
        .padding(12)
    }
}
