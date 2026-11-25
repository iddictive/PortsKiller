import AppKit
import Combine
import Foundation

private enum SessionRecoveryPreference {
    static let key = "SessionRecovery.enabled"

    static func load() -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return false
        }
        return value
    }

    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

@MainActor
final class AppModel: ObservableObject {
    private enum ScanResult: Sendable {
        case listeners([DevProcess])
        case activity([ActivityProcess])
        case agents([AgentActivity])
    }

    private struct ScanSnapshot {
        let result: ScanResult
        let completedAt: Date
    }

    @Published private var scans: [ProcessViewMode: ScanSnapshot] = [:]
    @Published private(set) var agentActionMessage: String?
    @Published private(set) var stoppingAgentIDs: Set<String> = []
    @Published private(set) var pendingLocalActions: [Int32: String] = [:]
    @Published private var listenerActionMessage: String?
    @Published private var activityActionMessage: String?
    @Published var systemResources: SystemResourceUsage = .unavailable
    @Published var projects: [ManualProject] = []
    @Published var selectedLogProjectID: UUID?
    @Published var lastError: String?
    @Published var loginItemEnabled: Bool = false
    @Published var isSessionRecoveryEnabled: Bool = FeatureFlags.sessionRecovery && SessionRecoveryPreference.load()
    @Published private(set) var sessionRecoverySnapshot = SessionRecoverySnapshot()
    @Published var menuBarMetric: MenuBarMetric = .cpu {
        didSet { menuBarMetricPreferences.save(menuBarMetric) }
    }
    @Published var processViewMode: ProcessViewMode = .agents {
        didSet { if processViewMode != oldValue { refresh() } }
    }

    var activeScanCompletedAt: Date? { scans[processViewMode]?.completedAt }
    var activeLocalActionMessage: String? {
        switch processViewMode {
        case .dev, .all: listenerActionMessage
        case .activity: activityActionMessage
        case .agents: nil
        }
    }

    var processes: [DevProcess] {
        guard case let .listeners(rows)? = scans[processViewMode]?.result else { return [] }
        return rows
    }

    var activityProcesses: [ActivityProcess] {
        guard case let .activity(rows)? = scans[.activity]?.result else { return [] }
        return rows
    }

    var agentActivities: [AgentActivity] {
        guard case let .agents(rows)? = scans[.agents]?.result else { return [] }
        return rows
    }

    let runner = ManagedProcessRunner()
    let sessionRecovery: SessionRecoveryService? = FeatureFlags.sessionRecovery ? SessionRecoveryService() : nil

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
        if let sessionRecovery {
            sessionRecovery.$snapshot
                .receive(on: RunLoop.main)
                .sink { [weak self] snapshot in self?.sessionRecoverySnapshot = snapshot }
                .store(in: &cancellables)
            Task {
                if isSessionRecoveryEnabled {
                    await sessionRecovery.start()
                } else {
                    await sessionRecovery.stop()
                }
            }
        }
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
            let result = await Task.detached(priority: .utility) {
                let scanner = ProcessScanner()
                return switch mode {
                case .agents:
                    ScanResult.agents(AgentActivityScanner().scan())
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
                self.scans[mode] = ScanSnapshot(result: result, completedAt: Date())
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
        guard processViewMode == .all else { return 0 }
        return processes.filter { $0.kind == .unknown }.count
    }

    var displayedProcessCount: Int {
        switch processViewMode {
        case .agents: agentActivities.filter { $0.kind == .work }.count
        case .activity: activityProcesses.count
        case .dev, .all: processes.count
        }
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

    func stopAgent(_ item: AgentActivity) {
        guard !stoppingAgentIDs.contains(item.id) else { return }
        guard item.kind == .work, let pid = item.pid, let identity = item.identity,
              agentActivities.contains(where: { $0.id == item.id && $0.identity == identity }) else {
            agentActionMessage = "The command changed while confirmation was open. No stop signal sent."
            refresh()
            return
        }
        agentActionMessage = nil
        stoppingAgentIDs.insert(item.id)
        let controller = processController
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await controller.interruptLocalCommand(rootPID: pid, expectedIdentity: identity,
                                                       displayedPIDs: item.memberPIDs,
                                                       permits: AgentActivityScanner.canInterrupt)
            }.value
            guard let self else { return }
            self.stoppingAgentIDs.remove(item.id)
            self.agentActionMessage = Self.interruptMessage(result, pid: pid)
            self.refresh()
        }
    }

    private static func interruptMessage(_ result: ProcessController.InterruptResult, pid: Int32) -> String {
        switch result {
        case .commandChanged:
            return "PID \(pid) already exited or changed. No stop signal sent."
        case .snapshotUnavailable:
            return "Couldn’t read the process group for PID \(pid). No stop signal sent."
        case .unsafeGroup:
            return "Couldn’t verify a safe stop for PID \(pid). No stop signal sent."
        case .noSignal:
            return "Couldn’t send the stop request for PID \(pid)."
        case let .requested(running, unconfirmed):
            if running.isEmpty && unconfirmed.isEmpty {
                return "Observed processes for PID \(pid) exited."
            }
            var notes = [String]()
            if !running.isEmpty {
                let summary = running.prefix(3).map(String.init).joined(separator: ", ")
                let more = running.count > 3 ? " and \(running.count - 3) more" : ""
                notes.append("still running: \(summary)\(more)")
            }
            if !unconfirmed.isEmpty {
                notes.append("\(unconfirmed.count) unverified")
            }
            return "Stop requested for PID \(pid) (\(notes.joined(separator: "; ")))."
        }
    }

