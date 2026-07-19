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
            memoryTotalBytes: 100,
            swap: SwapUsage(usedBytes: 1_073_741_824, totalBytes: 3_221_225_472)
        )

        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .cpu).metricLabel,
            "42%"
        )
        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .ram).metricLabel,
            "30%"
        )
        XCTAssertTrue(MenuBarStatusPresentation(resources: resources, metric: .cpu).showsSwapIndicator)
        XCTAssertTrue(MenuBarStatusPresentation(resources: resources, metric: .ram).showsSwapIndicator)

        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .ram).content(isRecovering: false),
            .metric(label: "30%", showsSwapIndicator: true)
        )
        XCTAssertEqual(
            MenuBarStatusPresentation(resources: resources, metric: .ram).content(isRecovering: true),
            .recovering
        )

        let iconOnly = MenuBarStatusPresentation(resources: resources, metric: .iconOnly)
        XCTAssertNil(iconOnly.metricLabel)
        XCTAssertFalse(iconOnly.showsSwapIndicator)
        XCTAssertEqual(iconOnly.accessibilityLabel(hasWarning: false), "PortsKiller")
        XCTAssertEqual(
            iconOnly.accessibilityLabel(hasWarning: true),
            "PortsKiller, unknown listener detected"
        )
    }

    func testSwapIndicatorDistinguishesInactiveUnavailableAndActiveSwap() {
        let inactive = SystemResourceUsage(
            cpuPercent: 10,
            memoryUsedBytes: 40,
            memoryTotalBytes: 100,
            swap: SwapUsage(usedBytes: 0, totalBytes: 0)
        )
        let unavailable = SystemResourceUsage(
            cpuPercent: 10,
            memoryUsedBytes: 40,
            memoryTotalBytes: 100,
            swap: nil
        )

        XCTAssertEqual(MenuBarStatusPresentation(resources: inactive, metric: .ram).metricLabel, "40%")
        XCTAssertEqual(MenuBarStatusPresentation(resources: unavailable, metric: .ram).metricLabel, "40%")
        XCTAssertFalse(MenuBarStatusPresentation(resources: inactive, metric: .ram).showsSwapIndicator)
        XCTAssertFalse(MenuBarStatusPresentation(resources: unavailable, metric: .ram).showsSwapIndicator)
        XCTAssertEqual(
            MenuBarStatusPresentation(resources: inactive, metric: .ram).accessibilityLabel(hasWarning: false),
            "PortsKiller, RAM 40 percent"
        )
    }
}
