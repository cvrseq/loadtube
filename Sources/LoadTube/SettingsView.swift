import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: Localization
    @AppStorage("theme") private var themeRaw: String = AppTheme.dark.rawValue
    @AppStorage("downloadFolder") private var folderPath: String = ""
    @AppStorage("preset") private var presetRaw: String = QualityPreset.maximum.rawValue

    var body: some View {
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

            VStack(alignment: .leading, spacing: 4) {
                Text("LoadTube 1.0")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(l10n.t("settings.aboutHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 470, height: 500)
    }

    private var currentFolderLabel: String {
        if folderPath.isEmpty {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            let url = downloads ?? FileManager.default.homeDirectoryForCurrentUser
            return displayPath(url) + " (" + l10n.t("settings.folderDefault") + ")"
        }
        return displayPath(URL(fileURLWithPath: folderPath))
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
}
