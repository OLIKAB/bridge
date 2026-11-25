import AppKit
import SwiftUI

/// The license the apps are released under, shown from each app's settings menu.
/// Kept in sync with LICENSE at the repository root.
public enum License {
    public static let author = "OLIKAB"
    public static let url = URL(string: "https://github.com/OLIKAB")!

    public static let text = """
    MIT License

    Copyright (c) 2026 OLIKAB

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    Created by OLIKAB (https://github.com/OLIKAB).
    """

    /// The standard About panel with the license as credits. The apps are menu bar agents
    /// (LSUIElement), so the app is activated first or the panel opens behind other windows.
    @MainActor public static func show() {
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        let link = (text as NSString).range(of: url.absoluteString)
        credits.addAttribute(.link, value: url, range: link)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 OLIKAB · MIT License",
        ])
    }
}

/// "About and license" item for the apps' settings menus.
public struct LicenseMenuItem: View {
    public init() {}

    public var body: some View {
        Button("About and license…") { License.show() }
    }
}
