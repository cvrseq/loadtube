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
