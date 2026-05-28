import Foundation

final class ProcessScanner {
    private let excludedCommands = [
        "airplay", "airport", "controlcenter", "dropbox", "figma", "firefox",
        "google chrome", "linear helper", "rapportd", "safari", "sharingd",
        "ssh", "spoofdpi", "syncthing"
    ]

    private let devTokens = [
        " npm ", "/npm ", "npm run dev", " pnpm ", "/pnpm ", "pnpm dev",
        " yarn ", "/yarn ", "yarn dev", " bun ", "/bun ", "bun dev",
        "vite", "next dev", "next-server", "astro", "nuxt", "tsx", "nodemon",
        "node"
    ]

    func scan(manualProjects: [ManualProject]) -> [DevProcess] {
        let listeners = listeningPorts()
        let processMap = processSnapshots()
        let resourceMap = resourceSnapshots()
        let childMap = resourceMap.values.reduce(into: [Int32: [Int32]]()) { partial, snapshot in
            partial[snapshot.parentPID, default: []].append(snapshot.pid)
        }
        var result: [DevProcess] = []

        for listener in listeners {
            guard let snapshot = processMap[listener.pid] else { continue }
            let initialCombined = "\(listener.executable) \(snapshot.executable) \(snapshot.command)"
            guard containsDevToken(initialCombined), !containsExcludedToken(initialCombined) else { continue }

            let cwd = cwd(for: listener.pid)
            let combined = "\(snapshot.executable) \(snapshot.command) \(cwd ?? "")"

            guard isLikelyDevProcess(combined: combined, cwd: cwd) else { continue }

            let matchedProject = manualProjects.first { project in
                project.port == listener.port || normalized(project.cwd) == normalized(cwd ?? "")
            }

            let projectName = matchedProject?.name
                ?? packageName(in: cwd)
                ?? URL(fileURLWithPath: cwd ?? snapshot.executable).lastPathComponent
                .emptyFallback(snapshot.executable)

            result.append(
                DevProcess(
                    name: projectName,
                    pid: listener.pid,
                    parentPID: snapshot.parentPID,
                    port: listener.port,
                    host: listener.host,
                    executable: snapshot.executable,
                    command: snapshot.command,
                    cwd: cwd,
                    framework: frameworkName(from: combined, cwd: cwd),
                    resources: aggregateResources(rootPID: listener.pid, resources: resourceMap, children: childMap),
                    projectID: matchedProject?.id
                )
            )
        }

        return result.sorted {
            if $0.name == $1.name { return $0.port < $1.port }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func listeningPorts() -> [ListeningPort] {
        let result = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpPnTc"])
        guard result.status == 0 else { return [] }

        var currentPID: Int32?
        var currentCommand = ""
        var ports: [ListeningPort] = []
        var pendingPort: (host: String, port: Int)?

        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
                currentCommand = ""
                pendingPort = nil
            } else if line.hasPrefix("c") {
                currentCommand = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                pendingPort = parseAddress(String(line.dropFirst()))
            } else if line == "TST=LISTEN", let pid = currentPID, let parsed = pendingPort {
                ports.append(
                    ListeningPort(pid: pid, executable: currentCommand, port: parsed.port, host: parsed.host)
                )
                pendingPort = nil
            }
        }

        return ports
    }

