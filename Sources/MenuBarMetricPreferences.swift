import Foundation

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu
    case ram
    case iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .ram: "RAM"
        case .iconOnly: "Icon"
        }
    }
}

struct MenuBarStatusPresentation {
    let resources: SystemResourceUsage
    let metric: MenuBarMetric

    var metricLabel: String? {
        switch metric {
        case .cpu:
            guard let cpu = resources.cpuPercent else { return "--" }
            return String(format: "%.0f%%", cpu)
        case .ram:
            return String(format: "%.0f%%", resources.memoryPercent)
        case .iconOnly:
            return nil
        }
    }

    var showsSwapIndicator: Bool {
        metric != .iconOnly && resources.swap?.isActive == true
    }

    func content(isRecovering: Bool) -> MenuBarStatusContent {
        if isRecovering {
            return .recovering
        }
        return .metric(label: metricLabel, showsSwapIndicator: showsSwapIndicator)
    }

    func accessibilityLabel(hasWarning: Bool) -> String {
        var parts = ["PortsKiller"]
        switch metric {
        case .cpu:
            let value = resources.cpuPercent.map { String(format: "%.0f percent", $0) } ?? "unavailable"
            parts.append("CPU \(value)")
        case .ram:
            parts.append(String(format: "RAM %.0f percent", resources.memoryPercent))
        case .iconOnly:
            break
        }
        if metric != .iconOnly, let swap = resources.swap, swap.isActive {
            let used = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: swap.usedBytes),
                countStyle: .memory
            )
            parts.append("swap \(used) in use")
        }
        if hasWarning {
            parts.append("unknown listener detected")
        }
        return parts.joined(separator: ", ")
    }
}

enum MenuBarStatusContent: Equatable {
    case metric(label: String?, showsSwapIndicator: Bool)
    case recovering
}

final class MenuBarMetricPreferences {
    private enum Key {
        static let metric = "MenuBar.metric"
        static let legacyShowsCPU = "MenuBar.showsCPU"
        static let legacyShowsRAM = "MenuBar.showsRAM"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MenuBarMetric {
        if let rawValue = defaults.string(forKey: Key.metric),
           let metric = MenuBarMetric(rawValue: rawValue) {
            return metric
        }

        let metric = migratedLegacyMetric()
        save(metric)
        return metric
    }

    func save(_ metric: MenuBarMetric) {
        defaults.set(metric.rawValue, forKey: Key.metric)
    }

    private func migratedLegacyMetric() -> MenuBarMetric {
        let showsCPU = defaults.object(forKey: Key.legacyShowsCPU) as? Bool ?? true
        let showsRAM = defaults.object(forKey: Key.legacyShowsRAM) as? Bool ?? true

        return switch (showsCPU, showsRAM) {
        case (false, true): .ram
        case (false, false): .iconOnly
        case (true, _): .cpu
        }
    }
}
