import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var manager: DownloadManager
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var tidal: TidalService
    @EnvironmentObject private var updates: UpdateManager
    @AppStorage("downloadFolder") private var folderPath: String = ""
    @AppStorage("preset") private var presetRaw: String = QualityPreset.maximum.rawValue

    @State private var urlText = ""
    @State private var allowPlaylist = false
    @State private var showSettings = false
    @State private var showLogin = false
    @State private var showSearch = false
    @State private var showArtistSheet = false
    @State private var isDropTarget = false
    @State private var pendingTidalURL: String?
    @State private var tidalPreview: TidalPreview?
    @State private var tidalResolved: TidalResolved?
    @State private var previewLoading = false
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var urlFocused: Bool

    init(ytDlp: String, ffmpegPath: String) {
        _manager = StateObject(wrappedValue: DownloadManager(ytDlp: ytDlp, ffmpegPath: ffmpegPath))
    }

    private var preset: QualityPreset {
        QualityPreset(rawValue: presetRaw) ?? .maximum
    }

    private var folder: URL {
        if folderPath.isEmpty {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: folderPath)
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private var isSpotifyInput: Bool {
        MusicResolver.isSpotifyLink(trimmedURL)
    }

    private var isTidalInput: Bool {
        TidalLinkParser.isTidalLink(trimmedURL)
    }

    private var isShortVideoInput: Bool {
        MediaSource.detect(trimmedURL).isShortVideo
    }

    /// Для Instagram и TikTok 4K/1080p-пресеты бессмысленны — показываем
    /// «Максимум» и «MP3», а сохранённый 4K/1080p сводим к «Максимуму».
    private var visiblePresets: [QualityPreset] {
        isShortVideoInput ? [.maximum, .mp3] : QualityPreset.allCases
    }

    private var effectivePreset: QualityPreset {
        guard isShortVideoInput else { return preset }
        return preset == .mp3 ? .mp3 : .maximum
    }

    private var sourceBadgeText: String {
        let source = MediaSource.detect(trimmedURL)
        return "\(l10n.t(source.titleKey)) · \(l10n.t("input.noWatermark"))"
    }

    var body: some View {
        VStack(spacing: 15) {
            header
            inputCard
            downloads
        }
        .padding(20)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showLogin, onDismiss: handleLoginDismissed) {
            TidalLoginView()
        }
        .sheet(isPresented: $showSearch) {
            TidalSearchView(
                initialQuery: isValidURL ? "" : trimmedURL,
                onDownload: { items in
                    for item in items {
                        manager.add(
                            url: item.url,
                            preset: preset,
                            allowPlaylist: true,
                            folder: folder
                        )
                    }
                },
                onRequestLogin: {
                    showSearch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showLogin = true
                    }
                }
            )
        }
        .sheet(isPresented: $showArtistSheet) {
            if case .artist(let artist) = tidalResolved {
                TidalArtistSheet(artist: artist) { albums in
                    for album in albums {
                        guard let id = album.id else { continue }
                        manager.add(
                            url: "https://tidal.com/browse/album/\(id)",
                            preset: preset,
                            allowPlaylist: true,
                            folder: folder
                        )
                    }
                }
            }
        }
        .onAppear {
            urlFocused = true
        }
        .onChange(of: urlText) { _, newValue in
            scheduleTidalPreview(for: newValue)
        }
        .onChange(of: tidal.isSignedIn) { _, signedIn in
            if signedIn {
                if let pending = pendingTidalURL {
                    pendingTidalURL = nil
                    manager.add(url: pending, preset: preset, allowPlaylist: true, folder: folder)
                    urlText = ""
                } else if isTidalInput {
                    scheduleTidalPreview(for: trimmedURL)
                }
            }
        }
        .onDrop(of: [.url, .plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .onDisappear {
            previewTask?.cancel()
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 12) {
            LogoView(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("LoadTube")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(l10n.t("app.subtitle"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))

                    if updates.hasUnseenUpdate {
                        Circle()
                            .fill(Color.ltAccent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                            .offset(x: 1, y: -1)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(l10n.t("settings.title"))
        }
    }

    // MARK: - Поле ввода

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(l10n.t("input.placeholder"), text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($urlFocused)
                    .onSubmit {
                        if isValidURL {
                            startDownload()
                        } else if !trimmedURL.isEmpty {
                            showSearch = true
                        }
                    }

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                        urlFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l10n.t("tidal.search.open"))

                Button(l10n.t("input.paste")) { pasteFromClipboard() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ltAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.08 : 0.05))
            )

            if isTidalInput {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("TIDAL")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.7)
                        Text(l10n.t("tidal.quality.autoShort"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(visiblePresets) { item in
                        presetChip(item)
                    }

                    if isShortVideoInput {
                        Spacer(minLength: 6)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(sourceBadgeText)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.ltAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.ltAccent.opacity(0.10)))
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(displayPath(folder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.t("input.folder.help"))

                Spacer(minLength: 8)

                if !isTidalInput {
                    Toggle(isOn: $allowPlaylist) {
                        Text(l10n.t("input.playlist"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help(l10n.t("input.playlist.help"))
                }
            }

            if isTidalInput {
                tidalPreviewCard
            }

            HStack(alignment: .center, spacing: 12) {
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    startDownload()
                } label: {
                    Label(downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!isValidURL || (isTidalInput && tidal.isBootstrapping))
            }
        }
        .padding(15)
        .cardBackground()
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.ltAccent.opacity(isDropTarget ? 1 : 0), lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    private var isArtistPreview: Bool {
        if case .artist = tidalResolved { return true }
        return false
    }

    private var hintText: String {
        if isTidalInput {
            if tidal.isBootstrapping {
                return l10n.t("tidal.checking")
            }
            if !tidal.isSignedIn {
                return l10n.t("tidal.hint.signIn")
            }
            if let preview = tidalPreview {
                var parts: [String] = []
                if let count = preview.count, count > 0 {
                    parts.append(l10n.f("tidal.preview.tracks", count))
                }
                if let quality = preview.quality, !quality.isEmpty {
                    parts.append(quality)
                }
                if !parts.isEmpty { return parts.joined(separator: " · ") }
            }
            return l10n.t("tidal.hint.signedIn")
        }
        if isShortVideoInput {
            return l10n.t("input.short.hint")
        }
        return isSpotifyInput ? l10n.t("input.spotify.hint") : l10n.t(effectivePreset.subtitleKey)
    }

    private var downloadButtonTitle: String {
        guard isTidalInput else { return l10n.t("input.download") }
        if tidal.isBootstrapping { return l10n.t("tidal.checkingShort") }
        if !tidal.isSignedIn { return l10n.t("tidal.login.action") }
        if let preview = tidalPreview {
            switch preview.kind {
            case .track:
                return l10n.t("tidal.download.track")
            case .video:
                return l10n.t("tidal.download.video")
            case .album, .playlist, .artist, .mix:
                if let count = preview.count, count > 0 {
                    return l10n.f("tidal.download.collection", count)
                }
                return l10n.t("tidal.download.collectionShort")
            }
        }
        return l10n.t("tidal.download.collectionShort")
    }

    @ViewBuilder
    private var tidalPreviewCard: some View {
        if tidal.isBootstrapping {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(l10n.t("tidal.checking"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(7)
        } else if !tidal.isSignedIn {
            HStack(spacing: 9) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ltAccent)
                Text(l10n.t("tidal.preview.login"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button(l10n.t("tidal.login.action")) {
                    pendingTidalURL = trimmedURL
                    showLogin = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.ltAccent)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.ltAccent.opacity(0.07))
            )
        } else if previewLoading {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(l10n.t("tidal.preview.loading"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(7)
        } else if let preview = tidalPreview {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    if let url = preview.artwork {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: icon(for: preview.kind))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: icon(for: preview.kind))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(preview.subtitle.isEmpty ? l10n.t(preview.kind.titleKey) : preview.subtitle)
                        if let count = preview.count, count > 0 {
                            Text("· \(l10n.f("tidal.preview.tracks", count))")
                        }
                        if let quality = preview.quality, !quality.isEmpty {
                            Text("· \(quality)")
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isArtistPreview {
                    Button(l10n.t("tidal.artist.choose")) {
                        showArtistSheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ltAccent)
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
        } else if let previewError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text(previewError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(7)
        }
    }

    private func icon(for kind: TidalItemKind) -> String {
        switch kind {
        case .track: return "music.note"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .artist: return "person"
        case .mix: return "shuffle"
        case .video: return "play.rectangle"
        }
    }

    private func presetChip(_ item: QualityPreset) -> some View {
        let selected = effectivePreset == item
        return Button {
            presetRaw = item.rawValue
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(l10n.t(item.titleKey))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background(
                Group {
                    if selected {
                        Capsule().fill(
                            LinearGradient(
                                colors: [.ltAccent, .ltAccentWarm],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        Capsule().fill(Color.primary.opacity(0.06))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(l10n.t(item.subtitleKey))
    }

    // MARK: - Список загрузок

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(l10n.t("downloads.title"))
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)

                if !manager.tasks.isEmpty {
                    Text("\(manager.tasks.count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if manager.hasFinished {
                    Button(l10n.t("downloads.clear")) { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button {
                    NSWorkspace.shared.open(folder)
                } label: {
                    Label(l10n.t("downloads.openFolder"), systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if manager.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(manager.tasks) { task in
                            if task.isCollection {
                                DownloadGroupRow(task: task, manager: manager)
                            } else {
                                DownloadRow(task: task, manager: manager)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text(l10n.t("downloads.empty.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(l10n.t("downloads.empty.desc"))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Действия

    private func startDownload() {
        guard isValidURL else { return }
        if isTidalInput && tidal.isBootstrapping { return }

        if isTidalInput && !tidal.isSignedIn {
            pendingTidalURL = trimmedURL
            showLogin = true
            return
        }

        manager.add(
            url: trimmedURL,
            preset: effectivePreset,
            allowPlaylist: allowPlaylist,
            folder: folder
        )
        urlText = ""
        tidalPreview = nil
        tidalResolved = nil
        previewError = nil
        previewTask?.cancel()
        urlFocused = true
    }

    private func scheduleTidalPreview(for value: String) {
        previewTask?.cancel()
        previewTask = nil
        previewLoading = false
        previewError = nil
        tidalPreview = nil
        tidalResolved = nil

        guard TidalLinkParser.isTidalLink(value), tidal.isSignedIn else { return }
        let link = value.trimmingCharacters(in: .whitespacesAndNewlines)
        previewLoading = true

        previewTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            do {
                let resolved = try await tidal.lookup(link)
                await MainActor.run {
                    guard !Task.isCancelled, trimmedURL == link else { return }
                    tidalResolved = resolved
                    tidalPreview = resolved.preview
                    previewLoading = false
                    previewError = nil
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    previewLoading = false
                    previewError = tidal.message(for: error)
                }
            }
        }
    }

    private func handleLoginDismissed() {
        if !tidal.isSignedIn {
            pendingTidalURL = nil
        } else if isTidalInput {
            scheduleTidalPreview(for: trimmedURL)
        }
    }

    private func pasteFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        urlText = string.trimmingCharacters(in: .whitespacesAndNewlines)
        urlFocused = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l10n.t("settings.change")
        panel.message = l10n.t("input.folder.help")
        if panel.runModal() == .OK, let chosen = panel.url {
            folderPath = chosen.path
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let object {
                    DispatchQueue.main.async {
                        urlText = object.absoluteString
                        urlFocused = true
                    }
                }
            }
            return true
        }

        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                if let text = object as? String {
                    DispatchQueue.main.async {
                        urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        urlFocused = true
                    }
                }
            }
            return true
        }

        return false
    }
}
