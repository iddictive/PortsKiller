import CryptoKit
import Foundation
import CoreServices

enum SessionRecoveryKind: String, Codable, Sendable {
    case cyber
    case transient

    var title: String {
        switch self {
        case .cyber: return "Cyber policy stop"
        case .transient: return "Temporary model failure"
        }
    }
}

struct SessionRecoveryEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let succeeded: Bool

    init(id: UUID = UUID(), date: Date = Date(), title: String, detail: String, succeeded: Bool = true) {
        self.id = id
        self.date = date
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
    }
}

struct SessionRecoverySnapshot: Equatable, Sendable {
    var isRunning = false
    var activeCount = 0
    var pendingCount = 0
    var recentEvents: [SessionRecoveryEvent] = []
    var issue: String?

    var isRecovering: Bool { activeCount > 0 }

    var statusText: String {
        if let issue { return issue }
        if activeCount > 0 { return "Resuming \(activeCount) session\(activeCount == 1 ? "" : "s")" }
        if pendingCount > 0 { return "Waiting to resume \(pendingCount) session\(pendingCount == 1 ? "" : "s")" }
        return isRunning ? "Watching Codex sessions" : "Recovery stopped"
    }
}

struct SessionRecoveryItem: Codable, Equatable, Sendable {
    let eventKey: String
    let sessionID: String
    let file: String
    let afterOffset: Int64
    let kind: SessionRecoveryKind
    let code: String
    var dueAt: Date
}

struct SessionRecoveryActive: Codable, Sendable {
    let item: SessionRecoveryItem
    let startedAt: Date
    let pid: Int32
    let processStart: String?
}

struct SessionRecoveryState: Codable, Sendable {
    static let version = 1

    var version = Self.version
    var files: [String: Int64] = [:]
    var pending: [String: SessionRecoveryItem] = [:]
    var handled: [String: Date] = [:]
    var active: [String: SessionRecoveryActive] = [:]
    var recentEvents: [SessionRecoveryEvent] = []
}

enum SessionRecoveryClassifier {
    static let cyberPrompt = "Продолжи выполнение текущей задачи с последнего подтверждённого безопасного состояния. Не повторяй формулировку, вызвавшую terminal error, и не пытайся обходить серверную policy. Используй только уже разрешённые штатные действия. Если следующий шаг действительно требует нового решения пользователя, кратко назови конкретный blocker."
    static let transientPrompt = "Продолжи выполнение текущей задачи с последнего подтверждённого состояния. Предыдущий turn завершился из-за временной перегрузки или сетевого сбоя модели; не начинай задачу заново и не повторяй уже завершённые действия."

    private static let transientCodes: Set<String> = [
        "server_overloaded", "server_error", "internal_server_error", "request_timeout",
        "gateway_timeout", "service_unavailable", "upstream_timeout", "stream_error", "network_error"
    ]
    private static let permanentPattern = #"\b(auth(?:entication|orization)?|billing|credit|quota|usage limit|permission|forbidden|invalid api|account)\b"#
    private static let transientPattern = #"(?:selected model is at capacity|model .* at capacity|server .* overload|high (?:load|demand|capacity)|temporar(?:ily|y) unavailable|service unavailable|gateway time(?:d? ?out)|request time(?:d? ?out)|server time(?:d? ?out)|upstream time(?:d? ?out)|stream (?:disconnected|closed unexpectedly)|connection (?:reset|timed out)|\b(?:502|503|504)\b)"#

    static func classify(code rawCode: String?, message: String?) -> (SessionRecoveryKind, String)? {
        let code = (rawCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = message ?? ""
        if code == "cyber_policy" { return (.cyber, code) }
        if code.range(of: #"rate.?limit|quota|usage|billing|auth|permission|forbidden"#, options: .regularExpression) != nil {
            return nil
        }
        if transientCodes.contains(code) { return (.transient, code) }
        let isPermanent = message.range(of: permanentPattern, options: [.regularExpression, .caseInsensitive]) != nil
        let isTransient = message.range(of: transientPattern, options: [.regularExpression, .caseInsensitive]) != nil
        return !isPermanent && isTransient ? (.transient, code.isEmpty ? "transient_message" : code) : nil
    }

    static func prompt(for kind: SessionRecoveryKind) -> String {
        kind == .cyber ? cyberPrompt : transientPrompt
    }

    static func isRecoveryPrompt(_ message: String) -> Bool {
        let value = message.trimmingCharacters(in: .newlines)
        return value == cyberPrompt || value == transientPrompt
    }
}

final class SessionRecoveryService: ObservableObject, @unchecked Sendable {
    private static let maximumScanBytes = 8 * 1_024 * 1_024

