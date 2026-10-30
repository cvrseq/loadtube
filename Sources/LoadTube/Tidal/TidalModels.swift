import Foundation

// MARK: - Качество

enum TidalQuality: String, CaseIterable, Identifiable, Codable {
    case auto
    case max
    case hifi
    case high
    case normal

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .auto: return "tidal.quality.auto"
        case .max: return "tidal.quality.max"
        case .hifi: return "tidal.quality.hifi"
        case .high: return "tidal.quality.high"
        case .normal: return "tidal.quality.normal"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "Auto"
        case .max: return "Max"
        case .hifi: return "HiFi"
        case .high: return "High"
        case .normal: return "Normal"
        }
    }

    /// Качества в порядке убывания: если тариф не позволяет Max, пробуем ниже.
    var candidates: [String] {
        switch self {
        case .auto, .max:
            return ["HI_RES_LOSSLESS", "HI_RES", "LOSSLESS", "HIGH", "LOW"]
        case .hifi:
            return ["LOSSLESS", "HIGH", "LOW"]
        case .high:
            return ["HIGH", "LOW"]
        case .normal:
            return ["LOW"]
        }
    }

    static func current() -> TidalQuality {
        let raw = UserDefaults.standard.string(forKey: "tidalQuality") ?? ""
        return TidalQuality(rawValue: raw) ?? .auto
    }
}

enum TidalVideoQuality: String, CaseIterable, Identifiable, Codable {
    case p1080
    case p720
    case p480
    case p360

    var id: String { rawValue }

    var height: Int {
        switch self {
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }

    var title: String {
        switch self {
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }

    static func current() -> TidalVideoQuality {
        let raw = UserDefaults.standard.string(forKey: "tidalVideoQuality") ?? ""
        return TidalVideoQuality(rawValue: raw) ?? .p1080
    }
}

enum TidalFolderStyle: String, CaseIterable, Identifiable, Codable {
    case organized
    case flat

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .organized: return "tidal.folder.organized"
        case .flat: return "tidal.folder.flat"
        }
    }

    static func current() -> TidalFolderStyle {
        let raw = UserDefaults.standard.string(forKey: "tidalFolderStyle") ?? ""
        return TidalFolderStyle(rawValue: raw) ?? .organized
    }
}

// MARK: - Ошибки

enum TidalError: LocalizedError {
    case notSignedIn
    case sessionExpired
    case unavailable
    case regionLocked
    case planRequired
    case playbackNotAllowed
    case assetUnavailable
    case previewOnly
    case rateLimited(seconds: Int)
    case network(String)
    case server(String)
    case manifestUnsupported
    case decryptionFailed
    case noTracks
    case searchFailed
    case cancelled
    case pendingAuthorization
    case slowDown

    /// Ключ локализации. Сообщение формируется на UI-слое.
    var key: String {
        switch self {
        case .notSignedIn: return "error.tidalNotSignedIn"
        case .sessionExpired: return "error.tidalSession"
        case .unavailable: return "error.tidalUnavailable"
        case .regionLocked: return "error.tidalRegion"
        case .planRequired: return "error.tidalPlan"
        case .playbackNotAllowed: return "error.tidalPlayback"
        case .assetUnavailable: return "error.tidalAsset"
        case .previewOnly: return "error.tidalPreview"
        case .rateLimited: return "error.tidalRate"
        case .network: return "error.network"
        case .server: return "error.tidalServer"
        case .manifestUnsupported: return "error.tidalManifest"
        case .decryptionFailed: return "error.tidalCrypto"
        case .noTracks: return "error.tidalNoTracks"
        case .searchFailed: return "error.tidalSearch"
        case .cancelled: return "row.cancelled"
        case .pendingAuthorization: return "tidal.login.waiting"
        case .slowDown: return "tidal.login.waiting"
        }
    }

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .server(let message): return message
        case .rateLimited(let seconds): return "Tidal rate limit, retry in \(seconds)s"
        default: return key
        }
    }
}

// MARK: - Модели API

struct TidalArtist: Codable, Identifiable, Hashable {
    let id: Int?
    let name: String?
    let picture: String?
    let type: String?

    var displayName: String { name ?? "Unknown artist" }
}

struct TidalAlbum: Codable, Identifiable, Hashable {
    let id: Int?
    let title: String?
    let duration: Int?
    let numberOfTracks: Int?
    let numberOfVideos: Int?
    let numberOfVolumes: Int?
    let releaseDate: String?
    let type: String?
    let version: String?
    let cover: String?
    let explicit: Bool?
    let audioQuality: String?
    let audioModes: [String]?
    let artist: TidalArtist?
    let artists: [TidalArtist]?
    let image: String?
    let imageID: String?

