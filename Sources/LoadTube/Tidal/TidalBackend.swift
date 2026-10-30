import Foundation

/// Скачивание треков и видео Tidal: playbackinfo → манифест → файл →
/// расшифровка → обложка/теги. Работает на главном акторе, сеть и ffmpeg
/// асинхронные, поэтому UI не блокируется.
@MainActor
final class TidalBackend {
    let ffmpegPath: String
    private var albumCache: [Int: TidalAlbum] = [:]
    private var subscription: TidalSubscriptionResponse?
    private var subscriptionLoaded = false
    private var subscriptionUserID: Int?

    init(ffmpegPath: String) {
        self.ffmpegPath = ffmpegPath
    }

    // MARK: - Трек

    func downloadTrack(
        _ track: TidalTrack,
        album: TidalAlbum?,
        playlist: TidalPlaylist?,
        mixTitle: String?,
        isSingle: Bool,
        position: Int?,
        totalTracks: Int,
        root: URL,
        task: DownloadTask
    ) async throws {
        guard track.idValue > 0 else { throw TidalError.unavailable }
        if await isFreeAccount() { throw TidalError.playbackNotAllowed }

        let fullAlbum = await fullAlbum(album ?? track.album)
        let resolved = try await resolveTrackStream(trackID: track.idValue, task: task)
        var stream = resolved.stream
        let actualQuality = qualityLabel(resolved.response)

        let finalURL = TidalPathBuilder.trackURL(
            track: track,
            album: fullAlbum,
            playlist: playlist,
            mixTitle: mixTitle,
            root: root,
            fileExtension: stream.fileExtension,
            style: TidalPreferences.folderStyle,
            isSingle: isSingle,
            position: position
        )

        task.actualQuality = actualQuality
        task.thumbnailURL = TidalConfig.coverURL(fullAlbum?.cover ?? track.album?.cover)

        if TidalPreferences.skipExisting,
           FileManager.default.fileExists(atPath: finalURL.path),
           Self.fileSize(finalURL) > 0 {
            task.wasSkipped = true
            task.progress = 1
            task.outputURL = finalURL
            task.detail = Localization.shared.t("tidal.detail.alreadyExists")
            return
        }

        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var downloaded = false
        for attempt in 0..<2 {
            do {
                try await downloadStream(stream, to: finalURL, task: task)
                downloaded = true
                break
            } catch let error as TidalHTTPError where (error.status == 403 || error.status == 410) && attempt == 0 {
                // Ссылка на CDN живёт недолго: получаем playbackinfo заново.
                stream = try await resolveTrackStream(trackID: track.idValue, task: task).stream
            } catch TidalError.network where attempt == 0 {
                // Короткий обрыв сети — пробуем тот же поток ещё раз.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard downloaded else { throw TidalError.unavailable }
        if task.cancelled { throw TidalError.cancelled }

        let cover = await coverFile(
            album: fullAlbum ?? track.album,
            directory: directory,
            isSingle: isSingle,
            saveSidecar: playlist == nil && mixTitle == nil,
            task: task
        )

        if task.cancelled { throw TidalError.cancelled }

        var lyricsText = ""
        if let lyrics = try? await TidalAPI.shared.lyrics(trackID: track.idValue) {
            lyricsText = lyrics.subtitles ?? lyrics.lyrics ?? ""
            if TidalPreferences.saveLyrics, !lyricsText.isEmpty {
                let lrc = TidalPathBuilder.lyricsFile(for: finalURL)
                try? lyricsText.write(to: lrc, atomically: true, encoding: .utf8)
            }
        }

        if task.cancelled { throw TidalError.cancelled }
        task.detail = Localization.shared.t("tidal.detail.tags")
        let numberingTotal = totalTracks > 1
            ? totalTracks
            : (fullAlbum?.numberOfTracks ?? totalTracks)
        await tag(
            file: finalURL,
            track: track,
            album: fullAlbum ?? track.album,
            playlist: playlist,
            position: position,
            totalTracks: numberingTotal,
            cover: cover,
            lyrics: lyricsText,
            task: task
        )

        if let cover, cover.path.contains(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: cover)
        }

        task.outputURL = finalURL
        task.progress = 1
        task.detail = Localization.shared.t("detail.finished")
    }

    // MARK: - Видео

    func downloadVideo(
        _ video: TidalVideo,
        album: TidalAlbum?,
        playlist: TidalPlaylist?,
        mixTitle: String?,
        isSingle: Bool,
        position: Int?,
        root: URL,
        task: DownloadTask
    ) async throws {
        guard video.idValue > 0 else { throw TidalError.unavailable }
        if await isFreeAccount() { throw TidalError.playbackNotAllowed }

        let response = try await TidalAPI.shared.videoPlayback(videoID: video.idValue)
        guard let mime = response.manifestMimeType, let manifest = response.manifest else {
            throw TidalError.manifestUnsupported
        }
        let stream = try TidalManifestParser.parse(
            mimeType: mime,
            manifest: manifest,
            quality: response.videoQuality
        )

        let masterURL: URL
        switch stream {
        case .hls(let url):
            masterURL = url
        case .file(let urls, _, _):
            guard let first = urls.first else { throw TidalError.manifestUnsupported }
            masterURL = first
        case .segments:
            throw TidalError.manifestUnsupported
        }

        let selected = await selectHLSVariant(masterURL)
        let finalURL = TidalPathBuilder.videoURL(
            video: video,
            album: album,
            playlist: playlist,
            mixTitle: mixTitle,
            root: root,
            style: TidalPreferences.folderStyle,
            isSingle: isSingle,
            position: position
        )
        task.actualQuality = selected.height > 0 ? "\(selected.height)p" : (response.videoQuality ?? "Video")
        task.thumbnailURL = TidalConfig.coverURL(video.imageID)

        if TidalPreferences.skipExisting,
           FileManager.default.fileExists(atPath: finalURL.path),
           Self.fileSize(finalURL) > 0 {
            task.wasSkipped = true
            task.progress = 1
            task.outputURL = finalURL
            task.detail = Localization.shared.t("tidal.detail.alreadyExists")
            return
        }

        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        task.state = .downloading
        task.detail = Localization.shared.t("tidal.detail.video")
        task.progress = 0

        let success = await runVideoFFmpeg(
            input: selected.url,
            output: finalURL,
            video: video,
            duration: TimeInterval(video.duration ?? 0),
            task: task,
            useBSF: true
        )
        if task.cancelled { throw TidalError.cancelled }
        if !success {
            let retry = await runVideoFFmpeg(
                input: selected.url,
                output: finalURL,
                video: video,
                duration: TimeInterval(video.duration ?? 0),
                task: task,
                useBSF: false
            )
            if task.cancelled { throw TidalError.cancelled }
            guard retry else {
                try? FileManager.default.removeItem(at: finalURL)
                throw TidalError.unavailable
            }
        }

        task.outputURL = finalURL
        task.progress = 1
        task.detail = Localization.shared.t("detail.finished")
    }

    // MARK: - Поток

    private struct ResolvedStream {
        let stream: TidalStream
        let response: TidalStreamResponse
    }

    private func resolveTrackStream(trackID: Int, task: DownloadTask) async throws -> ResolvedStream {
        var lastError: Error = TidalError.unavailable
        let candidates = TidalPreferences.quality.candidates

        for (index, quality) in candidates.enumerated() {
            var retriedRateLimit = false
            while true {
                if task.cancelled { throw TidalError.cancelled }
                do {
                    let response = try await TidalAPI.shared.playback(trackID: trackID, quality: quality)
                    if (response.assetPresentation ?? "").uppercased() == "PREVIEW"
                        || (response.streamType ?? "").uppercased() == "PREVIEW" {
                        lastError = TidalError.previewOnly
                        break
                    }
                    guard let mime = response.manifestMimeType,
                          let manifest = response.manifest else {
                        lastError = TidalError.manifestUnsupported
                        break
                    }
                    let stream = try TidalManifestParser.parse(
                        mimeType: mime,
                        manifest: manifest,
                        quality: response.audioQuality
                    )
                    if index > 0 {
                        task.warning = Localization.shared.f(
                            "tidal.warning.qualityFallback",
                            qualityLabel(response)
                        )
                    }
                    return ResolvedStream(stream: stream, response: response)
                } catch let error as TidalError {
                    lastError = error
                    if case .sessionExpired = error { throw error }
                    if case .playbackNotAllowed = error { throw error }
                    if case .assetUnavailable = error { throw error }
                    if case .regionLocked = error { throw error }
                    if case .unavailable = error { throw error }
                    if case .rateLimited(let seconds) = error, !retriedRateLimit {
                        retriedRateLimit = true
                        task.detail = Localization.shared.f("tidal.detail.rate", seconds)
                        try await Task.sleep(nanoseconds: UInt64(max(seconds, 5)) * 1_000_000_000)
                        continue
                    }
                    break
                } catch {
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    private func qualityLabel(_ response: TidalStreamResponse) -> String {
        if let bitDepth = response.bitDepth, let sampleRate = response.sampleRate, sampleRate > 0 {
            return "FLAC \(bitDepth)/\(sampleRate / 1000)"
        }
        switch (response.audioQuality ?? "").uppercased() {
        case "HI_RES_LOSSLESS": return "FLAC 24-bit"
        case "HI_RES": return "MQA 24-bit"
        case "LOSSLESS": return "FLAC"
        case "HIGH": return "AAC 320"
        case "LOW": return "AAC 96"
        default: return response.audioQuality ?? "Tidal"
        }
    }

    // MARK: - Скачивание файла

    private func downloadStream(
        _ stream: TidalStream,
        to finalURL: URL,
        task: DownloadTask
    ) async throws {
        let directory = finalURL.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".loadtube-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: temp) }

        task.state = .downloading
        task.progress = 0
        task.detail = Localization.shared.t("tidal.detail.downloading")

        switch stream {
        case .file(let urls, _, let encryptionKey):
            try await downloadMirrors(urls, to: temp, task: task)
            if let encryptionKey, !encryptionKey.isEmpty {
                task.detail = Localization.shared.t("tidal.detail.decrypt")
                let decrypted = directory.appendingPathComponent(".loadtube-\(UUID().uuidString).dec")
                defer { try? FileManager.default.removeItem(at: decrypted) }
                let credentials = try TidalCrypto.securityToken(encryptionKey)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try TidalCrypto.decryptFile(
                            input: temp,
                            output: decrypted,
                            key: credentials.key,
                            nonce: credentials.nonce
                        ) { fraction in
                            Task { @MainActor [weak task] in
                                task?.progress = 0.9 + fraction * 0.08
                            }
                        }
                    }.value
                } catch {
                    throw TidalError.decryptionFailed
                }
                try replaceFile(at: finalURL, with: decrypted)
            } else {
                try replaceFile(at: finalURL, with: temp)
            }

        case .segments(let urls, let codec):
            let raw = directory.appendingPathComponent(".loadtube-\(UUID().uuidString).seg")
            defer { try? FileManager.default.removeItem(at: raw) }
            try await downloadSegments(urls, to: raw, task: task)
            if codec.lowercased().contains("flac") {
                try replaceFile(at: finalURL, with: raw)
            } else {
                task.detail = Localization.shared.t("detail.converting")
                let remuxed = directory.appendingPathComponent(".loadtube-\(UUID().uuidString).remux")
                defer { try? FileManager.default.removeItem(at: remuxed) }
                let result = await ProcessRunner.run(
                    executable: ffmpegPath,
                    arguments: [
                        "-y", "-v", "error", "-nostdin",
                        "-i", raw.path,
                        "-c", "copy",
                        "-movflags", "+faststart",
                        remuxed.path
                    ],
                    environment: Self.environment()
                )
                if result.code == 0, FileManager.default.fileExists(atPath: remuxed.path) {
                    try replaceFile(at: finalURL, with: remuxed)
                } else {
                    task.warning = Localization.shared.t("tidal.warning.remux")
                    try replaceFile(at: finalURL, with: raw)
                }
            }

        case .hls:
            throw TidalError.manifestUnsupported
        }
    }

    private func downloadMirrors(
        _ urls: [URL],
        to destination: URL,
        task: DownloadTask
    ) async throws {
        var lastError: Error = TidalError.unavailable
        for url in urls {
            let downloader = TidalFileDownloader()
            task.cancelNetwork = { [weak downloader] in downloader?.cancel() }
            var lastBytes: Int64 = 0
            var lastDate = Date()

            downloader.onProgress = { written, total in
                Task { @MainActor [weak task] in
                    guard let task, task.state == .downloading else { return }
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastDate)
                    if elapsed >= 0.25 {
                        let delta = written - lastBytes
                        let speed = Double(delta) / elapsed
                        task.speed = Self.formatSpeed(speed)
                        if total > 0 {
                            let remaining = total - written
                            task.eta = Self.formatETA(speed > 0 ? Double(remaining) / speed : 0)
                            task.progress = min(Double(written) / Double(total) * 0.9, 0.9)
                        }
                        lastBytes = written
                        lastDate = now
                    }
                }
            }

            do {
                try await downloader.download(url, to: destination, headers: ["User-Agent": TidalConfig.userAgent])
                task.cancelNetwork = nil
                task.speed = ""
                task.eta = ""
                return
            } catch TidalError.cancelled {
                throw TidalError.cancelled
            } catch {
                lastError = error
                task.cancelNetwork = nil
                continue
            }
        }
        throw lastError
    }

    private func downloadSegments(
        _ urls: [URL],
        to destination: URL,
        task: DownloadTask
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw TidalError.network("Не удалось создать файл")
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        let start = Date()

        for (index, url) in urls.enumerated() {
            if task.cancelled { throw TidalError.cancelled }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TidalHTTPError(status: http.statusCode)
            }
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            let fraction = Double(index + 1) / Double(max(urls.count, 1))
            task.progress = min(fraction * 0.9, 0.9)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0 {
                task.speed = Self.formatSpeed(Double(written) / elapsed)
            }
        }
        task.speed = ""
        task.eta = ""
    }

    // MARK: - Обложка и теги

    private func coverFile(
        album: TidalAlbum?,
        directory: URL,
        isSingle: Bool,
        saveSidecar: Bool,
        task: DownloadTask
    ) async -> URL? {
        guard let coverID = album?.cover, !coverID.isEmpty,
              let url = TidalConfig.coverURL(coverID, width: 1280, height: 1280) else {
            return nil
        }

        let sidecar = TidalPathBuilder.coverFile(in: directory)
        if saveSidecar, !isSingle, TidalPreferences.saveCover,
           FileManager.default.fileExists(atPath: sidecar.path) {
            return sidecar
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }

            if saveSidecar, !isSingle, TidalPreferences.saveCover {
                try? data.write(to: sidecar)
                return sidecar
            }

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("loadtube-tidal-cover-\(UUID().uuidString).jpg")
            try? data.write(to: temp)
            return temp
        } catch {
            return nil
        }
    }

