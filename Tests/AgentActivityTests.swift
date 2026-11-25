import XCTest
@testable import PortsKiller

final class AgentActivityTests: XCTestCase {
    func testGroupsCommandDescendantsUnderVerifiedHostButNotUnrelatedNodeOrTheObserver() {
        let samples = AgentActivityScanner.samples("""
             10 1 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
             11 10 /bin/zsh
             12 11 /usr/bin/clang
             13 10 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
             14 1 /usr/local/bin/node
             15 11 /Applications/PortsKiller.app/Contents/MacOS/PortsKiller
             16 15 /bin/ps
             17 1 /Applications/Other.app/Contents/Helpers/Codex (Aperitif Renderer)
             18 1 /tmp/codex
             19 18 /bin/sh
            """)
        let rows = AgentActivityScanner.activities(samples, observer: 15) { $0 == 12 ? "Demo" : nil }
        XCTAssertEqual(rows.map(\.kind), [.work, .service, .host])
        XCTAssertEqual(rows[0].pid, 11)
        XCTAssertEqual(rows[0].title, "clang")
        XCTAssertEqual(rows[0].detail, "Demo · 2 processes")
        XCTAssertEqual(rows[1].title, "Computer use")
    }

    func testOpenHostWithToolServicesDoesNotImplyActiveAgentTask() {
        let samples = AgentActivityScanner.samples("""
            123 1 /Applications/Codex.app/Contents/Resources/codex
            124 123 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
            125 123 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
            """)
        let rows = AgentActivityScanner.activities(samples, observer: 999) { _ in nil }
        XCTAssertEqual(rows.map(\.kind), [.service, .host])
        XCTAssertNil(rows[0].pid)
    }

    func testCommandTreeTracksUniqueFootprintAndAStableRootIdentity() throws {
        let samples = AgentActivityScanner.samples("""
            210 1 1.2 /Applications/Codex.app/Contents/Resources/codex
            211 210 0.4 /bin/zsh
            212 211 3.2 /usr/bin/python3
            213 212 0.1 /usr/bin/clang
            214 210 0.2 /usr/bin/python3
            215 210 0.3 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
            216 215 0.8 /usr/bin/python3
            217 210 0.4 /usr/bin/python3
            218 210 0.2 /usr/bin/python3
            """, withCPU: true)
        let rows = AgentActivityScanner.activities(samples, observer: 999, verify: true, observe: { sample in
            .init(identity: self.identity(for: sample.pid), memory: UInt64(sample.pid) * 1024, location: nil,
                  service: [217, 218].contains(sample.pid) ? "Safari bridge" : nil)
        }, describe: { sample, _ in
            guard sample.pid == 212 else { return nil }
            return .init(title: "index.py", context: "Python", rank: 3,
                         location: URL(fileURLWithPath: "/demo/Sample Project"))
        }, project: { _ in nil })

        XCTAssertEqual(rows.map(\.kind), [.work, .work, .service, .service, .host])
        let tree = try XCTUnwrap(rows.first { $0.pid == 211 })
        XCTAssertEqual(tree.title, "index.py")
        XCTAssertEqual(tree.rowSubtitle, "Sample Project · Python · 3 processes")
        XCTAssertEqual(tree.id, "local:211:211.500000")
        XCTAssertEqual(tree.startedAt, Date(timeIntervalSince1970: 211.5))
        XCTAssertEqual(tree.identity, identity(for: 211))
        XCTAssertEqual(tree.memoryBytes, (211 + 212 + 213) * 1024)
        XCTAssertEqual(tree.memberPIDs, [211, 212, 213])
        XCTAssertEqual(try XCTUnwrap(tree.cpuPercent), 3.7, accuracy: 0.00001)
        XCTAssertNil(rows.first { $0.kind == .host }?.identity)
        let bridge = try XCTUnwrap(rows.first { $0.kind == .service })
        XCTAssertEqual(bridge.groupedProcessCount, 2)
        XCTAssertEqual(bridge.memoryBytes, (215 + 216) * 1024)
        XCTAssertNil(bridge.identity)
        XCTAssertFalse(rows.contains { $0.pid == 216 })
        let safari = try XCTUnwrap(rows.first { $0.title == "Safari bridge" })
        XCTAssertEqual(safari.memberPIDs, [217, 218])
        XCTAssertEqual(safari.memoryBytes, (217 + 218) * 1024)
        XCTAssertNil(safari.identity)
    }

    func testStopIsUnavailableWithAProtectedChild() throws {
        let samples = AgentActivityScanner.samples("""
            310 1 /Applications/Codex.app/Contents/Resources/codex
            311 310 /bin/zsh
            312 311 /usr/bin/python3
            313 311 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
            """)
        let rows = AgentActivityScanner.activities(samples, observer: 999, verify: true, observe: { sample in
            .init(identity: self.identity(for: sample.pid), memory: sample.pid == 312 ? nil : 100, location: nil)
        }, project: { _ in nil })
        let tree = try XCTUnwrap(rows.first { $0.kind == .work })
        XCTAssertNil(tree.identity)
        XCTAssertNil(tree.memoryBytes, "Do not present partial footprint as the whole command")
        XCTAssertEqual(tree.pid, 311)
        XCTAssertEqual(tree.groupedProcessCount, 2)
    }

    func testScriptLabelRequiresAFileInsideTheCheckout() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PortsKiller-test-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("Project", isDirectory: true)
        let tools = repo.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("external.py")
        try Data().write(to: outside)
        try Data().write(to: tools.appendingPathComponent("index.py"))
        try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent("external.py"), withDestinationURL: outside)

        XCTAssertEqual(AgentActivityScanner.verifiedScript("index.py", extensions: ["py"], cwd: tools, location: repo)?.name, "index.py")
        XCTAssertNil(AgentActivityScanner.verifiedScript("external.py", extensions: ["py"], cwd: tools, location: repo))
        XCTAssertNil(AgentActivityScanner.verifiedScript("absent.py", extensions: ["py"], cwd: tools, location: repo))
        XCTAssertNil(AgentActivityScanner.verifiedScript(outside.path, extensions: ["py"], cwd: tools, location: repo))
    }

    private func identity(for pid: Int32) -> ProcessIdentity {
        ProcessIdentity(ownerUID: 501, startTimeSeconds: UInt64(pid), startTimeMicroseconds: 500_000)
    }
}
