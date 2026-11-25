import Darwin
import Foundation

final class ProcessController: @unchecked Sendable {
    struct CommandProcess: Equatable, Sendable {
        let identity: ProcessIdentity
        let parentPID: Int32
        var exited = false
    }

    struct CommandAccess: Sendable {
        let parents: @Sendable () -> [Int32: Int32]?
        let read: @Sendable (Int32) -> CommandProcess?
        let isAbsent: @Sendable (Int32) -> Bool
        let sendTerm: @Sendable (Int32) -> Bool
        let attempts: Int
    }

    enum InterruptResult: Equatable, Sendable {
        case commandChanged, snapshotUnavailable, unsafeGroup, noSignal
        case requested(running: [Int32], unconfirmed: [Int32])
    }

    /// Agents only. Never escalates past SIGTERM and never follows a child that
    /// detached before signaling. Exit verification threads through PID reuse.
    func interruptLocalCommand(rootPID: Int32, expectedIdentity: ProcessIdentity,
                               displayedPIDs: [Int32],
                               permits: @Sendable (Int32) -> Bool,
                               access: CommandAccess? = nil) async -> InterruptResult {
        let access = access ?? CommandAccess(
            parents: Self.processParents, read: Self.readCommandProcess,
            isAbsent: { Darwin.kill($0, 0) != 0 && errno == ESRCH },
            sendTerm: { Darwin.kill($0, SIGTERM) == 0 }, attempts: 5
        )
        let ownPID = getpid()
        let ownUID = getuid()
        guard rootPID > 1, rootPID != ownPID, expectedIdentity.ownerUID == ownUID else { return .unsafeGroup }
        guard let root = access.read(rootPID) else {
            return access.isAbsent(rootPID) ? .commandChanged : .unsafeGroup
        }
        guard root.identity == expectedIdentity, !root.exited else { return .commandChanged }
        guard permits(rootPID) else { return .unsafeGroup }
        guard let parents = access.parents(), parents[rootPID] == root.parentPID else { return .snapshotUnavailable }

        let children = Dictionary(grouping: parents.keys, by: { parents[$0] ?? 0 })
        var group = [rootPID]
        var known: Set<Int32> = [rootPID]
        var index = 0
        while index < group.count {
            for child in children[group[index]] ?? [] {
                guard known.insert(child).inserted else { return .unsafeGroup }
                group.append(child)
            }
            index += 1
        }

        // Do not claim this stopped a member visible at confirmation that is
        // now gone from the tree but could still be running elsewhere.
        guard displayedPIDs.allSatisfy({ known.contains($0) || access.isAbsent($0) }) else { return .unsafeGroup }

        var targets = [Int32: CommandProcess]()
        for pid in group {
            guard pid > 1, pid != ownPID else { return .unsafeGroup }
            guard let record = access.read(pid) else {
                if access.isAbsent(pid) {
                    if pid == rootPID { return .commandChanged }
                    continue
                }
                return .unsafeGroup
            }
            if pid == rootPID, record.identity != expectedIdentity || record.exited { return .commandChanged }
            if record.exited { continue }
            guard record.identity.ownerUID == ownUID, record.parentPID == parents[pid], permits(pid) else {
                return .unsafeGroup
            }
            targets[pid] = record
        }

        func stillBelongs(_ pid: Int32) -> Bool {
            var current = pid
            while let record = targets[current], access.read(current) == record {
                if current == rootPID { return true }
                current = record.parentPID
            }
            return false
        }
        // Preflight finishes above before any signal. Verify identity and the
        // current parent chain again at delivery; POSIX signals are PID-based.
        var delivered = false
        for pid in group.reversed() where targets[pid] != nil {
            guard permits(pid), stillBelongs(pid) else { continue }
            if access.sendTerm(pid) { delivered = true }
        }

        func remaining() -> (running: [Int32], unconfirmed: [Int32]) {
            var running = [Int32]()
            var unconfirmed = [Int32]()
            for pid in group {
                guard let target = targets[pid] else { continue }
                if let current = access.read(pid) {
                    if current.identity == target.identity, !current.exited { running.append(pid) }
                } else if !access.isAbsent(pid) {
                    unconfirmed.append(pid)
                }
            }
            return (running.sorted(), unconfirmed.sorted())
        }

        var result = remaining()
        guard delivered else {
            return result.running.isEmpty && result.unconfirmed.isEmpty ? .commandChanged : .noSignal
        }
        for _ in 0..<access.attempts {
            guard !result.running.isEmpty || !result.unconfirmed.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(100))
            result = remaining()
        }
        return .requested(running: result.running, unconfirmed: result.unconfirmed)
    }

    private static func readCommandProcess(_ pid: Int32) -> CommandProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(exactly: pid), info.pbi_start_tvsec > 0,
              let parent = Int32(exactly: info.pbi_ppid) else { return nil }
        return CommandProcess(identity: ProcessIdentity(ownerUID: info.pbi_uid,
                                                        startTimeSeconds: UInt64(info.pbi_start_tvsec),
                                                        startTimeMicroseconds: UInt64(info.pbi_start_tvusec)),
                              parentPID: parent, exited: info.pbi_status == UInt32(SZOMB))
    }

    private static func processParents() -> [Int32: Int32]? {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid="])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        var parents = [Int32: Int32]()
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  parents.updateValue(parent, forKey: pid) == nil else { return nil }
        }
        return parents.isEmpty ? nil : parents
    }

    func terminateTree(rootPID: Int32) {
        let children = childMap()
        let tree = descendants(of: rootPID, in: children)
        let ordered = tree.reversed() + [rootPID]

        for pid in ordered {
            Darwin.kill(pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 0.6)

        for pid in ordered where isAlive(pid) {
            Darwin.kill(pid, SIGKILL)
        }
    }

    @discardableResult
    func terminateValidatedTree(rootPID: Int32, expectedIdentity: ProcessIdentity,
                                forceAfterGrace: Bool = true,
                                permits: @Sendable (Int32) -> Bool = { _ in true }) -> Bool {
        guard
            rootPID > 1, permits(rootPID),
            expectedIdentity.ownerUID == UInt32(getuid()),
            ProcessIdentityReader.read(pid: rootPID) == expectedIdentity
        else { return false }

        let children = childMap()
        let pids = Array(descendants(of: rootPID, in: children).reversed()) + [rootPID]
        let targets: [(pid: Int32, identity: ProcessIdentity)] = pids.compactMap { pid in
            guard
                let identity = ProcessIdentityReader.read(pid: pid),
                identity.ownerUID == expectedIdentity.ownerUID
            else { return nil }
            return (pid, identity)
        }
        guard pids.allSatisfy(permits),
              targets.contains(where: { $0.pid == rootPID && $0.identity == expectedIdentity }) else {
            return false
        }

        for target in targets {
            guard permits(target.pid), ProcessIdentityReader.read(pid: target.pid) == target.identity else { continue }
            Darwin.kill(target.pid, SIGTERM)
        }

        guard forceAfterGrace else { return true }
        Thread.sleep(forTimeInterval: 0.6)

        for target in targets where isAlive(target.pid) {
            guard permits(target.pid), ProcessIdentityReader.read(pid: target.pid) == target.identity else { continue }
            Darwin.kill(target.pid, SIGKILL)
        }
        return true
    }

    private func childMap() -> [Int32: [Int32]] {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid="])
        guard result.status == 0 else { return [:] }

        var map: [Int32: [Int32]] = [:]
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            map[ppid, default: []].append(pid)
        }
        return map
    }

    private func descendants(of pid: Int32, in map: [Int32: [Int32]]) -> [Int32] {
        let direct = map[pid] ?? []
        return direct + direct.flatMap { descendants(of: $0, in: map) }
    }

    private func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
