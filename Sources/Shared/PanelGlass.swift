import AppKit
import SwiftUI

public extension View {
    /// Buttons in this view that have no style of their own are Liquid Glass (`.glass`), as the
    /// system's own panels draw theirs on macOS 26; the plain bordered button looked flat beside the
    /// glass tab switch and switches. Put it at the root of each window, and of each popover's content,
    /// since a popover doesn't take its button style from the view it's anchored to.
    /// Older macOS: the bordered buttons as they were.
    @ViewBuilder
    func glassButtons() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    /// The main action of a form or line: tinted Liquid Glass (`.glassProminent`) in the accent color
    /// or `tint`. A glass button with the default action's shortcut (Return) isn't tinted by itself as
    /// a bordered one was, so a form's default button needs this too. Older macOS: `.borderedProminent`.
    @ViewBuilder
    func prominentButton(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).tint(tint).hiddenWhileFadingIn()
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

/// One segment of a `PanelSegments` switch: a title, a symbol, or both.
public struct PanelSegment<Value: Hashable> {
    let value: Value
    let title: String?
    let systemImage: String?

    public init(_ title: String?, systemImage: String? = nil, value: Value) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }
}

/// Picks one of a few views or sources (Memory/CPU, Changes/History, GitHub/GitLab): the system's
/// segmented control in the tabs role, which on macOS 27 has Liquid Glass's lens and the grey raised
/// selection of the system's own switchers, like the panel's Repos/Servers switch. SwiftUI's segmented
/// picker has no way to ask for that role and draws a flat blue selection, so AppKit's control is used.
/// Older macOS: SwiftUI's segmented picker. Takes its size from `.controlSize`; as wide as its segments
/// unless `fills` (then the segments share the width offered).
public struct PanelSegments<Value: Hashable>: View {
    let label: String
    let segments: [PanelSegment<Value>]
    @Binding var selection: Value
    let fills: Bool

    public init(_ label: String, selection: Binding<Value>, fills: Bool = false, segments: [PanelSegment<Value>]) {
        self.label = label
        self._selection = selection
        self.fills = fills
        self.segments = segments
    }

    public var body: some View {
        if #available(macOS 27, *) {
            TabRoleSegments(label: label, segments: segments, selection: $selection, fills: fills)
                .fixedSize(horizontal: !fills, vertical: true)
        } else {
            Picker(label, selection: $selection) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    Group {
                        if let title = segment.title, let image = segment.systemImage {
                            Label(title, systemImage: image).labelStyle(.titleAndIcon)
                        } else if let image = segment.systemImage {
                            Image(systemName: image)
                        } else {
                            Text(verbatim: segment.title ?? "")
                        }
                    }
                    .tag(segment.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: !fills, vertical: false)
        }
    }
}

@available(macOS 27, *)
private struct TabRoleSegments<Value: Hashable>: NSViewRepresentable {
    let label: String
    let segments: [PanelSegment<Value>]
    @Binding var selection: Value
    let fills: Bool

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.role = .tabs
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.controlSize = context.environment.controlSize.appKit
        control.segmentDistribution = fills ? .fillEqually : .fit
        control.setContentHuggingPriority(fills ? .defaultLow : .required, for: .horizontal)
        control.setAccessibilityLabel(label)
        if control.segmentCount != segments.count { control.segmentCount = segments.count }
        for (index, segment) in segments.enumerated() {
            if control.label(forSegment: index) != (segment.title ?? "") { control.setLabel(segment.title ?? "", forSegment: index) }
            // Set only when the symbol changes: a new image each update redraws the control.
            if context.coordinator.symbols.count <= index { context.coordinator.symbols.append(nil) }
            if context.coordinator.symbols[index] != segment.systemImage || control.image(forSegment: index) == nil && segment.systemImage != nil {
                context.coordinator.symbols[index] = segment.systemImage
                control.setImage(segment.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.title) }, forSegment: index)
            }
        }
        let index = segments.firstIndex { $0.value == selection } ?? -1
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TabRoleSegments
        var symbols: [String?] = []
        init(parent: TabRoleSegments) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.segments.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.segments[control.selectedSegment].value
        }
    }
}

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
