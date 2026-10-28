import Foundation
import Combine

/// Одна задача на скачивание. Наблюдается SwiftUI напрямую.
@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let preset: QualityPreset
    let allowPlaylist: Bool
    let folder: URL
    let isSpotify: Bool

    @Published var title: String = "…"
    @Published var thumbnailURL: URL?
    @Published var state: DownloadState = .queued
    @Published var progress: Double = 0
    @Published var speed: String = ""
    @Published var eta: String = ""
    @Published var detail: String = ""
    @Published var outputURL: URL?
    @Published var isPlaylist: Bool = false
    @Published var warning: String?

    // Внутреннее состояние процесса
    var process: Process?
    var cancelled = false
    var destinationStem: String?
    var lastError: String?
    var searchQuery: String?
    var spotifyFileBase: String?
    var spotifyTitle: String?
    var spotifyArtist: String?
    var spotifyArtwork: URL?

    init(
        url: String,
        preset: QualityPreset,
        allowPlaylist: Bool,
        folder: URL,
        isSpotify: Bool = false
    ) {
        self.url = url
        self.preset = preset
        self.allowPlaylist = allowPlaylist
        self.folder = folder
        self.isSpotify = isSpotify
        self.title = Localization.shared.t("row.preparing")
    }

    var isActive: Bool {
        switch state {
        case .preparing, .queued, .downloading, .merging:
            return true
        default:
            return false
        }
    }

    var failedMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func resetForRetry() {
        state = .queued
        progress = 0
        speed = ""
        eta = ""
        detail = ""
        outputURL = nil
        warning = nil
        cancelled = false
        process = nil
        destinationStem = nil
        lastError = nil
        searchQuery = nil
        spotifyFileBase = nil
        spotifyTitle = nil
        spotifyArtist = nil
        spotifyArtwork = nil
    }
}
