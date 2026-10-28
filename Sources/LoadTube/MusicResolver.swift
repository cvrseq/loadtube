import Foundation

struct MusicTrack {
    let title: String
    let artist: String
    let artwork: URL?

    var displayName: String {
        artist.isEmpty ? title : "\(artist) — \(title)"
    }

    var searchQuery: String {
        artist.isEmpty ? title : "\(artist) \(title)"
    }

    var fileBase: String {
        let raw = artist.isEmpty ? title : "\(artist) - \(title)"
        return MusicResolver.sanitize(raw)
    }
}

/// Разбор ссылок Spotify без API-ключей: oEmbed + JSON со страницы embed.
/// Аудио Spotify защищено DRM, поэтому приложение ищет этот трек на YouTube.
enum MusicResolver {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"

    static func isSpotifyLink(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "open.spotify.com" || host.hasSuffix(".spotify.com") || host == "spotify.link"
    }

    @MainActor
    static func resolve(_ string: String) async throws -> MusicTrack {
        guard var url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LTError.message(Localization.shared.t("error.spotifyLookup"))
        }

        // Короткие ссылки spotify.link ведут на open.spotify.com
        if url.host?.lowercased() != "open.spotify.com" {
            if let resolved = try? await followRedirects(url) {
                url = resolved
            }
        }

        guard let ref = parse(url) else {
            throw LTError.message(Localization.shared.t("error.spotifyLookup"))
        }

        guard ref.kind == "track" else {
            throw LTError.message(Localization.shared.t("error.spotifyOnlyTracks"))
        }

        let embedURL = URL(string: "https://open.spotify.com/embed/track/\(ref.id)")!
        let oembedURL = URL(string: "https://open.spotify.com/oembed?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2F\(ref.id)")!

        async let embedData = fetch(embedURL, userAgent: userAgent)
        async let oembedData = fetch(oembedURL, userAgent: nil)

        let embed = try? await embedData
        let oembed = try? await oembedData

        let entity = embed.flatMap(parseEmbed)
        let oembedInfo = oembed.flatMap(parseOEmbed)

        let title = entity?.name ?? oembedInfo?.title ?? ""
        let artist = entity?.artists.first ?? ""

        guard !title.isEmpty else {
            throw LTError.message(Localization.shared.t("error.spotifyLookup"))
        }

        let artworkURL = oembedInfo?.artwork.flatMap(URL.init(string:))
            ?? entity?.artwork.flatMap(URL.init(string:))

        return MusicTrack(title: title, artist: artist, artwork: artworkURL)
    }

    // MARK: - Ссылки

    private struct Ref {
        let kind: String
        let id: String
    }

    private static func parse(_ url: URL) -> Ref? {
        let components = url.pathComponents.filter { $0 != "/" }
        let kinds = ["track", "album", "playlist", "artist", "episode", "show"]
        guard let index = components.firstIndex(where: { kinds.contains($0) }),
              index + 1 < components.count else {
            return nil
        }
        let kind = components[index]
        let id = components[index + 1].split(separator: "?").first.map(String.init) ?? components[index + 1]
        return Ref(kind: kind, id: id)
    }

    private static func followRedirects(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }

    // MARK: - HTTP

    @MainActor
    private static func fetch(_ url: URL, userAgent: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LTError.message(Localization.shared.t("error.network"))
            }
            return data
        } catch let error as LTError {
            throw error
        } catch {
            throw LTError.message(Localization.shared.t("error.network"))
        }
    }

    // MARK: - JSON

    private struct EmbedEntity {
        let name: String
        let artists: [String]
        let artwork: String?
    }

    private struct OEmbed {
        let title: String
        let artwork: String?
    }

    private static func parseEmbed(_ data: Data) -> EmbedEntity? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "<script id=\"__NEXT_DATA__\" type=\"application/json\">(.*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let jsonRange = Range(match.range(at: 1), in: html),
              let jsonData = String(html[jsonRange]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        guard let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let data = state["data"] as? [String: Any],
              let entity = data["entity"] as? [String: Any] else {
            return nil
        }

        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? ""
        let artists = (entity["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return EmbedEntity(name: name, artists: artists, artwork: nil)
    }

    private static func parseOEmbed(_ data: Data) -> OEmbed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = root["title"] as? String ?? ""
        return OEmbed(title: title, artwork: root["thumbnail_url"] as? String)
    }

    // MARK: - Имя файла

    static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        var clean = name.components(separatedBy: forbidden).joined(separator: " ")
        while clean.contains("  ") {
            clean = clean.replacingOccurrences(of: "  ", with: " ")
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 140 {
            clean = String(clean.prefix(140)).trimmingCharacters(in: .whitespaces)
        }
        return clean.isEmpty ? "track" : clean
    }
}
