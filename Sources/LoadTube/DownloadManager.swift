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
    private let tidalBackend: TidalBackend
    private let maxConcurrent = 2
    private var running: Set<UUID> = []

    private var l10n: Localization { Localization.shared }

    init(ytDlp: String, ffmpegPath: String) {
        self.ytDlp = ytDlp
        self.ffmpegPath = ffmpegPath
        self.tidalBackend = TidalBackend(ffmpegPath: ffmpegPath)
    }

    // MARK: - Публичный интерфейс

    func add(url: String, preset: QualityPreset, allowPlaylist: Bool, folder: URL) {
        let source = MediaSource.detect(url)
        let spotify = source == .spotify
        let task = DownloadTask(
            url: url,
            preset: preset,
            allowPlaylist: allowPlaylist && (source == .youtube || source.isShortVideo),
            folder: folder,
            isSpotify: spotify,
            source: source
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
        task.cancel()
        if case .queued = task.state {
            task.state = .cancelled
        }
    }

    func cancelChild(_ parent: DownloadTask, child: DownloadTask) {
        child.cancel()
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

        if task.source == .tidal {
            await runTidal(task)
            return
        }

        await runYTDLP(task)
    }

    private func runYTDLP(_ task: DownloadTask) async {
        task.state = .preparing
        task.progress = 0
        task.speed = ""
        task.eta = ""
        task.detail = l10n.t("detail.fetching")

        let cookies = cookieSetup(for: task.source)
        if let warning = cookies.warning {
            task.warning = warning
        }

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
                let meta = try await fetchMetadata(task, cookies: cookies.arguments)
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
        await download(task, cookies: cookies.arguments)
    }

    // MARK: - Cookies для Instagram и TikTok

    private struct CookieSetup {
        let arguments: [String]
        let warning: String?
    }

    /// Safari на современных macOS защищён TCC, поэтому при отсутствии доступа
    /// пробуем другой установленный браузер, а если их нет — качаем без cookies.
    private func cookieSetup(for source: MediaSource) -> CookieSetup {
        guard source.isShortVideo else { return CookieSetup(arguments: [], warning: nil) }

        let raw = UserDefaults.standard.string(forKey: "cookieBrowser")
            ?? CookieBrowser.safari.rawValue
        guard let browser = CookieBrowser(rawValue: raw), browser != .none else {
            return CookieSetup(arguments: [], warning: nil)
        }

        if browser.isAvailable, let name = browser.ytDlpName {
            return CookieSetup(arguments: ["--cookies-from-browser", name], warning: nil)
        }

        if let fallback = CookieBrowser.allCases.first(where: {
            $0 != .none && $0 != browser && $0.isAvailable
        }), let name = fallback.ytDlpName {
            return CookieSetup(
                arguments: ["--cookies-from-browser", name],
                warning: l10n.f(
                    "cookies.warningFallback",
                    l10n.t(browser.titleKey),
                    l10n.t(fallback.titleKey)
                )
            )
        }

        return CookieSetup(arguments: [], warning: l10n.t("cookies.warningNone"))
    }

    /// Понятные сообщения для частых ошибок Instagram и TikTok.
    private func friendlyMessage(_ message: String, source: MediaSource) -> String {
        let lower = message.lowercased()

        if lower.contains("failed to decrypt") || lower.contains("keyring")
            || lower.contains("keychain") || lower.contains("operation not permitted")
            || lower.contains("permission denied") {
            return l10n.t("error.cookies")
        }
        if source == .instagram,
           lower.contains("login") || lower.contains("empty media response")
            || lower.contains("rate limit") || lower.contains("rate-limit")
            || lower.contains("checkpoint") {
            return l10n.t("error.instagramLogin")
        }
        if source == .tiktok, lower.contains("login") || lower.contains("log in") {
            return l10n.t("error.tiktokLogin")
        }
        if source.isShortVideo,
           lower.contains("requested format is not available")
            || lower.contains("no video formats found") {
            return l10n.t("error.shortVideoFormat")
        }
        return message
    }

    // MARK: - Tidal

    private func runTidal(_ task: DownloadTask) async {
        task.state = .preparing
        task.progress = 0
        task.speed = ""
        task.eta = ""
        task.detail = l10n.t("tidal.detail.resolving")

        do {
            let resolved = try await TidalService.shared.lookup(task.url)
            guard !task.cancelled else {
                finishCancelled(task)
                return
            }

            let preview = resolved.preview
            task.title = preview.title
            task.thumbnailURL = preview.artwork

            switch resolved {
            case .track(let track):
                task.tidalTrack = track
                task.tidalAlbum = track.album
                task.tidalIsSingle = true
                task.tidalTotalTracks = 1
                task.isPlaylist = false
                await downloadTidalSingle(task)
            case .video(let video):
                task.tidalVideo = video
                task.tidalAlbum = video.album
                task.tidalIsSingle = true
                task.isPlaylist = false
                await downloadTidalSingle(task)
            default:
                task.isCollection = true
                task.isTidalCollectionPreparing = true
                task.detail = l10n.t("tidal.detail.collecting")
                let collection = try await TidalService.shared.collection(for: resolved)
                guard !task.cancelled else {
                    finishCancelled(task)
                    return
                }
                try prepareTidalChildren(task, collection: collection, resolved: resolved)
                await runTidalCollection(task)
            }
        } catch {
            guard !task.cancelled else {
                finishCancelled(task)
                return
            }
            if case TidalError.sessionExpired = error {
                TidalService.shared.markSessionExpired()
            }
            task.state = .failed(TidalService.shared.message(for: error))
            task.speed = ""
            task.eta = ""
            task.isTidalCollectionPreparing = false
        }
    }

    private func prepareTidalChildren(
        _ parent: DownloadTask,
        collection: TidalCollection,
        resolved: TidalResolved
    ) throws {
        var items = collection.items
        if !TidalPreferences.downloadVideos {
            items.removeAll { item in
                if case .video = item.media { return true }
                return false
            }
        }
        guard !items.isEmpty else { throw TidalError.noTracks }

        let mixTitle: String?
        if case .mix = resolved {
            mixTitle = collection.title
        } else {
            mixTitle = nil
        }

        var children: [DownloadTask] = []
        for (index, item) in items.enumerated() {
            let child = DownloadTask(
                url: parent.url,
                preset: parent.preset,
                allowPlaylist: false,
                folder: parent.folder,
                source: .tidal
            )
            child.tidalAlbum = item.album
            child.tidalPlaylist = item.playlist
            child.tidalMixTitle = mixTitle
            child.tidalIsSingle = false
            child.thumbnailURL = TidalConfig.coverURL(
                item.album?.cover,
                width: 320,
                height: 320
            )
            child.state = .queued

            switch item.media {
            case .track(let track):
                child.tidalTrack = track
                child.title = track.displayTitle
                child.tidalPosition = mixTitle == nil
                    ? playlistPosition(for: track, index: index, playlist: item.playlist)
                    : (index + 1)
                child.tidalTotalTracks = collectionTotal(
                    for: item.album,
                    resolved: resolved,
                    fallback: items.count
                )
            case .video(let video):
                child.tidalVideo = video
                child.title = video.displayTitle
                child.tidalPosition = index + 1
                child.tidalTotalTracks = collectionTotal(
                    for: item.album,
                    resolved: resolved,
                    fallback: items.count
                )
            }
            children.append(child)
        }

        parent.children = children
        parent.totalCount = children.count
        parent.completedCount = 0
        parent.failedCount = 0
        parent.isTidalCollectionPreparing = false
    }

    private func playlistPosition(for track: TidalTrack, index: Int, playlist: TidalPlaylist?) -> Int {
        if playlist != nil {
            return track.trackNumberOnPlaylist ?? (index + 1)
        }
        return track.trackNumber ?? (index + 1)
    }

    private func collectionTotal(
        for album: TidalAlbum?,
        resolved: TidalResolved,
        fallback: Int
    ) -> Int {
        switch resolved {
        case .album, .artist:
            return album?.numberOfTracks ?? fallback
        case .playlist, .mix, .track, .video:
            return fallback
        }
    }

    private enum ChildOutcome {
        case finished
        case failed
        case cancelled
    }

    private func runTidalCollection(_ parent: DownloadTask) async {
        parent.state = .downloading
        parent.progress = 0
        parent.detail = l10n.f("tidal.detail.progress", 0, parent.totalCount)

        outer: for (index, child) in parent.children.enumerated() {
            if parent.cancelled {
                break outer
            }
            let outcome = await downloadTidalChild(child, parent: parent)
            switch outcome {
            case .finished:
                parent.completedCount += 1
            case .failed:
                parent.failedCount += 1
            case .cancelled:
                if parent.cancelled {
                    break outer
                }
                // Отменили только один трек — продолжаем остальные.
                parent.failedCount += 1
            }
            if parent.cancelled {
                break outer
            }
            if !TidalService.shared.isSignedIn {
                parent.speed = ""
                parent.eta = ""
                parent.state = .failed(l10n.t("error.tidalSession"))
                parent.detail = ""
                return
            }

            let attempted = parent.completedCount + parent.failedCount
            parent.progress = parent.totalCount > 0
                ? Double(attempted) / Double(parent.totalCount)
                : 0
            parent.detail = l10n.f("tidal.detail.progress", attempted, parent.totalCount)

            // Даём SwiftUI время обновить строку между треками.
            if index < parent.children.count - 1 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        parent.speed = ""
        parent.eta = ""
        parent.outputURL = parent.folder

        if parent.cancelled {
            parent.state = .cancelled
            parent.detail = ""
            return
        }

        if parent.completedCount == 0 && parent.failedCount > 0 {
            let reason = parent.children
                .compactMap(\.failedMessage)
                .first
            parent.state = .failed(reason ?? l10n.t("tidal.error.allTracks"))
            parent.detail = ""
            return
        }

        if parent.failedCount > 0 {
            parent.warning = l10n.f("tidal.warning.partial", parent.failedCount)
        }
        parent.progress = 1
        parent.state = .finished
        parent.detail = l10n.t("detail.finished")
        Notifier.completed(title: parent.title)
    }

    private func downloadTidalChild(
        _ child: DownloadTask,
        parent: DownloadTask
    ) async -> ChildOutcome {
        guard !child.cancelled, !parent.cancelled else {
            child.state = .cancelled
            return .cancelled
        }

        child.state = .downloading
        child.progress = 0
        child.detail = l10n.t("tidal.detail.downloading")

        do {
            if let track = child.tidalTrack {
                try await tidalBackend.downloadTrack(
                    track,
                    album: child.tidalAlbum ?? track.album,
                    playlist: child.tidalPlaylist,
                    mixTitle: child.tidalMixTitle,
                    isSingle: false,
                    position: child.tidalPosition,
                    totalTracks: child.tidalTotalTracks,
                    root: child.folder,
                    task: child
                )
            } else if let video = child.tidalVideo {
                try await tidalBackend.downloadVideo(
                    video,
                    album: child.tidalAlbum ?? video.album,
                    playlist: child.tidalPlaylist,
                    mixTitle: child.tidalMixTitle,
                    isSingle: false,
                    position: child.tidalPosition,
                    root: child.folder,
                    task: child
                )
            } else {
                throw TidalError.unavailable
            }

            child.state = .finished
            if child.wasSkipped {
                child.detail = l10n.t("tidal.detail.alreadyExists")
            }
            return .finished
        } catch TidalError.cancelled {
            child.state = .cancelled
            return .cancelled
        } catch {
            if parent.cancelled {
                child.state = .cancelled
                return .cancelled
            }
            if case TidalError.sessionExpired = error {
                TidalService.shared.markSessionExpired()
            }
            child.state = .failed(TidalService.shared.message(for: error))
            return .failed
        }
    }

    private func downloadTidalSingle(_ task: DownloadTask) async {
        task.state = .downloading
        task.progress = 0
        task.detail = l10n.t("tidal.detail.downloading")
        do {
            if let track = task.tidalTrack {
                try await tidalBackend.downloadTrack(
                    track,
                    album: task.tidalAlbum ?? track.album,
                    playlist: nil,
                    mixTitle: nil,
                    isSingle: true,
                    position: track.trackNumber,
                    totalTracks: track.album?.numberOfTracks ?? 1,
                    root: task.folder,
                    task: task
                )
            } else if let video = task.tidalVideo {
                try await tidalBackend.downloadVideo(
                    video,
                    album: task.tidalAlbum ?? video.album,
                    playlist: nil,
                    mixTitle: nil,
                    isSingle: true,
                    position: video.trackNumber,
                    root: task.folder,
                    task: task
                )
            } else {
                throw TidalError.unavailable
            }
            task.state = .finished
            task.progress = 1
            task.detail = l10n.t("detail.finished")
            Notifier.completed(title: task.title)
        } catch TidalError.cancelled {
            task.state = .cancelled
            task.detail = ""
        } catch {
            if case TidalError.sessionExpired = error {
                TidalService.shared.markSessionExpired()
            }
            task.state = .failed(TidalService.shared.message(for: error))
            task.speed = ""
            task.eta = ""
        }
    }

    private func finishCancelled(_ task: DownloadTask) {
        task.cancel()
        Self.cleanupPartials(task)
        task.state = .cancelled
        task.detail = ""
        task.speed = ""
        task.eta = ""
    }

    // MARK: - Метаданные

    private func fetchMetadata(_ task: DownloadTask, cookies: [String]) async throws -> VideoMeta {
        var args = ["-J", "--flat-playlist", "--no-warnings", "--ignore-config"]
        if !task.allowPlaylist {
            args.append("--no-playlist")
        }
        args += cookies
        args.append(task.url)

        let result = await ProcessRunner.run(
            executable: ytDlp,
            arguments: args,
            environment: Self.environment()
        )

        guard result.code == 0 else {
            throw LTError.message(
                friendlyMessage(Self.cleanError(result.lines), source: task.source)
            )
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

    private func download(_ task: DownloadTask, cookies: [String]) async {
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
        args += cookies
        args += effectivePreset.arguments(for: task.source)
        if task.source.isShortVideo {
            args += ["--merge-output-format", "mp4"]
        }
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
            task.state = .failed(friendlyMessage(message, source: task.source))
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
        if !task.isSpotify, !task.source.isShortVideo, task.preset == .mp4_4k, let input = outputURL {
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

        // Instagram и TikTok иногда отдают HEVC с тегом `hev1`, HE-AAC/Opus
        // или лишние дорожки — QuickTime такие файлы не открывает. Приводим
        // контейнер к совместимому виду (по возможности без перекодирования).
        if task.source.isShortVideo, !task.isSpotify, task.preset != .mp3,
           let url = finalURL {
            finalURL = await normalizeForQuickTime(task, input: url)
            if task.cancelled {
                if let result = finalURL {
                    try? FileManager.default.removeItem(at: result)
                }
                task.state = .cancelled
                task.speed = ""
                task.eta = ""
                try? FileManager.default.removeItem(at: printFile)
                return
            }
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

    // MARK: - Совместимость с QuickTime

    private struct StreamSummary {
        var videoCodec: String?
        var videoTag: String?
        var videoPixFmt: String?
        var videoHeight: Int = 0
        var audioCodecs: [String] = []
        var videoCount = 0
        var audioCount = 0
        var otherTracks = 0
    }

    private static func probeStreams(_ url: URL, ffmpegPath: String) async -> StreamSummary? {
        let result = await ProcessRunner.run(
            executable: ffprobePath(for: ffmpegPath),
            arguments: [
                "-v", "error",
                "-show_entries", "stream=codec_name,codec_type,codec_tag_string,pix_fmt,height",
                "-of", "compact=p=0:nk=0",
                url.path
            ],
            environment: environment()
        )
        guard result.code == 0 else { return nil }

        var summary = StreamSummary()
        for line in result.lines where !line.isEmpty {
            var fields: [String: String] = [:]
            for pair in line.split(separator: "|") {
                let parts = pair.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }

            switch fields["codec_type"] {
            case "video":
                summary.videoCount += 1
                if summary.videoCodec == nil {
                    summary.videoCodec = fields["codec_name"]
                    summary.videoTag = fields["codec_tag_string"]
                    summary.videoPixFmt = fields["pix_fmt"]
                    summary.videoHeight = Int(fields["height"] ?? "") ?? 0
                }
            case "audio":
                summary.audioCount += 1
                summary.audioCodecs.append(fields["codec_name"] ?? "")
            default:
                summary.otherTracks += 1
            }
        }
        return summary
    }

    private static func isQuickTimeCompatibleVideo(_ codec: String, pixFmt: String) -> Bool {
        let pix = pixFmt.lowercased()
        let chromaOK = !pix.contains("444") && !pix.contains("422")
        switch codec.lowercased() {
        case "h264":
            return chromaOK && !isTenBit(pix)
        case "hevc":
            return chromaOK
        default:
            return false
        }
    }

    /// Приводит файл Instagram/TikTok к виду, который открывает QuickTime:
    /// тег HEVC `hvc1`, AAC-звук, одна видео- и одна аудиодорожка.
    /// Если файл уже совместим, ничего не делает.
    private func normalizeForQuickTime(_ task: DownloadTask, input: URL) async -> URL {
        guard let summary = await Self.probeStreams(input, ffmpegPath: ffmpegPath),
              summary.videoCount == 1 else {
            return input
        }

        let videoCodec = (summary.videoCodec ?? "").lowercased()
        let videoTag = (summary.videoTag ?? "").lowercased()
        let pixFmt = summary.videoPixFmt ?? ""
        let audioCodec = (summary.audioCodecs.first ?? "").lowercased()

        let videoOK = Self.isQuickTimeCompatibleVideo(videoCodec, pixFmt: pixFmt)
        let tagOK = videoCodec != "hevc" || videoTag == "hvc1"
        let audioOK = audioCodec.isEmpty || audioCodec == "aac" || audioCodec == "alac"
        let extrasOK = summary.audioCount <= 1 && summary.otherTracks == 0

        guard !(videoOK && tagOK && audioOK && extrasOK) else { return input }

        task.state = .merging
        task.detail = l10n.t("detail.compatibility")
        task.progress = 0
        task.speed = ""
        task.eta = ""

        let fm = FileManager.default
        let base = input.deletingPathExtension()
        let output = input.pathExtension.lowercased() == "mp4"
            ? input
            : base.appendingPathExtension("mp4")
        let tempURL = base.appendingPathExtension("lt-qt.mp4")
        try? fm.removeItem(at: tempURL)

        let duration = await Self.mediaDuration(input, ffmpegPath: ffmpegPath)

        var args: [String] = [
            "-y", "-v", "error", "-nostdin",
            "-progress", "pipe:1", "-nostats",
            "-i", input.path,
            "-map", "0:v:0", "-map", "0:a:0?"
        ]

        if videoOK {
            args += ["-c:v", "copy"]
        } else {
            args += [
                "-c:v", "hevc_videotoolbox",
                "-b:v", Self.bitrate(forHeight: summary.videoHeight),
                "-pix_fmt", "yuv420p",
                "-tag:v", "hvc1"
            ]
        }

        if videoCodec == "hevc" {
            args += ["-tag:v", "hvc1"]
        }

        if audioOK {
            args += ["-c:a", "copy"]
        } else {
            args += ["-c:a", "aac", "-b:a", "192k"]
        }

        args += ["-movflags", "+faststart", tempURL.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
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
            try? fm.removeItem(at: tempURL)
            return input
        }

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                guard line.hasPrefix("out_time_us="), duration > 0 else { continue }
                guard let microseconds = Double(line.dropFirst("out_time_us=".count)),
                      microseconds > 0 else { continue }
                let ratio = min(max(microseconds / 1_000_000 / duration, 0), 1)
                task.progress = ratio
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
            return input
        }

        guard process.terminationStatus == 0,
              fm.fileExists(atPath: tempURL.path) else {
            try? fm.removeItem(at: tempURL)
            task.warning = l10n.t("warning.compatibility")
            return input
        }

        do {
            let isSameFile = output.standardizedFileURL == input.standardizedFileURL
            if !isSameFile {
                try? fm.removeItem(at: output)
            }
            try fm.removeItem(at: input)
            try fm.moveItem(at: tempURL, to: output)
            return output
        } catch {
            try? fm.removeItem(at: tempURL)
            return input
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
