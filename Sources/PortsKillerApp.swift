import Foundation
import SwiftUI

@main
enum PortsKillerMain {
    static func main() {
        if CommandLine.arguments.contains("--scan-once") || CommandLine.arguments.contains("--scan-all") {
            let projects = ProjectStore().load()
            let mode: ProcessViewMode = CommandLine.arguments.contains("--scan-all") ? .all : .dev
            let processes = ProcessScanner().scan(manualProjects: projects, mode: mode)
            for process in processes {
                let memory = String(format: "%.0fM", process.resources.memoryMegabytes)
                let cpu = String(format: "%.1f%%", process.resources.cpuPercent)
                print("\(process.kind.title)\t\(process.name)\t:\(process.port)\tpid=\(process.pid)\t\(process.framework)\tcpu=\(cpu)\tram=\(memory)\tup=\(process.resources.uptime)\t\(process.urlString)")
            }
            exit(0)
        }

        if CommandLine.arguments.contains("--scan-activity") {
            for process in ProcessScanner().scanActivity() {
                let memory = String(format: "%.0fM", process.resources.memoryMegabytes)
                let cpu = String(format: "%.1f%%", process.resources.cpuPercent)
                let pid = process.primaryPID.map(String.init) ?? "-"
                print("\(process.kind.title)\t\(process.name)\tpid=\(pid)\tprocesses=\(process.processCount)\tcpu=\(cpu)\trss=\(memory)\tup=\(process.resources.uptime)\tstoppable=\(process.canStop ? "yes" : "no")")
            }
            exit(0)
        }

        if CommandLine.arguments.contains("--system-stats") {
            let monitor = SystemResourceMonitor()
            _ = monitor.sample()
            Thread.sleep(forTimeInterval: 0.25)
            let resources = monitor.sample()
            let cpu = resources.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-"
            let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: resources.memoryUsedBytes), countStyle: .memory)
            let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: resources.memoryTotalBytes), countStyle: .memory)
            let swap = resources.swap.map {
                let swapUsed = ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.usedBytes), countStyle: .memory)
                let swapTotal = ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.totalBytes), countStyle: .memory)
                return "\(swapUsed)/\(swapTotal)"
            } ?? "unavailable"
            print("cpu=\(cpu)\tram=\(used)/\(total)\tram_percent=\(String(format: "%.1f%%", resources.memoryPercent))\tswap=\(swap)")
            exit(0)
        }

        if CommandLine.arguments.contains("--recovery-status") {
            let snapshot = SessionRecoveryService.persistedSnapshot()
            print("active=\(snapshot.activeCount)\tpending=\(snapshot.pendingCount)\tevents=\(snapshot.recentEvents.count)")
            exit(0)
        }

        PortsKillerApp.main()
    }
}

struct PortsKillerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            MenuBarIcon(
                resources: model.systemResources,
                metric: model.menuBarMetric,
                hasWarning: model.unknownProcessCount > 0,
                recovery: model.sessionRecoverySnapshot
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environmentObject(model)
        }

        Window("Add Project", id: "add-project") {
            AddProjectWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 620, height: 700)
    }
}

private struct MenuBarIcon: View {
    let resources: SystemResourceUsage
    let metric: MenuBarMetric
    let hasWarning: Bool
    let recovery: SessionRecoverySnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .semibold))

            statusText
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .fixedSize()
        .help(statusHelp)
        .accessibilityLabel("\(presentation.accessibilityLabel(hasWarning: hasWarning)), \(recovery.statusText)")
    }

    private var statusText: Text {
        switch presentation.content(isRecovering: recovery.isRecovering) {
        case .recovering:
            return appendingWarning(
                to: Text("⟳")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            )
        case let .metric(metricLabel, showsSwapIndicator):
            var label = Text(metricLabel ?? "")
            if showsSwapIndicator {
                label = label + Text(" ●")
                    .font(.system(size: 6, weight: .regular))
                    .foregroundColor(.primary)
            }
            return appendingWarning(to: label)
        }
    }

    private func appendingWarning(to label: Text) -> Text {
        guard hasWarning else { return label }
        return label + Text(" ●")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.red)
    }

    private var presentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            resources: resources,
            metric: metric
        )
    }

    private var swapHelp: String {
        guard let swap = resources.swap else { return "Swap unavailable" }
        let used = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: swap.usedBytes),
            countStyle: .memory
        )
        return "Swap in use: \(used)"
    }

    private var statusHelp: String {
        presentation.showsSwapIndicator
            ? "\(swapHelp) · \(recovery.statusText)"
            : recovery.statusText
    }

}
