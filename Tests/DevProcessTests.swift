import Darwin
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
        XCTAssertFalse(process.canStop, "A launch command must not authorize stopping an unverified listener")
        XCTAssertEqual(process.inferredRestartProject?.command, "npm run dev")
    }

    func testStopRequiresSameUserAndNeverAllowsSystemOrInspector() {
        let currentOwner = getuid()
        let otherOwner = currentOwner ^ 1
        XCTAssertTrue(listener(owner: currentOwner).canStop)
        XCTAssertFalse(listener(owner: otherOwner).canStop)
        XCTAssertFalse(listener(owner: currentOwner, kind: .system).canStop)
        XCTAssertFalse(listener(owner: currentOwner, pid: getpid()).canStop)
    }

    private func listener(owner: UInt32, kind: ProcessKind = .dev, pid: Int32 = Int32.max) -> DevProcess {
        DevProcess(name: "Example", pid: pid, parentPID: 1, port: 5173, host: "127.0.0.1",
                   executable: "node", command: "node server.js", cwd: nil, framework: "Node",
                   kind: kind, resources: .empty, projectID: nil, inferredRestartCommand: nil,
                   identity: ProcessIdentity(ownerUID: owner, startTimeSeconds: 1, startTimeMicroseconds: 0))
    }
}
