import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var processes: [DevProcess] = []
    @Published var projects: [ManualProject] = []
    @Published var selectedLogProjectID: UUID?
    @Published var lastError: String?
    @Published var loginItemEnabled: Bool = false

    let runner = ManagedProcessRunner()

    private let scanner = ProcessScanner()
    private let store = ProjectStore()
    private let processController = ProcessController()
    private let loginItemManager = LoginItemManager()
    private var refreshTimer: Timer?

    init() {
        projects = store.load()
        loginItemEnabled = loginItemManager.isEnabled
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        processes = scanner.scan(manualProjects: projects)
    }

    func addProject(_ project: ManualProject) {
        projects.append(project)
        store.save(projects)
        refresh()
    }

    func removeProjects(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        store.save(projects)
        refresh()
    }

    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        store.save(projects)
        refresh()
    }

    func open(_ process: DevProcess) {
        guard let url = URL(string: process.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(_ process: DevProcess) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(process.urlString, forType: .string)
    }

    func revealProjectFolder(_ process: DevProcess) {
        guard let cwd = process.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    func revealProject(_ project: ManualProject) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.cwd)])
    }

    func stop(_ process: DevProcess) {
        processController.terminateTree(rootPID: process.pid)
        refresh()
    }

    func restart(_ process: DevProcess) {
        guard let projectID = process.projectID, let project = projects.first(where: { $0.id == projectID }) else { return }
        processController.terminateTree(rootPID: process.pid)
        runner.start(project)
        selectedLogProjectID = project.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    func start(_ project: ManualProject) {
        runner.start(project)
        selectedLogProjectID = project.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItemManager.setEnabled(enabled)
            loginItemEnabled = loginItemManager.isEnabled
            lastError = nil
        } catch {
            loginItemEnabled = loginItemManager.isEnabled
            lastError = error.localizedDescription
        }
    }
}
