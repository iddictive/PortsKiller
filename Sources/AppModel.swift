import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    private enum ScanResult: Sendable {
        case listeners([DevProcess])
        case activity([ActivityProcess])
    }

    @Published var processes: [DevProcess] = []
    @Published var activityProcesses: [ActivityProcess] = []
    @Published var systemResources: SystemResourceUsage = .unavailable
    @Published var projects: [ManualProject] = []
    @Published var selectedLogProjectID: UUID?
    @Published var lastError: String?
    @Published var loginItemEnabled: Bool = false
    @Published private(set) var sessionRecoverySnapshot = SessionRecoverySnapshot()
    @Published var menuBarMetric: MenuBarMetric = .cpu {
        didSet { menuBarMetricPreferences.save(menuBarMetric) }
    }
    @Published var processViewMode: ProcessViewMode = .dev {
        didSet { refresh() }
    }

    let runner = ManagedProcessRunner()
    let sessionRecovery = SessionRecoveryService()

    private let store = ProjectStore()
    private let processController = ProcessController()
    private let loginItemManager = LoginItemManager()
    private let systemResourceMonitor = SystemResourceMonitor()
    private let menuBarMetricPreferences = MenuBarMetricPreferences()
    private var refreshTimer: Timer?
    private var resourceTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshPending = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        menuBarMetric = menuBarMetricPreferences.load()
        projects = store.load()
        loginItemEnabled = loginItemManager.isEnabled
        sessionRecovery.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.sessionRecoverySnapshot = snapshot }
            .store(in: &cancellables)
        Task { await sessionRecovery.start() }
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
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshGeneration &+= 1
        startRefresh()
    }

    private func startRefresh() {
        let generation = refreshGeneration
        let mode = processViewMode
        let capturedProjects = projects

        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let scanner = ProcessScanner()
                return switch mode {
                case .activity:
                    ScanResult.activity(scanner.scanActivity())
                case .dev, .all:
                    ScanResult.listeners(scanner.scan(manualProjects: capturedProjects, mode: mode))
                }
            }.value

            guard let self else { return }
            self.refreshTask = nil

            if generation == self.refreshGeneration,
               mode == self.processViewMode,
               capturedProjects == self.projects {
                switch result {
                case let .listeners(processes):
                    self.processes = processes
                case let .activity(processes):
                    self.activityProcesses = processes
                }
            }

            if self.refreshPending {
                self.refreshPending = false
                self.refreshGeneration &+= 1
                self.startRefresh()
            }
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
