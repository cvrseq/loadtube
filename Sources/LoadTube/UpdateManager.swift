import Foundation
import Combine
import AppKit

struct UpdateInfo: Identifiable {
    let id: String
    let version: String
    let tag: String
    let title: String
    let notes: String
    let pageURL: URL?
    let dmgURL: URL?
    let publishedAt: Date?
}

/// Мягкое (необязательное) обновление через GitHub Releases.
/// Ничего не устанавливает само: показывает предложение и по желанию
/// скачивает DMG в Downloads, после чего открывает его.
@MainActor
final class UpdateManager: ObservableObject {
    @Published private(set) var currentVersion: String
    @Published private(set) var available: UpdateInfo?
    @Published var showPrompt = false
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadComplete = false
    @Published private(set) var downloadError: String?
    @Published private(set) var downloadedURL: URL?
    @Published private(set) var manualStatus: String?

    private let repository = "cvrseq/loadtube"
    private var downloader: UpdateFileDownloader?
    private var l10n: Localization { Localization.shared }

    init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
    }

    var hasUnseenUpdate: Bool {
        guard let available else { return false }
        return skippedVersion != available.version
    }

    private var skippedVersion: String? {
        UserDefaults.standard.string(forKey: "skippedUpdateVersion")
    }

    private var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
    }

    // MARK: - Проверка

    func checkAutomatically() async {
        guard autoCheckEnabled else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if last > 0, now - last < 86_400 { return }

        // Не мешаем запуску приложения.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await check(present: true, silent: true)
    }

    func checkManually(present: Bool = true) async {
        await check(present: present, silent: false)
    }

    private func check(present: Bool, silent: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        if !silent { manualStatus = l10n.t("update.checking") }
        defer { isChecking = false }

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: "lastUpdateCheck"
        )

        do {
            let info = try await fetchLatestInfo()
            guard isNewer(info.version, than: currentVersion) else {
                available = nil
                if !silent {
                    manualStatus = l10n.t("update.upToDate")
                }
                return
            }

            available = info
            downloadError = nil
            downloadComplete = false
            downloadProgress = 0
            downloadedURL = nil

            if !silent && !present {
                manualStatus = nil
                return
            }
            if silent, skippedVersion == info.version {
                available = nil
                return
            }

            manualStatus = nil
            showPrompt = present
        } catch UpdateCheckError.noReleases {
            if !silent {
                manualStatus = l10n.t("update.noReleases")
            }
        } catch {
            if !silent {
                manualStatus = l10n.t("update.error")
            }
        }
    }

    // MARK: - Действия в окне обновления

    func dismiss() {
        if isDownloading {
            cancelDownload()
        }
        showPrompt = false
    }

    func presentPrompt() {
        guard available != nil else { return }
        downloadComplete = false
        downloadError = nil
        downloadProgress = 0
        downloadedURL = nil
        showPrompt = true
    }

    func skipCurrent() {
        guard let available else {
            showPrompt = false
            return
        }
        UserDefaults.standard.set(available.version, forKey: "skippedUpdateVersion")
        manualStatus = l10n.t("update.skipped")
        self.available = nil
        showPrompt = false
    }

    func openReleasePage() {
        guard let url = available?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealDownloaded() {
        guard let url = downloadedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDownloaded() {
        guard let url = downloadedURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Скачивание DMG

    func downloadAndOpen() {
        guard let info = available, !isDownloading else { return }
        guard let dmgURL = info.dmgURL else {
            openReleasePage()
            return
        }

        let destination = downloadsDirectory()
            .appendingPathComponent("LoadTube-\(sanitize(info.version)).dmg")
        try? FileManager.default.removeItem(at: destination)

        isDownloading = true
        downloadComplete = false
        downloadError = nil
        downloadProgress = 0
        downloadedURL = nil

        let downloader = UpdateFileDownloader()
        self.downloader = downloader
        downloader.onProgress = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.isDownloading else { return }
                self.downloadProgress = max(0, min(1, fraction))
            }
        }

        Task {
            do {
                try await downloader.download(dmgURL, to: destination)
                self.downloader = nil
                self.downloadProgress = 1

                let verify = await ProcessRunner.run(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["verify", destination.path],
                    environment: nil
                )
                guard verify.code == 0 else {
                    throw UpdateDownloadError.verifyFailed
                }

                self.downloadedURL = destination
                self.downloadComplete = true
                self.isDownloading = false
                NSWorkspace.shared.open(destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch UpdateDownloadError.cancelled {
                self.downloader = nil
                self.isDownloading = false
                self.downloadProgress = 0
                try? FileManager.default.removeItem(at: destination)
            } catch {
                self.downloader = nil
                self.isDownloading = false
                self.downloadProgress = 0
                self.downloadError = (error as? UpdateDownloadError) == .verifyFailed
                    ? self.l10n.t("update.verifyError")
                    : self.l10n.t("update.downloadError")
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
    }

    // MARK: - GitHub Releases

    private func fetchLatestInfo() async throws -> UpdateInfo {
        do {
            let release = try await fetchLatestRelease()
            guard let info = makeInfo(release) else {
                throw UpdateCheckError.badResponse
            }
            return info
        } catch UpdateCheckError.http(let status) where status == 403 || status == 429 || status >= 500 {
            // GitHub API rate limit/ошибка: публичный Atom-фид работает без токена.
            return try await fetchAtomInfo()
        }
    }

    private func fetchAtomInfo() async throws -> UpdateInfo {
        guard let url = URL(string: "https://github.com/\(repository)/releases.atom") else {
            throw UpdateCheckError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("LoadTube/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badResponse
        }
        if http.statusCode == 404 { throw UpdateCheckError.noReleases }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.http(http.statusCode)
        }

        let parser = AtomReleaseParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), let entry = parser.firstEntry else {
            throw UpdateCheckError.badResponse
        }

        var version = normalize(entry.tag)
        if version.rangeOfCharacter(from: .decimalDigits) == nil {
            version = Self.extractVersion(from: entry.title)
        }
        guard !version.isEmpty else { throw UpdateCheckError.badResponse }
        let tag = entry.tag.isEmpty ? version : entry.tag

        // В Atom-фиде нет прямых ссылок на assets. Пробуем стандартное имя
        // релизного DMG; если его нет, пользователь откроет страницу релиза.
        let dmg = URL(string: "https://github.com/\(repository)/releases/latest/download/LoadTube.dmg")
        return UpdateInfo(
            id: version,
            version: version,
            tag: tag,
            title: entry.title.isEmpty ? "LoadTube \(version)" : entry.title,
            notes: Self.stripHTML(entry.content),
            pageURL: URL(string: entry.link),
            dmgURL: dmg,
            publishedAt: Self.parseDate(entry.updated)
        )
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateCheckError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LoadTube/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badResponse
        }
        if http.statusCode == 404 {
            throw UpdateCheckError.noReleases
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.badResponse
        }
    }

    private func makeInfo(_ release: GitHubRelease) -> UpdateInfo? {
        var version = normalize(release.tagName)
        if version.rangeOfCharacter(from: .decimalDigits) == nil {
            version = Self.extractVersion(from: release.name ?? "")
        }
        guard !version.isEmpty else { return nil }

        let asset = (release.assets ?? []).first { asset in
            asset.name.lowercased().hasSuffix(".dmg")
        }
        let title = (release.name?.isEmpty == false)
            ? release.name!
            : "LoadTube \(version)"

        return UpdateInfo(
            id: version,
            version: version,
            tag: release.tagName,
            title: title,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: release.htmlURL.flatMap(URL.init(string:)),
            dmgURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            publishedAt: release.publishedAt.flatMap(Self.parseDate)
        )
    }

    private func normalize(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        if let cut = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            value = String(value[..<cut])
        }
        return value
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let lhs = remote.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t ")
        let clean = value.components(separatedBy: forbidden).joined(separator: "-")
        return clean.isEmpty ? "update" : clean
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stripHTML(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<[^>]+>",
            options: [.dotMatchesLineSeparators]
        ) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(value.startIndex..., in: value)
        let plain = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return plain
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractVersion(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)+") else {
            return ""
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range, in: text) else {
            return ""
        }
        return String(text[valueRange])
    }
}

