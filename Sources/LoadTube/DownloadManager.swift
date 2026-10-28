import Foundation
import Combine

struct VideoMeta {
    let title: String
    let thumbnail: URL?
    let isPlaylist: Bool
    let count: Int
}

/// Очередь загрузок: не больше двух одновременных задач.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []

    private let ytDlp: String
    private let ffmpegPath: String
    private let maxConcurrent = 2
    private var running: Set<UUID> = []

    private var l10n: Localization { Localization.shared }

    init(ytDlp: String, ffmpegPath: String) {
        self.ytDlp = ytDlp
        self.ffmpegPath = ffmpegPath
    }

    // MARK: - Публичный интерфейс

    func add(url: String, preset: QualityPreset, allowPlaylist: Bool, folder: URL) {
        let spotify = MusicResolver.isSpotifyLink(url)
        let task = DownloadTask(
            url: url,
            preset: preset,
            allowPlaylist: allowPlaylist && !spotify,
            folder: folder,
            isSpotify: spotify
        )
        tasks.insert(task, at: 0)
        schedule()
    }

    func retry(_ task: DownloadTask) {
        guard !task.isActive else { return }
        task.resetForRetry()
        schedule()
    }

    func cancel(_ task: DownloadTask) {
        task.cancelled = true
        task.process?.terminate()
        if case .queued = task.state {
            task.state = .cancelled
        }
    }

    func clearFinished() {
        tasks.removeAll { $0.state == .finished }
    }

    var hasFinished: Bool {
        tasks.contains { $0.state == .finished }
    }

    // MARK: - Очередь

    private func schedule() {
        for task in tasks.reversed() {
            guard running.count < maxConcurrent else { break }
            guard !running.contains(task.id) else { continue }
            if case .queued = task.state {
                running.insert(task.id)
                Task { await self.run(task) }
            }
        }
    }

    private func run(_ task: DownloadTask) async {
        defer {
            running.remove(task.id)
            schedule()
        }

        task.state = .preparing
        task.progress = 0
        task.speed = ""
        task.eta = ""
        task.detail = l10n.t("detail.fetching")

        // 1. Метаданные
        if task.isSpotify {
            task.detail = l10n.t("detail.spotifyLookup")
            do {
                let track = try await MusicResolver.resolve(task.url)
                guard !task.cancelled else {
                    finishCancelled(task)
                    return
                }
                task.title = track.displayName
                task.thumbnailURL = track.artwork
                task.searchQuery = track.searchQuery
                task.spotifyFileBase = track.fileBase
                task.spotifyTitle = track.title
                task.spotifyArtist = track.artist
                task.spotifyArtwork = track.artwork
                task.isPlaylist = false
                task.detail = l10n.t("detail.spotifySearching")
            } catch {
                guard !task.cancelled else {
                    finishCancelled(task)
                    return
                }
                task.state = .failed(error.localizedDescription)
                return
            }
        } else {
            do {
                let meta = try await fetchMetadata(task)
                guard !task.cancelled else {
                    finishCancelled(task)
                    return
                }
                task.title = meta.title
                task.thumbnailURL = meta.thumbnail
                task.isPlaylist = meta.isPlaylist
                if meta.isPlaylist {
                    task.detail = l10n.f("detail.playlist", meta.count)
                }
            } catch {
                guard !task.cancelled else {
                    finishCancelled(task)
                    return
                }
                task.state = .failed(error.localizedDescription)
                return
            }
        }

        guard !task.cancelled else {
            finishCancelled(task)
            return
        }

        // 2. Загрузка
        await download(task)
    }

    private func finishCancelled(_ task: DownloadTask) {
        task.process?.terminate()
        task.process = nil
        Self.cleanupPartials(task)
        task.state = .cancelled
        task.detail = ""
        task.speed = ""
        task.eta = ""
    }

    // MARK: - Метаданные

    private func fetchMetadata(_ task: DownloadTask) async throws -> VideoMeta {
        var args = ["-J", "--flat-playlist", "--no-warnings", "--ignore-config"]
        if !task.allowPlaylist {
            args.append("--no-playlist")
        }
        args.append(task.url)

        let result = await ProcessRunner.run(
            executable: ytDlp,
            arguments: args,
            environment: Self.environment()
        )

        guard result.code == 0 else {
            throw LTError.message(Self.cleanError(result.lines))
        }

        let json = result.lines.joined(separator: "\n")
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LTError.message(l10n.t("error.metadata"))
        }

        let isPlaylist = (dict["_type"] as? String) == "playlist"
        let title = (dict["title"] as? String) ?? l10n.t("meta.video")

        var thumbnail: URL?
        if let string = dict["thumbnail"] as? String {
            thumbnail = URL(string: string)
        }
        if thumbnail == nil,
           let thumbs = dict["thumbnails"] as? [[String: Any]],
           let last = thumbs.last,
           let string = last["url"] as? String {
            thumbnail = URL(string: string)
        }

        let count = (dict["entries"] as? [Any])?.count ?? 0

        return VideoMeta(title: title, thumbnail: thumbnail, isPlaylist: isPlaylist, count: count)
    }

    // MARK: - Загрузка

    private func download(_ task: DownloadTask) async {
        task.state = .downloading
        task.progress = 0
        task.lastError = nil
        task.destinationStem = nil

        // Для ссылок Spotify всегда качаем лучший звук в MP3.
        let effectivePreset: QualityPreset = task.isSpotify ? .mp3 : task.preset

        let folder = task.folder.path.hasSuffix("/") ? task.folder.path : task.folder.path + "/"
        let template: String
        if task.isPlaylist {
            template = folder + "%(playlist_title).100B/%(playlist_index)02d - %(title).120B [%(id)s].%(ext)s"
        } else {
            template = folder + "%(title).140B [%(id)s].%(ext)s"
        }

        let printFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadtube-\(task.id.uuidString).path")
        try? FileManager.default.removeItem(at: printFile)

        var args: [String] = [
            "--ignore-config",
            "--newline",
            "--no-quiet",
            "--no-simulate",
            "--no-mtime",
            "--no-colors",
            "--no-warnings",
            "--retries", "5",
            "--fragment-retries", "5",
            "--ffmpeg-location", ffmpegPath,
            "--progress-template",
            "download:LTDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--print-to-file", "after_move:%(filepath)s", printFile.path,
            "-o", template
        ]
        args += effectivePreset.arguments
        if task.isSpotify {
            args.append("--no-playlist")
        } else {
            args.append(task.allowPlaylist ? "--yes-playlist" : "--no-playlist")
        }
        args.append("--")
        if let query = task.searchQuery {
            args.append("ytsearch1:\(query)")
        } else {
            args.append(task.url)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = args
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        task.process = process

        do {
            try process.run()
        } catch {
            task.process = nil
            task.state = .failed(l10n.f("error.start", error.localizedDescription))
            return
        }

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                handle(line: line, task: task)
            }
        } catch {
            // Пайп закрылся — процесс завершился.
        }

        while process.isRunning {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        task.process = nil

        if task.cancelled {
            Self.cleanupPartials(task)
            task.state = .cancelled
            task.speed = ""
            task.eta = ""
            try? FileManager.default.removeItem(at: printFile)
            return
        }

        guard process.terminationStatus == 0 else {
            let message = task.lastError
                ?? l10n.f("error.exit", process.terminationStatus)
            Self.cleanupPartials(task)
            task.state = .failed(message)
            task.speed = ""
            task.eta = ""
            try? FileManager.default.removeItem(at: printFile)
            return
        }

        // Итоговый путь
        var outputURL: URL?
        if let text = try? String(contentsOf: printFile, encoding: .utf8) {
            let lines = text
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = lines.last, FileManager.default.fileExists(atPath: last) {
                outputURL = URL(fileURLWithPath: last)
            }
        }
        if outputURL == nil {
            outputURL = Self.findOutput(task)
        }

        // Для пресета «4K MP4» проверяем кодек и при необходимости
        // перекодируем в HEVC, чтобы файл открывался в QuickTime.
        var finalURL = outputURL
        if !task.isSpotify, task.preset == .mp4_4k, let input = outputURL {
            let info = await Self.probeVideo(input, ffmpegPath: ffmpegPath)
            if let info, !Self.isQuickTimeCodec(info.codec) {
                let converted = await transcodeToHEVC(
                    task,
                    input: input,
                    height: info.height,
                    pixFmt: info.pixFmt
                )
                if task.cancelled {
                    try? FileManager.default.removeItem(at: input)
                    task.state = .cancelled
                    task.speed = ""
                    task.eta = ""
                    try? FileManager.default.removeItem(at: printFile)
                    return
                }
                if let converted {
                    finalURL = converted
                } else {
                    task.warning = l10n.t("warning.transcodeFailed")
                }
            }
        }

        // Для Spotify переименовываем файл в «Исполнитель - Название».
        if task.isSpotify, let base = task.spotifyFileBase, let url = finalURL {
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let target = task.folder.appendingPathComponent("\(base).\(ext)")
            if url.standardizedFileURL != target.standardizedFileURL {
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                    finalURL = target
                }
            }
        }

        // Подставляем обложку и теги из Spotify.
        if task.isSpotify, let url = finalURL {
            finalURL = await applySpotifyTags(task, file: url)
        }

        task.outputURL = task.isPlaylist ? task.folder : finalURL
        task.progress = 1
        task.speed = ""
        task.eta = ""
        task.state = .finished
        task.detail = task.isPlaylist ? l10n.t("row.playlistSaved") : l10n.t("detail.finished")

        try? FileManager.default.removeItem(at: printFile)
        Notifier.completed(title: task.title)
    }

    // MARK: - Spotify: обложка и теги

    private func applySpotifyTags(_ task: DownloadTask, file: URL) async -> URL {
        guard let artwork = task.spotifyArtwork,
              let title = task.spotifyTitle,
              let artist = task.spotifyArtist else {
            return file
        }

        let fm = FileManager.default
        let coverURL = fm.temporaryDirectory
            .appendingPathComponent("loadtube-cover-\(task.id.uuidString).jpg")
        let tempURL = file.deletingPathExtension().appendingPathExtension("lt-tag.mp3")
        try? fm.removeItem(at: tempURL)

        do {
            var request = URLRequest(url: artwork)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return file
            }
            try data.write(to: coverURL)
        } catch {
            return file
        }

        task.detail = l10n.t("detail.tagsArtwork")

        let arguments = [
            "-y", "-v", "error", "-nostdin",
            "-i", file.path,
            "-i", coverURL.path,
            "-map", "0:a",
            "-map", "1:v",
            "-c", "copy",
            "-id3v2_version", "3",
            "-metadata", "title=\(title)",
            "-metadata", "artist=\(artist)",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            tempURL.path
        ]

        let result = await ProcessRunner.run(
            executable: ffmpegPath,
            arguments: arguments,
            environment: Self.environment()
        )
        try? fm.removeItem(at: coverURL)

        guard result.code == 0, fm.fileExists(atPath: tempURL.path) else {
            try? fm.removeItem(at: tempURL)
            return file
        }

        do {
            try fm.removeItem(at: file)
            try fm.moveItem(at: tempURL, to: file)
            return file
        } catch {
            try? fm.removeItem(at: tempURL)
            return file
        }
    }

    // MARK: - Перекодирование в HEVC

    private struct VideoInfo {
        let codec: String
        let height: Int
        let pixFmt: String
    }

    private static func isTenBit(_ pixFmt: String) -> Bool {
        let value = pixFmt.lowercased()
        return value.contains("10") || value.contains("12") || value.contains("p010")
            || value.contains("p210") || value.contains("p016")
    }

    private static func isQuickTimeCodec(_ codec: String) -> Bool {
        let value = codec.lowercased()
        return value == "h264" || value == "hevc"
    }

    private static func ffprobePath(for ffmpeg: String) -> String {
        (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
    }

    private static func probeVideo(_ url: URL, ffmpegPath: String) async -> VideoInfo? {
        let result = await ProcessRunner.run(
            executable: ffprobePath(for: ffmpegPath),
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_name,height,pix_fmt",
                "-of", "default=noprint_wrappers=1",
                url.path
            ],
            environment: environment()
        )
        guard result.code == 0 else { return nil }

        var codec = ""
        var height = 0
        var pixFmt = ""
        for line in result.lines {
            if line.hasPrefix("codec_name=") {
                codec = String(line.dropFirst("codec_name=".count))
            } else if line.hasPrefix("height=") {
                height = Int(line.dropFirst("height=".count)) ?? 0
            } else if line.hasPrefix("pix_fmt=") {
                pixFmt = String(line.dropFirst("pix_fmt=".count))
            }
        }
        return codec.isEmpty ? nil : VideoInfo(codec: codec, height: height, pixFmt: pixFmt)
    }

    private static func mediaDuration(_ url: URL, ffmpegPath: String) async -> Double {
        let result = await ProcessRunner.run(
            executable: ffprobePath(for: ffmpegPath),
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ],
            environment: environment()
        )
        guard let first = result.lines.first else { return 0 }
        return Double(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func bitrate(forHeight height: Int) -> String {
        switch height {
        case 2161...: return "24M"
        case 1441...2160: return "20M"
        case 1081...1440: return "12M"
        case 721...1080: return "8M"
        case 481...720: return "5M"
        default: return "3M"
        }
    }

    /// Перекодирует видео в HEVC/H.265 (аппаратно) и возвращает новый путь.
    private func transcodeToHEVC(
        _ task: DownloadTask,
        input: URL,
        height: Int,
        pixFmt: String
    ) async -> URL? {
        let fm = FileManager.default
        let base = input.deletingPathExtension()
        let finalURL = base.appendingPathExtension("mp4")
        let tempURL = base.appendingPathExtension("lt-tmp.mp4")
        try? fm.removeItem(at: tempURL)

        let duration = await Self.mediaDuration(input, ffmpegPath: ffmpegPath)

        task.state = .merging
        task.detail = l10n.t("detail.transcoding")
        task.progress = 0
        task.speed = ""
        task.eta = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var arguments: [String] = [
            "-y", "-v", "error", "-nostdin",
            "-progress", "pipe:1", "-nostats",
            "-i", input.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-map_metadata", "0", "-map_chapters", "0",
            "-c:v", "hevc_videotoolbox",
            "-b:v", Self.bitrate(forHeight: height),
            "-tag:v", "hvc1"
        ]
        if Self.isTenBit(pixFmt) {
            arguments += ["-profile:v", "main10", "-pix_fmt", "p010le"]
        }
        arguments += [
            "-c:a", "aac", "-b:a", "256k",
            "-movflags", "+faststart",
            tempURL.path
        ]
        process.arguments = arguments
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        task.process = process

        do {
            try process.run()
        } catch {
            task.process = nil
            try? fm.removeItem(at: tempURL)
            return nil
        }

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                guard line.hasPrefix("out_time_us="), duration > 0 else { continue }
                guard let microseconds = Double(line.dropFirst("out_time_us=".count)),
                      microseconds > 0 else { continue }
                let ratio = min(max(microseconds / 1_000_000 / duration, 0), 1)
                task.progress = ratio
                task.detail = l10n.f("detail.transcodingProgress", Int(ratio * 100))
            }
        } catch {
            // Пайп закрылся — процесс завершился.
        }

        while process.isRunning {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        task.process = nil

        if task.cancelled {
            try? fm.removeItem(at: tempURL)
            return nil
        }

        guard process.terminationStatus == 0, fm.fileExists(atPath: tempURL.path) else {
            try? fm.removeItem(at: tempURL)
            return nil
        }

        do {
            if input.path == finalURL.path {
                try fm.removeItem(at: input)
                try fm.moveItem(at: tempURL, to: finalURL)
            } else {
                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: tempURL, to: finalURL)
                try? fm.removeItem(at: input)
            }
            return finalURL
        } catch {
            try? fm.removeItem(at: tempURL)
            return nil
        }
    }

    // MARK: - Разбор строк yt-dlp

    private func handle(line: String, task: DownloadTask) {
        if let range = line.range(of: "LTDL|") {
            let payload = line[range.upperBound...]
            let parts = payload
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)

            if parts.count >= 6 {
                let status = parts[0]
                let downloaded = Double(parts[1]) ?? 0
                let total = Double(parts[2]) ?? Double(parts[3]) ?? 0

                if status == "finished" {
                    task.progress = 1
                    task.speed = ""
                    task.eta = ""
                } else if total > 0 {
                    task.progress = min(max(downloaded / total, 0), 1)
                    task.speed = Self.formatSpeed(Double(parts[4]))
                    task.eta = Self.formatETA(Double(parts[5]))
                } else if downloaded > 0 {
                    task.speed = Self.formatSpeed(Double(parts[4]))
                }
            }
            return
        }

        if line.contains("[download] Destination: ") {
            let path = line.components(separatedBy: "[download] Destination: ").last ?? ""
            task.destinationStem = (path as NSString).deletingPathExtension
            task.detail = (path as NSString).lastPathComponent
            return
        }

        if line.contains("[Merger]") {
            task.state = .merging
            task.progress = 1
            task.detail = l10n.t("detail.merging")
            task.speed = ""
            task.eta = ""
            return
        }

        if line.contains("[ExtractAudio]") || line.contains("[VideoConvertor]") {
            task.state = .merging
            task.progress = 1
            if task.isSpotify || task.preset == .mp3 {
                task.detail = l10n.t("detail.mp3")
            } else {
                task.detail = l10n.t("detail.converting")
            }
            task.speed = ""
            task.eta = ""
            return
        }

        if line.contains("[EmbedThumbnail]") {
            task.detail = l10n.t("detail.thumbnail")
            return
        }

        if line.contains("[Metadata]") {
            task.detail = l10n.t("detail.metadata")
            return
        }

        if line.contains("Downloading item ") {
            task.detail = line
                .replacingOccurrences(of: "[download] ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return
        }

        if line.contains("ERROR:") {
            task.lastError = Self.cleanError([line])
        }
    }

    // MARK: - Вспомогательное

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

    private static func cleanError(_ lines: [String]) -> String {
        var message = lines.last(where: { $0.contains("ERROR:") })
            ?? lines.last
            ?? Localization.shared.t("error.metadata")
        message = message.replacingOccurrences(of: "ERROR: ", with: "")

        if message.hasPrefix("["), let closing = message.firstIndex(of: "]") {
            message = String(message[message.index(after: closing)...]).trimmingCharacters(in: .whitespaces)
        }
        if message.isEmpty {
            message = Localization.shared.t("error.unknown")
        }
        return message
    }

    private static func formatSpeed(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
            + Localization.shared.t("speed.suffix")
    }

    private static func formatETA(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else { return "" }
        let seconds = Int(value)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func findOutput(_ task: DownloadTask) -> URL? {
        guard let stem = task.destinationStem else { return nil }
        let directory = (stem as NSString).deletingLastPathComponent
        let base = (stem as NSString).lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }

        var best: (URL, Date)?
        for item in items where item.hasPrefix(base) {
            let lower = item.lowercased()
            if lower.hasSuffix(".part") || lower.hasSuffix(".ytdl") || lower.contains(".temp") { continue }
            if item == base { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(item)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.1 {
                best = (url, date)
            }
        }
        return best?.0
    }

    private static func cleanupPartials(_ task: DownloadTask) {
        guard let stem = task.destinationStem else { return }
        let directory = (stem as NSString).deletingLastPathComponent
        let base = (stem as NSString).lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }

        for item in items where item.hasPrefix(base) {
            let lower = item.lowercased()
            if lower.hasSuffix(".part") || lower.hasSuffix(".ytdl") || lower.contains(".temp") || item == base {
                try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(item))
            }
        }
    }
}