    var displayTitle: String { title ?? "Unknown album" }
    var artistsDisplay: String {
        let names = (artists ?? (artist.map { [$0] } ?? [])).compactMap(\.name)
        return names.joined(separator: ", ")
    }
    var year: String {
        guard let releaseDate, releaseDate.count >= 4 else { return "" }
        return String(releaseDate.prefix(4))
    }
}

struct TidalPlaylist: Codable, Identifiable, Hashable {
    let uuid: String?
    let title: String?
    let numberOfTracks: Int?
    let numberOfVideos: Int?
    let description: String?
    let duration: Int?
    let image: String?
    let squareImage: String?

    var id: String { uuid ?? title ?? "playlist" }
    var displayTitle: String { title ?? "Playlist" }
}

struct TidalTrack: Codable, Identifiable, Hashable {
    let id: Int?
    let title: String?
    let duration: Int?
    let trackNumber: Int?
    let volumeNumber: Int?
    let trackNumberOnPlaylist: Int?
    let version: String?
    let isrc: String?
    let explicit: Bool?
    let audioQuality: String?
    let copyright: String?
    let artist: TidalArtist?
    let artists: [TidalArtist]?
    let album: TidalAlbum?
    let allowStreaming: Bool?
    let streamReady: Bool?
    let editable: Bool?
    let replayGain: Double?
    let peak: Double?
    let url: String?

    var idValue: Int { id ?? 0 }
    var displayTitle: String {
        guard let version, !version.isEmpty else { return title ?? "Track" }
        return "\(title ?? "Track") (\(version))"
    }
    var artistsDisplay: String {
        let names = (artists ?? (artist.map { [$0] } ?? [])).compactMap(\.name)
        return names.joined(separator: ", ")
    }
    var isAvailable: Bool {
        (streamReady ?? true) && (allowStreaming ?? true)
    }
}

struct TidalVideo: Codable, Identifiable, Hashable {
    let id: Int?
    let title: String?
    let duration: Int?
    let imageID: String?
    let imagePath: String?
    let trackNumber: Int?
    let releaseDate: String?
    let version: String?
    let quality: String?
    let explicit: Bool?
    let artist: TidalArtist?
    let artists: [TidalArtist]?
    let album: TidalAlbum?
    let allowStreaming: Bool?
    let streamReady: Bool?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case duration
        case imageID = "imageId"
        case imagePath
        case trackNumber
        case releaseDate
        case version
        case quality
        case explicit
        case artist
        case artists
        case album
        case allowStreaming
        case streamReady
        case url
    }

    var idValue: Int { id ?? 0 }
    var displayTitle: String {
        guard let version, !version.isEmpty else { return title ?? "Video" }
        return "\(title ?? "Video") (\(version))"
    }
    var artistsDisplay: String {
        let names = (artists ?? (artist.map { [$0] } ?? [])).compactMap(\.name)
        return names.joined(separator: ", ")
    }
    var isAvailable: Bool {
        (streamReady ?? true) && (allowStreaming ?? true)
    }
}

struct TidalMix: Codable, Identifiable, Hashable {
    let id: String?
    let title: String?
    let subTitle: String?
    let description: String?
    let image: String?
    let squareImage: String?

    var displayTitle: String { title ?? subTitle ?? "Tidal Mix" }
}

struct TidalItem: Decodable {
    let type: String
    let track: TidalTrack?
    let video: TidalVideo?

    enum CodingKeys: String, CodingKey {
        case type
        case item
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        if type == "video" {
            video = try? container.decodeIfPresent(TidalVideo.self, forKey: .item)
            track = nil
        } else {
            track = try? container.decodeIfPresent(TidalTrack.self, forKey: .item)
            video = nil
        }
    }
}

struct TidalItemPage: Decodable {
    let items: [TidalItem]?
    let totalNumberOfItems: Int?
}

struct TidalAlbumPage: Decodable {
    let items: [TidalAlbum]?
    let totalNumberOfItems: Int?
}

struct TidalPlaylistPage: Decodable {
    let items: [TidalPlaylist]?
    let totalNumberOfItems: Int?
}

struct TidalMixPage: Decodable {
    let items: [TidalMix]?
    let totalNumberOfItems: Int?
}