    private func tag(
        file: URL,
        track: TidalTrack,
        album: TidalAlbum?,
        playlist: TidalPlaylist?,
        position: Int?,
        totalTracks: Int,
        cover: URL?,
        lyrics: String,
        task: DownloadTask
    ) async {
        guard !ffmpegPath.isEmpty else {
            task.warning = Localization.shared.t("tidal.warning.tags")
            return
        }

        let ext = file.pathExtension
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".loadtube-tag-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: temp)

        var arguments: [String] = [
            "-y", "-v", "error", "-nostdin",
            "-i", file.path
        ]
        if let cover {
            arguments += ["-i", cover.path, "-map", "0:a", "-map", "1:v", "-c:v", "copy", "-disposition:v", "attached_pic", "-c:a", "copy"]
        } else {
            arguments += ["-map", "0:a", "-c", "copy"]
        }

        let number = position ?? track.trackNumber ?? 0
        let total = max(totalTracks, number)
        let trackValue = total > 0 ? "\(number)/\(total)" : "\(number)"
        let discValue = "\(track.volumeNumber ?? 1)/\(album?.numberOfVolumes ?? 1)"

        let metadata: [(String, String?)] = [
            ("title", track.displayTitle),
            ("artist", track.artistsDisplay),
            ("album", (album ?? track.album)?.displayTitle),
            ("album_artist", (album ?? track.album)?.artistsDisplay),
            ("track", trackValue),
            ("disc", discValue),
            ("date", (album ?? track.album)?.releaseDate),
            ("isrc", track.isrc),
            ("copyright", track.copyright),
            ("lyrics", lyrics.isEmpty ? nil : lyrics),
            ("comment", "TIDAL:\(track.idValue)")
        ]

        for (key, value) in metadata {
            guard let value, !value.isEmpty else { continue }
            arguments += ["-metadata", "\(key)=\(value)"]
        }

        arguments += ["-map_metadata", "0", temp.path]

        let result = await ProcessRunner.run(
            executable: ffmpegPath,
            arguments: arguments,
            environment: Self.environment()
        )
        guard result.code == 0, FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            task.warning = Localization.shared.t("tidal.warning.tags")
            return
        }

