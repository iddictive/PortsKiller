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

    var minimumSize: CGSize {
        switch self {
        case .processes: CGSize(width: 600, height: 220)
        case .preferences, .project: CGSize(width: 460, height: 300)
        }
    }

    var initialSize: CGSize {
        switch self {
        case .processes: CGSize(width: 680, height: 245)
        case .preferences: CGSize(width: 600, height: 440)
        case .project: CGSize(width: 620, height: 400)
        }
    }
}

extension View {
    /// Content sets its operable minimum; the native window owns user resizing.
    func screenBoundedPanel(_ role: UtilityPanelSize) -> some View {
        frame(minWidth: role.minimumSize.width, idealWidth: role.initialSize.width,
              maxWidth: .infinity, minHeight: role.minimumSize.height,
              idealHeight: role.initialSize.height, maxHeight: .infinity, alignment: .top)
    }
}
