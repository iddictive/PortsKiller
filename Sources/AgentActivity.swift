import Darwin
import Foundation

/// A local process observation, not a guessed Codex conversation or a remote job.
struct AgentActivity: Identifiable, Equatable, Sendable {
    enum Provider: String, Hashable, Sendable {
        case codex, claudeCode, claudeDesktop

        var title: String {
            switch self {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            }
        }

        var canOwnCommands: Bool { self != .claudeDesktop }
    }

    enum Kind: Int, Equatable, Sendable {
        case work, service, host, unavailable

        var title: String {
            switch self {
            case .work: "Local process"
            case .service: "Tool service"
            case .host: "Runtime"
            case .unavailable: "Unavailable"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let pid: Int32?
    let kind: Kind
    var project: String? = nil
    var groupedProcessCount: Int? = nil
    /// Sum of macOS physical footprints for the unique processes in this row.
    var memoryBytes: UInt64? = nil
    /// Sum of ps's per-process CPU estimates. 100% represents one full core.
    var cpuPercent: Double? = nil
    /// Only exposed for a validated local command root, never for a host/service.
    var identity: ProcessIdentity? = nil
    var startedAt: Date? = nil
    var toolContext: String? = nil
    var memberPIDs: [Int32] = []
    var provider: Provider? = nil
    var parentPID: Int32? = nil
    var parentName: String? = nil
    var projectFolder: String? = nil
    var rowSubtitle: String {
        guard kind == .work else { return detail }
        let count = groupedProcessCount.flatMap { $0 > 1 ? "\($0) processes" : nil }
        let fields = [project, toolContext, count].compactMap { $0 }
        return fields.isEmpty ? provider.map { "Under \($0.title)" } ?? "Local command" : fields.joined(separator: " · ")
    }
    var status: String { kind.title }
}

struct AgentActivityScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    struct Sample: Equatable {
        let pid: Int32
        let parent: Int32
        let executable: String
        let cpu: Double?

        var name: String { URL(fileURLWithPath: executable).lastPathComponent }
        var isCodex: Bool { runtimeProvider == .codex }
        var runtimeProvider: AgentActivity.Provider? { provider(under: AgentActivityScanner.home) }

        func provider(under home: String) -> AgentActivity.Provider? {
            let applicationPath = executable.hasPrefix(home + "/Applications/")
                ? String(executable.dropFirst(home.count)) : executable
            let managed = executable.hasPrefix("/opt/homebrew/") || executable.hasPrefix("/usr/local/")
            let parts = executable.split(separator: "/")
            if name == "codex" {
                if ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                    "/Applications/Codex.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/MacOS/codex",
                    "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].contains(applicationPath) { return .codex }
                if managed && executable.contains("/Caskroom/codex/") { return .codex }
                if let namespace = parts.lastIndex(of: "@openai"), namespace > 0, parts[namespace - 1] == "node_modules",
                   parts.indices.contains(namespace + 2),
                   ["codex", "codex-darwin-arm64", "codex-darwin-x64"].contains(parts[namespace + 1]),
                   parts[namespace + 2] == "vendor" { return .codex }
            }
            if applicationPath == "/Applications/Claude.app/Contents/MacOS/Claude" { return .claudeDesktop }
            if name == "claude" {
                let desktopPrefix = home + "/Library/Application Support/Claude/claude-code/"
                if executable.hasPrefix(desktopPrefix) {
                    let suffix = executable.dropFirst(desktopPrefix.count).split(separator: "/")
                    if suffix.count == 6, Self.isRelease(suffix[0]),
                       !suffix[1].isEmpty, suffix[1].allSatisfy(\.isHexDigit),
                       Array(suffix.dropFirst(2)) == ["claude.app", "Contents", "MacOS", "claude"] { return .claudeCode }
                }
                if managed && (executable.contains("/Caskroom/claude-code/")
                               || ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains(executable)) {
                    return .claudeCode
                }
            }
            let versions = home + "/.local/share/claude/versions/"
            if executable.hasPrefix(versions), Self.isRelease(executable.dropFirst(versions.count)) { return .claudeCode }
            return nil
        }

        private static func isRelease(_ value: Substring) -> Bool {
            let version = value.split(separator: ".", omittingEmptySubsequences: false)
            return version.count == 3 && version.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }

        var possiblyRuntime: Bool {
            runtimeProvider != nil || (!executable.contains("/") && ["codex", "claude", "claude-code"].contains(name.lowercased()))
        }

        func resolving(to path: String) -> Sample {
            Sample(pid: pid, parent: parent, executable: path, cpu: cpu)
        }

        var service: String? {
            if executable.hasPrefix("/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/")
                || (name == "SkyComputerUseService" && executable.hasSuffix("/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")) {
                return "Computer use"
            }
            if name == "codex-hooks-rs" && executable.hasSuffix("/.codex/bin/codex-hooks-rs") {
                return "Codex hooks"
            }
            if name == "node" && executable.contains("/Library/Application Support/Codex/artifact-sessions/runtime-generations/") {
                return "Codex artifact runtime"
            }
            if (executable.hasPrefix("/Applications/ChatGPT.app/Contents/") || executable.hasPrefix("/Applications/Codex.app/Contents/")) {
                return "Codex app helpers"
            }
            if executable == "/Applications/Claude.app/Contents/Helpers/disclaimer" {
                return "Claude Code launcher"
            }
            if executable.hasPrefix("/Applications/Claude.app/Contents/") {
                return "Claude app helpers"
            }
            return nil
        }

        var isInspector: Bool { name == "PortsKiller" }
    }

    struct Observation {
        let identity: ProcessIdentity
        let memory: UInt64?
        let location: URL?
        var cwd: URL? = nil
        var service: String? = nil
        var actualExecutable: String? = nil
        var provider: AgentActivity.Provider? = nil
    }

    struct Appearance: Equatable {
        let title: String
        let context: String
        let rank: Int
        var location: URL? = nil
    }

    func scan() -> [AgentActivity] {
        // The global snapshot contains only executable paths and process metadata.
        let startedBefore = Date()
        let result = Shell.run("/bin/ps", ["-U", String(getuid()), "-ww", "-o", "pid=,ppid=,%cpu=,comm="])
        let samples = Self.samples(result.output, withCPU: true)
        guard result.status == 0, !samples.isEmpty else {
            return [AgentActivity(id: "processes-unavailable", title: "Local processes unavailable",
                                  detail: "macOS did not return a process snapshot.", pid: nil, kind: .unavailable)]
        }
        return Self.activities(samples, observer: getpid(), verify: true, observe: { Self.observe($0, before: startedBefore) },
                               describe: Self.appearance, project: { _ in nil })
    }

    static func samples(_ output: String, withCPU: Bool = false) -> [Sample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let pathIndex = withCPU ? 3 : 2
            let fields = line.split(maxSplits: pathIndex, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == pathIndex + 1, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return Sample(pid: pid, parent: parent, executable: String(fields[pathIndex]), cpu: withCPU ? Double(fields[2]) : nil)
        }
    }

    static func activities(_ samples: [Sample], observer: Int32, verify: Bool = false,
                           observe: (Sample) -> Observation? = { _ in nil },
                           describe: (Sample, Observation) -> Appearance? = { _, _ in nil },
                           project: (Int32) -> String?) -> [AgentActivity] {
        let byParent = Dictionary(grouping: samples, by: \.parent)
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = [AgentActivity]()
        struct ServiceKey: Hashable {
            let title: String
            let provider: AgentActivity.Provider
        }
        var services = [ServiceKey: [Sample]]()
        var visited = Set<Int32>([observer])
        var read = [Int32: Observation]()
        var unreadable = Set<Int32>()
        func metadata(_ sample: Sample) -> Observation? {
            if let cached = read[sample.pid] { return cached }
            guard !unreadable.contains(sample.pid), let data = observe(sample) else {
                unreadable.insert(sample.pid)
                return nil
            }
            read[sample.pid] = data
            return data
        }
        let runtimes = samples.filter(\.possiblyRuntime).reduce(into: [Int32: AgentActivity.Provider]()) { result, sample in
            let observed = metadata(sample)
            guard !verify || observed != nil else { return }
            result[sample.pid] = observed?.provider ?? sample.runtimeProvider
        }
        func resolved(_ sample: Sample) -> Sample {
            guard let path = metadata(sample)?.actualExecutable else { return sample }
            return sample.resolving(to: path)
        }
        func parentName(_ pid: Int32) -> String? {
            if let runtime = runtimes[pid] { return runtime.title }
            guard let parent = byPID[pid], pid > 1, safeLabel(parent.name) else { return nil }
            return parent.name
        }
        func totals(_ nodes: [Sample]) -> (memory: UInt64?, cpu: Double?) {
            let footprints = nodes.compactMap { metadata($0)?.memory }
            let cpu = nodes.compactMap(\.cpu).filter { $0.isFinite && $0 >= 0 }
            let sum = footprints.reduce(UInt64(0)) { partial, next in
                let (total, overflow) = partial.addingReportingOverflow(next)
                return overflow ? .max : total
            }
            return (footprints.count == nodes.count ? sum : nil, cpu.count == nodes.count ? cpu.reduce(0, +) : nil)
        }
        func consume(_ node: Sample, provider: AgentActivity.Provider, serviceParent: String? = nil) {
            guard node.pid != observer, runtimes[node.pid] == nil, !node.isInspector,
                  visited.insert(node.pid).inserted else { return }
            let root = metadata(node)
            // The snapshot may already be stale. Do not attribute a recycled PID.
            guard !verify || root != nil else { return }
            if let service = node.service ?? root?.service ?? serviceParent {
                services[ServiceKey(title: service, provider: provider), default: []].append(node)
                for child in byParent[node.pid] ?? [] { consume(child, provider: provider, serviceParent: service) }
                return
            }
            guard provider.canOwnCommands else { return }

            var subtree = [node]
            var index = 0
            var canStop = root != nil
            while index < subtree.count {
                for child in byParent[subtree[index].pid] ?? [] {
                    guard runtimes[child.pid] == nil, !child.isInspector, child.pid != observer, metadata(child) != nil || !verify else {
                        canStop = false
                        continue
                    }
                    if child.service != nil || metadata(child)?.service != nil {
                        canStop = false
                        consume(child, provider: provider)
                        continue
                    }
                    if visited.insert(child.pid).inserted { subtree.append(child) }
                }
                index += 1
            }
            let shells = ["sh", "bash", "zsh", "fish", "env", "sandbox-exec"]
            let foreground = subtree.map(resolved).filter { !shells.contains($0.name) }
            var representative = foreground.first ?? node
            var appearance: Appearance?
            for candidate in foreground.prefix(12) {
                guard let data = metadata(candidate), let value = describe(candidate, data),
                      value.rank > (appearance?.rank ?? 0) else { continue }
                representative = candidate
                appearance = value
                if value.rank >= 3 { break }
            }
            let folder = appearance?.location ?? metadata(representative)?.location ?? root?.location
            let cwd = folder?.lastPathComponent
                ?? project(representative.pid) ?? (representative.pid == node.pid ? nil : project(node.pid))
            let group = subtree.count > 1 ? "\(subtree.count) processes" : nil
            let detail = [cwd, group].compactMap { $0 }.joined(separator: " · ")
            let resources = totals(subtree)
            let start = root.map { Date(timeIntervalSince1970: Double($0.identity.startTimeSeconds) + Double($0.identity.startTimeMicroseconds) / 1_000_000) }
            let stamp = root.map { "\($0.identity.startTimeSeconds).\($0.identity.startTimeMicroseconds)" } ?? node.name
            let fallback = safeLabel(representative.name) ? representative.name : "Local command"
            rows.append(AgentActivity(id: "local:\(node.pid):\(stamp)", title: appearance?.title ?? fallback,
                                      detail: detail.isEmpty ? "Under \(provider.title)" : detail, pid: node.pid,
                                      kind: .work, project: cwd, groupedProcessCount: subtree.count,
                                      memoryBytes: resources.memory, cpuPercent: resources.cpu, identity: canStop ? root?.identity : nil,
                                      startedAt: start, toolContext: appearance?.context, memberPIDs: subtree.map(\.pid).sorted(),
                                      provider: provider, parentPID: node.parent, parentName: parentName(node.parent),
                                      projectFolder: folder?.path))
        }
        for sample in samples {
            guard let provider = runtimes[sample.pid] else { continue }
            for child in byParent[sample.pid] ?? [] where provider.canOwnCommands || child.service == "Claude Code launcher" {
                consume(child, provider: provider)
            }
        }
        // Well-known detached helpers are not work and cannot be interrupted here.
        let detachedServices = ["Computer use", "Codex hooks", "Codex artifact runtime"]
        for sample in samples where sample.service.map(detachedServices.contains) == true {
            consume(sample, provider: .codex)
        }
        for (key, nodes) in services {
            let n = nodes.count
            let resources = totals(nodes)
            let parents = Set(nodes.map(\.parent))
            let parent = parents.count == 1 ? parents.first : nil
            rows.append(AgentActivity(id: "service:\(key.provider.rawValue):\(key.title)", title: key.title, detail: "\(n) helper process\(n == 1 ? "" : "es")",
                                      pid: n == 1 ? nodes.first?.pid : nil, kind: .service, groupedProcessCount: n,
                                      memoryBytes: resources.memory, cpuPercent: resources.cpu, memberPIDs: nodes.map(\.pid).sorted(),
                                      provider: key.provider, parentPID: parent, parentName: parent.flatMap(parentName)))
        }
        var runtimeGroups = [AgentActivity.Provider: [Sample]]()
        for sample in samples {
            if let provider = runtimes[sample.pid] { runtimeGroups[provider, default: []].append(sample) }
        }
        for (provider, nodes) in runtimeGroups {
            let n = nodes.count
            let resources = totals(nodes)
            let only = n == 1 ? nodes.first : nil
            let roots = Set(nodes.map { metadata($0)?.location })
            let folder = roots.count == 1 ? roots.first ?? nil : nil
            let parent = only?.parent
            rows.append(AgentActivity(id: provider == .codex ? "codex-runtime" : "\(provider.rawValue)-runtime",
                                      title: provider.title,
                                      detail: provider.canOwnCommands ? "\(n) local runtime\(n == 1 ? "" : "s")" : "Desktop application",
                                      pid: only?.pid, kind: .host, project: folder?.lastPathComponent, groupedProcessCount: n,
                                      memoryBytes: resources.memory, cpuPercent: resources.cpu, memberPIDs: nodes.map(\.pid).sorted(),
                                      provider: provider, parentPID: parent, parentName: parent.flatMap(parentName),
                                      projectFolder: folder?.path))
        }
        return rows.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if let left = $0.startedAt, let right = $1.startedAt, left != right { return left > right }
            return $0.id < $1.id
        }
    }

