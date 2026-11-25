import Darwin
import Foundation
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

    func testLocalInterruptDoesNotSignalWhenSnapshotFailsOrIncludesProtectedService() async {
        let root: Int32 = 1_000_001
        let child: Int32 = 1_000_002
        let identity = Self.identity(at: 10)
        let record = ProcessController.CommandProcess(identity: identity, parentPID: 42)
        let access = ProcessController.CommandAccess(parents: { nil }, read: { $0 == root ? record : nil },
                                                      isAbsent: { _ in false }, sendTerm: { _ in
            XCTFail("Missing snapshot must never send a signal")
            return false
        }, attempts: 0)
        let unavailable = await ProcessController().interruptLocalCommand(
            rootPID: root, expectedIdentity: identity, displayedPIDs: [root], permits: { _ in true }, access: access
        )
        XCTAssertEqual(unavailable, .snapshotUnavailable)

        let service = ProcessController.CommandProcess(identity: Self.identity(at: 11), parentPID: root)
        let protected = ProcessController.CommandAccess(parents: { [root: 42, child: root] },
                                                        read: { $0 == root ? record : service },
                                                        isAbsent: { _ in false }, sendTerm: { _ in
            XCTFail("Protected descendant must prevent signaling the whole tree")
            return false
        }, attempts: 0)
        let refused = await ProcessController().interruptLocalCommand(
            rootPID: root, expectedIdentity: identity, displayedPIDs: [root], permits: { $0 != child }, access: protected
        )
        XCTAssertEqual(refused, .unsafeGroup)
    }

    func testLocalInterruptReportsSurvivingChildAfterRootExits() async {
        let root: Int32 = 1_000_001
        let child: Int32 = 1_000_002
        let identity = Self.identity(at: 10)
        let state = SimulatedSignals(root: root, child: child, rootIdentity: identity, childIdentity: Self.identity(at: 11))
        let access = ProcessController.CommandAccess(parents: { [root: 42, child: root] },
                                                      read: state.read, isAbsent: { $0 == root && state.read($0) == nil },
                                                      sendTerm: state.sendTerm, attempts: 0)
        let outcome = await ProcessController().interruptLocalCommand(
            rootPID: root, expectedIdentity: identity, displayedPIDs: [root, child], permits: { _ in true }, access: access
        )
        XCTAssertEqual(outcome, .requested(running: [child], unconfirmed: []))
        XCTAssertEqual(state.sent, [child, root])
    }

    func testLocalInterruptReportsRejectedSignalInsteadOfSuccess() async {
        let pid: Int32 = 1_000_001
        let identity = Self.identity(at: 10)
        let record = ProcessController.CommandProcess(identity: identity, parentPID: 42)
        let access = ProcessController.CommandAccess(parents: { [pid: 42] }, read: { $0 == pid ? record : nil },
                                                      isAbsent: { _ in false }, sendTerm: { _ in false }, attempts: 0)
        let outcome = await ProcessController().interruptLocalCommand(
            rootPID: pid, expectedIdentity: identity, displayedPIDs: [pid], permits: { _ in true }, access: access
        )
        XCTAssertEqual(outcome, .noSignal)
    }

    private static func identity(at seconds: UInt64) -> ProcessIdentity {
        ProcessIdentity(ownerUID: getuid(), startTimeSeconds: seconds, startTimeMicroseconds: 0)
    }
}

private final class SimulatedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private let root: Int32
    private let child: Int32
    private let rootIdentity: ProcessIdentity
    private let childIdentity: ProcessIdentity
    private var signals = [Int32]()

    init(root: Int32, child: Int32, rootIdentity: ProcessIdentity, childIdentity: ProcessIdentity) {
        self.root = root
        self.child = child
        self.rootIdentity = rootIdentity
        self.childIdentity = childIdentity
    }

    var sent: [Int32] { lock.withLock { signals } }

    func read(_ pid: Int32) -> ProcessController.CommandProcess? {
        lock.withLock {
            let rootExited = signals.contains(root)
            switch pid {
            case root where !rootExited: return .init(identity: rootIdentity, parentPID: 42)
            case child: return .init(identity: childIdentity, parentPID: rootExited ? 1 : root)
            default: return nil
            }
        }
    }

    func sendTerm(_ pid: Int32) -> Bool {
        lock.withLock {
            signals.append(pid)
            return pid == root
        }
    }
}
