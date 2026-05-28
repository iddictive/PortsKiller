import Foundation

enum LoginItemError: LocalizedError {
    case appBundleRequired

    var errorDescription: String? {
        switch self {
        case .appBundleRequired:
            return "Login item requires running PortsKiller from a .app bundle."
        }
    }
}

final class LoginItemManager {
    private let label = "com.md.PortsKiller"

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            disable()
        }
    }

    private func enable() throws {
        guard let executable = bundledExecutablePath() else {
            throw LoginItemError.appBundleRequired
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func disable() {
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private func bundledExecutablePath() -> String? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
            .appendingPathComponent("Contents/MacOS/PortsKiller")
            .path
    }
}
