import AppKit
import Combine
import SwiftUI

private typealias QuickAppsState<Value> = SwiftUI.State<Value>

@MainActor
final class QuickAppsFocus: ObservableObject {
    @Published private(set) var request = 0

    func focusSearch() { request &+= 1 }
}

/// The status item's transient list of regular macOS applications.
/// This never works from a process-name lookup or sends a Unix signal.
@MainActor
struct QuickAppsView: View {
    let onOpenWorkspace: () -> Void
    let onSizeChange: (CGSize) -> Void
    let maximumBodyHeight: CGFloat
    @ObservedObject var focusRequest: QuickAppsFocus

    @QuickAppsState private var apps: [Entry]
    @QuickAppsState private var query = ""
    @QuickAppsState private var pending: Set<Entry.ID> = []
    @QuickAppsState private var warnings: [Entry.ID: String] = [:]
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Entry: Identifiable {
        struct ID: Hashable {
            let pid: pid_t
            let start: Date?
        }

        let id: ID
        let name: String
        let bundleURL: URL
        let application: NSRunningApplication
    }

    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.windowmanager",
        "com.apple.notificationcenterui", "com.apple.spotlight", "com.apple.securityagent"
    ]
    private static let coreServicesPath = "/System/Library/CoreServices/"
    private static let rowHeight: CGFloat = 42
    static let width: CGFloat = 326
    static let maxBodyHeight: CGFloat = 296

    init(focusRequest: QuickAppsFocus, maximumBodyHeight: CGFloat,
         onSizeChange: @escaping (CGSize) -> Void, onOpenWorkspace: @escaping () -> Void) {
        self.focusRequest = focusRequest
        self.maximumBodyHeight = maximumBodyHeight
        self.onSizeChange = onSizeChange
        self.onOpenWorkspace = onOpenWorkspace
        _apps = QuickAppsState(initialValue: Self.snapshot())
    }

    private var terms: [Substring] { query.split(whereSeparator: { $0.isWhitespace }) }

    private var matches: [Entry] {
        apps.filter { app in
            terms.allSatisfy { term in
                app.name.localizedStandardContains(String(term))
                    || (app.application.bundleIdentifier ?? "").localizedStandardContains(String(term))
            }
        }
    }

    var body: some View {
        let entries = matches
        VStack(alignment: .leading, spacing: 8) {
            search

            if entries.isEmpty {
                Text(terms.isEmpty ? "No apps available to quit" : "No matching apps")
                    .font(.callout)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.leading, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { appRow($0) }
                    }
                }
                .frame(height: listHeight(entries))
                .id(query)
            }

            WorkspaceSeparator()
            Button(action: onOpenWorkspace) {
                HStack {
                    Text("Open PortsKiller")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.medium))
                }
                .font(.callout.weight(.medium))
                .frame(minHeight: 28)
                .padding(.horizontal, 8)
            }
            .buttonStyle(WorkspaceButton())
            .accessibilityIdentifier("quick-apps.workspace")
        }
        .padding(10)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height))
        } action: { size in
            onSizeChange(size)
        }
        .foregroundStyle(WorkspaceStyle.ink)
        .background {
            if reduceTransparency || contrast == .increased {
                WorkspaceStyle.canvas(solid: true)
            } else {
                Rectangle().fill(.thinMaterial)
            }
        }
        .onAppear {
            reload()
            // With Reduce Motion, AppKit may have finished before SwiftUI mounted.
            if focusRequest.request != 0 { searchFocused = true }
        }
        .onChange(of: focusRequest.request) { _ in searchFocused = true }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            reload()
        }
    }

    private var search: some View {
        WorkspaceFilterField(
            query: $query, focus: $searchFocused, prompt: "Filter apps", label: "Filter running apps",
            identifier: "quick-apps.search", height: 32
        )
    }

    private func listHeight(_ entries: [Entry]) -> CGFloat {
        let extra = entries.reduce(0) { $0 + (warnings[$1.id] == nil ? 0 : 18) }
        return min(maximumBodyHeight, Self.rowHeight * CGFloat(entries.count) + CGFloat(extra))
    }

    private func appRow(_ entry: Entry) -> some View {
        let waiting = pending.contains(entry.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if let icon = entry.application.icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: 19))
                            .foregroundStyle(WorkspaceStyle.mutedInk)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Text(verbatim: entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 9)
                Button {
                    quit(entry)
                } label: {
                    HStack(spacing: 5) {
                        if waiting { ProgressView().controlSize(.mini) }
                        Text(waiting ? "Quitting" : "Quit")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 9)
                    .frame(minHeight: 27)
                    .background(WorkspaceStyle.control, in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
                }
                .buttonStyle(WorkspaceButton())
                .foregroundStyle(waiting ? WorkspaceStyle.disabledInk : WorkspaceStyle.ink)
                .disabled(waiting)
                .help("Ask \(entry.name) to quit normally")
                .accessibilityLabel(waiting ? "Quitting \(entry.name)" : "Quit \(entry.name)")
                .accessibilityIdentifier("quick-apps.quit.\(entry.id.pid)")
                .frame(width: 94, alignment: .trailing)
            }
            .frame(height: Self.rowHeight)

            if let warning = warnings[entry.id] {
                Text(verbatim: warning)
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .topLeading)
                    .padding(.leading, 33)
                    .accessibilityIdentifier("quick-apps.quit-status.\(entry.id.pid)")
            }
        }
        .padding(.horizontal, 6)
    }

    private func reload() {
        apps = Self.snapshot()
        let live = Set(apps.map(\.id))
        pending.formIntersection(live)
        warnings = warnings.filter { live.contains($0.key) }
    }

    private static func snapshot() -> [Entry] {
        NSWorkspace.shared.runningApplications.compactMap { entry(for: $0) }.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id.pid < right.id.pid : order == .orderedAscending
        }
    }

    private static func entry(for application: NSRunningApplication) -> Entry? {
        guard !application.isTerminated, application.activationPolicy == .regular,
              application.processIdentifier > 1, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleURL = application.bundleURL, bundleURL.pathExtension.lowercased() == "app",
              !bundleURL.path.hasPrefix(coreServicesPath),
              Bundle.main.bundleIdentifier.map({ application.bundleIdentifier != $0 }) != false,
              !protectedBundleIdentifiers.contains(application.bundleIdentifier?.lowercased() ?? "")
        else { return nil }

        let name = application.localizedName
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return Entry(id: .init(pid: application.processIdentifier, start: application.launchDate),
                     name: name, bundleURL: bundleURL, application: application)
    }

    private func quit(_ entry: Entry) {
        let id = entry.id
        guard !pending.contains(id) else { return }
        warnings.removeValue(forKey: id)

        guard let current = NSRunningApplication(processIdentifier: id.pid),
              let observed = Self.entry(for: current),
              observed.id == id, observed.bundleURL == entry.bundleURL,
              id.start != nil || current === entry.application
        else {
            reload()
            return
        }

        guard current.terminate() else {
            if current.isTerminated { reload() }
            else { warnings[id] = "Couldn’t request quit." }
            return
        }

        pending.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard pending.contains(id) else { return }
            reload()
            if pending.remove(id) != nil {
                warnings[id] = "Still open. Check for a save prompt."
            }
        }
    }
}
