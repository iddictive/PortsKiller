import AppKit
import SwiftUI

// Select the native property wrapper explicitly: SDKs that also provide a
// State macro can omit its plug-in from Command Line Tools installations.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var activePanel: MenuPanel?
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    var addProjectAction: ((DevProcess?) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            switch activePanel {
            case .preferences:
                PreferencesView {
                    activePanel = nil
                }
                .environmentObject(model)
            case nil:
                mainMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var mainMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspaceTitle)
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    filterField
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if FeatureFlags.sessionRecovery && model.processViewMode == .agents {
                            SessionRecoveryView()
                        }
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 8) {
                SystemResourceSummary(resources: model.systemResources)
                Spacer(minLength: 0)
                if model.processViewMode == .agents, let updated = model.agentActivityUpdatedAt {
                    Text("Scanned \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Time of the latest local process scan")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .onChange(of: model.processViewMode) { _ in query = "" }
        .screenBoundedPanel(.processes)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("View", selection: $model.processViewMode) {
                ForEach(ProcessViewMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 330)
            Spacer(minLength: 0)
            Button { addProjectAction?(nil) } label: {
                Label("Add Project", systemImage: "plus")
            }
            .controlSize(.small)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
                .accessibilityLabel("Refresh")
            Menu {
                Button("Find in this view") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Preferences…") { activePanel = .preferences }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit PortsKiller") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Preferences and app actions")
            .accessibilityLabel("App actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var workspaceTitle: String {
        switch model.processViewMode {
        case .agents: "Agent activity"
        case .dev: "Development servers"
        case .all: "Listening ports"
        case .activity: "Resource activity"
        }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Filter this view")
                .onExitCommand {
                    if query.isEmpty { searchFocused = false } else { query = "" }
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 168)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: searchFocused ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
    }

    private func matches(_ fields: [String]) -> Bool {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        return tokens.allSatisfy { token in fields.contains { $0.localizedCaseInsensitiveContains(String(token)) } }
    }

    @ViewBuilder private var content: some View {
        switch model.processViewMode {
        case .agents:
            agentList
        case .activity:
            let items = model.activityProcesses.filter { row in
                matches([row.name, row.kind.title, row.detail, row.primaryPID.map { String($0) } ?? ""])
            }
            if items.isEmpty { emptyOrFiltered }
            else { ForEach(items) { ActivityProcessRow(process: $0) } }
        case .dev, .all:
            let items = model.processes.filter { row in
                matches([row.name, row.kind.title, row.framework, row.cwd ?? "", String(row.port), String(row.pid)])
            }
            if items.isEmpty { emptyOrFiltered }
            else { ForEach(items) { ProcessRow(process: $0, configureRestart: { addProjectAction?($0) }) } }
        }
    }

    @ViewBuilder private var agentList: some View {
        let rows = model.agentActivities.filter { row in
            matches([row.title, row.detail, row.kind.title, row.pid.map { String($0) } ?? ""])
        }
        let work = rows.filter { $0.kind == .work }
        let services = rows.filter { $0.kind == .service || $0.kind == .host }
        let unavailable = model.agentActivities.filter { $0.kind == .unavailable }
        if !unavailable.isEmpty {
            ForEach(unavailable) { AgentObservationRow(item: $0) }
        }
        if model.agentActivityUpdatedAt == nil && rows.isEmpty && unavailable.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading local processes…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else if !query.isEmpty && work.isEmpty && services.isEmpty && unavailable.isEmpty {
            noMatches
        } else if !work.isEmpty || !services.isEmpty || unavailable.isEmpty {
            if !work.isEmpty || (query.isEmpty && unavailable.isEmpty) {
                sectionLabel("Local work", count: work.count)
                if work.isEmpty {
                    Text("No local agent commands observed in this scan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 7)
                } else {
                    ForEach(work) { AgentObservationRow(item: $0) }
                }
            }
            if !services.isEmpty {
                sectionLabel("Hosts & services", count: services.count)
                    .padding(.top, work.isEmpty && !query.isEmpty ? 0 : 12)
                ForEach(services) { AgentObservationRow(item: $0) }
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(verbatim: "\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var emptyOrFiltered: some View {
        if query.isEmpty { EmptyStateView() } else { noMatches }
    }

    private var noMatches: some View {
        HStack {
            Text("No matches for this filter.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Clear filter") { query = "" }.buttonStyle(.link)
        }
        .padding(.vertical, 12)
    }
}

private struct AgentObservationRow: View {
    let item: AgentActivity

    private var symbol: String {
        switch item.kind {
        case .work: "terminal"
        case .service: "gearshape.2"
        case .host: "macwindow"
        case .unavailable: "exclamationmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.kind == .work ? Color.accentColor : Color.secondary)
                .frame(width: 23)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let pid = item.pid {
                Text(verbatim: "PID \(pid)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .modifier(ProcessRowSurface())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.kind.title)
        .help(item.detail)
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

private enum MenuPanel {
    case preferences
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
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }
}

private struct ActivityProcessRow: View {
    @EnvironmentObject private var model: AppModel
    let process: ActivityProcess

    @ViewState private var confirmingStop = false

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
            if process.canStop {
                Button { confirmingStop = true } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop \(process.name)")
                .accessibilityLabel("Stop \(process.name)")
                .confirmationDialog("Stop \(process.name)?", isPresented: $confirmingStop) {
                    Button("Stop", role: .destructive) { model.stop(process) }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .modifier(ProcessRowSurface())
    }
}

private struct ProcessRow: View {
    @EnvironmentObject private var model: AppModel
    let process: DevProcess
    var configureRestart: (DevProcess) -> Void
    @ViewState private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(cpuPercent: process.resources.cpuPercent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: process.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 7) {
                        Button(process.urlString) { model.open(process) }
                            .buttonStyle(.link)
                            .help("Open in browser")
                        Text(verbatim: "PID \(process.pid)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                ResourceMonitor(resources: process.resources)
                Menu {
                    Button("Open in Browser") { model.open(process) }
                    Button("Copy URL") { model.copyURL(process) }
                    Button("Reveal in Finder") { model.revealProjectFolder(process) }
                        .disabled(process.cwd == nil)
                    Divider()
                    if process.canRestart {
                        Button("Restart") { model.restart(process) }
                            .disabled(!process.canStop)
                    } else {
                        Button("Set up restart…") { configureRestart(process) }
                    }
                    Button("Stop…", role: .destructive) { confirmingStop = true }
                        .disabled(!process.canStop)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(process.name) on port \(process.port)")
                .help("Process actions")
                .confirmationDialog("Stop \(process.name) on port \(process.port)?", isPresented: $confirmingStop) {
                    Button("Stop Process", role: .destructive) { model.stop(process) }
                    Button("Cancel", role: .cancel) {}
                }
            }
            if let projectID = process.projectID {
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
        .modifier(ProcessRowSurface())
    }
}

private struct ResourceMonitor: View {
    let resources: ResourceUsage
    var memoryLabel: String = "RAM"

    var body: some View {
        HStack(spacing: 12) {
            Text("CPU \(cpuText)")
            Text("\(memoryLabel) \(memoryText)")
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
    @ViewState private var command = "pnpm dev"
    @ViewState private var port = "3000"
    @ViewState private var packageManager = "npm"
    @ViewState private var scripts: [PackageScript] = []
    @ViewState private var selectedScript = ""
    @ViewState private var folderState = "Choose a project folder"

    init(process: DevProcess? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let process {
            _name = State(initialValue: process.name)
            _cwd = State(initialValue: process.cwd ?? "")
            _port = State(initialValue: String(process.port))
            _command = State(initialValue: "")
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Project folder", text: $cwd)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { loadFolder() }

                            Button {
                                chooseFolder()
                            } label: {
                                Label("Choose", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(folderState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(12)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            FieldBlock(title: "Name") {
                                TextField("my-app", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            FieldBlock(title: "Port") {
                                TextField("3000", text: $port)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        HStack(alignment: .top, spacing: 10) {
                            FieldBlock(title: "Package manager") {
                                Picker("", selection: $packageManager) {
                                    Text("npm").tag("npm")
                                    Text("pnpm").tag("pnpm")
                                    Text("yarn").tag("yarn")
                                    Text("bun").tag("bun")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .onChange(of: packageManager) { _ in applySelectedScript() }
                            }

                            FieldBlock(title: "Script") {
                                Picker("", selection: $selectedScript) {
                                    if scripts.isEmpty {
                                        Text("dev").tag("dev")
                                    } else {
                                        ForEach(scripts) { script in
                                            Text(script.name).tag(script.name)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: selectedScript) { _ in applySelectedScript() }
                            }
                        }

                        FieldBlock(title: "Command") {
                            TextField("npm run dev", text: $command)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(12)

                    if !scripts.isEmpty {
                        ScriptPreviewList(scripts: scripts, selectedScript: $selectedScript)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    loadFolder()
                } label: {
                    Label("Reload Scripts", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer()

                Button("Save") {
                    saveProject(start: false)
                }
                .disabled(!isValid)

                Button("Save & Start") {
                    saveProject(start: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .screenBoundedPanel(.project)
    }

    private var isValid: Bool {
        !name.isEmpty && !cwd.isEmpty && !command.isEmpty && Int(port) != nil
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
        let cleaned = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        cwd = cleaned

        guard FileManager.default.fileExists(atPath: cleaned) else {
            folderState = "Folder does not exist"
            scripts = []
            return
        }

        guard let info = inspector.inspect(cwd: cleaned) else {
            folderState = "No package.json found. You can still enter a command manually."
            if name.isEmpty { name = URL(fileURLWithPath: cleaned).lastPathComponent }
            scripts = []
            selectedScript = "dev"
            packageManager = "npm"
            command = "npm run dev"
            return
        }

        name = info.name
        packageManager = info.packageManager
        scripts = info.scripts
        selectedScript = info.scripts.first?.name ?? "dev"
        port = "\(info.suggestedPort)"
        applySelectedScript()
        folderState = "\(info.scripts.count) scripts loaded from package.json"
    }

    private func applySelectedScript() {
        guard !selectedScript.isEmpty else { return }
        command = inspector.command(packageManager: packageManager, scriptName: selectedScript)
    }

    private func saveProject(start: Bool) {
        guard let portNumber = Int(port) else { return }
        let project = ManualProject(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updater = GitHubUpdater.shared
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sheetHeader("Preferences", systemImage: "slider.horizontal.3")
                Spacer()
                Button("Done") { close() }
            }

            FittingScrollView {
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
                        }
                        Divider().padding(.vertical, 6)
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
                                }
                            }

                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Software updates")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(updateStatusText)
                                        .font(.caption)
                                        .foregroundStyle(updateStatusColor)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Button {
                                    updater.checkForUpdates(manual: true)
                                } label: {
                                    Label(updater.isChecking ? "Checking" : "Check", systemImage: "arrow.clockwise")
                                }
                                .disabled(updater.isChecking)
                                .controlSize(.small)
                            }

                            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                                .font(.system(size: 12, weight: .medium))

                            Toggle("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
                                .font(.system(size: 12, weight: .medium))
                                .disabled(!updater.automaticallyChecksForUpdates)

                            if updater.isDownloading {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: updater.downloadProgress)
                                    Text("Downloading update \(Int(updater.downloadProgress * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else if updater.updateAvailable {
                                HStack(spacing: 8) {
                                    Text("Version \(updater.latestVersion ?? "") is available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        updater.startDownload()
                                    } label: {
                                        Label("Install", systemImage: "square.and.arrow.down")
                                    }
                                    .disabled(updater.downloadURL == nil)
                                    .controlSize(.small)
                                }
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

                    VStack(spacing: 8) {
                        if model.projects.isEmpty {
                            SettingsBlock {
                                Text("No saved projects")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
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
            }
        }
        .padding(20)
        .screenBoundedPanel(onClose == nil ? .preferences : .processes)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var updateStatusText: String {
        if let error = updater.error {
            return "Installed \(updater.currentVersion). \(error)"
        }
        if updater.isChecking {
            return "Installed \(updater.currentVersion). Checking GitHub Releases…"
        }
        if let latestVersion = updater.latestVersion {
            return "Installed \(updater.currentVersion), latest \(latestVersion)"
        }
        return "Installed \(updater.currentVersion)"
    }

    private var updateStatusColor: Color {
        updater.error == nil ? Color.secondary : Color.red
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
                                .foregroundStyle(selectedScript == script.name ? .green : .secondary)

                            Text(script.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                        .background(
                            selectedScript == script.name
                                ? Color.green.opacity(0.10)
                                : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
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
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
