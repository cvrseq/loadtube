import SwiftUI
import AppKit

struct DownloadGroupRow: View {
    @ObservedObject var task: DownloadTask
    let manager: DownloadManager
    @EnvironmentObject private var l10n: Localization
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, !task.children.isEmpty {
                VStack(spacing: 0) {
                    Divider().opacity(0.35)
                    VStack(spacing: 2) {
                        ForEach(Array(task.children.enumerated()), id: \.element.id) { index, child in
                            TidalChildRow(
                                child: child,
                                index: index + 1,
                                manager: manager,
                                parent: task
                            )
                        }
                    }
                    .padding(.top, 4)
                }
            }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("TIDAL")
                        .font(.system(size: 8, weight: .bold))
                        .kerning(0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    statusIcon
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }

                progressBar
            }

            Spacer(minLength: 4)

            if !task.children.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(IconButtonStyle())
                .help(l10n.t("tidal.group.expand"))
            }

            actionButton
        }
    }

    private var artwork: some View {
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
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "square.stack")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 94, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .finished:
            Image(systemName: task.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
        case .cancelled:
            Image(systemName: "slash.circle.fill")
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
        max(0, min(1, task.progress))
    }

    private var barColor: Color {
        switch task.state {
        case .failed: return .red
        case .finished: return task.failedCount > 0 ? .orange : .green
        case .cancelled: return .secondary
        default: return .ltAccent
        }
    }

    private var statusColor: Color {
        switch task.state {
        case .finished: return task.failedCount > 0 ? .orange : .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .secondary
        }
    }

    private var statusText: String {
        switch task.state {
        case .preparing:
            return task.detail.isEmpty ? l10n.t("row.preparing") : task.detail
        case .queued:
            return l10n.t("row.queued")
        case .downloading:
            if !task.detail.isEmpty { return task.detail }
            return l10n.f("tidal.detail.progress", task.completedCount + task.failedCount, task.totalCount)
        case .merging:
            return task.detail.isEmpty ? l10n.t("row.merging") : task.detail
        case .finished:
            if let warning = task.warning { return warning }
            return l10n.f("tidal.group.saved", task.completedCount)
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
            Button {
                reveal()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help(l10n.t("row.reveal"))

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
        let url = task.outputURL ?? task.folder
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(task.folder)
        }
    }
}

private struct TidalChildRow: View {
    @ObservedObject var child: DownloadTask
    let index: Int
    let manager: DownloadManager
    let parent: DownloadTask
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var l10n: Localization

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(statusText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(statusText)
                    if let quality = child.actualQuality, !quality.isEmpty {
                        Text("· \(quality)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            if child.isActive {
                ProgressView(value: max(0, min(1, child.progress)))
                    .progressViewStyle(.linear)
                    .tint(Color.ltAccent)
                    .frame(width: 62)
                Button {
                    manager.cancelChild(parent, child: child)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if case .failed = child.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            } else if child.wasSkipped {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if child.state == .finished {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
        )
    }

    private var statusText: String {
        switch child.state {
        case .queued:
            return l10n.t("row.queued")
        case .preparing:
            return l10n.t("row.preparing")
        case .downloading:
            let percent = Int((child.progress * 100).rounded())
            var parts = ["\(percent)%"]
            if !child.speed.isEmpty { parts.append(child.speed) }
            return parts.joined(separator: " · ")
        case .merging:
            return child.detail.isEmpty ? l10n.t("row.merging") : child.detail
        case .finished:
            if child.wasSkipped { return l10n.t("tidal.detail.alreadyExists") }
            return l10n.t("row.done")
        case .failed(let message):
            return message
        case .cancelled:
            return l10n.t("row.cancelled")
        }
    }

    private var statusColor: Color {
        switch child.state {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}
