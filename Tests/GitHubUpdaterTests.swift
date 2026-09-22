import XCTest
@testable import PortsKiller

final class GitHubUpdaterTests: XCTestCase {
    func testUpdatesOnlyReplaceInstalledProductionApp() {
        XCTAssertTrue(GitHubUpdater.isAvailable(bundleIdentifier: "com.md.PortsKiller", bundleURL: URL(fileURLWithPath: "/Applications/PortsKiller.app")))
        XCTAssertFalse(GitHubUpdater.isAvailable(bundleIdentifier: "com.md.PortsKiller", bundleURL: URL(fileURLWithPath: "/tmp/PortsKiller.app")))
        XCTAssertFalse(GitHubUpdater.isAvailable(bundleIdentifier: "com.example.preview", bundleURL: URL(fileURLWithPath: "/Applications/PortsKiller.app")))
    }

    func testReleaseRejectsUnrelatedDMG() throws {
        let json = #"{"tag_name":"v0.2.0","assets":[{"name":"Other.dmg","browser_download_url":"https://example.com/Other.dmg"}]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertNil(release.dmgAssetURL)
    }

    func testReleaseNotesSelectVersionAndLimitSummary() {
        let markdown = "# Changelog\n\n## 0.3.0\n- Future\n\n## 0.2.0\n- Native windows\n- **Updater** checks\n- Cards\n- Fourth\n"
        XCTAssertEqual(UpdateReleaseNotes.releaseNotes(from: markdown, version: "v0.2.0"), ["Native windows", "Updater checks", "Cards"])
        XCTAssertEqual(UpdateReleaseNotes.summaryLines(from: "No bullet notes"), [])
    }
}