struct TidalSearchPage<T: Decodable>: Decodable {
    let limit: Int?
    let offset: Int?
    let totalNumberOfItems: Int?
    let items: [T]?
}

struct TidalSearchResult: Decodable {
    let artists: TidalSearchPage<TidalArtist>?
    let albums: TidalSearchPage<TidalAlbum>?
    let tracks: TidalSearchPage<TidalTrack>?
    let videos: TidalSearchPage<TidalVideo>?
    let playlists: TidalSearchPage<TidalPlaylist>?
    let mixes: TidalSearchPage<TidalMix>?
}

struct TidalStreamResponse: Decodable {
    let trackId: Int?
    let videoId: Int?
    let streamType: String?
    let assetPresentation: String?
    let audioMode: String?
    let audioQuality: String?
    let videoQuality: String?
    let manifestMimeType: String?
    let manifest: String?
    let bitDepth: Int?
    let sampleRate: Int?

    enum CodingKeys: String, CodingKey {
        case trackId = "trackid"
        case videoId = "videoid"
        case streamType
        case assetPresentation
        case audioMode
        case audioQuality
        case videoQuality
        case manifestMimeType
        case manifest
        case bitDepth
        case sampleRate
    }
}

struct TidalLyrics: Decodable {
    let trackId: Int?
    let lyricsProvider: String?
    let lyrics: String?
    let subtitles: String?
}

struct TidalBSMessage: Decodable {
    let codecs: String?
    let mimeType: String?
    let urls: [String]?
    let keyId: String?
    let encryptionKey: String?
}

struct TidalSessionInfo: Decodable {
    let userId: Int?
    let countryCode: String?
    let sessionId: String?
    let partnerId: Int?
}

struct TidalSubscriptionResponse: Decodable {
    let status: String?
    let subscription: Plan?
    let premiumAccess: Bool?
    let highestSoundQuality: String?
    let paymentOverdue: Bool?

    struct Plan: Decodable {
        let type: String?
    }

    var isFree: Bool {
        if premiumAccess == false { return true }
        return (subscription?.type ?? "").uppercased() == "FREE"
    }

    var planName: String {
        subscription?.type ?? status ?? "TIDAL"
    }
}

// MARK: - Резолв ссылки

enum TidalResolved {
    case track(TidalTrack)
    case album(TidalAlbum)
    case playlist(TidalPlaylist)
    case artist(TidalArtist)
    case mix(TidalMix)
    case video(TidalVideo)

    var preview: TidalPreview {
        switch self {
        case .track(let track):
            return TidalPreview(
                kind: .track,
                id: String(track.idValue),
                title: track.displayTitle,
                subtitle: track.artistsDisplay,
                artwork: TidalConfig.coverURL(track.album?.cover),
                count: nil,
                quality: track.audioQuality
            )
        case .album(let album):
            return TidalPreview(
                kind: .album,
                id: String(album.id ?? 0),
                title: album.displayTitle,
                subtitle: album.artistsDisplay,
                artwork: TidalConfig.coverURL(album.cover),
                count: album.numberOfTracks,
                quality: album.audioQuality
            )
        case .playlist(let playlist):
            return TidalPreview(
                kind: .playlist,
                id: playlist.uuid ?? "",
                title: playlist.displayTitle,
                subtitle: playlist.description ?? "",
                artwork: TidalConfig.coverURL(playlist.squareImage ?? playlist.image),
                count: playlist.numberOfTracks,
                quality: nil
            )
        case .artist(let artist):
            return TidalPreview(
                kind: .artist,
                id: String(artist.id ?? 0),
                title: artist.displayName,
                subtitle: "",
                artwork: TidalConfig.coverURL(artist.picture),
                count: nil,
                quality: nil
            )
        case .mix(let mix):
            return TidalPreview(
                kind: .mix,
                id: mix.id ?? "",
                title: mix.displayTitle,
                subtitle: mix.subTitle ?? mix.description ?? "Mix",
                artwork: TidalConfig.coverURL(mix.squareImage ?? mix.image),
                count: nil,
                quality: nil
            )
        case .video(let video):
            return TidalPreview(
                kind: .video,
                id: String(video.idValue),
                title: video.displayTitle,
                subtitle: video.artistsDisplay,
                artwork: TidalConfig.coverURL(video.imageID),
                count: nil,
                quality: video.quality
            )
        }
    }
}

