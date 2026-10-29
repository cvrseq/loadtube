import Foundation
import SwiftUI

// MARK: - Качество загрузки

enum QualityPreset: String, CaseIterable, Identifiable, Codable {
    case maximum
    case mp4_4k
    case mp4_1080
    case mp3

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .maximum: return "preset.maximum.title"
        case .mp4_4k: return "preset.4k.title"
        case .mp4_1080: return "preset.1080.title"
        case .mp3: return "preset.mp3.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .maximum: return "preset.maximum.subtitle"
        case .mp4_4k: return "preset.4k.subtitle"
        case .mp4_1080: return "preset.1080.subtitle"
        case .mp3: return "preset.mp3.subtitle"
        }
    }

    var icon: String {
        switch self {
        case .maximum: return "sparkles"
        case .mp4_4k: return "4k.tv"
        case .mp4_1080: return "tv"
        case .mp3: return "music.note"
        }
    }

    /// Аргументы yt-dlp для выбранного пресета.
    var arguments: [String] {
        switch self {
        case .maximum:
            return ["-f", "bestvideo*+bestaudio/best"]
        case .mp4_4k:
            return [
                "-f", "bv*[ext=mp4][height<=4320]+ba[ext=m4a]/bv*[height<=4320]+ba/b",
                "--merge-output-format", "mp4"
            ]
        case .mp4_1080:
            return [
                "-f", "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][vcodec^=avc1]/bv*[height<=1080]+ba/b",
                "--merge-output-format", "mp4"
            ]
        case .mp3:
            return [
                "-f", "bestaudio/best",
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "--embed-metadata",
                "--embed-thumbnail"
            ]
        }
    }

    /// Аргументы с учётом источника.
    ///
    /// Instagram и TikTok отдают максимум 1080p, поэтому 4K/1080p-пресеты
    /// для них сводятся к «Максимуму». У TikTok водяной знак есть только
    /// в отдельном формате `download` — его исключаем, остальные
    /// playback-стримы чистые и содержат звук.
    func arguments(for source: MediaSource) -> [String] {
        guard source.isShortVideo else { return arguments }

        switch self {
        case .maximum, .mp4_4k, .mp4_1080:
            return source == .tiktok
                ? ["-f", "b[format_id!=download]"]
                : ["-f", "bv*+ba/b"]
        case .mp3:
            if source == .tiktok {
                // «bestaudio» у TikTok — это только музыкальная дорожка,
                // поэтому берём видео целиком и вытаскиваем из него звук.
                return [
                    "-f", "b[format_id!=download]",
                    "-x",
                    "--audio-format", "mp3",
                    "--audio-quality", "0",
                    "--embed-metadata",
                    "--embed-thumbnail"
                ]
            }
            return arguments
        }
    }
}

// MARK: - Источник ссылки

enum MediaSource: String, Equatable {
    case youtube
    case spotify
    case tidal
    case instagram
    case tiktok

    static func detect(_ string: String) -> MediaSource {
        if TidalLinkParser.isTidalLink(string) { return .tidal }
        if MusicResolver.isSpotifyLink(string) { return .spotify }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host?.lowercased() {
            if host == "instagram.com" || host.hasSuffix(".instagram.com") {
                return .instagram
            }
            if host == "tiktok.com" || host.hasSuffix(".tiktok.com")
                || host.hasSuffix(".tiktokv.com") {
                return .tiktok
            }
        }
        return .youtube
    }

    /// Короткие вертикальные видео: Instagram Reels и TikTok.
    var isShortVideo: Bool {
        self == .instagram || self == .tiktok
    }

    var titleKey: String {
        switch self {
        case .youtube: return "source.youtube"
        case .spotify: return "source.spotify"
        case .tidal: return "source.tidal"
        case .instagram: return "source.instagram"
        case .tiktok: return "source.tiktok"
        }
    }
}

// MARK: - Cookies браузера

/// Откуда брать cookies для Instagram и TikTok.
/// Safari на современных macOS читается только с «Полным доступом к диску»,
/// Chrome может запросить доступ к «Связке ключей», Firefox читается без запросов.
enum CookieBrowser: String, CaseIterable, Identifiable {
    case none
    case safari
    case chrome
    case firefox
    case edge
    case brave

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .none: return "cookies.none"
        case .safari: return "cookies.safari"
        case .chrome: return "cookies.chrome"
        case .firefox: return "cookies.firefox"
        case .edge: return "cookies.edge"
        case .brave: return "cookies.brave"
        }
    }

    /// Значение для `--cookies-from-browser`.
    var ytDlpName: String? {
        self == .none ? nil : rawValue
    }

    /// Файлы cookies браузера (может быть несколько профилей).
    var cookieStoreCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .none:
            return []
        case .safari:
            return [
                "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                "\(home)/Library/Cookies/Cookies.binarycookies"
            ]
        case .chrome:
            return Self.profileStores(
                base: "\(home)/Library/Application Support/Google/Chrome",
                file: "Cookies"
            )
        case .edge:
            return Self.profileStores(
                base: "\(home)/Library/Application Support/Microsoft Edge",
                file: "Cookies"
            )
        case .brave:
            return Self.profileStores(
                base: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser",
                file: "Cookies"
            )
        case .firefox:
            let base = "\(home)/Library/Application Support/Firefox/Profiles"
            let profiles = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
            return profiles.map { "\(base)/\($0)/cookies.sqlite" }
        }
    }

    /// Можно ли прочитать хранилище cookies (без запуска yt-dlp).
    /// Safari защищён TCC: без «Полного доступа к диску» чтение запрещено.
    var isAvailable: Bool {
        for path in cookieStoreCandidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                try? handle.close()
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private static func profileStores(base: String, file: String) -> [String] {
        guard FileManager.default.fileExists(atPath: base) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return items
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") || $0 == "Guest Profile" }
            .map { "\(base)/\($0)/\(file)" }
    }
}

// MARK: - Состояние загрузки

enum DownloadState: Equatable {
    case preparing
    case queued
    case downloading
    case merging
    case finished
    case failed(String)
    case cancelled
}

// MARK: - Тема оформления

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "theme.system"
        case .dark: return "theme.dark"
        case .light: return "theme.light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
