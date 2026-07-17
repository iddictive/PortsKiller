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
            print("cpu=\(cpu)\tram=\(used)/\(total)\tram_percent=\(String(format: "%.1f%%", resources.memoryPercent))")
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
                hasWarning: model.unknownProcessCount > 0
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .semibold))

            if let metricLabel = presentation.metricLabel {
                Text(metricLabel)
            }

            if hasWarning {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .fixedSize()
        .accessibilityLabel(presentation.accessibilityLabel(hasWarning: hasWarning))
    }

    private var presentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            resources: resources,
            metric: metric
        )
    }
}
