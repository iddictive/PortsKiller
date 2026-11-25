import AppKit
import SwiftUI

private typealias WorkspaceState<Value> = SwiftUI.State<Value>

enum WorkspaceStyle {
    private static let windowBase = Color(nsColor: .windowBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let mutedInk = Color(nsColor: .secondaryLabelColor)
    static let disabledInk = Color(nsColor: .disabledControlTextColor)

    // The real backdrop comes from the AppKit window, not a simulated gradient.
    // Reserve opaque paint for Accessibility's transparency/contrast settings.
    static func canvas(solid: Bool) -> Color { solid ? windowBase : windowBase.opacity(0.44) }

    static let railBacking = Color(nsColor: .controlBackgroundColor)
    static let railEdge = Color.primary.opacity(0.11)
    static let hairline = Color.primary.opacity(0.12)
    static let group = Color.primary.opacity(0.065)
    static let control = Color.primary.opacity(0.085)
    static let selectionEdge = Color.primary.opacity(0.15)
    static let selected = Color.primary.opacity(0.12)
    static let selectedHovered = Color.primary.opacity(0.15)
    static let hovered = Color.primary.opacity(0.095)
    static let controlHovered = Color.primary.opacity(0.13)
    static let pressed = Color.primary.opacity(0.17)

    static let gutter: CGFloat = 20
    static let controlRadius: CGFloat = 8
    static let groupRadius: CGFloat = 12
    static let railRadius: CGFloat = 15
}

struct WorkspaceRail: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: WorkspaceStyle.railRadius)
            if reduceTransparency || contrast == .increased {
                shape.fill(WorkspaceStyle.railBacking)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceStyle.railRadius)
                .strokeBorder(WorkspaceStyle.railEdge, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

struct WorkspaceSeparator: View {
    var body: some View {
        Rectangle()
            .fill(WorkspaceStyle.hairline)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

struct WorkspaceButton: ButtonStyle {
    var selected = false
    var restingFill = false

    func makeBody(configuration: Configuration) -> some View {
        Content(label: configuration.label, selected: selected, pressed: configuration.isPressed, restingFill: restingFill)
    }

    private struct Content<Label: View>: View {
        let label: Label
        let selected: Bool
        let pressed: Bool
        let restingFill: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @WorkspaceState private var hovered = false

        var body: some View {
            label
                .contentShape(RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
                .background(fill, in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                            .strokeBorder(contrast == .increased ? WorkspaceStyle.mutedInk : WorkspaceStyle.selectionEdge,
                                          lineWidth: contrast == .increased ? 1 : 0.5)
                            .allowsHitTesting(false)
                    }
                }
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            guard enabled else { return .clear }
            if pressed { return WorkspaceStyle.pressed }
            if selected { return hovered ? WorkspaceStyle.selectedHovered : WorkspaceStyle.selected }
            if restingFill { return hovered ? WorkspaceStyle.controlHovered : WorkspaceStyle.control }
            if hovered { return WorkspaceStyle.hovered }
            return .clear
        }
    }
}

/// One stable search control on both the workspace glass and the app picker.
struct WorkspaceFilterField: View {
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    let prompt: String
    let label: String
    let identifier: String
    let height: CGFloat
    var clearsOnEscape = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
                .accessibilityHidden(true)
            if clearsOnEscape {
                input.onExitCommand {
                    if query.isEmpty { focus.wrappedValue = false } else { query = "" }
                }
            } else {
                input
            }
            Button {
                query = ""
                focus.wrappedValue = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 17, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .accessibilityHidden(query.isEmpty)
            .accessibilityLabel("Clear filter")
        }
        .font(.system(size: 12))
        .foregroundStyle(WorkspaceStyle.ink)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(WorkspaceStyle.control, in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                .strokeBorder(focus.wrappedValue ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var input: some View {
        TextField(label, text: $query, prompt: Text(prompt).foregroundColor(WorkspaceStyle.mutedInk))
            .textFieldStyle(.plain)
            .focused(focus)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
