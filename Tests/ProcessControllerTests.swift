import Darwin
import XCTest
@testable import PortsKiller

final class ProcessControllerTests: XCTestCase {
    func testValidatedTerminationRejectsStaleProcessIdentity() throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let currentIdentity = try XCTUnwrap(ProcessIdentityReader.read(pid: pid))
        let staleIdentity = ProcessIdentity(
            ownerUID: currentIdentity.ownerUID,
            startTimeSeconds: currentIdentity.startTimeSeconds,
            startTimeMicroseconds: currentIdentity.startTimeMicroseconds + 1
        )

        XCTAssertFalse(
            ProcessController().terminateValidatedTree(
                rootPID: pid,
                expectedIdentity: staleIdentity
            )
        )
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
    }
}
