import Foundation

/// Пара клиентских ключей Tidal. Ключи, как и в tidal-dl, являются публичными
/// идентификаторами клиентов; секрет нужен только для OAuth-обмена токена.
struct TidalCredential {
    let platform: String
    let clientId: String
    let clientSecret: String
}

enum TidalConfig {
    static let apiBase = URL(string: "https://api.tidal.com/v1")!
    static let authBase = URL(string: "https://auth.tidal.com/v1/oauth2")!
    static let listenBase = URL(string: "https://listen.tidal.com/v1")!
    static let resourcesBase = URL(string: "https://resources.tidal.com/images")!

    static let scope = "r_usr+w_usr+w_sub"

    /// Порядок важен: сначала пробуем ключи, которые исторически отдают
    /// максимальное качество. При ошибке клиента переходим к следующему.
    static let credentials: [TidalCredential] = [
        TidalCredential(
            platform: "Fire TV",
            clientId: "7m7Ap0JC9j1cOM3n",
            clientSecret: "vRAdA108tlvkJpTsGZS8rGZ7xTlbJ0qaZ2K9saEzsgY="
        ),
        TidalCredential(
            platform: "Android Auto",
            clientId: "zU4XHVVkc2tDPo4t",
            clientSecret: "VJKhDFqJPqvsPVNBV6ukXTJmwlvbttP7wlMlrc72se4="
        ),
        TidalCredential(
            platform: "TV",
            clientId: "8SEZWa4J1NVC5U5Y",
            clientSecret: "owUYDkxddz+9FpvGX24DlxECNtFEMBxipU0lBfrbq60="
        ),
        TidalCredential(
            platform: "Android TV",
            clientId: "Pzd0ExNVHkyZLiYN",
            clientSecret: "W7X6UvBaho+XOi1MUeCX6ewv2zTdSOV3Y7qC3p3675I="
        )
    ]

    /// Мастер-ключ из RedSea/tidal-dl для расшифровки security token.
    static let masterKeyBase64 = "UIlTTEMmmLfGowo/UC60x2H45W6MdGgTRfo/umg4754="

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"

    static let sessionFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("LoadTube", isDirectory: true)
            .appendingPathComponent("tidal-session.json")
    }()

    static var legacyTokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tidal-dl.token.json")
    }

    static func coverURL(_ id: String?, width: Int = 1280, height: Int = 1280) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        let path = id.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(path)/\(width)x\(height).jpg")
    }
}