    @MainActor @Published private(set) var snapshot = SessionRecoverySnapshot()

    private let fileManager: FileManager
    private let codexHome: URL
    private let sessionsRoot: URL
    private let stateDirectory: URL
    private let stateURL: URL
    private let workerQueue = DispatchQueue(label: "com.md.PortsKiller.session-recovery", qos: .utility)
    private var state: SessionRecoveryState
    private var lastSweepDate: Date
    private var isRunning = false
    private var issue: String?
    private var lastPublishedSnapshot = SessionRecoverySnapshot()
    private var eventStream: FSEventStreamRef?
    private var dueTimer: DispatchSourceTimer?
    private var fallbackTimer: DispatchSourceTimer?
    private var scanWorkItem: DispatchWorkItem?
    private var stateSaveWorkItem: DispatchWorkItem?
    private var runningProcesses: [String: Process] = [:]

    init(
        fileManager: FileManager = .default,
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        stateDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.codexHome = codexHome
        sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.stateDirectory = stateDirectory ?? applicationSupport
            .appendingPathComponent("PortsKiller", isDirectory: true)
            .appendingPathComponent("session-recovery", isDirectory: true)
        stateURL = self.stateDirectory.appendingPathComponent("state.json")
        state = Self.loadState(from: stateURL) ?? SessionRecoveryState()
        lastSweepDate = (try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
    }

    func start() async {
        await onWorker { self.startOnWorker() }
    }

    private func startOnWorker() {
        guard !isRunning else { return }
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
            if state.files.isEmpty {
                baselineRecentFiles()
            } else {
                _ = scanRecentFiles(modifiedAfter: lastSweepDate.addingTimeInterval(-5))
            }
            lastSweepDate = Date()
            reconcileInterruptedRecoveries()
            startEventStream()
            startTimers()
            isRunning = true
            issue = nil
            saveState()
            publishSnapshot()
        } catch {
            issue = "Recovery unavailable"
            isRunning = false
            publishSnapshot()
        }
    }

    func scanNow() async {
        await onWorker {
            _ = self.scanAllFiles()
            self.tick()
        }
    }

    func stop() async {
        await onWorker { self.stopOnWorker() }
    }

    private func stopOnWorker() {
        dueTimer?.cancel()
        fallbackTimer?.cancel()
        dueTimer = nil
        fallbackTimer = nil
        scanWorkItem?.cancel()
        scanWorkItem = nil
        if stateSaveWorkItem != nil {
            saveState()
        }
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            self.eventStream = nil
        }
        for process in runningProcesses.values where process.isRunning {
            process.terminate()
        }
        runningProcesses.removeAll()
        isRunning = false
        publishSnapshot()
    }

    private func onWorker(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            workerQueue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func startTimers() {
        let dueTimer = DispatchSource.makeTimerSource(queue: workerQueue)
        dueTimer.schedule(deadline: .now() + 1, repeating: 1)
        dueTimer.setEventHandler { [weak self] in self?.tick() }
        dueTimer.resume()
        self.dueTimer = dueTimer

        let fallbackTimer = DispatchSource.makeTimerSource(queue: workerQueue)
        fallbackTimer.schedule(deadline: .now() + 300, repeating: 300)
        fallbackTimer.setEventHandler { [weak self] in self?.reconcileRecentFiles() }
        fallbackTimer.resume()
        self.fallbackTimer = fallbackTimer
    }

    static func persistedSnapshot(fileManager: FileManager = .default) -> SessionRecoverySnapshot {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PortsKiller/session-recovery/state.json")
        guard let state = loadState(from: root) else { return SessionRecoverySnapshot() }
        return SessionRecoverySnapshot(
            isRunning: false,
            activeCount: state.active.count,
            pendingCount: state.pending.count,
            recentEvents: state.recentEvents,
            issue: nil
        )
    }

    private func startEventStream() {
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let service = Unmanaged<SessionRecoveryService>.fromOpaque(info).takeUnretainedValue()
            let pathBuffer = paths.bindMemory(to: UnsafePointer<CChar>?.self, capacity: count)
            let changedPaths = (0..<count).compactMap { index -> String? in
                guard let path = pathBuffer[index] else { return nil }
                return String(cString: path)
            }
            service.scheduleScan(paths: changedPaths)
        }
        eventStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [sessionsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        )
        if let eventStream {
            FSEventStreamSetDispatchQueue(eventStream, workerQueue)
            FSEventStreamStart(eventStream)
        }
    }

