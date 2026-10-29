import Foundation

enum TidalMedia {
    case track(TidalTrack)
    case video(TidalVideo)

    var title: String {
        switch self {
        case .track(let track): return track.displayTitle
        case .video(let video): return video.displayTitle
        }
    }

    var id: String {
        switch self {
        case .track(let track): return String(track.idValue)
        case .video(let video): return String(video.idValue)
        }
    }
}

struct TidalCollectionItem {
    let media: TidalMedia
    let album: TidalAlbum?
    let playlist: TidalPlaylist?
}

struct TidalCollection {
    let title: String
    let artwork: URL?
    let items: [TidalCollectionItem]
}

/// Сетевой слой Tidal. Все запросы идут через один актор, чтобы
/// обновление токена и пагинация не конфликтовали.
actor TidalAPI {
    static let shared = TidalAPI()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 120
            configuration.httpAdditionalHeaders = ["User-Agent": TidalConfig.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Резолв

    func resolve(_ link: TidalLink) async throws -> TidalResolved {
        switch link.kind {
        case .track:
            guard let id = Int(link.id) else { throw TidalError.unavailable }
            return .track(try await track(id))
        case .album:
            guard let id = Int(link.id) else { throw TidalError.unavailable }
            return .album(try await album(id))
        case .playlist:
            return .playlist(try await playlist(link.id))
        case .artist:
            guard let id = Int(link.id) else { throw TidalError.unavailable }
            return .artist(try await artist(id))
        case .mix:
            return .mix(try await mix(link.id))
        case .video:
            guard let id = Int(link.id) else { throw TidalError.unavailable }
            return .video(try await video(id))
        }
    }

    func track(_ id: Int) async throws -> TidalTrack {
        try await request("tracks/\(id)")
    }

    func album(_ id: Int) async throws -> TidalAlbum {
        try await request("albums/\(id)")
    }

    func playlist(_ id: String) async throws -> TidalPlaylist {
        try await request("playlists/\(id)")
    }

    func artist(_ id: Int) async throws -> TidalArtist {
        try await request("artists/\(id)")
    }

    func video(_ id: Int) async throws -> TidalVideo {
        try await request("videos/\(id)")
    }

    func mix(_ id: String) async throws -> TidalMix {
        if let value: TidalMix = try? await request("mixes/\(id)") {
            return value
        }
        return TidalMix(
            id: id,
            title: "Tidal Mix \(id)",
            subTitle: nil,
            description: nil,
            image: nil,
            squareImage: nil
        )
    }

    // MARK: - Коллекции

    func collection(for resolved: TidalResolved) async throws -> TidalCollection {
        switch resolved {
        case .track(let track):
            return TidalCollection(
                title: track.displayTitle,
                artwork: TidalConfig.coverURL(track.album?.cover),
                items: [TidalCollectionItem(media: .track(track), album: track.album, playlist: nil)]
            )
        case .video(let video):
            return TidalCollection(
                title: video.displayTitle,
                artwork: TidalConfig.coverURL(video.imageID),
                items: [TidalCollectionItem(media: .video(video), album: video.album, playlist: nil)]
            )
        case .album(let album):
            let items = try await albumItems(album.id ?? 0)
            return TidalCollection(
                title: album.displayTitle,
                artwork: TidalConfig.coverURL(album.cover),
                items: items.compactMap { item in
                    switch item {
                    case .track(let track):
                        return TidalCollectionItem(
                            media: .track(track),
                            album: album,
                            playlist: nil
                        )
                    case .video(let video):
                        return TidalCollectionItem(
                            media: .video(video),
                            album: album,
                            playlist: nil
                        )
                    }
                }
            )
        case .playlist(let playlist):
            let items = try await playlistItems(playlist.uuid ?? "")
            return TidalCollection(
                title: playlist.displayTitle,
                artwork: TidalConfig.coverURL(playlist.squareImage ?? playlist.image),
                items: items.compactMap { item in
                    switch item {
                    case .track(let track):
                        return TidalCollectionItem(
                            media: .track(track),
                            album: track.album,
                            playlist: playlist
                        )
                    case .video(let video):
                        return TidalCollectionItem(
                            media: .video(video),
                            album: video.album,
                            playlist: playlist
                        )
                    }
                }
            )
        case .mix(let mix):
            let items = try await mixItems(mix.id ?? "")
            return TidalCollection(
                title: mix.displayTitle,
                artwork: TidalConfig.coverURL(mix.squareImage ?? mix.image),
                items: items.compactMap { item in
                    switch item {
                    case .track(let track):
                        return TidalCollectionItem(media: .track(track), album: track.album, playlist: nil)
                    case .video(let video):
                        return TidalCollectionItem(media: .video(video), album: video.album, playlist: nil)
                    }
                }
            )
        case .artist(let artist):
            let albums = try await artistAlbums(artist.id ?? 0)
            var result: [TidalCollectionItem] = []
            for album in albums {
                guard let albumID = album.id else { continue }
                let items = (try? await albumItems(albumID)) ?? []
                for item in items {
                    switch item {
                    case .track(let track):
                        result.append(TidalCollectionItem(
                            media: .track(track),
                            album: album,
                            playlist: nil
                        ))
                    case .video(let video):
                        result.append(TidalCollectionItem(
                            media: .video(video),
                            album: album,
                            playlist: nil
                        ))
                    }
                }
            }
            return TidalCollection(
                title: artist.displayName,
                artwork: TidalConfig.coverURL(artist.picture),
                items: result
            )
        }
    }

    func albumItems(_ id: Int) async throws -> [TidalMedia] {
        try await allItems("albums/\(id)/items").compactMap { item in
            if let track = item.track, track.isAvailable { return .track(track) }
            if let video = item.video, video.isAvailable { return .video(video) }
            return nil
        }
    }

    func playlistItems(_ uuid: String) async throws -> [TidalMedia] {
        try await allItems("playlists/\(uuid)/items").compactMap { item in
            if let track = item.track, track.isAvailable { return .track(track) }
            if let video = item.video, video.isAvailable { return .video(video) }
            return nil
        }
    }

    func mixItems(_ id: String) async throws -> [TidalMedia] {
        try await allItems("mixes/\(id)/items").compactMap { item in
            if let track = item.track, track.isAvailable { return .track(track) }
            if let video = item.video, video.isAvailable { return .video(video) }
            return nil
        }
    }

    func artistAlbums(_ id: Int) async throws -> [TidalAlbum] {
        var result = try await allAlbums("artists/\(id)/albums", filter: nil)
        let includeEP = UserDefaults.standard.object(forKey: "tidalIncludeEP") as? Bool ?? true
        if includeEP {
            result += try await allAlbums("artists/\(id)/albums", filter: "EPSANDSINGLES")
        }
        var seen = Set<Int>()
        return result.filter { album in
            guard let albumID = album.id else { return false }
            return seen.insert(albumID).inserted
        }
    }

    func myPlaylists(userID: Int) async throws -> [TidalPlaylist] {
        var result: [TidalPlaylist] = []
        var offset = 0
        let limit = 50
        while true {
            let page: TidalPlaylistPage = try await request(
                "users/\(userID)/playlists",
                params: ["limit": String(limit), "offset": String(offset)]
            )
            let items = page.items ?? []
            result += items
            let total = page.totalNumberOfItems ?? 0
            if items.count < limit || (total > 0 && result.count >= total) {
                break
            }
            offset += items.count
            if offset > 10_000 { break }
        }
        return result
    }

    // MARK: - Поиск

    func search(_ query: String, kind: TidalItemKind, limit: Int = 25) async throws -> [TidalSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let page: TidalSearchResult = try await request(
            "search",
            params: [
                "query": trimmed,
                "limit": String(limit),
                "offset": "0",
                "types": kind.searchType
            ]
        )
        switch kind {
        case .track:
            return (page.tracks?.items ?? []).map { .track($0) }
        case .album:
            return (page.albums?.items ?? []).map { .album($0) }
        case .playlist:
            return (page.playlists?.items ?? []).map { .playlist($0) }
        case .artist:
            return (page.artists?.items ?? []).map { .artist($0) }
        case .mix:
            return (page.mixes?.items ?? []).map { .mix($0) }
        case .video:
            return (page.videos?.items ?? []).map { .video($0) }
        }
    }

    // MARK: - Потоки

    func playback(trackID: Int, quality: String) async throws -> TidalStreamResponse {
        try await request(
            "tracks/\(trackID)/playbackinfopostpaywall",
            params: [
                "audioquality": quality,
                "playbackmode": "STREAM",
                "assetpresentation": "FULL"
            ]
        )
    }

    func videoPlayback(videoID: Int) async throws -> TidalStreamResponse {
        try await request(
            "videos/\(videoID)/playbackinfopostpaywall",
            params: [
                "videoquality": "HIGH",
                "playbackmode": "STREAM",
                "assetpresentation": "FULL"
            ]
        )
    }

    func lyrics(trackID: Int) async throws -> TidalLyrics {
        try await request(
            "tracks/\(trackID)/lyrics",
            base: TidalConfig.listenBase,
            includeCountry: true
        )
    }

    // MARK: - Пагинация

    private func allItems(_ path: String) async throws -> [TidalItem] {
        var result: [TidalItem] = []
        var offset = 0
        let limit = 50
        while true {
            let page: TidalItemPage = try await request(
                path,
                params: ["limit": String(limit), "offset": String(offset)]
            )
            let items = page.items ?? []
            result += items
            let total = page.totalNumberOfItems ?? 0
            if items.count < limit || (total > 0 && result.count >= total) {
                break
            }
            offset += items.count
            if offset > 20_000 { break }
        }
        return result
    }

    private func allAlbums(_ path: String, filter: String?) async throws -> [TidalAlbum] {
        var result: [TidalAlbum] = []
        var offset = 0
        let limit = 50
        while true {
            var params = ["limit": String(limit), "offset": String(offset)]
            if let filter { params["filter"] = filter }
            let page: TidalAlbumPage = try await request(path, params: params)
            let items = page.items ?? []
            result += items
            let total = page.totalNumberOfItems ?? 0
            if items.count < limit || (total > 0 && result.count >= total) {
                break
            }
            offset += items.count
            if offset > 20_000 { break }
        }
        return result
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        _ path: String,
        params: [String: String] = [:],
        base: URL = TidalConfig.apiBase,
        includeCountry: Bool = true
    ) async throws -> T {
        let data = try await rawRequest(
            path,
            params: params,
            base: base,
            includeCountry: includeCountry
        )
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TidalError.server("Tidal response")
        }
    }

    private func rawRequest(
        _ path: String,
        params: [String: String],
        base: URL,
        includeCountry: Bool
    ) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            var tokenSession: TidalSession
            if attempt == 1 {
                tokenSession = try await TidalAuth.shared.validSession()
            } else {
                tokenSession = try await TidalAuth.shared.validSession(forceRefresh: true)
            }

            guard var components = URLComponents(
                url: base.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            ) else {
                throw TidalError.server("Tidal URL")
            }
            var query = components.queryItems ?? []
            for (key, value) in params {
                query.append(URLQueryItem(name: key, value: value))
            }
            if includeCountry {
                let fallback = Locale.current.region?.identifier ?? "US"
                let country = tokenSession.countryCode.isEmpty ? fallback : tokenSession.countryCode
                query.append(URLQueryItem(name: "countryCode", value: country))
            }
            components.queryItems = query

            guard let url = components.url else { throw TidalError.server("Tidal URL") }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 45
            request.setValue("Bearer \(tokenSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw TidalError.network(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw TidalError.network("Tidal response")
            }

            if http.statusCode == 401 {
                if attempt < 2 {
                    continue
                }
                await TidalAuth.shared.invalidate()
                throw TidalError.sessionExpired
            }
            if http.statusCode == 429 {
                let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 20
                throw TidalError.rateLimited(seconds: max(retry, 5))
            }
            if http.statusCode == 404 {
                throw TidalError.unavailable
            }
            if http.statusCode == 403 {
                throw classifyForbidden(data)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw TidalError.server(errorMessage(from: data) ?? "Tidal (\(http.statusCode))")
            }
            return data
        }
    }

    private func classifyForbidden(_ data: Data) -> TidalError {
        let message = (errorMessage(from: data) ?? "").lowercased()
        if message.contains("preview") || message.contains("fragment") {
            return .previewOnly
        }
        if message.contains("subscription") || message.contains("plan") || message.contains("tier") {
            return .planRequired
        }
        if message.contains("country") || message.contains("region") || message.contains("territor") {
            return .regionLocked
        }
        return .unavailable
    }

    private func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = object["userMessage"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