// MARK: - Atom fallback

private struct AtomEntry {
    var title = ""
    var link = ""
    var updated = ""
    var content = ""
    var tag = ""
}

private final class AtomReleaseParser: NSObject, XMLParserDelegate {
    private var inEntry = false
    private var done = false
    private var entry = AtomEntry()
    private var buffer = ""

    private(set) var firstEntry: AtomEntry?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !done else { return }

        if elementName == "entry" {
            inEntry = true
            entry = AtomEntry()
            return
        }
        guard inEntry else { return }

        if elementName == "link",
           (attributeDict["rel"] ?? "alternate") == "alternate",
           let href = attributeDict["href"] {
            entry.link = href
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry, !done else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inEntry, !done else { return }

        switch elementName {
        case "title":
            entry.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "updated":
            entry.updated = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "content":
            entry.content = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "entry":
            if let range = entry.link.range(of: "/tag/") {
                entry.tag = String(entry.link[range.upperBound...])
                    .split(separator: "?").first.map(String.init) ?? ""
            }
            firstEntry = entry
            inEntry = false
            done = true
        default:
            break
        }
        buffer = ""
    }
}

// MARK: - GitHub API

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: String?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateCheckError: Error {
    case badURL
    case badResponse
    case noReleases
    case http(Int)
}