    private func processSnapshots() -> [Int32: ProcessInfoSnapshot] {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm=,args="])
        guard result.status == 0 else { return [:] }

        var snapshots: [Int32: ProcessInfoSnapshot] = [:]
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let parts = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            snapshots[pid] = ProcessInfoSnapshot(
                pid: pid,
                parentPID: ppid,
                executable: parts[2],
                command: parts[3]
            )
        }
        return snapshots
    }

    private func resourceSnapshots() -> [Int32: ProcessResourceSnapshot] {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,etime="])
        guard result.status == 0 else { return [:] }

        var snapshots: [Int32: ProcessResourceSnapshot] = [:]
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let parts = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard
                parts.count == 5,
                let pid = Int32(parts[0]),
                let ppid = Int32(parts[1]),
                let cpu = Double(parts[2]),
                let rssKilobytes = UInt64(parts[3])
            else { continue }

            snapshots[pid] = ProcessResourceSnapshot(
                pid: pid,
                parentPID: ppid,
                cpuPercent: cpu,
                residentBytes: rssKilobytes * 1024,
                elapsedTime: parts[4]
            )
        }
        return snapshots
    }

    private func cwd(for pid: Int32) -> String? {
        let result = Shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        guard result.status == 0 else { return nil }
        return result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    private func aggregateResources(
        rootPID: Int32,
        resources: [Int32: ProcessResourceSnapshot],
        children: [Int32: [Int32]]
    ) -> ResourceUsage {
        guard let root = resources[rootPID] else { return .empty }

        var stack = [rootPID]
        var visited = Set<Int32>()
        var cpu = 0.0
        var memory: UInt64 = 0

        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let snapshot = resources[pid] {
                cpu += snapshot.cpuPercent
                memory += snapshot.residentBytes
            }
            stack.append(contentsOf: children[pid] ?? [])
        }

        return ResourceUsage(cpuPercent: cpu, memoryBytes: memory, uptime: root.elapsedTime)
    }

    private func isLikelyDevProcess(combined: String, cwd: String?) -> Bool {
        let value = " \(combined.lowercased()) "
        if excludedCommands.contains(where: { value.contains($0) }) { return false }
        if devTokens.contains(where: { value.contains($0) }) {
            if value.contains(" node ") || value.contains("/node ") {
                return hasPackageJSON(cwd: cwd) || value.contains("vite") || value.contains("next") || value.contains("server")
            }
            return true
        }
        return false
    }

    private func containsDevToken(_ value: String) -> Bool {
        let normalized = " \(value.lowercased()) "
        return devTokens.contains(where: { normalized.contains($0) })
    }

    private func containsExcludedToken(_ value: String) -> Bool {
        let normalized = " \(value.lowercased()) "
        return excludedCommands.contains(where: { normalized.contains($0) })
    }

    private func frameworkName(from combined: String, cwd: String?) -> String {
        let value = combined.lowercased()
        if value.contains("next") || packageJSON(in: cwd)?.dependenciesContain("next") == true { return "Next.js" }
        if value.contains("vite") || packageJSON(in: cwd)?.dependenciesContain("vite") == true { return "Vite" }
        if value.contains("astro") || packageJSON(in: cwd)?.dependenciesContain("astro") == true { return "Astro" }
        if value.contains("nuxt") || packageJSON(in: cwd)?.dependenciesContain("nuxt") == true { return "Nuxt" }
        if value.contains("nodemon") { return "Nodemon" }
        if value.contains("tsx") { return "TSX" }
        if value.contains("bun") { return "Bun" }
        return "Node"
    }

    private func packageName(in cwd: String?) -> String? {
        packageJSON(in: cwd)?["name"] as? String
    }

    private func hasPackageJSON(cwd: String?) -> Bool {
        guard let cwd else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("package.json").path)
    }

    private func packageJSON(in cwd: String?) -> [String: Any]? {
        guard let cwd else { return nil }
        let url = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func parseAddress(_ value: String) -> (host: String, port: Int)? {
        let endpoint = value.components(separatedBy: "->").first ?? value
        guard let colonIndex = endpoint.lastIndex(of: ":") else { return nil }
        let portText = endpoint[endpoint.index(after: colonIndex)...]
        guard let port = Int(portText) else { return nil }
        let host = String(endpoint[..<colonIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (host.isEmpty ? "localhost" : host, port)
    }

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private extension Dictionary where Key == String, Value == Any {
    func dependenciesContain(_ packageName: String) -> Bool {
        let groups = ["dependencies", "devDependencies", "peerDependencies"]
        return groups.contains { group in
            guard let deps = self[group] as? [String: Any] else { return false }
            return deps[packageName] != nil
        }
    }
}

private extension String {
    func emptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
