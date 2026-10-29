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
    let source: MediaSource

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

    // Tidal
    @Published var isCollection: Bool = false
    @Published var children: [DownloadTask] = []
    @Published var totalCount: Int = 0
    @Published var completedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var actualQuality: String?
    @Published var wasSkipped: Bool = false
    @Published var isTidalCollectionPreparing: Bool = false

    var tidalTrack: TidalTrack?
    var tidalVideo: TidalVideo?
    var tidalAlbum: TidalAlbum?
    var tidalPlaylist: TidalPlaylist?
    var tidalMixTitle: String?
    var tidalIsSingle: Bool = false
    var tidalPosition: Int?
    var tidalTotalTracks: Int = 0

    // Внутреннее состояние процесса
    var process: Process?
    var cancelNetwork: (() -> Void)?
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
        isSpotify: Bool = false,
        source: MediaSource? = nil
    ) {
        self.url = url
        self.preset = preset
        self.allowPlaylist = allowPlaylist
        self.folder = folder
        self.isSpotify = isSpotify
        self.source = source ?? MediaSource.detect(url)
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

    var isTidal: Bool { source == .tidal }

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
        cancelNetwork = nil
        destinationStem = nil
        lastError = nil
        searchQuery = nil
        spotifyFileBase = nil
        spotifyTitle = nil
        spotifyArtist = nil
        spotifyArtwork = nil

        children = []
        totalCount = 0
        completedCount = 0
        failedCount = 0
        actualQuality = nil
        wasSkipped = false
        isTidalCollectionPreparing = false
        isCollection = false
        tidalTrack = nil
        tidalVideo = nil
        tidalAlbum = nil
        tidalPlaylist = nil
        tidalMixTitle = nil
        tidalIsSingle = false
        tidalPosition = nil
        tidalTotalTracks = 0
    }

    func cancel() {
        cancelled = true
        process?.terminate()
        process = nil
        cancelNetwork?()
        cancelNetwork = nil
        for child in children {
            child.cancel()
        }
    }
}
