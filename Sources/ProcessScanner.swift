import Darwin
import Foundation

final class ProcessScanner {
    private let systemTokens = [
        "airplay", "airport", "controlcenter", "rapportd", "safari", "sharingd",
        "ssh", "universalcontrol", "identityservices",
        "knowledgeconstructiond", "rapport", "remoted", "screensharing"
    ]

    private let desktopAppTokens = [
        "dropbox", "figma", "firefox", "google chrome", "google drive",
        "linear helper", "spoofdpi", "syncthing"
    ]

    private let devTokens = [
        " npm ", "/npm ", "npm run dev", " pnpm ", "/pnpm ", "pnpm dev",
        " yarn ", "/yarn ", "yarn dev", " bun ", "/bun ", "bun dev",
        "vite", "next dev", "next-server", "astro", "nuxt", "tsx", "nodemon",
        "node"
    ]

    private let jsToolTokens = [
        " npm ", "/npm ", " pnpm ", "/pnpm ", " yarn ", "/yarn ", " bun ", "/bun ",
        "node", "tsx", "playwright", "vite-node"
    ]

    private let mcpServerTokens = [
        "/mcp/", "/mcp ", " mcp ", " mcp-", "/mcp-",
        "mcp-server", "modelcontextprotocol", "@modelcontextprotocol"
    ]

    private let localServiceTokens = [
        "postgres", "redis", "mysql", "mongod", "nginx", "caddy", "ollama",
        "python", "uvicorn", "gunicorn", "ruby", "rails", "php", "java"
    ]

    private let simulatorTokens = [
        "coresimulator", "/developer/coreSimulator/", ".simruntime/", "launchd_sim",
        "simdiskimaged", "simlaunchhost", "simulatortrampoline", "simrender",
        "simmetal", "simaudio", "qemu-system", "android emulator", "-avd "
    ].map { $0.lowercased() }

    private let activityToolTokens = [
        "node", "npm", "pnpm", "yarn", "bun", "tsx", "xcodebuild", "swift",
        "docker", "orbstack", "colima", "playwright", "codex", "ollama"
    ]

    private let activityMinimumCPU = 3.0
    private let activityMinimumMemory: UInt64 = 200 * 1_048_576
    private let packageScriptInspector = PackageScriptInspector()

