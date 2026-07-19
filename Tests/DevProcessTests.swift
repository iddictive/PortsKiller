import XCTest
@testable import PortsKiller

final class DevProcessTests: XCTestCase {
    func testRestartAvailabilityUsesScannedCommandWithoutReadingProjectFolder() {
        let process = DevProcess(
            name: "Example",
            pid: 42,
            parentPID: 1,
            port: 5173,
            host: "127.0.0.1",
            executable: "node",
            command: "node server.js",
            cwd: "/path/that/does/not/exist",
            framework: "Node",
            kind: .dev,
            resources: .empty,
            projectID: nil,
            inferredRestartCommand: "npm run dev"
        )

        XCTAssertTrue(process.canRestart)
        XCTAssertEqual(process.inferredRestartProject?.command, "npm run dev")
    }
}
