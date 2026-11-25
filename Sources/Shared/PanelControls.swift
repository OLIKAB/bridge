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

/// An icon that switches a setting on and off, told apart from buttons that do something: while on,
/// the glyph is in the accent color on an accent fill, like a selected segment; while off, it's grey
/// with only the shared hover. Group switches in `PanelToggleGroup`, so they read as a set of options.
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
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // In a `PanelToggleGroup` tray (2 pt around), as tall as a text field, its corners
                // concentric with the tray's.
                .frame(width: 28, height: PanelMetrics.fieldHeight - 4)
                .background(fill(isOn), in: RoundedRectangle(cornerRadius: PanelMetrics.fieldCornerRadius - 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func fill(_ isOn: Bool) -> AnyShapeStyle {
        if isOn { return hovering ? AnyShapeStyle(.tint.tertiary) : AnyShapeStyle(.tint.quaternary) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
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
}

/// A button in a line with a text field (Commit & Push, Send, Terminal): exactly as tall as the field
/// and as round, filled like it, or in the accent (or `tint`) when it's the line's main action.
public struct PanelFieldButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color?
    let iconOnly: Bool

    public init(prominent: Bool = false, tint: Color? = nil, iconOnly: Bool = false) {
        self.prominent = prominent
        self.tint = tint
        self.iconOnly = iconOnly
    }

    public func makeBody(configuration: Configuration) -> some View {
        PanelFieldButton(configuration: configuration, prominent: prominent, tint: tint, iconOnly: iconOnly)
    }
}

private struct PanelFieldButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    let iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.fieldCornerRadius, style: .continuous)
        configuration.label
            .font(prominent ? .callout.weight(.medium) : .callout)
            .lineLimit(1)
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? PanelMetrics.fieldHeight + 4 : nil, height: PanelMetrics.fieldHeight)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(fill, in: shape)
            .overlay {
                if !prominent { shape.strokeBorder(.quaternary) }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovering = $0 && isEnabled }
    }

    private var fill: AnyShapeStyle {
        if prominent {
            let color = tint ?? .accentColor
            return AnyShapeStyle(color.opacity(configuration.isPressed ? 0.75 : hovering ? 0.9 : 1))
        }
        if configuration.isPressed { return AnyShapeStyle(.tertiary) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }
}

public extension ButtonStyle where Self == PanelFieldButtonStyle {
    /// A secondary button beside a text field.
    static var fieldRow: PanelFieldButtonStyle { PanelFieldButtonStyle() }

    /// A button beside a text field: `prominent` for the line's main action.
    static func fieldRow(prominent: Bool = false, tint: Color? = nil, iconOnly: Bool = false) -> PanelFieldButtonStyle {
        PanelFieldButtonStyle(prominent: prominent, tint: tint, iconOnly: iconOnly)
    }
}

/// Switches (`.toggleStyle(.panel)`) side by side in one faint capsule-like tray, so a row of options
/// looks different from a row of buttons that open or run something, as a segmented control does.
public struct PanelToggleGroup<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.fieldCornerRadius, style: .continuous)
        HStack(spacing: 2) { content }
            .padding(2)
            .background(.quinary, in: shape)
            .overlay(shape.strokeBorder(.quaternary))
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