    func stop(_ process: DevProcess) {
        performListenerAction(process, restartProject: nil)
    }

    func stop(_ process: ActivityProcess) {
        guard let pid = process.primaryPID, pendingLocalActions[pid] == nil else { return }
        guard process.canStop, let identity = process.identity,
              activityProcesses.contains(where: { $0.id == process.id && $0.identity == identity }) else {
            activityActionMessage = "The process changed. No stop signal sent."
            refresh()
            return
        }
        activityActionMessage = nil
        pendingLocalActions[pid] = "Stopping…"
        let controller = processController
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await controller.interruptLocalCommand(rootPID: pid, expectedIdentity: identity,
                                                       displayedPIDs: process.targetPIDs,
                                                       permits: ProcessScanner.permitsLocalAction)
            }.value
            guard let self else { return }
            self.pendingLocalActions[pid] = nil
            self.activityActionMessage = Self.interruptMessage(result, pid: pid)
            self.refresh()
        }
    }

    func restart(_ process: DevProcess) {
        guard let project = restartProject(for: process) else {
            listenerActionMessage = "No launch command is available for port \(process.port)."
            return
        }
        performListenerAction(process, restartProject: project)
    }

    private func restartProject(for process: DevProcess) -> ManualProject? {
        if let projectID = process.projectID { return projects.first(where: { $0.id == projectID }) }
        return process.inferredRestartProject
    }

    private enum ListenerActionResult: Sendable {
        case listenerUnverified, launchDirectoryUnavailable
        case portInUse(Int), portUnverified(Int)
        case interrupted(ProcessController.InterruptResult)
    }

    private func performListenerAction(_ process: DevProcess, restartProject project: ManualProject?) {
        let pid = process.pid
        guard pendingLocalActions[pid] == nil else { return }
        guard process.canStop, let identity = process.identity,
              processes.contains(where: { $0.id == process.id && $0.identity == identity && $0.canStop }) else {
            listenerActionMessage = "The listener changed or could not be verified. No stop signal sent."
            refresh()
            return
        }
        let restarting = project != nil
        listenerActionMessage = nil
        pendingLocalActions[pid] = restarting ? "Restarting…" : "Stopping…"
        let controller = processController
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> ListenerActionResult in
                let scanner = ProcessScanner()
                if let project {
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: project.cwd, isDirectory: &directory),
                          directory.boolValue else { return .launchDirectoryUnavailable }
                }
                guard scanner.liveListenerPIDs(on: process.port)?.contains(pid) == true else {
                    return .listenerUnverified
                }
                let result = await controller.interruptLocalCommand(rootPID: pid, expectedIdentity: identity,
                                                                    displayedPIDs: process.memberPIDs,
                                                                    permits: ProcessScanner.permitsLocalAction)
                if let project, result == .requested(running: [], unconfirmed: []) {
                    for port in Set([process.port, project.port]).sorted() {
                        guard let listeners = scanner.liveListenerPIDs(on: port) else { return .portUnverified(port) }
                        guard listeners.isEmpty else { return .portInUse(port) }
                    }
                }
                return .interrupted(result)
            }.value
            guard let self else { return }
            self.pendingLocalActions[pid] = nil
            let unchanged: Bool
            if process.projectID != nil {
                unchanged = self.restartProject(for: process) == project
            } else {
                unchanged = true
            }
            switch outcome {
            case .listenerUnverified:
                self.listenerActionMessage = "Couldn’t verify PID \(pid) is still listening on port \(process.port). No stop signal sent."
            case .launchDirectoryUnavailable:
                self.listenerActionMessage = "The project folder is unavailable. No stop signal sent."
            case let .portInUse(port):
                self.listenerActionMessage = "Port \(port) is still in use. Restart skipped."
            case let .portUnverified(port):
                self.listenerActionMessage = "Couldn’t verify port \(port) is free. Restart skipped."
            case let .interrupted(result):
                if let project, result == .requested(running: [], unconfirmed: []) {
                    if unchanged {
                        self.start(project)
                        self.listenerActionMessage = "Launch requested for \(project.name)."
                    } else {
                        self.listenerActionMessage = "Launch settings changed. Restart skipped."
                    }
                } else {
                    let message = Self.interruptMessage(result, pid: pid)
                    self.listenerActionMessage = restarting ? "\(message) Restart skipped." : message
                }
            }
            self.refresh()
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

    func setSessionRecoveryEnabled(_ enabled: Bool) {
        guard FeatureFlags.sessionRecovery, let sessionRecovery, isSessionRecoveryEnabled != enabled else { return }
        isSessionRecoveryEnabled = enabled
        SessionRecoveryPreference.save(enabled)
        Task {
            if enabled {
                await sessionRecovery.start()
            } else {
                await sessionRecovery.stop()
            }
        }
    }
}