        do {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            task.warning = Localization.shared.t("tidal.warning.tags")
        }
    }

    // MARK: - Видео: HLS и ffmpeg

    private func selectHLSVariant(_ masterURL: URL) async -> TidalHLSVariant {
        guard masterURL.pathExtension.lowercased() == "m3u8" else {
            return TidalHLSVariant(height: 0, bandwidth: 0, url: masterURL)
        }
        do {
            var request = URLRequest(url: masterURL)
            request.timeoutInterval = 20
            request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else {
                return TidalHLSVariant(height: 0, bandwidth: 0, url: masterURL)
            }
            let variants = TidalHLS.variants(from: text, baseURL: masterURL)
            if let best = TidalHLS.bestVariant(
                from: variants,
                maxHeight: TidalPreferences.videoQuality.height
            ) {
                return best
            }
        } catch {
            // Если не удалось разобрать master-плейлист, ffmpeg справится сам.
        }
        return TidalHLSVariant(height: 0, bandwidth: 0, url: masterURL)
    }

    private func runVideoFFmpeg(
        input: URL,
        output: URL,
        video: TidalVideo,
        duration: TimeInterval,
        task: DownloadTask,
        useBSF: Bool
    ) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var arguments = [
            "-y", "-v", "error", "-nostdin",
            "-progress", "pipe:1", "-nostats",
            "-user_agent", TidalConfig.userAgent,
            "-i", input.absoluteString,
            "-c", "copy"
        ]
        if useBSF {
            arguments += ["-bsf:a", "aac_adtstoasc"]
        }
        arguments += [
            "-movflags", "+faststart",
            "-metadata", "title=\(video.displayTitle)",
            "-metadata", "artist=\(video.artistsDisplay)",
            output.path
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
            return false
        }

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if task.cancelled { break }
                if line.hasPrefix("out_time_us="), duration > 0 {
                    if let microseconds = Double(line.dropFirst("out_time_us=".count)),
                       microseconds > 0 {
                        let fraction = min(microseconds / 1_000_000 / duration, 1)
                        task.progress = max(task.progress, fraction)
                    }
                }
            }
        } catch {
            // Пайп закрылся.
        }

        while process.isRunning {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        task.process = nil

        if task.cancelled {
            return false
        }
        return process.terminationStatus == 0 && fm.fileExists(atPath: output.path)
    }

    // MARK: - Вспомогательное

    private func replaceFile(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: source, to: destination)
    }

    /// Проверяем тариф один раз за сессию, чтобы Free-аккаунт получал
    /// понятное сообщение, а не 401/4005.
    private func isFreeAccount() async -> Bool {
        let userID = TidalService.shared.account?.userId
        if subscriptionLoaded, subscriptionUserID == userID {
            return subscription?.isFree ?? false
        }
        if let value = try? await TidalAPI.shared.subscription() {
            subscription = value
            subscriptionUserID = userID
            subscriptionLoaded = true
            return value.isFree
        }
        return false
    }

    /// В playlist/mix API отдаёт альбом частично (id, title, cover).
    /// Догружаем полные метаданные, чтобы теги и год были корректными.
    private func fullAlbum(_ album: TidalAlbum?) async -> TidalAlbum? {
        guard let album, let id = album.id else { return album }
        if !(album.artists?.isEmpty ?? true), album.releaseDate != nil {
            return album
        }
        if let cached = albumCache[id] {
            return cached
        }
        if let full = try? await TidalAPI.shared.album(id) {
            albumCache[id] = full
            return full
        }
        return album
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
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

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
            + Localization.shared.t("speed.suffix")
    }

    private static func formatETA(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        let value = Int(seconds)
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
