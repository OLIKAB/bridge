import SwiftUI

public extension View {
    /// A capsule of Liquid Glass for something that floats over the content (a confirmation, a hint, a
    /// group of toolbar icons), as macOS 26 draws its own. `interactive` for one that is itself a button,
    /// so it answers the pointer as the system's glass buttons do. Older macOS: the material and hairline
    /// these capsules had before.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.quaternary))
        }
    }
}

/// An on/off setting as a row: its name on the left, the system switch on the right, as in Control
/// Center's Wi-Fi and Bluetooth panels. The system switch is the one control that gets Liquid Glass's
/// lens on macOS 26 (the knob turns to glass and magnifies under the pointer while held or dragged);
/// drawn imitations of it looked home-made, so settings that stand in a panel, page or popover use this
/// rather than a checkbox. A form's columns put a switch's label in the label column, which pushed the
/// fields far to the right, so these rows go below a form, not in it.
public struct PanelSwitch: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
