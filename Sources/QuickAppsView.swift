import AppKit
import Combine
import SwiftUI

private typealias QuickAppsState<Value> = SwiftUI.State<Value>

@MainActor
final class QuickAppsFocus: ObservableObject {
    @Published private(set) var request = 0

    func focusSearch() { request &+= 1 }
}

/// The status item's transient launcher for regular apps and observed local processes.
@MainActor
struct QuickAppsView: View {
    @ObservedObject var model: AppModel
    let onOpenWorkspace: () -> Void
    let onClose: () -> Void
    let onSizeChange: (CGSize) -> Void
    let maximumBodyHeight: CGFloat
    @ObservedObject var focusRequest: QuickAppsFocus

    @QuickAppsState private var apps: [Entry]
    @AppStorage("QuickApps.mode") private var mode: Mode = .apps
    @QuickAppsState private var appQuery = ""
    @QuickAppsState private var processQuery = ""
    @QuickAppsState private var processKind: ActivityProcessKind?
    @QuickAppsState private var confirmStop: ActivityProcess?
    @QuickAppsState private var pending: Set<Entry.ID> = []
    @QuickAppsState private var warnings: [Entry.ID: String] = [:]
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Mode: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case processes = "Processes"

        var id: Self { self }
    }

    private static let processKinds: [ActivityProcessKind] = [.simulator, .developerTool, .application, .other, .system]

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
    private static let confirmationHeight: CGFloat = 64
    static let width: CGFloat = 344
    static let maxBodyHeight: CGFloat = 296
    static let maxChromeHeight: CGFloat = 182

    init(model: AppModel, focusRequest: QuickAppsFocus, maximumBodyHeight: CGFloat,
         onSizeChange: @escaping (CGSize) -> Void, onOpenWorkspace: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.model = model
        self.focusRequest = focusRequest
        self.maximumBodyHeight = maximumBodyHeight
        self.onSizeChange = onSizeChange
        self.onOpenWorkspace = onOpenWorkspace
        self.onClose = onClose
        _apps = QuickAppsState(initialValue: Self.snapshot())
    }

    private var appTerms: [Substring] { appQuery.split(whereSeparator: \.isWhitespace) }
    private var processTerms: [Substring] { processQuery.split(whereSeparator: \.isWhitespace) }

    private var matchedApps: [Entry] {
        apps.filter { app in
            appTerms.allSatisfy { term in
                app.name.localizedStandardContains(String(term))
                    || (app.application.bundleIdentifier ?? "").localizedStandardContains(String(term))
            }
        }
    }

    private var matchedProcesses: [ActivityProcess] {
        model.quickActivityProcesses.filter { row in
            guard processKind == nil || processKind == row.kind else { return false }
            return processTerms.allSatisfy { term in
                let text = String(term)
                if let pid = Int32(term) { return row.targetPIDs.contains(pid) }
                return [row.name, row.kind.title, row.detail].contains { $0.localizedStandardContains(text) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            categoryPicker
            HStack(spacing: 6) {
                search
                if mode == .processes { processTypePicker }
            }

            if mode == .apps {
                appsList
            } else {
                processesList
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
            if mode == .processes { model.refreshQuickActivity() }
            // With Reduce Motion, AppKit may have finished before SwiftUI mounted.
            if focusRequest.request != 0 { searchFocused = true }
        }
        .onChange(of: focusRequest.request) { _ in searchFocused = true }
        .onChange(of: mode) { current in
            confirmStop = nil
            if current == .processes { model.refreshQuickActivity() }
        }
        .onChange(of: processQuery) { _ in confirmStop = nil }
        .onChange(of: processKind) { _ in confirmStop = nil }
        .task(id: mode) {
            guard mode == .processes else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard !Task.isCancelled else { return }
                model.refreshQuickActivity()
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            reload()
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 8) {
            Picker("Category", selection: $mode) {
                ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("quick-apps.category")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(WorkspaceButton())
            .accessibilityLabel("Close quick panel")
            .accessibilityIdentifier("quick-apps.close")
            .help("Close (Esc)")
        }
    }

    private var search: some View {
        WorkspaceFilterField(
            query: mode == .apps ? $appQuery : $processQuery,
            focus: $searchFocused,
            prompt: mode == .apps ? "Filter apps" : "Process name or PID",
            label: mode == .apps ? "Filter running apps" : "Filter local processes by name or PID",
            identifier: "quick-apps.search", height: 32
        )
    }

    private var processTypePicker: some View {
        Menu {
            Picker("Process type", selection: $processKind) {
                Text("All types").tag(nil as ActivityProcessKind?)
                ForEach(Self.processKinds, id: \.self) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(processKind?.title ?? "All types")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.mutedInk)
            }
                .padding(.horizontal, 8)
                .frame(width: 91, height: 32)
                .background(WorkspaceStyle.control, in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Process type")
        .accessibilityValue(processKind?.title ?? "All types")
        .accessibilityIdentifier("quick-processes.type")
        .help(processKind.map { "Process type: \($0.title)" } ?? "Filter by process type")
    }

    @ViewBuilder private var appsList: some View {
        let entries = matchedApps
        if entries.isEmpty {
            emptyLabel(appTerms.isEmpty ? "No apps available to quit" : "No matching apps")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { appRow($0) }
                }
            }
            .frame(height: listHeight(entries))
            .id(appQuery)
        }
    }

    @ViewBuilder private var processesList: some View {
        let entries = matchedProcesses
        if let message = model.quickActivityActionMessage {
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(WorkspaceStyle.mutedInk)
                .lineLimit(2)
                .padding(.horizontal, 6)
                .accessibilityIdentifier("quick-processes.action-status")
        }
        if model.activityScanCompletedAt == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Scanning this Mac…")
            }
            .font(.callout)
            .foregroundStyle(WorkspaceStyle.mutedInk)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.leading, 6)
        } else if entries.isEmpty {
            emptyLabel(processTerms.isEmpty && processKind == nil ? "No local activity detected" : "No matching processes")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { row in processRow(row) }
                }
            }
            .frame(height: min(maximumBodyHeight, Self.rowHeight * CGFloat(entries.count) +
                               (entries.contains(where: isConfirming) ? Self.confirmationHeight : 0)))
            .id(processQuery)
        }
    }

    private func emptyLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(WorkspaceStyle.mutedInk)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.leading, 6)
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

    private func isConfirming(_ process: ActivityProcess) -> Bool {
        confirmStop?.id == process.id && confirmStop?.identity == process.identity && process.canStop
    }

    private func compactProcessName(_ name: String) -> String {
        if name == "CoreSimulator services" { return "Simulator services" }
        if name.hasPrefix("Claude Helper ("), let role = name.split(separator: "(").last {
            return "Claude " + role.trimmingCharacters(in: CharacterSet(charactersIn: ")"))
        }
        if name == "Codex (Aperitif Renderer)" { return "Codex Renderer" }
        return name
    }

    private func processRow(_ process: ActivityProcess) -> some View {
        let pid = process.primaryPID
        let pending = pid.flatMap { model.pendingLocalActions[$0] }
        let selected = isConfirming(process)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: processSymbol(process.kind))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: compactProcessName(process.name))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(process.name)
                        .accessibilityLabel(process.name)
                    HStack(spacing: 5) {
                        Text(process.kind.title)
                        if let pid { Text("· PID \(pid)").monospacedDigit() }
                    }
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .lineLimit(1)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 4)
                if process.resources.memoryBytes > 0 {
                    Text(verbatim: ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: process.resources.memoryBytes), countStyle: .memory
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .lineLimit(1)
                    .frame(width: 59, alignment: .trailing)
                    .help("Resident memory")
                }
                if let pending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 57, height: 27)
                        .accessibilityLabel(pending)
                        .help(pending)
                } else if process.canStop, pid != nil {
                    Button {
                        confirmStop = selected ? nil : process
                    } label: {
                        Text("Stop…")
                            .font(.callout.weight(.medium))
                            .frame(width: 57, height: 27)
                    }
                    .buttonStyle(WorkspaceButton(selected: selected, restingFill: true))
                    .accessibilityLabel("Stop \(process.name)")
                    .accessibilityHint("Review the process before sending a stop request.")
                    .accessibilityIdentifier("quick-processes.stop.\(process.id)")
                    .help("Review and stop \(process.name)")
                } else {
                    // Observation-only processes must never appear stoppable.
                    Text("Read-only")
                        .font(.caption2)
                        .foregroundStyle(WorkspaceStyle.mutedInk)
                        .frame(width: 57, alignment: .trailing)
                }
            }
            .frame(height: Self.rowHeight)

            if selected, let target = confirmStop {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Stop this process and its verified children? Unsaved work may be lost.")
                        .font(.caption)
                        .foregroundStyle(WorkspaceStyle.mutedInk)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Cancel") { confirmStop = nil }
                            .accessibilityIdentifier("quick-processes.cancel-stop")
                        Button("Stop", role: .destructive) {
                            confirmStop = nil
                            model.stop(target)
                        }
                        .accessibilityLabel("Confirm stop \(target.name)")
                        .accessibilityIdentifier("quick-processes.confirm-stop")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.leading, 33)
                .frame(height: Self.confirmationHeight, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius).fill(WorkspaceStyle.group)
            }
        }
        .accessibilityIdentifier("quick-processes.row.\(process.id)")
    }

    private func processSymbol(_ kind: ActivityProcessKind) -> String {
        switch kind {
        case .simulator: "iphone"
        case .application: "macwindow"
        case .developerTool: "terminal"
        case .system: "gearshape"
        case .other: "waveform.path"
        }
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
