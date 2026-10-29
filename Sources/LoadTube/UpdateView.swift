import SwiftUI
import AppKit

struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updates: UpdateManager
    @EnvironmentObject private var l10n: Localization

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let info = updates.available {
                subtitle(info)
                notes(info)

                if updates.isDownloading {
                    downloading
                } else if updates.downloadComplete {
                    completed
                } else {
                    if let error = updates.downloadError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions(info)
                }
            } else {
                Text(l10n.t("update.error"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(l10n.t("update.footer"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 540, height: 520)
        .onDisappear {
            if updates.isDownloading {
                updates.cancelDownload()
            }
        }
    }

    // MARK: - Элементы

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.ltAccent.opacity(0.22), .ltAccentWarm.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ltAccent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("update.title"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(l10n.t("update.softHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                updates.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .help(l10n.t("update.later"))
        }
    }

    private func subtitle(_ info: UpdateInfo) -> some View {
        HStack(spacing: 6) {
            Text(l10n.f("update.versionLine", info.version, updates.currentVersion))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            if let date = info.publishedAt {
                Text("· \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func notes(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.t("update.notes"))
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)

            ScrollView {
                Group {
                    if info.notes.isEmpty {
                        Text(l10n.t("update.noNotes"))
                    } else if let attributed = try? AttributedString(markdown: info.notes) {
                        Text(attributed)
                    } else {
                        Text(info.notes)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
            }
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }

    private var downloading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.t("update.downloading"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int((updates.downloadProgress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: updates.downloadProgress)
                .tint(Color.ltAccent)
            HStack {
                Spacer()
                Button(l10n.t("update.cancel")) {
                    updates.cancelDownload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var completed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                Text(l10n.t("update.downloadDone"))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(l10n.t("update.reveal")) {
                    updates.revealDownloaded()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ltAccent)

                Button(l10n.t("update.openDMG")) {
                    updates.openDownloaded()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                Spacer()

                Button(l10n.t("update.done")) {
                    updates.dismiss()
                }
                .buttonStyle(AccentButtonStyle())
            }
        }
    }

    private func actions(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    updates.downloadAndOpen()
                } label: {
                    Label(
                        info.dmgURL == nil
                            ? l10n.t("update.openPage")
                            : (updates.downloadError == nil ? l10n.t("update.download") : l10n.t("update.retry")),
                        systemImage: info.dmgURL == nil ? "safari" : "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(AccentButtonStyle())

                Button(l10n.t("update.later")) {
                    updates.dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(spacing: 14) {
                Button(l10n.t("update.skip")) {
                    updates.skipCurrent()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                Button(l10n.t("update.openPage")) {
                    updates.openReleasePage()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }
}