    /// Re-check the current process and its chain, not just the previous row's PID.
    static func canInterrupt(pid: Int32) -> Bool {
        var cursor = pid
        var seen = Set<Int32>()
        var child: ProcessIdentity?
        for depth in 0..<32 {
            guard cursor > 1, cursor != getpid(), seen.insert(cursor).inserted, let record = processRecord(cursor),
                  record.identity.ownerUID == getuid(), let executable = processPath(cursor),
                  processRecord(cursor)?.identity == record.identity else { return false }
            if let child,
               (record.identity.startTimeSeconds, record.identity.startTimeMicroseconds) >
                   (child.startTimeSeconds, child.startTimeMicroseconds) { return false }
            let sample = Sample(pid: cursor, parent: record.parent, executable: executable, cpu: nil)
            if let provider = sample.runtimeProvider { return depth > 0 && provider.canOwnCommands }
            guard sample.service == nil, !sample.isInspector, record.parent != cursor,
                  interpretedService(sample) == nil, processRecord(cursor)?.identity == record.identity else { return false }
            child = record.identity
            cursor = record.parent
        }
        return false
    }

    private static func processRecord(_ pid: Int32) -> (identity: ProcessIdentity, parent: Int32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(exactly: pid), info.pbi_start_tvsec > 0,
              let parent = Int32(exactly: info.pbi_ppid) else { return nil }
        return (ProcessIdentity(ownerUID: info.pbi_uid, startTimeSeconds: UInt64(info.pbi_start_tvsec),
                                startTimeMicroseconds: UInt64(info.pbi_start_tvusec)), parent)
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let size = UInt32(buffer.count)
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, size) }
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func matchesExecutable(reported: Sample, canonical path: String) -> Bool {
        if reported.executable == path { return true }
        guard !reported.executable.contains("/") else { return false }
        let actual = reported.resolving(to: path)
        return reported.name == actual.name || (reported.possiblyRuntime && actual.runtimeProvider != nil)
    }

