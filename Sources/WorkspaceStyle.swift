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
}

struct WorkspaceRail: ViewModifier {
    func body(content: Content) -> some View {
        // One material behind both columns and the traffic lights. A quiet tint
        // marks navigation; don't stack a second sheet of glass inside the rail.
        content.background(Color.primary.opacity(0.035))
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
    @Environment(\.colorSchemeContrast) private var contrast

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
            if !query.isEmpty {
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
                .accessibilityLabel("Clear filter")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(WorkspaceStyle.ink)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.52), in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                .strokeBorder(focus.wrappedValue ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background(SearchClickAway(editing: focus.wrappedValue))
    }

    private var input: some View {
        // AppKit can dim a native placeholder on glass even with a colored
        // attributed prompt. Keep a single native editor for input/VoiceOver,
        // but give the empty label a deliberate level between entered text
        // and the system's disabled placeholder.
        TextField(label, text: $query, prompt: Text(""))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(WorkspaceStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if query.isEmpty {
                    Text(verbatim: prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(WorkspaceStyle.ink.opacity(contrast == .increased ? 0.90 : 0.76))
                        .lineLimit(1)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused(focus)
            .accessibilityLabel(label)
            .accessibilityHint(Text(verbatim: prompt))
            .accessibilityIdentifier(identifier)
    }
}

// Observe, never intercept: outside clicks end editing before the same event
// goes to its original button, row, scroll area, or native window drag region.
private struct SearchClickAway: NSViewRepresentable {
    let editing: Bool
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.editing = editing }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.editing = false }

    final class Observer: NSView {
        var editing = false { didSet { syncMonitor() } }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncMonitor()
        }
        private func syncMonitor() {
            guard editing, window != nil else {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }
    }
}

extension View {
    @ViewBuilder func workspaceScrollEdges() -> some View {
        // This scroll view is already bounded by the fixed header and footer.
        // Don't also fade the first and last rows under a native toolbar mask.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
