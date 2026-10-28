import Foundation

struct ProcessOutput {
    let code: Int32
    let lines: [String]
}

enum LTError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Запускает дочерний процесс и построчно отдаёт вывод.
enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: ((String) -> Void)? = nil
    ) async -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ProcessOutput(code: -1, lines: ["ERROR: \(error.localizedDescription)"])
        }

        var lines: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                lines.append(line)
                if lines.count > 600 { lines.removeFirst(200) }
                onLine?(line)
            }
        } catch {
            // Процесс закрыл пайп — это нормальное завершение.
        }

        while process.isRunning {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        return ProcessOutput(code: process.terminationStatus, lines: lines)
    }
}
