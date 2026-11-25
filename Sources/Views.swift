import AppKit
import SwiftUI

// Select the native property wrapper explicitly: SDKs that also provide a
// State macro can omit its plug-in from Command Line Tools installations.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var showingSettings = false
    @ViewState private var searchByMode: [ProcessViewMode: String] = [:]
    @ViewState private var interruptTarget: AgentActivity?
    @ViewState private var confirmingInterrupt = false
    @ViewState private var ramSort: Bool? = nil
    @ViewState private var showAgentPIDColumn = false
    @FocusState private var searchFocused: Bool
    var addProjectAction: ((DevProcess?) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            navigation
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(showingSettings ? "Settings" : workspaceTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.35)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if !showingSettings {
                        filterField
                        refreshButton
                    }
                }
                .padding(.horizontal, WorkspaceStyle.gutter)
                .padding(.top, 16)
                .padding(.bottom, 12)
                if showingSettings {
                    PreferencesView(addProjectAction: addProjectAction.map { open in { open(nil) } })
                } else {
                    WorkspaceSeparator().padding(.horizontal, WorkspaceStyle.gutter)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if model.processViewMode == .agents, FeatureFlags.sessionRecovery { SessionRecoveryView() }
                            if let error = model.lastError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .padding(.vertical, 6)
                            }
                            content
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: Bool.self) { geometry in
                            geometry.size.width >= AgentObservationRow.pidColumnThreshold
                        } action: { fits in
                            showAgentPIDColumn = fits
                        }
                        .padding(.horizontal, WorkspaceStyle.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                    .workspaceScrollEdges()
                    .id(model.processViewMode)
                    WorkspaceSeparator().padding(.horizontal, WorkspaceStyle.gutter)
                    workspaceFooter
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(WorkspaceStyle.ink)
        .alert("Interrupt this command?", isPresented: $confirmingInterrupt, presenting: interruptTarget) { item in
            Button("Cancel", role: .cancel) {}
            Button("Interrupt", role: .destructive) { model.stopAgent(item) }
        } message: { item in
            if let pid = item.pid {
                Text("Requests a stop for \(item.title) (PID \(pid)) and its verified child processes. Unsaved output may be lost.")
            }
        }
        .screenBoundedPanel(.processes)
    }

    private var workspaceFooter: some View {
        HStack(spacing: 8) {
            SystemResourceSummary(resources: model.systemResources)
            Spacer(minLength: 4)
            if model.processViewMode == .agents,
               model.agentActivities.contains(where: { $0.kind == .unavailable }) {
                Text("Scan unavailable")
            } else if let completed = model.activeScanCompletedAt {
                TimelineView(.periodic(from: completed, by: 1)) { context in
                    let seconds = Int(max(0, context.date.timeIntervalSince(completed)))
                    Text(seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago")
                }
                .help("Time since the last scan for this view")
                .accessibilityIdentifier("workspace.scan-age")
            } else {
                Text("Not yet scanned")
            }
            Button { model.toggleWorkspaceScanPause() } label: {
                Image(systemName: model.isWorkspaceScanPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(WorkspaceButton(selected: model.isWorkspaceScanPaused))
            .accessibilityLabel(model.isWorkspaceScanPaused ? "Resume auto-scan" : "Pause auto-scan")
            .accessibilityIdentifier("workspace.scan-toggle")
            .help(model.isWorkspaceScanPaused ? "Resume auto-scan" : "Pause auto-scan")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(WorkspaceStyle.mutedInk)
        .lineLimit(1)
        .padding(.horizontal, WorkspaceStyle.gutter)
        .padding(.vertical, 10)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ProcessViewMode.allCases) { mode in
                let selected = !showingSettings && model.processViewMode == mode
                let route = navigationRoute(for: mode)
                Button {
                    searchFocused = false
                    showingSettings = false
                    if model.processViewMode != mode { model.processViewMode = mode }
                } label: {
                    navLabel(mode.title, symbol: route.symbol, shortcut: route.hint)
                }
                .buttonStyle(WorkspaceButton(selected: selected))
                .keyboardShortcut(route.key, modifiers: .command)
                .help("\(mode.title) (\(route.hint))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 8)
            if addProjectAction != nil {
                Button { addProjectAction?(nil) } label: {
                    navLabel("Add project", symbol: "plus")
                }
                .buttonStyle(WorkspaceButton())
            }
            Button {
                searchFocused = false
                showingSettings.toggle()
            } label: {
                navLabel("Settings", symbol: showingSettings ? "gearshape.fill" : "gearshape", shortcut: "⌘,")
            }
            .buttonStyle(WorkspaceButton(selected: showingSettings))
            .help("Settings (⌘,)")
            .accessibilityAddTraits(showingSettings ? .isSelected : [])
            .accessibilityIdentifier("workspace.settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 10)
        // The standard window buttons remain in their native AppKit positions.
        .padding(.top, 36)
        .frame(width: 152)
        .frame(maxHeight: .infinity)
        .modifier(WorkspaceRail())
    }

    private func navLabel(_ title: String, symbol: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 17)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .medium))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if let shortcut {
                Spacer(minLength: 0)
                Text(verbatim: shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func navigationRoute(for mode: ProcessViewMode) -> (symbol: String, key: KeyEquivalent, hint: String) {
        switch mode {
        case .agents: ("terminal", "1", "⌘1")
        case .dev: ("chevron.left.forwardslash.chevron.right", "2", "⌘2")
        case .all: ("point.3.connected.trianglepath.dotted", "3", "⌘3")
        case .activity: ("waveform.path", "4", "⌘4")
        }
    }

    private var refreshButton: some View {
        Button { model.refresh() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(WorkspaceButton())
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel("Refresh")
        .help("Refresh (⌘R)")
    }

    private var workspaceTitle: String {
        switch model.processViewMode {
        case .agents: "Agent activity"
        case .dev: "Development servers"
        case .all: "Listening ports"
        case .activity: "Resource activity"
        }
    }

    private var filterScope: (prompt: String, label: String, help: String) {
        switch model.processViewMode {
        case .agents:
            ("Project or PID", "Filter agents", "Filter by project, command, provider, or PID (⌘F)")
        case .dev, .all:
            ("URL, port, PID", "Filter listening processes", "Filter by project, framework, host, URL, port, or PID (⌘F)")
        case .activity:
            ("App or PID", "Filter resource activity", "Filter by app, process type, or any PID (⌘F)")
        }
    }

    private var filterField: some View {
        let scope = filterScope
        return WorkspaceFilterField(
            query: Binding(get: { query }, set: { query = $0 }),
            focus: $searchFocused, prompt: scope.prompt, label: scope.label,
            identifier: "workspace.filter", height: 34, clearsOnEscape: true
        )
        // A list column appearing/disappearing must not shift header controls.
        .frame(width: 150)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
        }
        .help(scope.help)
    }

    // Each view owns its filter; switching views never focuses the field or
    // makes the user retype a process ID on the way back.
    private var query: String {
        get { searchByMode[model.processViewMode] ?? "" }
        nonmutating set { searchByMode[model.processViewMode] = newValue }
    }

    private var filterTokens: [Substring] {
        query.split(whereSeparator: { $0.isWhitespace || $0 == "·" })
    }

    /// Search attributes the workspace shows or copies, never raw command arguments.
    private func filter<Row>(_ rows: [Row], text: (Row) -> [String], numbers: (Row) -> [Int]) -> [Row] {
        let tokens = filterTokens
        guard !tokens.isEmpty else { return rows }
        return rows.filter { row in
            let fields = text(row)
            let identifiers = numbers(row)
            return tokens.allSatisfy { token in
                if let number = Int(token) { return identifiers.contains(number) }
                return fields.contains { $0.localizedStandardContains(String(token)) }
            }
        }
    }

    private var filteredAgents: [AgentActivity] {
        filter(model.agentActivities, text: { row in
            [row.title, row.detail, row.kind.title, row.project ?? "", row.toolContext ?? "",
             row.provider?.title ?? "", row.parentName ?? "", row.projectFolder ?? ""]
        }, numbers: { row in
            row.memberPIDs.map(Int.init) + (row.pid.map { [Int($0)] } ?? [])
        })
    }

    @ViewBuilder private var content: some View {
        if let message = model.activeLocalActionMessage {
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(WorkspaceStyle.ink)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("workspace.process-action-status")
        }
        if model.activeScanCompletedAt == nil {
            HStack(spacing: 8) {
                if !model.isWorkspaceScanPaused {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(model.isWorkspaceScanPaused ? "Auto-scan paused" : "Scanning this Mac…")
                    .font(.callout)
            }
            .foregroundStyle(WorkspaceStyle.mutedInk)
            .padding(.vertical, 12)
            .accessibilityIdentifier("workspace.scanning")
        } else {
            switch model.processViewMode {
            case .agents:
                agentList
            case .activity:
                let all = model.activityProcesses
                let items = filter(all, text: { [$0.name, $0.kind.title, $0.detail] },
                                   numbers: { $0.targetPIDs.map(Int.init) })
                if all.isEmpty { EmptyStateView() }
                else if items.isEmpty { noMatches }
                else { ForEach(items) { ActivityProcessRow(process: $0) } }
            case .dev, .all:
                let all = model.processes
                let items = filter(all, text: { row in
                    [row.name, row.kind.title, row.framework, row.cwd ?? "", row.host, row.urlString]
                }, numbers: { [$0.port, Int($0.pid)] })
                if all.isEmpty { EmptyStateView() }
                else if items.isEmpty { noMatches }
                else {
                    ForEach(items) {
                        ProcessRow(process: $0, usesDirectActions: true,
                                   configureRestart: { addProjectAction?($0) })
                    }
                }
            }
        }
    }

    @ViewBuilder private var agentList: some View {
        let rows = filteredAgents
        let work = rows.filter { $0.kind == .work }
        let services = rows.filter { $0.kind == .service || $0.kind == .host }
        let unavailable = model.agentActivities.first { $0.kind == .unavailable }

        if let message = model.agentActionMessage {
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(WorkspaceStyle.ink)
                .padding(.vertical, 8)
                .accessibilityIdentifier("agents.action-status")
        }

        if let unavailable {
            agentScanState(unavailable.title, detail: unavailable.detail, symbol: "exclamationmark.circle")
        } else if !filterTokens.isEmpty && rows.isEmpty && !model.agentActivities.isEmpty {
            noMatches
        } else {
            if !work.isEmpty {
                agentSection("Local commands", rows: work, showColumns: true)
            } else if filterTokens.isEmpty || model.agentActivities.isEmpty {
                agentScanState("No local agent commands detected", detail: "Cloud jobs aren’t shown here.", symbol: "terminal")
            }
            if !services.isEmpty {
                agentSection("Runtimes and services", rows: services, showColumns: work.isEmpty)
                    .padding(.top, work.isEmpty && !filterTokens.isEmpty ? 0 : 13)
            }
        }
    }

    private func agentScanState(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WorkspaceStyle.mutedInk)
                .accessibilityHidden(true)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.callout.weight(.medium))
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 10)
    }

    private func agentSection(_ title: String, rows: [AgentActivity], showColumns: Bool) -> some View {
        Section {
            ForEach(sortedByMemory(rows)) { item in
                let interrupting = model.stoppingAgentIDs.contains(item.id)
                AgentObservationRow(
                    item: item,
                    interrupting: interrupting,
                    showPIDColumn: showAgentPIDColumn
                ) {
                    interruptTarget = item
                    confirmingInterrupt = true
                }
            }
        } header: {
            HStack(spacing: AgentObservationRow.columnSpacing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if showColumns {
                    Button {
                        ramSort = ramSort.map { !$0 } ?? true
                    } label: {
                        HStack(spacing: 4) {
                            Text("RAM")
                            if let ramSort {
                                Image(systemName: ramSort ? "arrow.down" : "arrow.up")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                        }
                        .frame(width: AgentObservationRow.ramWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Sort by memory")
                    .accessibilityValue(ramSort.map { $0 ? "Highest first" : "Lowest first" } ?? "Default order")
                    .help("Sort by memory")
                    if showAgentPIDColumn {
                        Text("PID")
                            .frame(width: AgentObservationRow.pidWidth, alignment: .trailing)
                    }
                    Text("Actions")
                        .frame(width: WorkspaceRowActionMetrics.width)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkspaceStyle.mutedInk)
            .padding(.horizontal, AgentObservationRow.horizontalInset)
            .padding(.vertical, 5)
        }
    }

    private func sortedByMemory(_ rows: [AgentActivity]) -> [AgentActivity] {
        guard let ramSort else { return rows }
        return rows.enumerated().sorted { left, right in
            switch (left.element.memoryBytes, right.element.memoryBytes) {
            case let (leftBytes?, rightBytes?) where leftBytes != rightBytes:
                return ramSort ? leftBytes > rightBytes : leftBytes < rightBytes
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    private var noMatches: some View {
        HStack {
            Text("No matches for this filter.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Clear filter") {
                query = ""
                searchFocused = true
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 12)
    }
}

private enum WorkspaceRowActionMetrics {
    static let size: CGFloat = 28
    static let spacing: CGFloat = 3
    static let width = 4 * size + 3 * spacing
}

private struct WorkspaceRowActions<Reveal: View, Copy: View, Extra: View, Stop: View>: View {
    @ViewBuilder var reveal: () -> Reveal
    @ViewBuilder var copy: () -> Copy
    @ViewBuilder var extra: () -> Extra
    @ViewBuilder var stop: () -> Stop

    var body: some View {
        HStack(spacing: WorkspaceRowActionMetrics.spacing) {
            reveal().frame(width: WorkspaceRowActionMetrics.size)
            copy().frame(width: WorkspaceRowActionMetrics.size)
            extra().frame(width: WorkspaceRowActionMetrics.size)
            stop().frame(width: WorkspaceRowActionMetrics.size)
        }
        .frame(width: WorkspaceRowActionMetrics.width, height: WorkspaceRowActionMetrics.size)
    }
}

private struct WorkspaceRowAction: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    var unavailableReason: String?
    var pending: String?
    var selected = false
    var hint: String?
    let action: () -> Void

    init(_ title: String, symbol: String, role: ButtonRole? = nil,
         unavailableReason: String? = nil, pending: String? = nil,
         selected: Bool = false, hint: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.unavailableReason = unavailableReason
        self.pending = pending
        self.selected = selected
        self.hint = hint
        self.action = action
    }

    var body: some View {
        Group {
            if let pending {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(pending)
            } else {
                Button(role: role, action: action) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(unavailableReason == nil ? WorkspaceStyle.ink : WorkspaceStyle.disabledInk)
                        .frame(width: WorkspaceRowActionMetrics.size, height: WorkspaceRowActionMetrics.size)
                }
                .buttonStyle(WorkspaceButton(selected: selected))
                .disabled(unavailableReason != nil)
                .accessibilityLabel(title)
                .accessibilityHint(unavailableReason ?? hint ?? "")
            }
        }
        .frame(width: WorkspaceRowActionMetrics.size, height: WorkspaceRowActionMetrics.size)
        .contentShape(Rectangle())
        .help(unavailableReason ?? pending ?? title)
    }
}

private struct AgentObservationRow: View {
    nonisolated static let pidColumnThreshold: CGFloat = 500
    static let horizontalInset: CGFloat = 10
    static let columnSpacing: CGFloat = 10
    static let ramWidth: CGFloat = 68
    static let pidWidth: CGFloat = 48
    let item: AgentActivity
    let interrupting: Bool
    let showPIDColumn: Bool
    let onInterrupt: () -> Void
    @ViewState private var copied = false
    @ViewState private var showingDetails = false

    private var symbol: String {
        switch item.kind {
        case .work: "terminal"
        case .service: "gearshape.2"
        case .host: "macwindow"
        case .unavailable: "exclamationmark.circle"
        }
    }

    private var primary: String { item.title }

    private var secondary: String {
        guard item.kind == .work else { return item.detail }
        let context = item.toolContext.flatMap {
            item.title.localizedStandardContains($0) ? nil : $0
        }
        let values = [item.project, item.provider?.title, context]
            .compactMap { $0 }
            .filter { $0.localizedCaseInsensitiveCompare(primary) != .orderedSame }
        if !values.isEmpty { return values.joined(separator: " · ") }
        if let started = item.startedAt {
            return "Started \(started.formatted(date: .omitted, time: .standard))"
        }
        return item.kind.title
    }

    private var memory: String? { item.memoryBytes.map(byteString) }
    private var pid: String? { item.pid.map { String($0) } }
    private var cpu: String? {
        item.cpuPercent.map { String(format: $0 < 10 ? "%.1f%%" : "%.0f%%", $0) }
    }
    private var parent: String? {
        let fields = [item.parentName, item.parentPID.map { "PID \($0)" }].compactMap { $0 }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    private var stopUnavailableReason: String? {
        switch item.kind {
        case .work:
            return item.pid != nil && item.identity != nil
                ? nil
                : "The process group could not be verified for a safe stop."
        case .service:
            return "Tool services are read-only here."
        case .host:
            return "Agent runtimes are read-only here."
        case .unavailable:
            return "There is no process to stop."
        }
    }

    private var copyablePIDs: [Int32] {
        let members = item.memberPIDs
        return members.isEmpty ? item.pid.map { [$0] } ?? [] : members
    }

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            rowLabel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(primary), \(secondary)")
                .accessibilityValue(accessibleSummary)
                .accessibilityIdentifier("agents.row.\(item.id)")
            rowActions
        }
        .padding(.trailing, Self.horizontalInset)
        .id(item.id)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: Self.columnSpacing) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(WorkspaceStyle.mutedInk)
                .frame(width: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: primary)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if !showPIDColumn, let pid {
                        Text("PID \(pid)")
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(verbatim: secondary)
                        .truncationMode(showPIDColumn ? .middle : .tail)
                }
                .font(.subheadline)
                .foregroundStyle(WorkspaceStyle.mutedInk)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: memory ?? "—")
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.ramWidth, alignment: .trailing)
            if showPIDColumn {
                Text(verbatim: pid ?? "—")
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .frame(width: Self.pidWidth, alignment: .trailing)
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .padding(.leading, Self.horizontalInset)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private var accessibleSummary: String {
        let size = memory.map { "RAM \($0)" } ?? "RAM unavailable"
        let processID = pid.map { "PID \($0)" }
            ?? (copyablePIDs.isEmpty ? "PID unavailable" : "\(copyablePIDs.count) process IDs")
        return [size, processID].joined(separator: ", ")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: primary)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .lineLimit(2)
            if item.kind == .work {
                inspectorPair(
                    ("Project", item.project), ("Provider", item.provider?.title)
                )
                inspectorPair(
                    ("Classification", item.toolContext ?? item.kind.title),
                    ("Started", item.startedAt?.formatted(date: .abbreviated, time: .standard))
                )
                inspectorPair(
                    ("PID", pid), ("RAM", memory)
                )
                if cpu != nil || item.groupedProcessCount != nil {
                    inspectorPair(("CPU", cpu), ("Processes", item.groupedProcessCount.map(String.init)))
                }
            } else {
                inspectorPair(
                    ("Provider", item.provider?.title ?? item.kind.title), ("PID", pid)
                )
                if memory != nil || cpu != nil {
                    inspectorPair(("RAM", memory), ("CPU", cpu))
                }
            }
            if let folder = item.projectFolder {
                inspectorFact("Project folder", folder)
            }
            if let parent {
                inspectorFact("Parent process", parent)
            }
            if copyablePIDs.count > 1 {
                inspectorFact("Process IDs", copyablePIDs.map(String.init).joined(separator: " · "))
            }
            if let reason = stopUnavailableReason {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(width: 326, alignment: .leading)
    }

    @ViewBuilder private func inspectorPair(_ first: (String, String?), _ second: (String, String?)) -> some View {
        if first.1 != nil || second.1 != nil {
            HStack(alignment: .top, spacing: 14) {
                inspectorFact(first.0, first.1)
                inspectorFact(second.0, second.1)
            }
        }
    }

    @ViewBuilder private func inspectorFact(_ label: String, _ value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                Text(verbatim: value)
                    .font(.callout.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            // Keep alternating facts aligned without making absent facts look actionable.
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                .accessibilityHidden(true)
        }
    }

    private var rowActions: some View {
        WorkspaceRowActions {
            WorkspaceRowAction("Reveal project in Finder", symbol: "folder",
                               unavailableReason: item.projectFolder == nil ? "No project folder was verified for this process." : nil) {
                guard let path = item.projectFolder else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
            }
            .accessibilityIdentifier("agents.reveal.\(item.id)")
        } copy: {
            copyPIDButton
        } extra: {
            WorkspaceRowAction("Process details", symbol: "info.circle", selected: showingDetails) {
                showingDetails.toggle()
            }
            .accessibilityIdentifier("agents.details.\(item.id)")
            .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
                FittingScrollView { inspector }
                    .frame(width: 326)
                    .frame(maxHeight: 340)
            }
        } stop: {
            WorkspaceRowAction("Stop \(primary)…", symbol: "stop.circle", role: .destructive,
                               unavailableReason: stopUnavailableReason,
                               pending: interrupting ? "Waiting for this command to exit." : nil,
                               hint: "Requests a stop for this command and its verified child processes.") {
                onInterrupt()
            }
            .accessibilityIdentifier("agents.interrupt.\(item.id)")
        }
    }

    private var copyPIDButton: some View {
        let copyTitle = copyablePIDs.count > 1 ? "Copy \(copyablePIDs.count) PIDs" : "Copy PID"
        return WorkspaceRowAction(copied ? "Copied" : copyTitle,
                                  symbol: copied ? "checkmark" : "document.on.document",
                                  unavailableReason: copyablePIDs.isEmpty ? "No process IDs available." : nil) {
            let board = NSPasteboard.general
            board.clearContents()
            if board.setString(copyablePIDs.map(String.init).joined(separator: "\n"), forType: .string) {
                copied = true
            }
        }
        .accessibilityIdentifier("agents.copy-pid.\(item.id)")
    }
}

private struct SessionRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var isExpanded = false

    private var snapshot: SessionRecoverySnapshot { model.sessionRecoverySnapshot }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                if snapshot.recentEvents.isEmpty {
                    Text("No recovery events yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    ForEach(snapshot.recentEvents.prefix(5)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(event.succeeded ? Color.secondary : Color.orange)
                                .frame(width: 14)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(event.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(event.date, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.statusText)
                        .font(.caption)
                        .foregroundStyle(snapshot.issue == nil ? Color.secondary : Color.orange)
                }

                Spacer()

                if snapshot.pendingCount > 0 {
                    Text("\(snapshot.pendingCount) pending")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)

    }

    private var emptyTitle: String {
        switch model.processViewMode {
        case .agents: return "No local agent commands observed"
        case .dev: return "No dev servers found"
        case .all: return "No listeners found"
        case .activity: return "No heavy background processes"
        }
    }

    private var emptyDetail: String {
        switch model.processViewMode {
        case .agents: return "Only activity on this Mac is shown."
        case .dev: return "Refresh or add a project to start one."
        case .all: return "Refresh to scan local TCP ports."
        case .activity: return "Simulators appear here even without an open port."
        }
    }
}

private struct ProcessRowSurface: ViewModifier {
    var horizontalInset: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityProcessRow: View {
    @EnvironmentObject private var model: AppModel
    let process: ActivityProcess

    @ViewState private var confirmingStop = false

    private var pending: String? {
        process.primaryPID.flatMap { model.pendingLocalActions[$0] }
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(cpuPercent: process.resources.cpuPercent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: process.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: process.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            ResourceMonitor(resources: process.resources, memoryLabel: "RSS")
            if process.kind == .simulator, process.primaryPID != nil {
                Button { confirmingStop = true } label: {
                    Group {
                        if pending != nil { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "stop.circle") }
                    }
                    .frame(width: 17, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!process.canStop || pending != nil)
                .help(pending ?? (process.canStop ? "Request a stop for \(process.name)" : "This process could not be verified for a safe stop."))
                .accessibilityLabel(pending ?? "Stop \(process.name)")
                .confirmationDialog("Stop \(process.name)?", isPresented: $confirmingStop) {
                    Button("Stop", role: .destructive) { model.stop(process) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Requests a stop for the simulator and its verified child processes.")
                }
            }
        }
        .modifier(ProcessRowSurface())
    }
}

private struct ProcessRow: View {
    @EnvironmentObject private var model: AppModel
    let process: DevProcess
    var usesDirectActions = false
    var configureRestart: (DevProcess) -> Void
    @ViewState private var confirmingAction = false
    @ViewState private var confirmingRestart = false
    @ViewState private var showingLogs = false
    @ViewState private var copiedURL = false
    private var pending: String? { model.pendingLocalActions[process.pid] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(cpuPercent: process.resources.cpuPercent)
                VStack(alignment: .leading, spacing: 2) {
                    if process.name.hasPrefix("@"), let package = process.name.split(separator: "/").last {
                        ViewThatFits(in: .horizontal) {
                            Text(verbatim: process.name).fixedSize(horizontal: true, vertical: false)
                            Text(verbatim: String(package)).lineLimit(1)
                        }
                        .font(.body.weight(.medium))
                        .accessibilityLabel(process.name)
                        .help(process.name)
                    } else {
                        Text(verbatim: process.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if usesDirectActions {
                        ViewThatFits(in: .horizontal) {
                            addressLine(process.urlString).fixedSize(horizontal: true, vertical: false)
                            addressLine(":\(process.port)").fixedSize(horizontal: true, vertical: false)
                        }
                    } else {
                        addressLine(process.urlString)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ResourceMonitor(resources: process.resources, stableColumns: usesDirectActions)
                if usesDirectActions {
                    directActions
                } else {
                    processMenu
                }
            }
            if !usesDirectActions, let projectID = process.projectID {
                DisclosureGroup {
                    LogView(text: model.runner.logs(for: projectID))
                        .padding(.top, 4)
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 18)
            }
        }
        .modifier(ProcessRowSurface(horizontalInset: usesDirectActions ? AgentObservationRow.horizontalInset : 4))
        .task(id: copiedURL) {
            guard copiedURL else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copiedURL = false }
        }
    }

    private func addressLine(_ address: String) -> some View {
        HStack(spacing: 7) {
            Button(address) { model.open(process) }
                .buttonStyle(.link)
                .help("Open \(process.urlString) in browser")
                .accessibilityLabel("Open \(process.urlString)")
            Text(verbatim: "PID \(process.pid)")
                .foregroundStyle(WorkspaceStyle.mutedInk)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var directActions: some View {
        WorkspaceRowActions {
            WorkspaceRowAction("Reveal project in Finder", symbol: "folder",
                               unavailableReason: process.cwd == nil ? "No project folder was found for this process." : nil) {
                model.revealProjectFolder(process)
            }
            .accessibilityIdentifier("dev.reveal.\(process.id)")
        } copy: {
            WorkspaceRowAction(copiedURL ? "Copied" : "Copy URL",
                               symbol: copiedURL ? "checkmark" : "document.on.document") {
                model.copyURL(process)
                copiedURL = true
            }
            .accessibilityIdentifier("dev.copy-url.\(process.id)")
        } extra: {
            processMenu
        } stop: {
            WorkspaceRowAction("Stop \(process.name)…", symbol: "stop.circle", role: .destructive,
                               unavailableReason: process.stopUnavailableReason,
                               pending: pending, hint: "Opens a confirmation before stopping this process.") {
                requestAction(restart: false)
            }
            .accessibilityIdentifier("dev.stop.\(process.id)")
        }
    }

    private var processMenu: some View {
        Menu {
            if !usesDirectActions {
                Button("Open in Browser") { model.open(process) }
                Button("Copy URL") { model.copyURL(process) }
                Button("Reveal in Finder") { model.revealProjectFolder(process) }
                    .disabled(process.cwd == nil)
                Divider()
            }
            if process.canRestart {
                Button("Restart…") { requestAction(restart: true) }
                    .disabled(!process.canStop || pending != nil)
            } else {
                Button("Set up restart…") { configureRestart(process) }
            }
            if usesDirectActions, process.projectID != nil {
                Button("Show Logs") { showingLogs = true }
            }
            if !usesDirectActions {
                Button("Stop…", role: .destructive) { requestAction(restart: false) }
                    .disabled(!process.canStop || pending != nil)
            }
            if let note = pending ?? process.stopUnavailableReason {
                Text(verbatim: note)
            }
        } label: {
            Group {
                if !usesDirectActions, pending != nil { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: usesDirectActions ? 13 : 12, weight: .medium))
                }
            }
            .frame(width: usesDirectActions ? WorkspaceRowActionMetrics.size : 17,
                   height: usesDirectActions ? WorkspaceRowActionMetrics.size : 18)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(process.name) on port \(process.port)")
        .accessibilityValue(pending ?? "")
        .help("More actions")
        .popover(isPresented: $showingLogs, arrowEdge: .trailing) {
            if let projectID = process.projectID {
                ScrollView {
                    LogView(text: model.runner.logs(for: projectID))
                        .padding(12)
                }
                .frame(width: 420, height: 250)
            }
        }
        .confirmationDialog(
            "\(confirmingRestart ? "Restart" : "Stop") \(process.name) on port \(process.port)?",
            isPresented: $confirmingAction
        ) {
            if confirmingRestart {
                Button("Restart", role: .destructive) { model.restart(process) }
            } else {
                Button("Stop Process", role: .destructive) { model.stop(process) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmingRestart
                 ? "Starts the project again only after the old process group exits and the port is free."
                 : "Requests a stop for PID \(process.pid) and its verified child processes.")
        }
    }

    private func requestAction(restart: Bool) {
        guard process.canStop, pending == nil else { return }
        confirmingRestart = restart
        confirmingAction = true
    }
}
private struct ResourceMonitor: View {
    let resources: ResourceUsage
    var memoryLabel: String = "RAM"
    var stableColumns = false

    var body: some View {
        HStack(spacing: 12) {
            Text("CPU \(cpuText)")
                .frame(width: stableColumns ? 57 : nil, alignment: .trailing)
            Text("\(memoryLabel) \(memoryText)")
                .frame(width: stableColumns ? 62 : nil, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Uptime \(cleanUptime)")
    }

    private var cpuText: String {
        resources.cpuPercent < 10
            ? String(format: "%.1f%%", resources.cpuPercent)
            : String(format: "%.0f%%", resources.cpuPercent)
    }

    private var memoryText: String {
        resources.memoryMegabytes >= 1024
            ? String(format: "%.1fG", resources.memoryMegabytes / 1024)
            : String(format: "%.0fM", resources.memoryMegabytes)
    }

    private var cleanUptime: String {
        resources.uptime.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private struct StatusDot: View {
    let cpuPercent: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)

    }

    private var color: Color {
        if cpuPercent >= 80 { return .red }
        if cpuPercent >= 35 { return .orange }
        return .secondary
    }
}

private struct IconActionButton: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let disabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct SystemResourceSummary: View {
    let resources: SystemResourceUsage

    var body: some View {
        HStack(spacing: 9) {
            Text("CPU \(cpuText)")
                .help("Total system CPU")
            Text("RAM \(memoryCompactText)")
                .help("Physical memory: \(memoryDetail)")
            HStack(spacing: 3) {
                if resources.swap?.isActive == true {
                    Image(systemName: "arrow.left.arrow.right")
                }
                Text("Swap \(swapText)")
            }
            .foregroundStyle(resources.swap?.isActive == true ? .orange : .secondary)
            .help(swapDetail)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System CPU \(cpuText), physical memory \(memoryDetail), \(swapDetail)")
    }

    private var cpuText: String {
        guard let cpu = resources.cpuPercent else { return "--" }
        return String(format: "%.0f%%", cpu)
    }

    private var memoryCompactText: String {
        "\(byteString(resources.memoryUsedBytes))/\(byteString(resources.memoryTotalBytes))"
    }

    private var memoryDetail: String {
        "\(byteString(resources.memoryUsedBytes)) of \(byteString(resources.memoryTotalBytes))"
    }

    private var swapText: String {
        guard let swap = resources.swap else { return "--" }
        return swap.usedBytes == 0 ? "0 B" : byteString(swap.usedBytes)
    }

    private var swapDetail: String {
        guard let swap = resources.swap else { return "Swap unavailable" }
        guard swap.isActive else { return "Swap not in use" }
        return "Swap in use: \(byteString(swap.usedBytes))"
    }
}

struct AddProjectView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    private let inspector = PackageScriptInspector()

    @ViewState private var name = ""
    @ViewState private var cwd = ""
    @ViewState private var command = ""
    @ViewState private var port = "3000"
    @ViewState private var packageManager = "npm"
    @ViewState private var scripts: [PackageScript] = []
    @ViewState private var selectedScript = ""
    @ViewState private var inspectedFolder: String?
    @ViewState private var suggestedCommand: String?
    @ViewState private var suggestedName: String?
    @ViewState private var suggestedPort: String? = "3000"
    @ViewState private var folderState = "Choose a project folder to find its launch scripts."

    init(process: DevProcess? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let process {
            _name = State(initialValue: process.name)
            _cwd = State(initialValue: process.cwd ?? "")
            _port = State(initialValue: String(process.port))
            _suggestedPort = State(initialValue: nil)
            _inspectedFolder = State(initialValue: process.cwd)
            _folderState = State(initialValue: "Enter the command used to start this process.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sheetHeader("Add Project", systemImage: "plus.app")
                Spacer()
                Button("Cancel") { onClose() }
            }

            FittingScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsBlock {
                        FieldBlock(title: "Project folder") {
                            HStack(spacing: 8) {
                                TextField("Path to a folder", text: folderChoice)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Project folder")
                                    .onSubmit { loadFolder() }

                                Button {
                                    chooseFolder()
                                } label: {
                                    Label("Choose…", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Text(folderState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsBlock {
                        HStack(spacing: 10) {
                            FieldBlock(title: "Name") {
                                TextField("Project name", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            FieldBlock(title: "Port") {
                                TextField("3000", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Port")
                            }
                            .frame(width: 85)
                        }

                        if !scripts.isEmpty {
                            FieldBlock(title: "Package manager") {
                                Picker("Package manager", selection: managerChoice) {
                                    Text("npm").tag("npm")
                                    Text("pnpm").tag("pnpm")
                                    Text("yarn").tag("yarn")
                                    Text("bun").tag("bun")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }

                            ScriptPreviewList(scripts: scripts, selectedScript: scriptChoice)
                        }

                        FieldBlock(title: "Launch command") {
                            TextField("Enter a command", text: $command)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Launch command")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let validationMessage, !folderPath.isEmpty, validationMessage != folderState {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    loadFolder()
                } label: {
                    Label("Load Scripts", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(folderPath.isEmpty)

                Spacer()

                Button("Save") {
                    saveProject(start: false)
                }
                .disabled(validationMessage != nil)

                Button("Save & Start") {
                    saveProject(start: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .screenBoundedPanel(.project)
    }

    private var folderPath: String { (trimmed(cwd) as NSString).expandingTildeInPath }

    private var folderChoice: Binding<String> {
        Binding(get: { cwd }, set: { path in
            cwd = path
            guard folderPath != inspectedFolder else { return }
            if command == suggestedCommand { command = "" }
            inspectedFolder = nil
            suggestedCommand = nil
            selectedScript = ""
            scripts = []
            folderState = "Load scripts from this folder or enter a launch command."
        })
    }

    private var managerChoice: Binding<String> {
        Binding(get: { packageManager }, set: { manager in
            packageManager = manager
            if command == suggestedCommand { applySelectedScript() }
        })
    }

    private var scriptChoice: Binding<String> {
        Binding(get: { command == suggestedCommand ? selectedScript : "" }, set: { script in
            selectedScript = script
            applySelectedScript()
        })
    }

    private var validationMessage: String? {
        if folderPath.isEmpty { return "Choose a project folder before saving." }
        if !isDirectory(folderPath) { return "Enter the path to an existing folder." }
        if trimmed(name).isEmpty { return "Enter a project name." }
        if Int(trimmed(port)).map({ (1...65535).contains($0) }) != true { return "Use a port from 1 to 65535." }
        if trimmed(command).isEmpty { return "Select a script or enter a launch command." }
        return nil
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
            loadFolder()
        }
    }

    private func loadFolder() {
        let cleaned = folderPath
        inspectedFolder = cleaned
        cwd = cleaned

        guard isDirectory(cleaned) else {
            folderState = "Enter the path to an existing folder."
            if command == suggestedCommand { command = "" }
            suggestedCommand = nil
            selectedScript = ""
            scripts = []
            return
        }

        let info = inspector.inspect(cwd: cleaned)
        if trimmed(name).isEmpty || name == suggestedName {
            name = info?.name ?? URL(fileURLWithPath: cleaned).lastPathComponent
            suggestedName = name
        }
        guard let info, !info.scripts.isEmpty else {
            folderState = "No package scripts found. Enter a launch command."
            if command == suggestedCommand { command = "" }
            suggestedCommand = nil
            selectedScript = ""
            scripts = []
            return
        }

        let shouldSuggestCommand = trimmed(command).isEmpty || command == suggestedCommand
        let preferred = info.scripts.first { $0.name == selectedScript } ?? info.scripts[0]
        packageManager = info.packageManager
        if trimmed(port).isEmpty || port == suggestedPort {
            port = String(info.suggestedPort)
            suggestedPort = port
        }
        scripts = info.scripts
        selectedScript = preferred.name
        if shouldSuggestCommand { applySelectedScript() }
        folderState = "Scripts from package.json"
    }

    private func applySelectedScript() {
        guard scripts.contains(where: { $0.name == selectedScript }) else { return }
        let generated = inspector.command(packageManager: packageManager, scriptName: selectedScript)
        command = generated
        suggestedCommand = generated
    }

    private func saveProject(start: Bool) {
        guard validationMessage == nil, let portNumber = Int(trimmed(port)) else { return }
        let project = ManualProject(
            name: trimmed(name),
            cwd: folderPath,
            command: trimmed(command),
            port: portNumber
        )
        model.addProject(project)
        if start {
            model.start(project)
        }
        onClose()
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = GitHubUpdater.shared
    var addProjectAction: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsBlock {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at login")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Start PortsKiller in the menu bar after macOS login.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.loginItemEnabled },
                                set: { model.setLoginItemEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Launch at login")
                    }
                    WorkspaceSeparator().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Menu bar metric")
                            .font(.system(size: 13, weight: .semibold))

                        Picker("Menu bar metric", selection: $model.menuBarMetric) {
                            ForEach(MenuBarMetric.allCases) { metric in
                                Text(metric.title).tag(metric)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                SettingsBlock {
                    VStack(alignment: .leading, spacing: 12) {
                        if FeatureFlags.sessionRecovery {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Codex session recovery")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Disable to stop reading ~/.codex sessions and skip resume attempts when apps crash.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { model.isSessionRecoveryEnabled },
                                        set: { model.setSessionRecoveryEnabled($0) }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel("Codex session recovery")
                            }
                        }

                        HStack(spacing: 10) {
                            Text("Software updates")
                                .font(.system(size: 13, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 0)
                            if updater.isAvailable {
                                Button {
                                    updater.checkForUpdates(manual: true)
                                } label: {
                                    Label(updater.isChecking ? "Checking…" : "Check for Updates", systemImage: "arrow.clockwise")
                                }
                                .disabled(updater.isChecking || updater.isDownloading)
                                .controlSize(.small)
                                .fixedSize()
                            }
                        }

                        Text(updater.isAvailable ? "Installed version \(updater.currentVersion)" : "This build: \(updater.currentVersion)")
                            .font(.caption)
                            .foregroundStyle(WorkspaceStyle.mutedInk)

                        if updater.isAvailable {
                            updateFeedback

                            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                                .font(.callout)
                                .toggleStyle(.switch)
                                .controlSize(.small)

                            Toggle("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
                                .font(.callout)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!updater.automaticallyChecksForUpdates)
                                .help(updater.automaticallyChecksForUpdates ? "Downloads updates before asking to install." : "Turn on automatic checks first.")
                        } else {
                            Text("To update, open the copy of PortsKiller in Applications.")
                                .font(.caption)
                                .foregroundStyle(WorkspaceStyle.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Text("Projects")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !model.projects.isEmpty {
                        Text(verbatim: "\(model.projects.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 3) {
                    if model.projects.isEmpty {
                        SettingsBlock {
                            HStack(spacing: 10) {
                                Text("No saved projects")
                                    .font(.callout)
                                    .foregroundStyle(WorkspaceStyle.mutedInk)
                                Spacer(minLength: 0)
                                if let addProjectAction {
                                    Button(action: addProjectAction) {
                                        Label("Add Project", systemImage: "plus")
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                    .accessibilityIdentifier("settings.add-project")
                                }
                            }
                        }
                    } else {
                        ForEach(model.projects) { project in
                            ProjectPreferenceRow(project: project)
                                .environmentObject(model)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceStyle.gutter)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var updateFeedback: some View {
        if updater.isDownloading {
            ProgressView("Downloading update", value: updater.downloadProgress)
                .controlSize(.small)
        } else if updater.isChecking {
            Text("Checking GitHub Releases…")
                .font(.caption)
                .foregroundStyle(WorkspaceStyle.mutedInk)
        } else {
            if let error = updater.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updater.updateAvailable, let version = updater.latestVersion, updater.downloadURL != nil {
                HStack(spacing: 8) {
                    Text("Version \(version) available")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        updater.startDownload()
                    } label: {
                        Label("Download Update", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Downloads the update. Installation requires confirmation.")
                }
            } else if updater.error == nil, updater.latestVersion != nil {
                Text("You’re up to date.")
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.mutedInk)
            }
        }
    }
}

private struct FieldBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct ScriptPreviewList: View {
    let scripts: [PackageScript]
    @Binding var selectedScript: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scripts")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(scripts) { script in
                    Button {
                        selectedScript = script.name
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedScript == script.name ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedScript == script.name ? WorkspaceStyle.ink : WorkspaceStyle.mutedInk)

                            Text(script.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 92, alignment: .leading)

                            Text(script.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(WorkspaceButton(selected: selectedScript == script.name))
                    .accessibilityAddTraits(selectedScript == script.name ? .isSelected : [])
                    .help("\(script.name): \(script.body)")
                }
            }
        }
    }
}

private struct SettingsBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(WorkspaceStyle.group, in: RoundedRectangle(cornerRadius: WorkspaceStyle.groupRadius))
    }
}

private struct ProjectPreferenceRow: View {
    @EnvironmentObject private var model: AppModel
    let project: ManualProject

    var body: some View {
        SettingsBlock {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(verbatim: ":\(project.port)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text(project.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(verbatim: project.command)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    IconActionButton("Start", systemImage: "play.fill") {
                        model.start(project)
                    }
                    IconActionButton("Reveal in Finder", systemImage: "folder") {
                        model.revealProject(project)
                    }
                    IconActionButton("Remove", systemImage: "trash", role: .destructive) {
                        model.removeProject(id: project.id)
                    }
                }
            }
        }
    }
}

struct LogView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last launch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Copy launch log")
                }
            }

            Text(text.isEmpty ? "No logs for this launch yet." : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private func sheetHeader(_ title: String, systemImage: String) -> some View {
    Text(title).font(.headline)
}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}
