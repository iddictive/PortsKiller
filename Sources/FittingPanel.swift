import AppKit
import SwiftUI

/// Prefer the body's intrinsic height; scroll only when the parent cannot fit it.
struct FittingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
    }
}

enum UtilityPanelSize {
    case processes, preferences, project

    // Product reading-width budgets, not display dimensions. Native controls
    // retain their minimum sizes; long process metadata may truncate.
    // Beyond this reading budget the list scrolls, instead of consuming the display.
    var maximumHeight: CGFloat { 640 }

    var preferredWidth: CGFloat {
        switch self {
        case .processes: 600
        case .preferences, .project: 620
        }
    }
}

extension View {
    /// Menu-bar windows receive an ideal-size proposal, not a fixed viewport.
    /// Bound that proposal by the display containing the invoking pointer.
    func screenBoundedPanel(_ size: UtilityPanelSize) -> some View {
        let screen = NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let width = min(size.preferredWidth, screen?.visibleFrame.width ?? size.preferredWidth)
        return frame(idealWidth: width, maxWidth: width, maxHeight: min(size.maximumHeight, screen?.visibleFrame.height ?? size.maximumHeight))
            .fixedSize()
    }
}

/// Keep the MenuBarExtra host in sync when its conditional content shrinks.
/// SwiftUI can update its ideal size without shrinking the existing panel.
struct PanelWindowSize: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window,
                  self.size.width > 0, self.size.height > 0 else { return }
            let oldFrame = window.frame
            let contentSize = window.contentView?.bounds.size ?? .zero
            guard abs(contentSize.width - self.size.width) > 0.5
                    || abs(contentSize.height - self.size.height) > 0.5 else { return }
            window.setContentSize(self.size)
            window.setFrameOrigin(NSPoint(x: oldFrame.maxX - window.frame.width,
                                          y: oldFrame.maxY - window.frame.height))
        }
    }
}