    private func scheduleScan(paths: [String]) {
        var jsonlPaths = Set(paths.filter { $0.hasSuffix(".jsonl") })
        let recentCutoff = Date().addingTimeInterval(-120)
        for path in paths where !path.hasSuffix(".jsonl") {
            let eventURL = URL(fileURLWithPath: path, isDirectory: true)
            if eventURL.standardizedFileURL.path == sessionsRoot.standardizedFileURL.path {
                jsonlPaths.formUnion(listRecentSessionFiles(modifiedAfter: recentCutoff).map(\.path))
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: eventURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                jsonlPaths.formUnion(listSessionFiles(at: eventURL, modifiedAfter: recentCutoff).map(\.path))
            }
        }
        guard !jsonlPaths.isEmpty else { return }
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var changed = false
            for path in jsonlPaths {
                changed = self.scanFile(URL(fileURLWithPath: path)) || changed
            }
            if changed {
                self.scheduleStateSave()
                self.publishSnapshot()
            }
        }
        scanWorkItem = work
        workerQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func baselineRecentFiles() {
        for file in listRecentSessionFiles(modifiedAfter: nil) {
            state.files[file.path] = fileSize(file)
        }
    }

    @discardableResult
    private func scanAllFiles() -> Bool {
        scanFiles(listSessionFiles())
    }

    @discardableResult
    private func scanRecentFiles(modifiedAfter cutoff: Date?) -> Bool {
        scanFiles(listRecentSessionFiles(modifiedAfter: cutoff))
    }

    @discardableResult
    private func scanFiles(_ files: [URL]) -> Bool {
        var changed = false
        for file in files {
            guard state.files[file.path] != fileSize(file) else { continue }
            changed = scanFile(file) || changed
        }
        if changed {
            scheduleStateSave()
            publishSnapshot()
        }
        return changed
    }

    private func reconcileRecentFiles() {
        let cutoff = lastSweepDate.addingTimeInterval(-5)
        lastSweepDate = Date()
        _ = scanRecentFiles(modifiedAfter: cutoff)
    }

    private func listRecentSessionFiles(modifiedAfter cutoff: Date?) -> [URL] {
        recentSessionRoots().flatMap { listSessionFiles(at: $0, modifiedAfter: cutoff) }
    }

    private func recentSessionRoots(now: Date = Date()) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (0..<3).compactMap { dayOffset -> URL? in
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func listSessionFiles(at root: URL? = nil, modifiedAfter cutoff: Date? = nil) -> [URL] {
        let root = root ?? sessionsRoot
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL, url.pathExtension == "jsonl" else { return nil }
            if let cutoff {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff else { return nil }
            }
            return url
        }
    }

    @discardableResult
    private func scanFile(_ file: URL) -> Bool {
        let previousOffset = state.files[file.path] ?? 0
        let result = readCompleteLines(
            file: file,
            offset: previousOffset,
            maximumBytes: Self.maximumScanBytes
        )
        var changed = result.offset != previousOffset
        state.files[file.path] = result.offset
        for line in result.lines {
            guard let item = recoveryItem(from: line.data, file: file, afterOffset: line.afterOffset) else { continue }
            guard state.handled[item.eventKey] == nil, state.pending[item.eventKey] == nil else { continue }
            var pending = item
            pending.dueAt = Date().addingTimeInterval(item.kind == .cyber ? 8 : 25)
            state.pending[pending.eventKey] = pending
            recordEvent(title: "Recovery queued", detail: item.kind.title)
            changed = true
        }
        return changed
    }

    private func recoveryItem(from data: Data, file: URL, afterOffset: Int64) -> SessionRecoveryItem? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "event_msg",
            let payload = json["payload"] as? [String: Any],
            payload["type"] as? String == "task_complete",
            let error = payload["error"] as? [String: Any],
            let classification = SessionRecoveryClassifier.classify(
                code: error["codex_error_info"] as? String ?? error["code"] as? String,
                message: error["message"] as? String
            ),
            let sessionID = Self.sessionID(from: file.lastPathComponent)
        else { return nil }

