import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var manager: DownloadManager
    @EnvironmentObject private var l10n: Localization
    @AppStorage("downloadFolder") private var folderPath: String = ""
    @AppStorage("preset") private var presetRaw: String = QualityPreset.maximum.rawValue

    @State private var urlText = ""
    @State private var allowPlaylist = false
    @State private var showSettings = false
    @State private var isDropTarget = false
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
        .onAppear {
            urlFocused = true
        }
        .onDrop(of: [.url, .plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
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
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
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
                    .onSubmit { startDownload() }

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

            HStack(spacing: 8) {
                ForEach(QualityPreset.allCases) { item in
                    presetChip(item)
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

                Toggle(isOn: $allowPlaylist) {
                    Text(l10n.t("input.playlist"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .foregroundStyle(.secondary)
                .help(l10n.t("input.playlist.help"))
            }

            HStack(alignment: .center, spacing: 12) {
                Text(isSpotifyInput ? l10n.t("input.spotify.hint") : l10n.t(preset.subtitleKey))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    startDownload()
                } label: {
                    Label(l10n.t("input.download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!isValidURL)
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

    private func presetChip(_ item: QualityPreset) -> some View {
        let selected = preset == item
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
                            DownloadRow(task: task, manager: manager)
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
        manager.add(url: trimmedURL, preset: preset, allowPlaylist: allowPlaylist, folder: folder)
        urlText = ""
        urlFocused = true
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
