import Foundation

struct DevProcess: Identifiable, Hashable {
    var id: String { "\(pid):\(port)" }

    let name: String
    let pid: Int32
    let parentPID: Int32
    let port: Int
    let host: String
    let executable: String
    let command: String
    let cwd: String?
    let framework: String
    let kind: ProcessKind
    let resources: ResourceUsage
    let projectID: UUID?

    var urlString: String {
        "http://localhost:\(port)"
    }

    var canRestart: Bool {
        projectID != nil || inferredRestartProject != nil
    }

    var canStop: Bool {
        kind != .system
    }

    var inferredRestartProject: ManualProject? {
        guard projectID == nil, kind == .dev, let cwd else { return nil }
        guard let command = PackageScriptInspector().restartCommand(cwd: cwd, port: port) else { return nil }
        return ManualProject(name: name, cwd: cwd, command: command, port: port)
    }
}

enum ProcessViewMode: String, CaseIterable, Identifiable {
    case dev
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dev: return "Dev"
        case .all: return "All"
        }
    }
}

enum ProcessKind: String, Hashable {
    case dev
    case jsTool
    case localService
    case desktopApp
    case system
    case unknown

    var title: String {
        switch self {
        case .dev: return "Dev"
        case .jsTool: return "JS Tool"
        case .localService: return "Service"
        case .desktopApp: return "App"
        case .system: return "System"
        case .unknown: return "Unknown"
        }
    }

    var sortPriority: Int {
        switch self {
        case .unknown: return 0
        case .dev: return 1
        case .jsTool: return 2
        case .localService: return 3
        case .desktopApp: return 4
        case .system: return 5
        }
    }
}

struct ResourceUsage: Hashable {
    let cpuPercent: Double
    let memoryBytes: UInt64
    let uptime: String

    static let empty = ResourceUsage(cpuPercent: 0, memoryBytes: 0, uptime: "-")

    var memoryMegabytes: Double {
        Double(memoryBytes) / 1_048_576
    }
}

struct ManualProject: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var cwd: String
    var command: String
    var port: Int

    init(id: UUID = UUID(), name: String, cwd: String, command: String, port: Int) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.port = port
    }
}

struct ProcessInfoSnapshot {
    let pid: Int32
    let parentPID: Int32
    let executable: String
    let command: String
}

struct ProcessResourceSnapshot {
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let residentBytes: UInt64
    let elapsedTime: String
}

struct ListeningPort {
    let pid: Int32
    let executable: String
    let port: Int
    let host: String
}
