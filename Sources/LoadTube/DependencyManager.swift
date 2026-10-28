import Foundation
import Combine
import Darwin

/// Ищет инструменты, а при отсутствии скачивает портативные yt-dlp + ffmpeg
/// в ~/Library/Application Support/LoadTube/bin (Homebrew не требуется).
@MainActor
final class DependencyManager: ObservableObject {
    enum Phase: Equatable {
        case checking
        case ready
        case missing
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var log = ""
    /// 0...1 во время скачивания; -1 когда прогресс неизвестен (Homebrew).
    @Published private(set) var progress: Double = 0
    @Published private(set) var ytDlpPath: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var brewPath: String?

    private var isInstalling = false

    static let binDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LoadTube/bin", isDirectory: true)
    }()

    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin"
    ]

    static func find(_ name: String) -> String? {
        let local = binDirectory.appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: local) {
            return local
        }
        for directory in searchPaths {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func check() {
        ytDlpPath = Self.find("yt-dlp")
        ffmpegPath = Self.find("ffmpeg")
        brewPath = Self.find("brew")

        if ytDlpPath != nil && ffmpegPath != nil {
            phase = .ready
        } else {
            phase = .missing
        }
    }

    // MARK: - Портативная установка

    func install() {
        guard !isInstalling else { return }
        isInstalling = true
        log = ""
        progress = 0
        phase = .installing

        Task {
            do {
                try await installPortable()
                progress = 1
                append(Localization.shared.t("install.successLog"))
                isInstalling = false
                check()
            } catch {
                isInstalling = false
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func installPortable() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.binDirectory, withIntermediateDirectories: true)

        let suffix = Self.architecture == "x86_64" ? "x64" : "arm64"
        let items: [(name: String, url: String)] = [
            ("yt-dlp", "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"),
            ("ffmpeg", "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-\(suffix)"),
            ("ffprobe", "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffprobe-darwin-\(suffix)")
        ]

        for (index, item) in items.enumerated() {
            append("⬇️ \(item.name)…")
            guard let url = URL(string: item.url) else {
                throw LTError.message(Localization.shared.t("install.downloadFailed"))
            }

            let base = Double(index) / Double(items.count)
            let weight = 1.0 / Double(items.count)
            let downloaded = try await download(url) { fraction in
                Task { @MainActor in
                    self.progress = base + weight * fraction
                }
            }

            let destination = Self.binDirectory.appendingPathComponent(item.name)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: downloaded, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            Self.stripQuarantine(destination)
            append("✅ \(item.name)")
        }

        try await validateBinary(Self.binDirectory.appendingPathComponent("yt-dlp"), arguments: ["--version"])
        try await validateBinary(Self.binDirectory.appendingPathComponent("ffmpeg"), arguments: ["-version"])
        try await validateBinary(Self.binDirectory.appendingPathComponent("ffprobe"), arguments: ["-version"])
    }

    private func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = FileDownloadDelegate()
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.onProgress = progress
            delegate.onFinish = { result in
                session.invalidateAndCancel()
                switch result {
                case .success(let fileURL):
                    continuation.resume(returning: fileURL)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    private func validateBinary(_ url: URL, arguments: [String]) async throws {
        let result = await ProcessRunner.run(
            executable: url.path,
            arguments: arguments,
            environment: Self.environment()
        )
        guard result.code == 0 else {
            throw LTError.message(Localization.shared.t("install.invalidBinary"))
        }
    }

    // MARK: - Homebrew (резервный вариант)

    func installViaHomebrew() {
        guard !isInstalling else { return }

        guard let brew = brewPath ?? Self.find("brew") else {
            phase = .failed(Localization.shared.t("install.homebrewMissingError"))
            return
        }

        brewPath = brew
        isInstalling = true
        log = ""
        progress = -1
        phase = .installing

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"

        Task {
            let result = await ProcessRunner.run(
                executable: brew,
                arguments: ["install", "yt-dlp", "ffmpeg"],
                environment: environment
            ) { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }

            isInstalling = false

            if result.code == 0 {
                append(Localization.shared.t("install.successLog"))
                check()
            } else {
                let detail = Self.lastMeaningfulLine(result.lines)
                phase = .failed(Localization.shared.f("install.brewFailed", detail))
            }
        }
    }

    private func append(_ line: String) {
        log += line + "\n"
        if log.count > 80_000 {
            log = String(log.suffix(60_000))
        }
    }

    private static func lastMeaningfulLine(_ lines: [String]) -> String {
        if let error = lines.last(where: { $0.contains("Error:") || $0.contains("error:") }) {
            return error
        }
        return lines.last ?? Localization.shared.t("install.brewUnknown")
    }

    // MARK: - Вспомогательное

    private static var architecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
    }

    private static func stripQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let current = environment["PATH"], !current.isEmpty {
            environment["PATH"] = extra + ":" + current
        } else {
            environment["PATH"] = extra
        }
        return environment
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?
    private var finished = false

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadtube-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: temporary)
            finished = true
            onFinish?(.success(temporary))
        } catch {
            finished = true
            onFinish?(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }
        finished = true
        if let error {
            onFinish?(.failure(error))
        } else {
            onFinish?(.failure(LTError.message("Download failed")))
        }
    }
}
