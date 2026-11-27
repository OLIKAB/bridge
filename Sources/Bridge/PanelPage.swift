import Shared
import SwiftUI

/// A form shown as a page of the menu bar panel, in place of the list, the way Control Center opens
/// Wi-Fi or Bluetooth in its own panel rather than in a window over it. A popover from a menu bar panel
/// is a window over a window: it could open off screen, and Esc and focus went to the wrong one.
enum PanelPage: Hashable {
    case newProject, clone, importRepos, cleanUp, settings
    /// The settings page as a new user first sees it (`SettingsPage.isFirstRun`).
    case setup
    /// How the repository at `path` is started (`StartCommandEditor`). A page rather than a popover on its
    /// row: a field in a popover is drawn dark, unlike the panel's on its glass, and the form had grown
    /// (apps, scripts, the agent's search) past what a popover holds well.
    case startCommand(path: String)

    var title: String {
        switch self {
        case .newProject: "New project"
        case .clone: "Clone repository"
        case .importRepos: "Find repositories"
        case .cleanUp: "Clean up repositories"
        case .settings: "Settings"
        case .setup: "Set up Bridge"
        // The repository's name, as the page is about that one and says so nowhere else.
        case .startCommand(let path): "Start \((path as NSString).lastPathComponent)"
        }
    }
}

extension View {
    /// Gives a page's field the keyboard as the page comes up, so typing starts there without a click.
    /// A moment after it appears rather than in `onAppear`: pages open from a menu (+, a row's right-click
    /// menu), and as a menu closes macOS gives the keyboard back to the view that had it, the panel's
    /// prompt field, which undid a focus set in `onAppear`.
    func focusesWhenShown(_ focus: @escaping @MainActor () -> Void) -> some View {
        task {
            try? await Task.sleep(for: .milliseconds(80))
            focus()
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
