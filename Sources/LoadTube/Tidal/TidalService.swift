import Foundation
import Combine

struct TidalPreferences {
    static var quality: TidalQuality { TidalQuality.current() }
    static var videoQuality: TidalVideoQuality { TidalVideoQuality.current() }
    static var folderStyle: TidalFolderStyle { TidalFolderStyle.current() }

    static var saveCover: Bool {
        UserDefaults.standard.object(forKey: "tidalSaveCover") as? Bool ?? true
    }

    static var saveLyrics: Bool {
        UserDefaults.standard.object(forKey: "tidalSaveLyrics") as? Bool ?? false
    }

    static var downloadVideos: Bool {
        UserDefaults.standard.object(forKey: "tidalDownloadVideos") as? Bool ?? true
    }

    static var skipExisting: Bool {
        UserDefaults.standard.object(forKey: "tidalSkipExisting") as? Bool ?? true
    }

    static var includeEP: Bool {
        UserDefaults.standard.object(forKey: "tidalIncludeEP") as? Bool ?? true
    }
}

/// Состояние Tidal для SwiftUI: аккаунт, вход, поиск.
@MainActor
final class TidalService: ObservableObject {
    static let shared = TidalService()

    @Published private(set) var account: TidalAccount?
    @Published private(set) var isBootstrapping = true
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    var isSignedIn: Bool { account != nil }

    private init() {}

    func bootstrap() async {
        let session = await TidalAuth.shared.bootstrap()
        account = session?.account
        isBootstrapping = false
    }

    func startLogin() async throws -> TidalDeviceLogin {
        isSigningIn = true
        defer { isSigningIn = false }
        return try await TidalAuth.shared.startDeviceLogin()
    }

    func waitForLogin(_ login: TidalDeviceLogin) async throws -> TidalAccount {
        let session = try await TidalAuth.shared.pollLogin(login)
        let account = session.account
        self.account = account
        return account
    }

    func signOut() async {
        await TidalAuth.shared.signOut()
        account = nil
        lastError = nil
    }

    func markSessionExpired() {
        account = nil
    }

    func lookup(_ url: String) async throws -> TidalResolved {
        guard let link = TidalLinkParser.parse(url) else {
            throw TidalError.unavailable
        }
        guard isSignedIn else { throw TidalError.notSignedIn }
        do {
            return try await TidalAPI.shared.resolve(link)
        } catch TidalError.sessionExpired {
            account = nil
            throw TidalError.sessionExpired
        }
    }

    func collection(for resolved: TidalResolved) async throws -> TidalCollection {
        do {
            return try await TidalAPI.shared.collection(for: resolved)
        } catch TidalError.sessionExpired {
            account = nil
            throw TidalError.sessionExpired
        }
    }

    func search(_ query: String, kind: TidalItemKind) async throws -> [TidalSearchItem] {
        guard isSignedIn else { throw TidalError.notSignedIn }
        do {
            return try await TidalAPI.shared.search(query, kind: kind)
        } catch TidalError.sessionExpired {
            account = nil
            throw TidalError.sessionExpired
        }
    }

    func myPlaylists() async throws -> [TidalPlaylist] {
        guard let account else { throw TidalError.notSignedIn }
        do {
            return try await TidalAPI.shared.myPlaylists(userID: account.userId)
        } catch TidalError.sessionExpired {
            self.account = nil
            throw TidalError.sessionExpired
        }
    }

    func artistAlbums(_ artist: TidalArtist) async throws -> [TidalAlbum] {
        guard let id = artist.id else { throw TidalError.unavailable }
        do {
            return try await TidalAPI.shared.artistAlbums(id)
        } catch TidalError.sessionExpired {
            account = nil
            throw TidalError.sessionExpired
        }
    }

    func message(for error: Error) -> String {
        if let tidalError = error as? TidalError {
            switch tidalError {
            case .rateLimited(let seconds):
                return Localization.shared.f("error.tidalRate", seconds)
            case .server(let detail):
                return Localization.shared.t("error.tidalServer") + " " + detail
            case .network(let detail):
                return Localization.shared.t("error.network") + " " + detail
            default:
                return Localization.shared.t(tidalError.key)
            }
        }
        return error.localizedDescription
    }
}
