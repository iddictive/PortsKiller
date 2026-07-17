import Foundation

final class ProcessController: @unchecked Sendable {
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
    func terminateValidatedTree(rootPID: Int32, expectedIdentity: ProcessIdentity) -> Bool {
        guard
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
        guard targets.contains(where: { $0.pid == rootPID && $0.identity == expectedIdentity }) else {
            return false
        }

        for target in targets {
            guard ProcessIdentityReader.read(pid: target.pid) == target.identity else { continue }
            Darwin.kill(target.pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 0.6)

        for target in targets where isAlive(target.pid) {
            guard ProcessIdentityReader.read(pid: target.pid) == target.identity else { continue }
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