        let timestamp = json["timestamp"] as? String ?? ""
        let turnID = payload["turn_id"] as? String ?? ""
        let eventKey = Self.hash("\(sessionID)|\(turnID)|\(timestamp)|\(classification.1)")
        return SessionRecoveryItem(
            eventKey: eventKey,
            sessionID: sessionID,
            file: file.path,
            afterOffset: afterOffset,
            kind: classification.0,
            code: classification.1,
            dueAt: Date()
        )
    }

    private func tick() {
        var changed = reconcileFinishedProcesses()
        let now = Date()
        changed = prune(now: now) || changed
        for (eventKey, item) in state.pending where item.dueAt <= now {
            changed = true
            state.pending[eventKey] = nil
            if hasLaterManualActivity(item) {
                state.handled[eventKey] = now
                recordEvent(title: "Recovery skipped", detail: "Newer manual activity found")
                continue
            }
            if state.active[item.sessionID] != nil {
                state.handled[eventKey] = now
                continue
            }
            startRecovery(item)
        }
        if changed {
            saveState()
            publishSnapshot()
        }
    }

    private func startRecovery(_ item: SessionRecoveryItem) {
        guard let workspace = sessionWorkspace(file: URL(fileURLWithPath: item.file)) else {
            state.handled[item.eventKey] = Date()
            recordEvent(title: "Recovery skipped", detail: "Original workspace is missing", succeeded: false)
            return
        }
        guard let codexExecutable = resolveCodexExecutable() else {
            var retry = item
            retry.dueAt = Date().addingTimeInterval(60)
            state.pending[item.eventKey] = retry
            recordEvent(title: "Recovery delayed", detail: "Codex CLI was not found", succeeded: false)
            return
        }

        let process = Process()
        let input = Pipe()
        process.executableURL = codexExecutable
        process.arguments = ["exec", "resume", "--json", item.sessionID, "-"]
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_RECOVERY_WATCHDOG"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            self.workerQueue.async {
                self.finishRecovery(item, status: status)
            }
        }

        do {
            try process.run()
            let prompt = SessionRecoveryClassifier.prompt(for: item.kind) + "\n"
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            state.handled[item.eventKey] = Date()
            state.active[item.sessionID] = .init(
                item: item,
                startedAt: Date(),
                pid: process.processIdentifier,
                processStart: processStartIdentity(process.processIdentifier)
            )
            runningProcesses[item.sessionID] = process
            recordEvent(title: "Recovery started", detail: item.kind.title)
        } catch {
            var retry = item
            retry.dueAt = Date().addingTimeInterval(60)
            state.pending[item.eventKey] = retry
            recordEvent(title: "Recovery delayed", detail: "Could not start Codex CLI", succeeded: false)
        }
    }

    private func finishRecovery(_ item: SessionRecoveryItem, status: Int32) {
        runningProcesses[item.sessionID] = nil
        state.active[item.sessionID] = nil
        if status == 0 {
            recordEvent(title: "Recovery finished", detail: item.kind.title)
        } else {
            state.handled[item.eventKey] = nil
            var retry = item
            retry.dueAt = Date().addingTimeInterval(60)
            state.pending[item.eventKey] = retry
            recordEvent(title: "Recovery delayed", detail: "Codex exited with status \(status)", succeeded: false)
        }
        saveState()
        publishSnapshot()
    }

    @discardableResult
    private func reconcileFinishedProcesses() -> Bool {
        var changed = false
        for (sessionID, active) in state.active where runningProcesses[sessionID] == nil {
            guard !processRecordIsAlive(active) else { continue }
            reconcile(active: active)
            changed = true
        }
        return changed
    }

    private func reconcileInterruptedRecoveries() {
        for active in state.active.values where !processRecordIsAlive(active) {
            reconcile(active: active)
        }
    }

    private func reconcile(active: SessionRecoveryActive) {
        state.active[active.item.sessionID] = nil
        let tail = inspectTail(active.item, after: active.startedAt)
        if tail.hasTerminal || tail.hasManualActivity {
            state.handled[active.item.eventKey] = Date()
            return
        }
        state.handled[active.item.eventKey] = nil
        var retry = active.item
        retry.dueAt = Date().addingTimeInterval(1)
        state.pending[retry.eventKey] = retry
        recordEvent(title: "Recovery restored", detail: "Interrupted retry was queued again")
    }

    private func hasLaterManualActivity(_ item: SessionRecoveryItem) -> Bool {
        inspectTail(item, afterOffset: item.afterOffset).hasManualActivity
    }

    private func inspectTail(_ item: SessionRecoveryItem, after date: Date? = nil, afterOffset: Int64? = nil) -> (hasTerminal: Bool, hasManualActivity: Bool) {
        let result = readCompleteLines(file: URL(fileURLWithPath: item.file), offset: afterOffset ?? item.afterOffset)
        var hasTerminal = false
        var hasManualActivity = false
        for line in result.lines {
            guard let json = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { continue }
            if let date, let raw = json["timestamp"] as? String,
               let eventDate = ISO8601DateFormatter().date(from: raw), eventDate <= date { continue }
            guard json["type"] as? String == "event_msg", let payload = json["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String
            if type == "task_complete" || type == "turn_aborted" { hasTerminal = true }
            if type == "user_message", let message = payload["message"] as? String,
               !SessionRecoveryClassifier.isRecoveryPrompt(message) { hasManualActivity = true }
        }
        return (hasTerminal, hasManualActivity)
    }

    private func sessionWorkspace(file: URL) -> URL? {
        let result = readCompleteLines(file: file, offset: 0, maximumBytes: 512 * 1024)
        for line in result.lines {
            guard
                let json = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                json["type"] as? String == "session_meta",
                let payload = json["payload"] as? [String: Any],
                let cwd = payload["cwd"] as? String,
                fileManager.fileExists(atPath: cwd)
            else { continue }
            return URL(fileURLWithPath: cwd, isDirectory: true)
        }
        return nil
    }

    private func resolveCodexExecutable() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func processRecordIsAlive(_ active: SessionRecoveryActive) -> Bool {
        guard kill(active.pid, 0) == 0, let expected = active.processStart else { return false }
        return processStartIdentity(active.pid) == expected
    }

    private func processStartIdentity(_ pid: Int32) -> String? {
        let result = Shell.run("/bin/ps", ["-p", String(pid), "-o", "lstart="])
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !value.isEmpty ? value : nil
    }

    @discardableResult
    private func prune(now: Date) -> Bool {
        let dayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let pruned = state.handled.filter { $0.value >= dayAgo }
        guard pruned.count != state.handled.count else { return false }
        state.handled = pruned
        return true
    }

    private func recordEvent(title: String, detail: String, succeeded: Bool = true) {
        state.recentEvents.insert(.init(title: title, detail: detail, succeeded: succeeded), at: 0)
        state.recentEvents = Array(state.recentEvents.prefix(8))
    }

    private func publishSnapshot() {
        let snapshot = SessionRecoverySnapshot(
            isRunning: isRunning,
            activeCount: state.active.count,
            pendingCount: state.pending.count,
            recentEvents: state.recentEvents,
            issue: issue
        )
        guard snapshot != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = snapshot
        Task { @MainActor [weak self] in
            self?.snapshot = snapshot
        }
    }

    private func scheduleStateSave() {
        stateSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveState()
        }
        stateSaveWorkItem = work
        workerQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func saveState() {
        stateSaveWorkItem?.cancel()
        stateSaveWorkItem = nil
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.sessionRecovery.encode(state)
            try data.write(to: stateURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            issue = "Recovery state could not be saved"
        }
    }

    private static func loadState(from url: URL) -> SessionRecoveryState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.sessionRecovery.decode(SessionRecoveryState.self, from: data),
              state.version == SessionRecoveryState.version else { return nil }
        return state
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func readCompleteLines(file: URL, offset: Int64, maximumBytes: Int? = nil) -> (lines: [(data: Data, afterOffset: Int64)], offset: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], offset) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size < UInt64(max(0, offset)) ? 0 : UInt64(max(0, offset))
        try? handle.seek(toOffset: start)
        let requested = maximumBytes.map { min(UInt64($0), size - start) }
        let data = (try? handle.read(upToCount: requested.map(Int.init) ?? Int(size - start))) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], Int64(start)) }
        let complete = data.prefix(through: lastNewline)
        var lines: [(Data, Int64)] = []
        var lineStart = complete.startIndex
        for newline in complete.indices where complete[newline] == 0x0A {
            let afterNewline = complete.index(after: newline)
            if lineStart < newline {
                let afterOffset = Int64(start) + Int64(complete.distance(from: complete.startIndex, to: afterNewline))
                lines.append((Data(complete[lineStart..<newline]), afterOffset))
            }
            lineStart = afterNewline
        }
        return (lines, Int64(start) + Int64(complete.count))
    }

    private static func sessionID(from filename: String) -> String? {
        let pattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#
        guard let range = filename.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(filename[range]).replacingOccurrences(of: ".jsonl", with: "")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var sessionRecovery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sessionRecovery: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
