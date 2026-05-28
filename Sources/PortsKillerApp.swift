import Foundation
import SwiftUI

@main
enum PortsKillerMain {
    static func main() {
        if CommandLine.arguments.contains("--scan-once") {
            let projects = ProjectStore().load()
            let processes = ProcessScanner().scan(manualProjects: projects)
            for process in processes {
                let memory = String(format: "%.0fM", process.resources.memoryMegabytes)
                let cpu = String(format: "%.1f%%", process.resources.cpuPercent)
                print("\(process.name)\t:\(process.port)\tpid=\(process.pid)\t\(process.framework)\tcpu=\(cpu)\tram=\(memory)\tup=\(process.resources.uptime)\t\(process.urlString)")
            }
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
            MenuBarIcon(count: model.processes.count)
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
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 18)

            if count > 0 {
                Text(verbatim: countText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, count > 9 ? 3 : 4)
                    .frame(height: 11)
                    .background(Color.green, in: Capsule())
                    .offset(x: 5, y: -3)
            }
        }
        .frame(width: 28, height: 18)
        .accessibilityLabel("Dev processes: \(count)")
    }

    private var countText: String {
        count > 99 ? "99+" : "\(count)"
    }
}
