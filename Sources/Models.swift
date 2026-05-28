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
    let resources: ResourceUsage
    let projectID: UUID?

    var urlString: String {
        "http://localhost:\(port)"
    }

    var canRestart: Bool {
        projectID != nil
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
