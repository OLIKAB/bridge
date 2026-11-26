import AppKit
import CoreImage
import SwiftUI

/// The hover and press feedback every small control in the panels shares, so nothing under the pointer
/// stays dead: a faint fill under the pointer, a stronger one while pressed, and for toggles a steady
/// fill while on. Like the toolbar buttons in macOS's own windows, which the borderless style lacks.
private struct ControlFill: ViewModifier {
    let isHovered: Bool
    let isPressed: Bool
    var isOn = false
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

    func body(content: Content) -> some View {
        content.background(fill, in: shape)
    }

    private var fill: AnyShapeStyle {
        if isPressed { return AnyShapeStyle(.tertiary) }
        if isOn { return isHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary) }
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }
}

/// For icon buttons (`IconButton`, a row's star, a disclosure arrow): no bezel at rest, the shared
/// fill under the pointer and while pressed.
public struct PanelButtonStyle: ButtonStyle {
    var isOn = false

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    public func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .modifier(ControlFill(isHovered: hovering && isEnabled, isPressed: configuration.isPressed, isOn: isOn))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == PanelButtonStyle {
    static var panel: PanelButtonStyle { PanelButtonStyle() }
}

/// An icon that switches something on and off among other icons on glass (the main window's toolbar
/// groups), where a segmented control would look out of place: while on, it sits on a raised neutral
/// thumb with the glyph in the accent color; while off, it's grey with only the shared hover. In the
/// panels, switches are a `PanelToggleBar`.
public struct PanelToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PanelToggleBody(configuration: configuration)
    }
}

private struct PanelToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let isOn = configuration.isOn
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.fieldCornerRadius - 2, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: PanelMetrics.fieldHeight - 4)
                .background {
                    if isOn {
                        // The thumb: lighter than the tray, with a hairline and a soft shadow under it.
                        shape.fill(Color(nsColor: .controlColor).opacity(hovering ? 1 : 0.85))
                            .overlay(shape.strokeBorder(.white.opacity(0.08)))
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    } else if hovering {
                        shape.fill(.quaternary)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

public extension ToggleStyle where Self == PanelToggleStyle {
    static var panel: PanelToggleStyle { PanelToggleStyle() }
}

public enum PanelMetrics {
    /// The height of a text field (`panelField`), and of every button, switch tray or icon that stands
    /// in a line with one, so a field and its buttons line up top and bottom. System buttons are a few
    /// points shorter than a field, which looked off beside one.
    public static let fieldHeight: CGFloat = 28
    /// The corner radius shared by a field and the buttons beside it.
    public static let fieldCornerRadius: CGFloat = 8
    /// How far in from a large system field's edge its text starts, for text laid over a field
    /// (a placeholder that changes often, Claude writing).
    public static let fieldTextInset: CGFloat = 8
}

public extension NSImage {
    /// A copy in shades of grey, for a colored logo standing for something that's off.
    @MainActor var grayscale: NSImage {
        if let cached = GrayImages.cache.object(forKey: self) { return cached }
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let gray = CIImage(cgImage: cg).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let image = NSImage(size: size)
        image.addRepresentation(NSCIImageRep(ciImage: gray))
        GrayImages.cache.setObject(image, forKey: self)
        return image
    }

    /// A copy drawn at `side` points square.
    func sized(_ side: CGFloat) -> NSImage {
        let copy = self.copy() as? NSImage ?? self
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}

@MainActor private enum GrayImages {
    static let cache = NSCache<NSImage, NSImage>()
}

public extension View {
    /// A button in a line with a text field (Commit & Push, Send, Terminal): the system's bordered button
    /// at the large size, which is as tall as a large text field (`panelField`); `prominent` for the
    /// line's main action, in the accent or `tint`. Drawn buttons and fields were used before, made to
    /// match each other; the system's own match each other already.
    @ViewBuilder
    func fieldRowButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        } else {
            buttonStyle(.bordered).controlSize(.large)
        }
    }
}

/// One on/off icon in a `PanelToggleBar`.
public struct PanelToggleItem {
    let image: NSImage
    let name: String
    let isOn: Binding<Bool>

    /// `name` is the tooltip and VoiceOver label (a first line, details after "\n").
    public init(_ image: NSImage, name: String, isOn: Binding<Bool>) {
        // VoiceOver reads a segment by its image's description: the tooltip's first line.
        let label = name.split(separator: "\n").first.map(String.init) ?? name
        if image.accessibilityDescription == label {
            self.image = image
        } else {
            let copy = image.copy() as? NSImage ?? image
            copy.accessibilityDescription = label
            self.image = copy
        }
        self.name = name
        self.isOn = isOn
    }

    public init(systemImage: String, name: String, isOn: Binding<Bool>) {
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: name) ?? NSImage()
        self.init(image, name: name, isOn: isOn)
    }
}

