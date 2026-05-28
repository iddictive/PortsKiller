import Foundation

struct ProjectFolderInfo {
    let name: String
    let packageManager: String
    let scripts: [PackageScript]
    let suggestedPort: Int
}

struct PackageScript: Identifiable, Hashable {
    var id: String { name }

    let name: String
    let body: String
}

final class PackageScriptInspector {
    func inspect(cwd: String) -> ProjectFolderInfo? {
        let folderURL = URL(fileURLWithPath: cwd)
        let packageURL = folderURL.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let scriptsObject = json["scripts"] as? [String: String] ?? [:]
        let scripts = scriptsObject
            .map { PackageScript(name: $0.key, body: $0.value) }
            .sorted(by: scriptSort)

        return ProjectFolderInfo(
            name: json["name"] as? String ?? folderURL.lastPathComponent,
            packageManager: packageManager(in: folderURL),
            scripts: scripts,
            suggestedPort: suggestedPort(from: scripts) ?? 3000
        )
    }

    func command(packageManager: String, scriptName: String) -> String {
        switch packageManager {
        case "pnpm":
            return "pnpm \(scriptName)"
        case "yarn":
            return "yarn \(scriptName)"
        case "bun":
            return "bun run \(scriptName)"
        default:
            return "npm run \(scriptName)"
        }
    }

    private func packageManager(in folderURL: URL) -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folderURL.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if fileManager.fileExists(atPath: folderURL.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if fileManager.fileExists(atPath: folderURL.appendingPathComponent("bun.lockb").path) { return "bun" }
        if fileManager.fileExists(atPath: folderURL.appendingPathComponent("bun.lock").path) { return "bun" }
        return "npm"
    }

    private func suggestedPort(from scripts: [PackageScript]) -> Int? {
        let preferred = scripts.first(where: { $0.name == "dev" }) ?? scripts.first
        guard let body = preferred?.body else { return nil }

        let patterns = [
            #"--port[=\s]+([0-9]{2,5})"#,
            #"-p\s+([0-9]{2,5})"#,
            #"PORT=([0-9]{2,5})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            guard
                let match = regex.firstMatch(in: body, range: range),
                let portRange = Range(match.range(at: 1), in: body),
                let port = Int(body[portRange])
            else { continue }
            return port
        }

        return nil
    }

    private func scriptSort(_ lhs: PackageScript, _ rhs: PackageScript) -> Bool {
        let priority = ["dev", "start", "serve", "preview", "storybook"]
        let left = priority.firstIndex(of: lhs.name) ?? Int.max
        let right = priority.firstIndex(of: rhs.name) ?? Int.max
        if left != right { return left < right }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
