import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var processes: [DevProcess] = []
    @Published var activityProcesses: [ActivityProcess] = []
    @Published var systemResources: SystemResourceUsage = .unavailable
    @Published var projects: [ManualProject] = []
    @Published var selectedLogProjectID: UUID?
    @Published var lastError: String?
    @Published var loginItemEnabled: Bool = false
    @Published var processViewMode: ProcessViewMode = .dev {
        didSet { refresh() }
    }

    let runner = ManagedProcessRunner()

    private let scanner = ProcessScanner()
    private let store = ProjectStore()
    private let processController = ProcessController()
    private let loginItemManager = LoginItemManager()
    private let systemResourceMonitor = SystemResourceMonitor()
    private var refreshTimer: Timer?
    private var resourceTimer: Timer?

    init() {
        projects = store.load()
        loginItemEnabled = loginItemManager.isEnabled
        refreshSystemResources()
        refresh()
        GitHubUpdater.shared.checkForUpdates()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        resourceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemResources() }
        }
    }

    func refresh() {
        switch processViewMode {
        case .activity:
            activityProcesses = scanner.scanActivity()
        case .dev, .all:
            processes = scanner.scan(manualProjects: projects, mode: processViewMode)
        }
    }

    func refreshSystemResources() {
        systemResources = systemResourceMonitor.sample()
    }

    var unknownProcessCount: Int {
        guard processViewMode != .activity else { return 0 }
        return processes.filter { $0.kind == .unknown }.count
    }

    var displayedProcessCount: Int {
        processViewMode == .activity ? activityProcesses.count : processes.count
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

    func stop(_ process: ActivityProcess) {
        guard
            process.canStop,
            let pid = process.primaryPID,
            let identity = process.identity
        else { return }

        let controller = processController
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                controller.terminateValidatedTree(rootPID: pid, expectedIdentity: identity)
            }.value
            self?.refresh()
        }
    }

    func restart(_ process: DevProcess) {
        let project: ManualProject?
        if let projectID = process.projectID {
            project = projects.first(where: { $0.id == projectID })
        } else {
            project = process.inferredRestartProject
        }

        guard let project else { return }
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
