import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var tidal: TidalService
    @EnvironmentObject private var updates: UpdateManager
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("theme") private var themeRaw: String = AppTheme.dark.rawValue
    @AppStorage("downloadFolder") private var folderPath: String = ""
    @AppStorage("preset") private var presetRaw: String = QualityPreset.maximum.rawValue
    @AppStorage("tidalQuality") private var tidalQualityRaw: String = TidalQuality.auto.rawValue
    @AppStorage("tidalVideoQuality") private var tidalVideoQualityRaw: String = TidalVideoQuality.p1080.rawValue
    @AppStorage("tidalFolderStyle") private var tidalFolderStyleRaw: String = TidalFolderStyle.organized.rawValue
    @AppStorage("tidalSaveCover") private var tidalSaveCover = true
    @AppStorage("tidalSaveLyrics") private var tidalSaveLyrics = false
    @AppStorage("tidalDownloadVideos") private var tidalDownloadVideos = true
    @AppStorage("tidalSkipExisting") private var tidalSkipExisting = true
    @AppStorage("tidalIncludeEP") private var tidalIncludeEP = true
    @AppStorage("tidalClientIndex") private var tidalClientIndex = 1
    @AppStorage("cookieBrowser") private var cookieBrowserRaw: String = CookieBrowser.safari.rawValue
    @State private var showLogin = false
    @State private var cookieStatus: String?
    @State private var cookieStatusOK = false
    @State private var cookieNeedsSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(l10n.t("settings.title"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Spacer()
                    Button(l10n.t("settings.done")) { dismiss() }
                        .buttonStyle(AccentButtonStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("settings.language"))
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(l10n.t(language.titleKey)).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("settings.theme"))
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(l10n.t(theme.titleKey)).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("settings.folder"))
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 10) {
                        Text(currentFolderLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(l10n.t("settings.change")) { chooseFolder() }
                            .font(.system(size: 12))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("settings.defaultQuality"))
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $presetRaw) {
                        ForEach(QualityPreset.allCases) { item in
                            Text(l10n.t(item.titleKey)).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("cookies.title"))
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 10) {
                        Text(l10n.t("cookies.label"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 112, alignment: .leading)
                        Picker("", selection: $cookieBrowserRaw) {
                            ForEach(CookieBrowser.allCases) { browser in
                                Text(l10n.t(browser.titleKey)).tag(browser.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 170)
                        Spacer()
                    }

                    Text(l10n.t("cookies.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(l10n.t("cookies.check")) { checkCookies() }
                            .font(.system(size: 11))

                        if let status = cookieStatus {
                            Text(status)
                                .font(.system(size: 10.5))
                                .foregroundStyle(cookieStatusOK ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if cookieNeedsSettings {
                            Button(l10n.t("cookies.openSettings")) { openFullDiskAccess() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.ltAccent)
                        }
                    }
                }
                .onChange(of: cookieBrowserRaw) { _, _ in
                    cookieStatus = nil
                    cookieStatusOK = false
                    cookieNeedsSettings = false
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Tidal")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if tidal.isSignedIn {
                            HStack(spacing: 8) {
                                if let account = tidal.account {
                                    Text(account.display)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                Button(l10n.t("tidal.logout")) {
                                    Task { await tidal.signOut() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            }
                        } else if tidal.isBootstrapping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button(l10n.t("tidal.login.action")) {
                                showLogin = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.ltAccent)
                        }
                    }

                    HStack(spacing: 10) {
                        Text(l10n.t("tidal.client"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 112, alignment: .leading)
                        Picker("", selection: $tidalClientIndex) {
                            ForEach(Array(TidalConfig.credentials.indices), id: \.self) { index in
                                Text(clientLabel(index)).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 230)
                        Spacer()
                    }

                    Text(l10n.t("tidal.client.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if tidal.isSignedIn {
                        HStack(spacing: 10) {
                            Text(l10n.t("tidal.quality"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 112, alignment: .leading)
                            Picker("", selection: $tidalQualityRaw) {
                                ForEach(TidalQuality.allCases) { quality in
                                    Text(l10n.t(quality.titleKey)).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 170)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Text(l10n.t("tidal.videoQuality"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 112, alignment: .leading)
                            Picker("", selection: $tidalVideoQualityRaw) {
                                ForEach(TidalVideoQuality.allCases) { quality in
                                    Text(quality.title).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 110)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Text(l10n.t("tidal.folder"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 112, alignment: .leading)
                            Picker("", selection: $tidalFolderStyleRaw) {
                                ForEach(TidalFolderStyle.allCases) { style in
                                    Text(l10n.t(style.titleKey)).tag(style.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 230)
                            Spacer()
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 6) {
                            Toggle(l10n.t("tidal.saveCover"), isOn: $tidalSaveCover)
                            Toggle(l10n.t("tidal.saveLyrics"), isOn: $tidalSaveLyrics)
                            Toggle(l10n.t("tidal.downloadVideos"), isOn: $tidalDownloadVideos)
                            Toggle(l10n.t("tidal.skipExisting"), isOn: $tidalSkipExisting)
                            Toggle(l10n.t("tidal.includeEP"), isOn: $tidalIncludeEP)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))

                        Text(l10n.t("tidal.settings.qualityHint"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(l10n.t("tidal.settings.hint"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LoadTube \(updates.currentVersion)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(l10n.t("update.check")) {
                            updates.checkManually()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.ltAccent)
                    }

                    Toggle(l10n.t("update.auto"), isOn: $autoUpdateCheck)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .onChange(of: autoUpdateCheck) { _, enabled in
                            updates.setAutoCheck(enabled)
                        }

                    Text(l10n.t("settings.aboutHint"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(width: 520, height: 690)
        .sheet(isPresented: $showLogin) {
            TidalLoginView()
        }
    }

    private var currentFolderLabel: String {
        if folderPath.isEmpty {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            let url = downloads ?? FileManager.default.homeDirectoryForCurrentUser
            return displayPath(url) + " (" + l10n.t("settings.folderDefault") + ")"
        }
        return displayPath(URL(fileURLWithPath: folderPath))
    }

    private func clientLabel(_ index: Int) -> String {
        switch index {
        case 0: return l10n.t("tidal.client.firetv")
        case 1: return l10n.t("tidal.client.androidAuto")
        case 2: return l10n.t("tidal.client.tv")
        case 3: return l10n.t("tidal.client.androidTv")
        default: return "Tidal"
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l10n.t("settings.change")
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    // MARK: - Cookies для Instagram и TikTok

    private func checkCookies() {
        let browser = CookieBrowser(rawValue: cookieBrowserRaw) ?? .safari
        guard browser != .none else {
            cookieStatusOK = false
            cookieNeedsSettings = false
            cookieStatus = l10n.t("cookies.disabled")
            return
        }

        let available = browser.isAvailable
        cookieStatusOK = available
        cookieNeedsSettings = !available && browser == .safari
        cookieStatus = l10n.t(available ? "cookies.available" : "cookies.unavailable")
    }

    private func openFullDiskAccess() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
