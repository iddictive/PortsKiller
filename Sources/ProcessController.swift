import Foundation

final class ProcessController {
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
