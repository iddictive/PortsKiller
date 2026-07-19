import Foundation

struct DevProcess: Identifiable, Hashable, Sendable {
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
    let inferredRestartCommand: String?

    var urlString: String {
        "http://localhost:\(port)"
    }

    var canRestart: Bool {
        projectID != nil || inferredRestartCommand != nil
    }

    var canStop: Bool {
        kind != .system
    }

    var inferredRestartProject: ManualProject? {
        guard projectID == nil, let cwd, let command = inferredRestartCommand else { return nil }
        return ManualProject(name: name, cwd: cwd, command: command, port: port)
    }
}

enum ProcessViewMode: String, CaseIterable, Identifiable, Sendable {
    case dev
    case all
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dev: return "Dev"
        case .all: return "Ports"
        case .activity: return "Activity"
        }
    }
}

struct ActivityProcess: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let command: String
    let kind: ActivityProcessKind
    let resources: ResourceUsage
    let processCount: Int
    let targetPIDs: [Int32]
    let identity: ProcessIdentity?
    let canStop: Bool

    var primaryPID: Int32? {
        targetPIDs.first
    }
}

enum ActivityProcessKind: String, Hashable, Sendable {
    case simulator
    case application
    case developerTool
    case system
    case other

    var title: String {
        switch self {
        case .simulator: return "Simulator"
        case .application: return "App"
        case .developerTool: return "Dev Tool"
        case .system: return "System"
        case .other: return "Process"
        }
    }
}

enum ProcessKind: String, Hashable, Sendable {
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

struct ResourceUsage: Hashable, Sendable {
    let cpuPercent: Double
    let memoryBytes: UInt64
    let uptime: String

    static let empty = ResourceUsage(cpuPercent: 0, memoryBytes: 0, uptime: "-")

    var memoryMegabytes: Double {
        Double(memoryBytes) / 1_048_576
    }
}

struct SystemResourceUsage: Hashable, Sendable {
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let swap: SwapUsage?

    static let unavailable = SystemResourceUsage(
        cpuPercent: nil,
        memoryUsedBytes: 0,
        memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
        swap: nil
    )

    var memoryPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100, 100)
    }
}

struct SwapUsage: Hashable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var isActive: Bool {
        usedBytes > 0
    }
}

struct ManualProject: Identifiable, Codable, Hashable, Sendable {
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

struct ProcessSnapshot {
    let pid: Int32
    let parentPID: Int32
    let ownerUID: UInt32
    let executable: String
    let command: String
    let resources: ResourceUsage
}

struct ListeningPort {
    let pid: Int32
    let executable: String
    let port: Int
    let host: String
}
