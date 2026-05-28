import Foundation

@MainActor
final class ManagedProcessRunner: ObservableObject {
    @Published private(set) var logsByProjectID: [UUID: String] = [:]
    private var runningProcesses: [UUID: Process] = [:]

    func start(_ project: ManualProject) {
        stopManaged(projectID: project.id)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", project.command]
        process.currentDirectoryURL = URL(fileURLWithPath: project.cwd)
        process.environment = mergedEnvironment()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let appendOutput: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.append(text, projectID: project.id)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = appendOutput
        errorPipe.fileHandleForReading.readabilityHandler = appendOutput

        process.terminationHandler = { [weak self, weak outputPipe, weak errorPipe] process in
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.runningProcesses[project.id] = nil
                self?.append("\nProcess exited with status \(process.terminationStatus).\n", projectID: project.id)
            }
        }

        do {
            append("$ \(project.command)\n", projectID: project.id)
            try process.run()
            runningProcesses[project.id] = process
        } catch {
            append("Failed to start: \(error.localizedDescription)\n", projectID: project.id)
        }
    }

    func stopManaged(projectID: UUID) {
        guard let process = runningProcesses[projectID] else { return }
        process.terminate()
        runningProcesses[projectID] = nil
    }

    func logs(for projectID: UUID) -> String {
        logsByProjectID[projectID] ?? ""
    }

    private func append(_ text: String, projectID: UUID) {
        let current = logsByProjectID[projectID] ?? ""
        let next = String((current + text).suffix(40_000))
        logsByProjectID[projectID] = next
    }

    private func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], commonPaths]
            .compactMap { $0 }
            .joined(separator: ":")
        return environment
    }
}
