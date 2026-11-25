import Darwin
import Foundation

/// A local process observation, not a guessed Codex conversation or a remote job.
struct AgentActivity: Identifiable, Equatable, Sendable {
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
    var status: String { kind.title }
}

struct AgentActivityScanner {
    struct Sample: Equatable {
        let pid: Int32
        let parent: Int32
        let executable: String

        var name: String { URL(fileURLWithPath: executable).lastPathComponent }
        var isCodex: Bool {
            guard name == "codex" else { return false }
            return executable.contains("/CodexCLI.app/Contents/MacOS/")
                || executable.hasSuffix("/Codex.app/Contents/Resources/codex")
                || executable.contains("/@openai/codex")
                || executable.contains("/Caskroom/codex/")
                || ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].contains(executable)
        }
        var service: String? {
            if executable.contains("/ChatGPT.app/Contents/Resources/cua_node/bin/") {
                return "Computer use"
            }
            if name == "codex-hooks-rs" && executable.contains("/.codex/bin/") {
                return "Codex hooks"
            }
            return nil
        }
    }

    func scan() -> [AgentActivity] {
        // comm is the executable, not the command line. Prompts, tokens and
        // environments must never enter this observer, even transiently.
        let result = Shell.run("/bin/ps", ["-U", String(getuid()), "-ww", "-o", "pid=,ppid=,comm="])
        let samples = Self.samples(result.output)
        guard result.status == 0, !samples.isEmpty else {
            return [AgentActivity(id: "processes-unavailable", title: "Local processes unavailable",
                                  detail: "macOS did not return a process snapshot.", pid: nil, kind: .unavailable)]
        }
        return Self.activities(samples, observer: getpid(), project: Self.projectName)
    }

    static func samples(_ output: String) -> [Sample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return Sample(pid: pid, parent: parent, executable: String(fields[2]))
        }
    }

    static func activities(_ samples: [Sample], observer: Int32, project: (Int32) -> String?) -> [AgentActivity] {
        let byParent = Dictionary(grouping: samples, by: \.parent)
        let runtimes = samples.filter(\.isCodex)
        var rows = [AgentActivity]()
        var services = [String: [Int32]]()
        var visited = Set<Int32>([observer])
        func consume(_ node: Sample) {
            // Do not count the inspector as agent work when opened from Codex.
            guard node.pid != observer, !node.isCodex, node.name != "PortsKiller",
                  visited.insert(node.pid).inserted else { return }
            if let service = node.service {
                services[service, default: []].append(node.pid)
                for child in byParent[node.pid] ?? [] { consume(child) }
                return
            }

            // A shell and all the processes it launches describe one local command.
            // Group them without reading args or guessing the user's task title.
            var subtree = [node]
            var index = 0
            while index < subtree.count {
                for child in byParent[subtree[index].pid] ?? [] {
                    guard !child.isCodex, child.name != "PortsKiller", child.pid != observer else { continue }
                    if child.service != nil { consume(child); continue }
                    if visited.insert(child.pid).inserted { subtree.append(child) }
                }
                index += 1
            }
            let shells = ["sh", "bash", "zsh", "fish", "env", "sandbox-exec"]
            let representative = subtree.first { !shells.contains($0.name) } ?? node
            let cwd = project(representative.pid) ?? (representative.pid == node.pid ? nil : project(node.pid))
            let group = subtree.count > 1 ? "\(subtree.count) processes" : nil
            let detail = [cwd, group].compactMap { $0 }.joined(separator: " · ")
            rows.append(AgentActivity(id: "local:\(node.pid):\(node.name)", title: representative.name,
                                      detail: detail.isEmpty ? "Started under Codex" : detail, pid: node.pid, kind: .work))
        }
        for runtime in runtimes {
            for child in byParent[runtime.pid] ?? [] { consume(child) }
        }
        // Detached, known helper services have stable installation identities.
        // An unrelated node/python, or an Electron renderer, is never an agent.
        for sample in samples where sample.service == "Codex hooks" { consume(sample) }
        for (title, pids) in services {
            let n = pids.count
            rows.append(AgentActivity(id: "service:\(title)", title: title, detail: "\(n) helper process\(n == 1 ? "" : "es")",
                                      pid: n == 1 ? pids.first : nil, kind: .service))
        }
        if !runtimes.isEmpty {
            let n = runtimes.count
            rows.append(AgentActivity(id: "codex-runtime", title: "Codex", detail: "\(n) local runtime\(n == 1 ? "" : "s")",
                                      pid: n == 1 ? runtimes.first?.pid : nil, kind: .host))
        }
        return rows.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func projectName(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let cwd = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard cwd.hasPrefix(home + "/") else { return nil }
        let parts = cwd.dropFirst(home.count + 1).split(separator: "/")
        // Reading standard protected folders can prompt for unrelated access.
        guard !parts.contains(where: { $0.hasPrefix(".") }),
              !["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].contains(String(parts.first ?? "")) else { return nil }
        var directory = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<12 where directory.path.hasPrefix(home + "/") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.lastPathComponent
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