/// Icons that switch settings on and off, side by side: the system's segmented control with any number
/// of segments selected (`selectAny`), so it looks like the tab switch above it and like the option
/// bars in macOS's own toolbars, and a switch never looks like a button that runs something. It
/// replaced a drawn tray of drawn switches, whose on state never looked like the system's.
/// Takes the size from `.controlSize`.
public struct PanelToggleBar: NSViewRepresentable {
    let items: [PanelToggleItem]

    public init(_ items: [PanelToggleItem]) {
        self.items = items
    }

    public func makeNSView(context: Context) -> ToggleSegments {
        let control = ToggleSegments()
        control.trackingMode = .selectAny
        control.segmentStyle = .automatic
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    public func updateNSView(_ control: ToggleSegments, context: Context) {
        context.coordinator.items = items
        control.controlSize = context.environment.controlSize.appKit
        if control.segmentCount != items.count { control.segmentCount = items.count }
        for (index, item) in items.enumerated() {
            if control.image(forSegment: index) != item.image { control.setImage(item.image, forSegment: index) }
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setSelected(item.isOn.wrappedValue, forSegment: index)
        }
        let tooltips = context.coordinator.tooltips
        control.onHover = { [weak control] index in
            guard let control else { return }
            let text = index.map { context.coordinator.items.indices.contains($0) ? context.coordinator.items[$0].name : "" } ?? ""
            tooltips.hover(index, text: text, rect: index.map(control.segmentRect) ?? .zero, in: control)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator: NSObject {
        var items: [PanelToggleItem] = []
        let tooltips = PartTooltips()

        @objc func changed(_ control: NSSegmentedControl) {
            for (index, item) in items.enumerated() where control.isSelected(forSegment: index) != item.isOn.wrappedValue {
                item.isOn.wrappedValue = control.isSelected(forSegment: index)
            }
        }
    }
}

/// The segmented control behind `PanelToggleBar`: says which segment is under the pointer, for its
/// tooltips (`panelTooltip` can't go on a segment).
public final class ToggleSegments: NSSegmentedControl {
    var onHover: ((Int?) -> Void)?
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let x = convert(event.locationInWindow, from: nil).x
        onHover?((0..<segmentCount).first { segmentRect($0).minX <= x && x < segmentRect($0).maxX })
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    /// Where a segment is: they're as wide as one another, each holding one icon of the same size.
    func segmentRect(_ index: Int) -> CGRect {
        let width = bounds.width / CGFloat(max(segmentCount, 1))
        return CGRect(x: width * CGFloat(index), y: 0, width: width, height: bounds.height)
    }
}

private extension ControlSize {
    var appKit: NSControl.ControlSize {
        switch self {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
    }
}

/// A menu behind an icon, with the same hover as the icon buttons beside it. A borderless menu
/// (`.menuStyle(.borderlessButton)`) shows nothing under the pointer.
public struct PanelMenu<Content: View, Icon: View>: View {
    let help: String
    let content: Content
    let icon: Icon
    @State private var hovering = false

    public init(help: String, @ViewBuilder content: () -> Content, @ViewBuilder icon: () -> Icon) {
        self.help = help
        self.content = content()
        self.icon = icon()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            // A small chevron after the icon, as on a toolbar's pull-down buttons, so a button that
            // opens a menu is told apart from one that acts at once and from a switch.
            HStack(spacing: 2) {
                icon
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 5)
            .frame(height: 22)
            .modifier(ControlFill(isHovered: hovering, isPressed: false))
            .contentShape(Rectangle())
        }
        // A button-style menu draws its label as it is, so the fill above shows.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .panelTooltip(help)
        .accessibilityLabel(help)
    }
}

public extension PanelMenu where Icon == Image {
    init(_ systemImage: String, help: String, @ViewBuilder content: () -> Content) {
        self.init(help: help, content: content) { Image(systemName: systemImage) }
    }
}

/// A small capsule button, for pinned skills and the like: a faint fill at rest, stronger under the
/// pointer and while pressed.
public struct PanelChipStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PanelChipBody(configuration: configuration)
    }
}

private struct PanelChipBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? AnyShapeStyle(.tertiary) : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary), in: .capsule)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == PanelChipStyle {
    static var panelChip: PanelChipStyle { PanelChipStyle() }
}
