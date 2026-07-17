import Foundation
import XCTest
@testable import PortsKiller

final class MenuBarMetricPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarMetricPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultAndLegacyBothSelectionResolveToCPU() {
        let preferences = MenuBarMetricPreferences(defaults: defaults)

        XCTAssertEqual(preferences.load(), .cpu)

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "MenuBar.showsCPU")
        defaults.set(true, forKey: "MenuBar.showsRAM")
        XCTAssertEqual(preferences.load(), .cpu)
    }

    func testLegacySingleAndEmptySelectionsMigrate() {
        let preferences = MenuBarMetricPreferences(defaults: defaults)

        defaults.set(false, forKey: "MenuBar.showsCPU")
        defaults.set(true, forKey: "MenuBar.showsRAM")
        XCTAssertEqual(preferences.load(), .ram)

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "MenuBar.showsCPU")
        defaults.set(false, forKey: "MenuBar.showsRAM")
        XCTAssertEqual(preferences.load(), .iconOnly)
    }

    func testSelectedMetricPersists() {
        let preferences = MenuBarMetricPreferences(defaults: defaults)

        for metric in MenuBarMetric.allCases {
            preferences.save(metric)
            XCTAssertEqual(preferences.load(), metric)
        }
    }

    func testPresentationShowsAtMostOneMetric() {
        let resources = SystemResourceUsage(
            cpuPercent: 42.4,
            memoryUsedBytes: 30,
            memoryTotalBytes: 100
        )

        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .cpu).metricLabel,
            "CPU 42%"
        )
        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .ram).metricLabel,
            "RAM 30%"
        )

        let iconOnly = MenuBarStatusPresentation(resources: resources, metric: .iconOnly)
        XCTAssertNil(iconOnly.metricLabel)
        XCTAssertEqual(iconOnly.accessibilityLabel(hasWarning: false), "PortsKiller")
        XCTAssertEqual(
            iconOnly.accessibilityLabel(hasWarning: true),
            "PortsKiller, unknown listener detected"
        )
    }
}
