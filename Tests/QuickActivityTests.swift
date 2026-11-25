import Darwin
import Foundation
import XCTest
@testable import PortsKiller

final class QuickActivityTests: XCTestCase {
    func testQuietOwnedProcessIsSearchableAndStoppableInQuickActivity() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let pid = child.processIdentifier
        let full = ProcessScanner().scanActivity(includingIdle: true)
        let row = try XCTUnwrap(full.first { $0.primaryPID == pid })
        XCTAssertTrue(row.canStop)
        XCTAssertEqual(row.name, "sleep")
        XCTAssertFalse(full.contains { $0.primaryPID == getpid() })
        XCTAssertFalse(ProcessScanner.permitsActivityAction(pid: getpid()))
        XCTAssertFalse(ProcessScanner.permitsActivityAction(pid: 1))
        if let observation = ProcessScanner().scanActivity().first(where: { $0.primaryPID == pid }) {
            XCTAssertFalse(observation.canStop)
        }

        let identity = try XCTUnwrap(row.identity)
        let result = await ProcessController().interruptLocalCommand(
            rootPID: pid, expectedIdentity: identity, displayedPIDs: row.targetPIDs,
            permits: ProcessScanner.permitsActivityAction
        )
        XCTAssertEqual(result, .requested(running: [], unconfirmed: []))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }
}