    func scan(manualProjects: [ManualProject], mode: ProcessViewMode = .dev) -> [DevProcess] {
        let listeners = listeningPorts()
        let processMap = processSnapshots()
        let cwdByPID = workingDirectories(for: Set(listeners.map(\.pid)))
        let childMap = processMap.values.reduce(into: [Int32: [Int32]]()) { partial, snapshot in
            partial[snapshot.parentPID, default: []].append(snapshot.pid)
        }
        var result: [DevProcess] = []
        var seenListeners = Set<String>()

        for listener in listeners {
            guard let snapshot = processMap[listener.pid] else { continue }
            guard seenListeners.insert("\(listener.pid):\(listener.port)").inserted else { continue }
            let initialCombined = "\(listener.executable) \(snapshot.executable) \(snapshot.command)"

            let cwd = cwdByPID[listener.pid]
            let combined = "\(snapshot.executable) \(snapshot.command) \(cwd ?? "")"
            let kind = classify(combined: "\(initialCombined) \(combined)", cwd: cwd)

            if mode == .dev, kind != .dev { continue }

            let matchedProject = manualProjects.first { project in
                project.port == listener.port || normalized(project.cwd) == normalized(cwd ?? "")
            }

            let projectName = matchedProject?.name
                ?? mcpDisplayName(from: "\(initialCombined) \(combined)")
                ?? packageName(in: cwd)
                ?? displayName(cwd: cwd, executable: snapshot.executable, listenerExecutable: listener.executable)
            let inferredRestartCommand = matchedProject == nil && kind == .dev
                ? cwd.flatMap { packageScriptInspector.restartCommand(cwd: $0, port: listener.port) }
                : nil

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
                    framework: frameworkName(from: combined, cwd: cwd, executable: snapshot.executable, listenerExecutable: listener.executable),
                    kind: kind,
                    resources: aggregateResources(rootPID: listener.pid, snapshots: processMap, children: childMap),
                    projectID: matchedProject?.id,
                    inferredRestartCommand: inferredRestartCommand
                )
            )
        }

        return result.sorted {
            if $0.kind.sortPriority != $1.kind.sortPriority {
                return $0.kind.sortPriority < $1.kind.sortPriority
            }
            if $0.name == $1.name { return $0.port < $1.port }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func scanActivity(limit: Int = 18) -> [ActivityProcess] {
        let snapshots = processSnapshots()
        guard !snapshots.isEmpty, limit > 0 else { return [] }

        let children = snapshots.values.reduce(into: [Int32: [Int32]]()) { partial, snapshot in
            partial[snapshot.parentPID, default: []].append(snapshot.pid)
        }
        let simulatorPIDs = Set(snapshots.values.filter(isSimulatorProcess).map(\.pid))
        let runtimeRoots = simulatorPIDs.compactMap { snapshots[$0] }.filter(isSimulatorRuntimeRoot)
        var coveredSimulatorPIDs = Set<Int32>()
        var simulatorEntries: [ActivityProcess] = []

        for root in runtimeRoots {
            let familyPIDs = descendantsIncludingRoot(root.pid, children: children)
            coveredSimulatorPIDs.formUnion(familyPIDs)
            let isAndroid = root.command.lowercased().contains("qemu-system")
                || root.command.lowercased().contains("-avd ")
            let identity = ProcessIdentityReader.read(pid: root.pid)
            simulatorEntries.append(
                ActivityProcess(
                    id: "simulator:\(root.pid)",
                    name: isAndroid ? "Android Emulator" : "iOS Simulator",
                    detail: simulatorDetail(for: root, processCount: familyPIDs.count),
                    command: root.command,
                    kind: .simulator,
                    resources: aggregateResources(rootPID: root.pid, snapshots: snapshots, children: children),
                    processCount: familyPIDs.count,
                    targetPIDs: [root.pid],
                    identity: identity,
                    canStop: identity?.ownerUID == UInt32(getuid())
                )
            )
        }

        let servicePIDs = simulatorPIDs.subtracting(coveredSimulatorPIDs)
        if !servicePIDs.isEmpty {
            simulatorEntries.append(
                ActivityProcess(
                    id: "simulator-services",
                    name: "CoreSimulator services",
                    detail: "\(servicePIDs.count) background processes",
                    command: "CoreSimulator support services",
                    kind: .simulator,
                    resources: aggregateResources(pids: servicePIDs, snapshots: snapshots),
                    processCount: servicePIDs.count,
                    targetPIDs: [],
                    identity: nil,
                    canStop: false
                )
            )
        }

        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let heavyEntries = snapshots.values
            .filter { snapshot in
                snapshot.pid > 1
                    && snapshot.pid != currentPID
                    && !simulatorPIDs.contains(snapshot.pid)
                    && (snapshot.resources.cpuPercent >= activityMinimumCPU
                        || snapshot.resources.memoryBytes >= activityMinimumMemory)
            }
            .map { snapshot in
                let kind = activityKind(for: snapshot)
                return ActivityProcess(
                    id: "process:\(snapshot.pid)",
                    name: activityDisplayName(for: snapshot),
                    detail: "PID \(snapshot.pid)",
                    command: snapshot.command,
                    kind: kind,
                    resources: snapshot.resources,
                    processCount: 1,
                    targetPIDs: [snapshot.pid],
                    identity: nil,
                    canStop: false
                )
            }
            .sorted(by: resourceSort)

        let reservedSimulatorCount = min(simulatorEntries.count, min(6, limit))
        let selected = Array(simulatorEntries.sorted(by: resourceSort).prefix(reservedSimulatorCount))
            + Array(heavyEntries.prefix(limit - reservedSimulatorCount))
        return selected.sorted(by: resourceSort)
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

    private func processSnapshots() -> [Int32: ProcessSnapshot] {
        let result = Shell.run("/bin/ps", ["-ww", "-axo", "pid=,ppid=,uid=,%cpu=,rss=,etime=,args="])
        guard result.status == 0 else { return [:] }

        var snapshots: [Int32: ProcessSnapshot] = [:]
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let parts = line.split(maxSplits: 6, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard
                parts.count == 7,
                let pid = Int32(parts[0]),
                let ppid = Int32(parts[1]),
                let ownerUID = UInt32(parts[2]),
                let cpu = Double(parts[3]),
                let rssKilobytes = UInt64(parts[4])
            else { continue }

            let command = parts[6]
            let executable = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? command
            snapshots[pid] = ProcessSnapshot(
                pid: pid,
                parentPID: ppid,
                ownerUID: ownerUID,
                executable: executable,
                command: command,
                resources: ResourceUsage(
                    cpuPercent: cpu,
                    memoryBytes: rssKilobytes * 1024,
                    uptime: parts[5]
                )
            )
        }
        return snapshots
    }

    private func workingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.sorted().map(String.init).joined(separator: ",")
        let result = Shell.run("/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-Fpn"])
        guard !result.output.isEmpty else { return [:] }

        var currentPID: Int32?
        var directories: [Int32: String] = [:]
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let currentPID {
                directories[currentPID] = String(line.dropFirst())
            }
        }
        return directories
    }

    private func aggregateResources(
        rootPID: Int32,
        snapshots: [Int32: ProcessSnapshot],
        children: [Int32: [Int32]]
    ) -> ResourceUsage {
        guard let root = snapshots[rootPID] else { return .empty }

        var stack = [rootPID]
        var visited = Set<Int32>()
        var cpu = 0.0
        var memory: UInt64 = 0

        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let snapshot = snapshots[pid] {
                cpu += snapshot.resources.cpuPercent
                memory += snapshot.resources.memoryBytes
            }
            stack.append(contentsOf: children[pid] ?? [])
        }

        return ResourceUsage(cpuPercent: cpu, memoryBytes: memory, uptime: root.resources.uptime)
    }

    private func aggregateResources(
        pids: Set<Int32>,
        snapshots: [Int32: ProcessSnapshot]
    ) -> ResourceUsage {
        let values = pids.compactMap { snapshots[$0]?.resources }
        guard let first = values.first else { return .empty }
        return ResourceUsage(
            cpuPercent: values.reduce(0) { $0 + $1.cpuPercent },
            memoryBytes: values.reduce(0) { $0 + $1.memoryBytes },
            uptime: first.uptime
        )
    }

    private func descendantsIncludingRoot(
        _ rootPID: Int32,
        children: [Int32: [Int32]]
    ) -> Set<Int32> {
        var stack = [rootPID]
        var result = Set<Int32>()
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    private func isSimulatorProcess(_ snapshot: ProcessSnapshot) -> Bool {
        let value = snapshot.command.lowercased()
        return simulatorTokens.contains { value.contains($0) }
    }

    private func isSimulatorRuntimeRoot(_ snapshot: ProcessSnapshot) -> Bool {
        let value = snapshot.command.lowercased()
        return value.hasPrefix("launchd_sim ")
            || value.contains("qemu-system")
            || value.contains(" -avd ")
    }

    private func simulatorDetail(for snapshot: ProcessSnapshot, processCount: Int) -> String {
        let command = snapshot.command
        if let devicesRange = command.range(of: "/Devices/", options: .caseInsensitive) {
            let suffix = command[devicesRange.upperBound...]
            let deviceID = suffix.split(separator: "/").first.map(String.init) ?? ""
            if !deviceID.isEmpty {
                return "Device \(deviceID.prefix(8)) · \(processCount) processes"
            }
        }
        return "\(processCount) processes"
    }

    private func activityKind(for snapshot: ProcessSnapshot) -> ActivityProcessKind {
        let value = snapshot.command.lowercased()
        if snapshot.ownerUID == 0 || value.hasPrefix("/system/") || value.contains("/usr/libexec/") {
            return .system
        }
        if value.contains(".app/contents/") { return .application }
        if activityToolTokens.contains(where: { value.contains($0) }) { return .developerTool }
        return .other
    }

    private func activityDisplayName(for snapshot: ProcessSnapshot) -> String {
        if let appRange = snapshot.command.range(of: ".app/", options: [.caseInsensitive, .backwards]) {
            let appPath = snapshot.command[..<appRange.lowerBound]
            if let component = appPath.split(separator: "/").last, !component.isEmpty {
                return String(component)
            }
        }

        let executableName = URL(fileURLWithPath: snapshot.executable).lastPathComponent
        if !executableName.isEmpty && executableName != "/" { return executableName }
        return "PID \(snapshot.pid)"
    }

    private func resourceSort(_ lhs: ActivityProcess, _ rhs: ActivityProcess) -> Bool {
        if lhs.resources.memoryBytes != rhs.resources.memoryBytes {
            return lhs.resources.memoryBytes > rhs.resources.memoryBytes
        }
        if lhs.resources.cpuPercent != rhs.resources.cpuPercent {
            return lhs.resources.cpuPercent > rhs.resources.cpuPercent
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func isLikelyDevProcess(combined: String, cwd: String?) -> Bool {
        let value = " \(combined.lowercased()) "
        if isLikelyMCPProcess(combined: combined) {
            return true
        }
        if systemTokens.contains(where: { value.contains($0) }) || desktopAppTokens.contains(where: { value.contains($0) }) {
            return false
        }
        if isDevFrameworkProject(cwd: cwd), jsToolTokens.contains(where: { value.contains($0) }) {
            return true
        }
        if devTokens.contains(where: { value.contains($0) }) {
            if value.contains(" node ") || value.contains("/node ") {
                return value.contains("vite")
                    || value.contains("next")
                    || value.contains("server")
                    || (hasPackageJSON(cwd: cwd) && isDevFrameworkProject(cwd: cwd))
            }
            return true
        }
        return false
    }

    private func classify(combined: String, cwd: String?) -> ProcessKind {
        let value = " \(combined.lowercased()) "
        if isLikelyDevProcess(combined: combined, cwd: cwd) { return .dev }
        if desktopAppTokens.contains(where: { value.contains($0) }) { return .desktopApp }
        if isLikelyMCPProcess(combined: combined) || jsToolTokens.contains(where: { value.contains($0) }) || hasPackageJSON(cwd: cwd) { return .jsTool }
        if localServiceTokens.contains(where: { value.contains($0) }) { return .localService }
        if systemTokens.contains(where: { value.contains($0) }) || value.contains("/system/") || value.contains("/usr/libexec/") {
            return .system
        }
        return .unknown
    }

    private func frameworkName(from combined: String, cwd: String?, executable: String, listenerExecutable: String) -> String {
        let value = combined.lowercased()
        if isLikelyMCPProcess(combined: combined) { return "MCP" }
        if value.contains("next") || packageJSON(in: cwd)?.dependenciesContain("next") == true { return "Next.js" }
        if value.contains("vite") || packageJSON(in: cwd)?.dependenciesContain("vite") == true { return "Vite" }
        if value.contains("astro") || packageJSON(in: cwd)?.dependenciesContain("astro") == true { return "Astro" }
        if value.contains("nuxt") || packageJSON(in: cwd)?.dependenciesContain("nuxt") == true { return "Nuxt" }
        if value.contains("nodemon") { return "Nodemon" }
        if value.contains("tsx") { return "TSX" }
        if value.contains("bun") { return "Bun" }
        if value.contains("node") { return "Node" }
        return listenerExecutable.emptyFallback(URL(fileURLWithPath: executable).lastPathComponent)
    }

    private func isLikelyMCPProcess(combined: String) -> Bool {
        let value = " \(combined.lowercased()) "
        return mcpServerTokens.contains { value.contains($0) }
    }

    private func mcpDisplayName(from combined: String) -> String? {
        combined
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { rawToken -> String? in
                let token = String(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard token.contains("/mcp/") || token.contains("/mcp-") else { return nil }
                let name = URL(fileURLWithPath: token).deletingLastPathComponent().lastPathComponent
                return name.isEmpty ? nil : name
            }
            .first
    }

    private func packageName(in cwd: String?) -> String? {
        packageJSON(in: cwd)?["name"] as? String
    }

    private func hasPackageJSON(cwd: String?) -> Bool {
        guard let cwd else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("package.json").path)
    }

    private func isDevFrameworkProject(cwd: String?) -> Bool {
        guard let package = packageJSON(in: cwd) else { return false }
        return ["vite", "next", "astro", "nuxt"].contains { package.dependenciesContain($0) }
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

    private func displayName(cwd: String?, executable: String, listenerExecutable: String) -> String {
        if let cwd {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }

        if !listenerExecutable.isEmpty && listenerExecutable != "/" { return listenerExecutable }

        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if !executableName.isEmpty && executableName != "/" { return executableName }

        return listenerExecutable.emptyFallback("pid")
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
