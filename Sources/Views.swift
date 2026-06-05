import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var activePanel: MenuPanel?

    var body: some View {
        Group {
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.processes.isEmpty {
                        EmptyStateView()
                    } else {
                        ForEach(model.processes) { process in
                            ProcessRow(process: process)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 560)

            footer

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 680)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text("Processes")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.processViewMode == .dev ? "JS TCP listeners" : "All TCP listeners")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $model.processViewMode) {
                ForEach(ProcessViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 112)

            CountBadge(count: model.processes.count, unknownCount: model.unknownProcessCount)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "add-project")
            } label: {
                Label("Add", systemImage: "plus")
            }

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                activePanel = .preferences
            } label: {
                Label("Prefs", systemImage: "slider.horizontal.3")
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.top, 2)
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
            Text(model.processViewMode == .dev ? "No dev servers found" : "No listeners found")
                .font(.system(size: 13, weight: .medium))
            Text(model.processViewMode == .dev ? "Refresh or add a project to start one." : "Refresh to scan local TCP ports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProcessRow: View {
    @EnvironmentObject private var model: AppModel
    let process: DevProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                identity
                    .frame(width: 220, alignment: .leading)

                ResourceMonitor(resources: process.resources)
                    .frame(width: 188, alignment: .leading)

                Spacer(minLength: 8)

                actionButtons
            }

            HStack(spacing: 8) {
                Text(process.urlString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(verbatim: "PID \(process.pid)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let command = visibleCommand(process.command) {
                    Text(verbatim: command)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var identity: some View {
        HStack(spacing: 9) {
            StatusDot(cpuPercent: process.resources.cpuPercent)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Text(process.framework)
                    if model.processViewMode == .all {
                        KindBadge(kind: process.kind)
                    }
                    if let cwd = process.cwd {
                        Text(URL(fileURLWithPath: cwd).lastPathComponent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            IconActionButton("Open", systemImage: "safari") { model.open(process) }
            IconActionButton("Copy URL", systemImage: "doc.on.doc") { model.copyURL(process) }
            IconActionButton("Reveal in Finder", systemImage: "folder", disabled: process.cwd == nil) {
                model.revealProjectFolder(process)
            }
            IconActionButton("Restart", systemImage: "arrow.clockwise", disabled: !process.canRestart) {
                model.restart(process)
            }
            IconActionButton("Stop", systemImage: "stop.fill", role: .destructive, disabled: !process.canStop) {
                model.stop(process)
            }
        }
    }
}

private struct ResourceMonitor: View {
    let resources: ResourceUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                MetricValue(label: "CPU", value: cpuText)
                MetricValue(label: "RAM", value: memoryText)
                MetricValue(label: "UP", value: cleanUptime)
            }

            HStack(spacing: 5) {
                MiniMeter(value: min(resources.cpuPercent / 100, 1), tint: cpuTint)
                    .help("CPU \(cpuText)")
                MiniMeter(value: min(resources.memoryMegabytes / 2048, 1), tint: .blue)
                    .help("RAM \(memoryText)")
            }
        }
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

    private var cpuTint: Color {
        if resources.cpuPercent >= 80 { return .red }
        if resources.cpuPercent >= 35 { return .orange }
        return .green
    }
}

private struct MetricValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 54, alignment: .leading)
    }
}

private struct MiniMeter: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
                Capsule()
                    .fill(tint.opacity(0.78))
                    .frame(width: max(3, proxy.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

private struct StatusDot: View {
    let cpuPercent: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.35), radius: 3, y: 1)
    }

    private var color: Color {
        if cpuPercent >= 80 { return .red }
        if cpuPercent >= 35 { return .orange }
        return .green
    }
}

private struct KindBadge: View {
    let kind: ProcessKind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .dev: return .green
        case .jsTool: return .blue
        case .localService: return .orange
        case .desktopApp: return .secondary
        case .system: return .secondary
        case .unknown: return .red
        }
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
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : foregroundStyle)
        .background(Color(nsColor: .windowBackgroundColor).opacity(disabled ? 0.35 : 0.82), in: RoundedRectangle(cornerRadius: 6))
        .disabled(disabled)
        .help(title)
    }

    private var foregroundStyle: Color {
        role == .destructive ? .red : .primary
    }
}

private struct CountBadge: View {
    let count: Int
    let unknownCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text("\(count) active")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            if unknownCount > 0 {
                Text(verbatim: "\(unknownCount)?")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private var dotColor: Color {
        if unknownCount > 0 { return .red }
        return count == 0 ? .secondary : .green
    }
}

struct AddProjectView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    private let inspector = PackageScriptInspector()

    @State private var name = ""
    @State private var cwd = ""
    @State private var command = "pnpm dev"
    @State private var port = "3000"
    @State private var packageManager = "npm"
    @State private var scripts: [PackageScript] = []
    @State private var selectedScript = ""
    @State private var folderState = "Choose a project folder"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sheetHeader("Add Project", systemImage: "plus.app")
                Spacer()
                Button("Cancel") { onClose() }
            }

            ScrollView {
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
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            FieldBlock(title: "Name") {
                                TextField("my-app", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            FieldBlock(title: "Port") {
                                TextField("3000", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 86)
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
                                .frame(width: 150)
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
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    if !scripts.isEmpty {
                        ScriptPreviewList(scripts: scripts, selectedScript: $selectedScript)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)

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
        .frame(width: 620)
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

struct AddProjectWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AddProjectView {
            dismiss()
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sheetHeader("Preferences", systemImage: "slider.horizontal.3")
                Spacer()
                Button("Done") { close() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsBlock {
                        HStack(spacing: 10) {
                            Image(systemName: "power.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)

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
                    }

                    HStack {
                        Text("Projects")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(verbatim: "\(model.projects.count)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    LazyVStack(spacing: 8) {
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
            .frame(maxHeight: 430)
        }
        .padding(20)
        .frame(width: 620)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
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
        content
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
                Text(verbatim: "\(text.count) chars")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
    HStack(spacing: 8) {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
        Text(title)
            .font(.headline)
    }
}

private func compactCommand(_ command: String) -> String {
    command
        .replacingOccurrences(of: "next-server ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func visibleCommand(_ command: String) -> String? {
    let compact = compactCommand(command)
    guard !compact.isEmpty else { return nil }
    if compact.hasPrefix("(") && compact.hasSuffix(")") { return nil }
    return compact
}