    private static func observe(_ reported: Sample, before snapshotStart: Date) -> Observation? {
        guard let record = processRecord(reported.pid), record.identity.ownerUID == getuid(),
              record.parent == reported.parent, let path = processPath(reported.pid),
              matchesExecutable(reported: reported, canonical: path) else { return nil }
        let started = Double(record.identity.startTimeSeconds) + Double(record.identity.startTimeMicroseconds) / 1_000_000
        guard started <= snapshotStart.timeIntervalSince1970 else { return nil }
        let sample = reported.resolving(to: path)
        let provider = sample.runtimeProvider
        var usage = rusage_info_v2()
        let usageStatus = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(sample.pid, RUSAGE_INFO_V2, $0) }
        }
        let service = provider == nil ? sample.service ?? interpretedService(sample) : nil
        let cwd = provider != .claudeDesktop && service == nil ? workingDirectory(sample.pid) : nil
        guard let latest = processRecord(sample.pid), latest.identity == record.identity, latest.parent == record.parent,
              processPath(sample.pid) == path else { return nil }
        return Observation(identity: record.identity, memory: usageStatus == 0 ? usage.ri_phys_footprint : nil,
                           location: cwd.flatMap(projectRoot), cwd: cwd, service: service,
                           actualExecutable: path, provider: provider)
    }

    private static func workingDirectory(_ pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let cwd = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard cwd.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    private static func projectRoot(_ cwd: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard cwd.path.hasPrefix(home + "/") else { return nil }
        let parts = cwd.path.dropFirst(home.count + 1).split(separator: "/")
        // Reading standard protected folders can prompt for unrelated access.
        guard !parts.contains(where: { $0.hasPrefix(".") }),
              !["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].contains(String(parts.first ?? "")) else { return nil }
        var directory = cwd
        for _ in 0..<12 where directory.path.hasPrefix(home + "/") {
            if safeLabel(directory.lastPathComponent),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private enum Tool {
        case python, swift, node, git

        init?(_ sample: Sample) {
            let name = sample.name.lowercased()
            let path = sample.executable
            let appleTool = path.hasPrefix("/usr/bin/") || path.hasPrefix("/Library/Developer/CommandLineTools/")
                || path.hasPrefix("/Applications/Xcode.app/Contents/Developer/")
            let installedTool = path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
                || path.hasPrefix(AgentActivityScanner.home + "/.nvm/versions/node/")
            guard appleTool || installedTool else { return nil }
            if name == "python" || name == "python3" || (name.hasPrefix("python3.") && name.dropFirst(8).allSatisfy(\.isNumber)) {
                self = .python
            } else if ["swift", "swift-driver", "swift-build", "swift-run", "swift-test", "swift-package", "swift-frontend"].contains(name) {
                self = .swift
            } else if name == "node" {
                self = .node
            } else if name == "git" {
                self = .git
            } else {
                return nil
            }
        }

        var label: String {
            switch self {
            case .python: "Python"
            case .swift: "Swift"
            case .node: "Node.js"
            case .git: "Git"
            }
        }

        var scriptExtensions: Set<String> {
            switch self {
            case .python: ["py"]
            case .swift: ["swift"]
            case .node: ["js", "mjs", "cjs", "ts", "mts", "cts"]
            case .git: []
            }
        }
    }

    /// The installed Safari bridge is itself a Python script, not an independent
    /// user command. An arbitrary script in .codex/bin is deliberately not a match.
    /// Shared guard for both the Agents tree and direct process actions.
    static func isProtectedRuntime(_ sample: Sample) -> Bool {
        sample.runtimeProvider != nil || sample.isInspector || sample.service != nil
            || interpretedService(sample) != nil
    }

    private static func interpretedService(_ sample: Sample) -> String? {
        guard let tool = Tool(sample), tool == .python || tool == .node else { return nil }
        if tool == .node {
            return withArgv(sample) { arguments in
                var args = arguments
                guard let operand = args.next(), let script = operand.projectPathCandidate(),
                      verifiedMCPEntry(script) else { return nil }
                return "MCP bridge"
            }
        }
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/bin/codex-safari-native").path
        return withArgv(sample) { arguments in
            var args = arguments
            guard args.remaining == 1, let operand = args.next(), operand.matches(any: [script]),
                  let value = try? FileManager.default.attributesOfItem(atPath: script)[.type] as? FileAttributeType,
                  value == .typeRegular else { return nil }
            return "Safari bridge"
        }
    }

    static func verifiedMCPEntry(_ script: String) -> Bool {
        let supportRoots = [home + "/.codex/mcp/", home + "/.claude/mcp/"]
        guard let root = supportRoots.first(where: { script.hasPrefix($0) }) else { return false }
        let candidate = URL(fileURLWithPath: script)
        let resolved = candidate.resolvingSymlinksInPath()
        guard ["js", "cjs", "mjs"].contains(candidate.pathExtension.lowercased()),
              resolved.path.hasPrefix(root),
              let type = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    private static func appearance(_ sample: Sample, _ data: Observation) -> Appearance? {
        if ["xcodebuild", "clang", "clang++", "swiftc", "swift-frontend", "make", "cmake", "ninja", "cargo", "rustc"].contains(sample.name) {
            return Appearance(title: sample.name, context: "Build tool", rank: 2)
        }
        guard let tool = Tool(sample), processRecord(sample.pid)?.identity == data.identity else { return nil }
        let fallback = Appearance(title: tool.label, context: sample.name == tool.label ? "Interpreter" : sample.name, rank: 1)
        if tool == .swift, ["swift-build", "swift-run", "swift-test", "swift-package"].contains(sample.name) {
            return Appearance(title: sample.name.replacingOccurrences(of: "-", with: " "), context: tool.label, rank: 2)
        }
        let projected = withArgv(sample) { arguments -> Appearance? in
            var args = arguments
            guard var operand = args.next() else { return nil }
            switch tool {
            case .python:
                for _ in 0..<5 where operand.matches(any: ["-u", "-B", "-I", "-S", "-E", "-O", "-OO", "-s", "-q"]) {
                    guard let following = args.next() else { return nil }
                    operand = following
                }
                if operand.matches(any: ["-c"]) { return Appearance(title: "Inline Python", context: tool.label, rank: 2) }
                if operand.matches(any: ["-m"]) {
                    guard let module = args.next(), let name = module.allowed(in: ["pytest", "unittest", "http.server", "venv", "pip", "uvicorn"]) else { return nil }
                    return Appearance(title: name, context: tool.label, rank: 2)
                }
            case .swift:
                if let command = operand.allowed(in: ["build", "test", "run", "package", "repl", "format"]) {
                    return Appearance(title: "swift " + command, context: tool.label, rank: 2)
                }
            case .node:
                if operand.matches(any: ["-e", "--eval", "-p", "--print"]) {
                    return Appearance(title: "Inline Node.js", context: tool.label, rank: 2)
                }
            case .git:
                if let command = operand.allowed(in: ["status", "fetch", "push", "pull", "clone", "log", "diff", "merge", "rebase", "commit", "worktree"]) {
                    return Appearance(title: "git " + command, context: tool.label, rank: 2)
                }
                return nil
            }
            guard let path = operand.projectPathCandidate(),
                  let script = verifiedScript(path, extensions: tool.scriptExtensions, cwd: data.cwd, location: data.location) else { return nil }
            return Appearance(title: script.name, context: tool.label, rank: 3, location: script.location)
        }
        // Do not associate the projected label with a reused PID.
        guard processRecord(sample.pid)?.identity == data.identity, processPath(sample.pid) == sample.executable else { return nil }
        return projected ?? fallback
    }

    private static func safeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80
            && !value.hasPrefix(".")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.isBidiControl }
    }

    static func verifiedScript(_ path: String, extensions: Set<String>, cwd: URL?, location: URL?) -> (name: String, location: URL)? {
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            guard let cwd else { return nil }
            candidate = cwd.appendingPathComponent(path).standardizedFileURL
        }
        guard extensions.contains(candidate.pathExtension.lowercased()), safeLabel(candidate.lastPathComponent) else { return nil }
        let parent = candidate.deletingLastPathComponent()
        guard let root = location.flatMap({ candidate.path.hasPrefix($0.path + "/") ? $0 : nil }) ?? projectRoot(parent),
              candidate.path.hasPrefix(root.path + "/"),
              !candidate.path.dropFirst(root.path.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"), resolved.lastPathComponent == candidate.lastPathComponent,
              !resolved.path.dropFirst(root.path.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let type = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType,
              type == .typeRegular else { return nil }
        return (candidate.lastPathComponent, root)
    }

    // KERN_PROCARGS2 returns argc, executable path, argv, then environment. Only
    // the few leading argv operands are accessed; never read/copy the env tail,
    // inline code, prompts, or arbitrary flags. Nothing raw escapes this scope.
    private static func withArgv<Value>(_ sample: Sample, project: (Arguments) -> Value?) -> Value? {
        let capacity = sysconf(_SC_ARG_MAX)
        guard capacity > 0, capacity <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: capacity)
        return bytes.withUnsafeMutableBytes { buffer in
            defer { if let base = buffer.baseAddress { _ = memset_s(base, buffer.count, 0, buffer.count) } }
            var mib = [CTL_KERN, KERN_PROCARGS2, sample.pid]
            var length = capacity
            guard sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0) == 0,
                  length > MemoryLayout<Int32>.size else { return nil }
            let raw = UnsafeRawBufferPointer(rebasing: buffer.prefix(length))
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            guard argc >= 2, argc <= 16_384 else { return nil }
            var index = MemoryLayout<Int32>.size
            while index < raw.count, raw[index] != 0 { index += 1 } // kernel executable path
            while index < raw.count, raw[index] == 0 { index += 1 } // padding
            var args = Arguments(bytes: raw, index: index, remaining: argc)
            guard let program = args.next(), program.matchesProgram(sample.name) else { return nil }
            return project(args)
        }
    }

    private struct Arguments {
        let bytes: UnsafeRawBufferPointer
        var index: Int
        var remaining: Int

        mutating func next() -> Argument? {
            guard remaining > 0, index < bytes.count else { return nil }
            let begin = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
                if index - begin > 512 { return nil }
            }
            guard index < bytes.count else { return nil }
            let token = UnsafeRawBufferPointer(rebasing: bytes[begin..<index])
            index += 1
            remaining -= 1
            return Argument(bytes: token)
        }
    }

    private struct Argument {
        let bytes: UnsafeRawBufferPointer

        func allowed(in choices: [String]) -> String? {
            choices.first { bytes.elementsEqual($0.utf8) }
        }

        func matches(any choices: [String]) -> Bool { allowed(in: choices) != nil }

        func matchesProgram(_ executableName: String) -> Bool {
            guard !bytes.contains(61) else { return false } // never interpret an environment token
            let basename = bytes.suffix(from: bytes.lastIndex(of: 47).map { $0 + 1 } ?? bytes.startIndex)
            if basename.elementsEqual(executableName.utf8) { return true }
            let names = executableName.lowercased().hasPrefix("python") ? ["python", "python3"] :
                executableName.hasPrefix("swift") ? ["swift", "swiftc"] : []
            return names.contains { basename.elementsEqual($0.utf8) }
        }

        func projectPathCandidate() -> String? {
            guard let first = bytes.first, first != 45, bytes.contains(46),
                  bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
