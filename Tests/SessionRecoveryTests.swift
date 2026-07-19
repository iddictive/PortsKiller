import Foundation
import XCTest
@testable import PortsKiller

final class SessionRecoveryTests: XCTestCase {
    func testClassifierAcceptsRecoverableTerminalErrors() {
        let cyber = SessionRecoveryClassifier.classify(code: "cyber_policy", message: "flagged")
        XCTAssertEqual(cyber?.0, .cyber)
        XCTAssertEqual(cyber?.1, "cyber_policy")

        let capacity = SessionRecoveryClassifier.classify(
            code: "server_overloaded",
            message: "Selected model is at capacity."
        )
        XCTAssertEqual(capacity?.0, .transient)

        let timeout = SessionRecoveryClassifier.classify(
            code: nil,
            message: "Gateway timed out with status 504"
        )
        XCTAssertEqual(timeout?.0, .transient)
    }

    func testClassifierRejectsPermanentAndOrdinaryErrors() {
        XCTAssertNil(SessionRecoveryClassifier.classify(code: "quota_exceeded", message: "Usage limit reached"))
        XCTAssertNil(SessionRecoveryClassifier.classify(code: "authentication_failed", message: "Invalid API token"))
        XCTAssertNil(SessionRecoveryClassifier.classify(code: "invalid_request", message: "Malformed input"))
    }

    func testOnlyExactRecoveryPromptsAreRecognizedAsWatchdogActivity() {
        XCTAssertTrue(SessionRecoveryClassifier.isRecoveryPrompt(SessionRecoveryClassifier.cyberPrompt + "\n"))
        XCTAssertTrue(SessionRecoveryClassifier.isRecoveryPrompt(SessionRecoveryClassifier.transientPrompt))
        XCTAssertFalse(SessionRecoveryClassifier.isRecoveryPrompt("Продолжай"))
    }

    @MainActor
    func testServiceBaselinesOldErrorsAndQueuesOnlyNewRecoverableError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortsKillerRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = "00000000-0000-4000-8000-000000000001"
        let file = sessions.appendingPathComponent("rollout-\(sessionID).jsonl")

        try writeLine([
            "timestamp": "2026-07-19T08:00:00.000Z",
            "type": "session_meta",
            "payload": ["cwd": root.path]
        ], to: file, append: false)
        try writeLine(taskError(code: "cyber_policy", message: "old"), to: file)

        let service = SessionRecoveryService(codexHome: root, stateDirectory: state)
        await service.start()
        XCTAssertEqual(service.snapshot.pendingCount, 0)

        try writeLine(taskError(code: "server_overloaded", message: "Selected model is at capacity."), to: file)
        await service.scanNow()
        XCTAssertEqual(service.snapshot.pendingCount, 1)

        try writeLine(taskError(code: "quota_exceeded", message: "Usage limit reached"), to: file)
        await service.scanNow()
        XCTAssertEqual(service.snapshot.pendingCount, 1)
        await service.stop()
    }

    @MainActor
    func testNoopScanDoesNotRewriteRecoveryState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortsKillerRecoveryNoopTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-00000000-0000-4000-8000-000000000001.jsonl")
        try writeLine([
            "timestamp": "2026-07-19T08:00:00.000Z",
            "type": "session_meta",
            "payload": ["cwd": root.path]
        ], to: file, append: false)

        let service = SessionRecoveryService(codexHome: root, stateDirectory: stateDirectory)
        await service.start()
        let stateURL = stateDirectory.appendingPathComponent("state.json")
        let before = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber

        await service.scanNow()

        let after = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(after, before)
        await service.stop()
    }

    private func taskError(code: String, message: String) -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": "event_msg",
            "payload": [
                "type": "task_complete",
                "turn_id": UUID().uuidString,
                "error": ["message": message, "codex_error_info": code]
            ]
        ]
    }

    private func writeLine(_ value: [String: Any], to file: URL, append: Bool = true) throws {
        let data = try JSONSerialization.data(withJSONObject: value) + Data([0x0A])
        if append, FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: file)
        }
    }
}
