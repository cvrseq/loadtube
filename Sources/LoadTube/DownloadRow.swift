import SwiftUI
import AppKit

struct DownloadRow: View {
    @ObservedObject var task: DownloadTask
    let manager: DownloadManager
    @EnvironmentObject private var l10n: Localization
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if task.isTidal {
                        Text("TIDAL")
                            .font(.system(size: 8, weight: .bold))
                            .kerning(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.09)))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    statusIcon
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(statusText)
                }

                progressBar
            }

            Spacer(minLength: 4)
            actionButton
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Элементы строки

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.ltAccent.opacity(0.55), Color.ltAccentWarm.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = task.thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 94, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholderIcon: some View {
        Image(systemName: showsAudioIcon ? "music.note" : "play.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private var showsAudioIcon: Bool {
        task.isSpotify || task.preset == .mp3 || (task.isTidal && task.tidalVideo == nil)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
        case .cancelled:
            Image(systemName: "slash.circle.fill")
                .font(.system(size: 10))
        case .merging:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10))
        default:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.08))
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * clampedProgress)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: clampedProgress)
    }

    private var clampedProgress: Double {
        if task.state == .merging { return 1 }
        return max(0, min(1, task.progress))
    }

    private var barColor: Color {
        switch task.state {
        case .failed:
            return .red
        case .finished:
            return .green
        case .merging:
            return .orange
        default:
            return .ltAccent
        }
    }

    private var statusColor: Color {
        switch task.state {
        case .finished:
            return .green
        case .failed:
            return .red
        case .merging:
            return .orange
        case .cancelled:
            return .secondary
        default:
            return .secondary
        }
    }

    private var statusText: String {
        switch task.state {
        case .preparing:
            return task.detail.isEmpty ? l10n.t("row.preparing") : task.detail
        case .queued:
            return l10n.t("row.queued")
        case .downloading:
            var parts: [String] = []
            let percent = Int((task.progress * 100).rounded())
            parts.append("\(percent)%")
            if !task.speed.isEmpty { parts.append(task.speed) }
            if !task.eta.isEmpty { parts.append(l10n.f("row.eta", task.eta)) }
            if let quality = task.actualQuality, !quality.isEmpty { parts.append(quality) }
            return parts.joined(separator: " · ")
        case .merging:
            return task.detail.isEmpty ? l10n.t("row.merging") : task.detail
        case .finished:
            if task.wasSkipped { return l10n.t("tidal.detail.alreadyExists") }
            if let warning = task.warning { return warning }
            if task.isPlaylist { return l10n.t("row.playlistSaved") }
            return task.outputURL?.lastPathComponent ?? l10n.t("row.done")
        case .failed(let message):
            return message
        case .cancelled:
            return l10n.t("row.cancelled")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch task.state {
        case .finished:
            HStack(spacing: 6) {
                Button {
                    reveal()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle())
                .help(l10n.t("row.reveal"))

                if let url = task.outputURL, !task.isPlaylist {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(l10n.t("row.open"))
                }
            }

        case .failed, .cancelled:
            Button {
                manager.retry(task)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help(l10n.t("row.retry"))

        default:
            Button {
                manager.cancel(task)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .help(l10n.t("row.cancel"))
        }
    }

    private func reveal() {
        if let url = task.outputURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(task.folder)
        }
    }
}
