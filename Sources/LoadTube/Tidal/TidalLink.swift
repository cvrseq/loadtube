import Foundation

struct TidalLink {
    let kind: TidalItemKind
    let id: String

    var canonicalURL: String {
        switch kind {
        case .track, .album, .artist, .video:
            return "https://tidal.com/browse/\(kind.rawValue)/\(id)"
        case .playlist, .mix:
            return "https://tidal.com/browse/\(kind.rawValue)/\(id)"
        }
    }
}

enum TidalLinkParser {
    static func isTidalLink(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "tidal.com"
            || host.hasSuffix(".tidal.com")
            || host == "tidalhifi.com"
            || host.hasSuffix(".tidalhifi.com")
    }

    static func parse(_ string: String) -> TidalLink? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isTidalLink(trimmed) else { return nil }

        let components = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }

        let kinds = Set(TidalItemKind.allCases.map(\.rawValue))

        // Поддерживаем и /browse/track/123, и /track/123, и listen.tidal.com/album/123.
        guard let index = components.firstIndex(where: { kinds.contains($0.lowercased()) }),
              index + 1 < components.count else {
            return nil
        }

        let kind = TidalItemKind(rawValue: components[index].lowercased()) ?? .track
        let rawID = components[index + 1]
        let id = rawID.split(separator: "?").first.map(String.init) ?? rawID
        guard !id.isEmpty else { return nil }

        // Для числовых типов отсекаем мусор вроде "123/extra".
        if kind != .playlist && kind != .mix && Int(id) == nil {
            return nil
        }

        return TidalLink(kind: kind, id: id)
    }

    static func canonicalURL(for item: TidalSearchItem) -> String {
        item.url
    }
}
