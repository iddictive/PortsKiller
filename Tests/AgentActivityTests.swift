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
}