enum TidalItemKind: String, Codable, CaseIterable, Identifiable {
    case track
    case album
    case playlist
    case artist
    case mix
    case video

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .track: return "tidal.kind.track"
        case .album: return "tidal.kind.album"
        case .playlist: return "tidal.kind.playlist"
        case .artist: return "tidal.kind.artist"
        case .mix: return "tidal.kind.mix"
        case .video: return "tidal.kind.video"
        }
    }

    var searchType: String {
        switch self {
        case .track: return "TRACKS"
        case .album: return "ALBUMS"
        case .playlist: return "PLAYLISTS"
        case .artist: return "ARTISTS"
        case .mix: return "PLAYLISTS"
        case .video: return "VIDEOS"
        }
    }

    static var searchCases: [TidalItemKind] {
        [.track, .album, .playlist, .artist, .video]
    }
}

struct TidalPreview {
    let kind: TidalItemKind
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    let count: Int?
    let quality: String?
}

struct TidalDeviceLogin {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: Int
    let credentialIndex: Int
}

struct TidalAccount {
    let userId: Int
    let countryCode: String
    let credentialIndex: Int

    var display: String {
        "\(countryCode) · ID \(userId)"
    }
}

struct TidalSession: Codable {
    var userId: Int
    var countryCode: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: TimeInterval
    var credentialIndex: Int
    var sessionId: String? = nil

    var isExpired: Bool {
        expiresAt > 0 && Date().timeIntervalSince1970 >= expiresAt - 60
    }

    var account: TidalAccount {
        TidalAccount(userId: userId, countryCode: countryCode, credentialIndex: credentialIndex)
    }
}

// MARK: - Поиск

enum TidalSearchItem: Identifiable {
    case track(TidalTrack)
    case album(TidalAlbum)
    case playlist(TidalPlaylist)
    case artist(TidalArtist)
    case mix(TidalMix)
    case video(TidalVideo)

    var id: String {
        switch self {
        case .track(let item): return "track-\(item.idValue)"
        case .album(let item): return "album-\(item.id ?? 0)"
        case .playlist(let item): return "playlist-\(item.uuid ?? item.title ?? "unknown")"
        case .artist(let item): return "artist-\(item.id ?? 0)"
        case .mix(let item): return "mix-\(item.id ?? item.title ?? "unknown")"
        case .video(let item): return "video-\(item.idValue)"
        }
    }

    var kind: TidalItemKind {
        switch self {
        case .track: return .track
        case .album: return .album
        case .playlist: return .playlist
        case .artist: return .artist
        case .mix: return .mix
        case .video: return .video
        }
    }

    var title: String {
        switch self {
        case .track(let item): return item.displayTitle
        case .album(let item): return item.displayTitle
        case .playlist(let item): return item.displayTitle
        case .artist(let item): return item.displayName
        case .mix(let item): return item.displayTitle
        case .video(let item): return item.displayTitle
        }
    }

    var subtitle: String {
        switch self {
        case .track(let item): return item.artistsDisplay
        case .album(let item): return item.artistsDisplay
        case .playlist(let item): return item.description ?? ""
        case .artist: return ""
        case .mix(let item): return item.subTitle ?? ""
        case .video(let item): return item.artistsDisplay
        }
    }

    var artwork: URL? {
        switch self {
        case .track(let item): return TidalConfig.coverURL(item.album?.cover, width: 320, height: 320)
        case .album(let item): return TidalConfig.coverURL(item.cover, width: 320, height: 320)
        case .playlist(let item): return TidalConfig.coverURL(item.squareImage ?? item.image, width: 320, height: 320)
        case .artist(let item): return TidalConfig.coverURL(item.picture, width: 320, height: 320)
        case .mix(let item): return TidalConfig.coverURL(item.squareImage ?? item.image, width: 320, height: 320)
        case .video(let item): return TidalConfig.coverURL(item.imageID, width: 320, height: 320)
        }
    }

    var url: String {
        switch self {
        case .track(let item): return "https://tidal.com/browse/track/\(item.idValue)"
        case .album(let item): return "https://tidal.com/browse/album/\(item.id ?? 0)"
        case .playlist(let item): return "https://tidal.com/browse/playlist/\(item.uuid ?? "")"
        case .artist(let item): return "https://tidal.com/browse/artist/\(item.id ?? 0)"
        case .mix(let item): return "https://tidal.com/browse/mix/\(item.id ?? "")"
        case .video(let item): return "https://tidal.com/browse/video/\(item.idValue)"
        }
    }
}
