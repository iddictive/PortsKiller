import Foundation

enum Shell {
    struct Result {
        let output: String
        let status: Int32
    }

    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return Result(output: error.localizedDescription, status: 127)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return Result(output: output, status: process.terminationStatus)
    }
}
