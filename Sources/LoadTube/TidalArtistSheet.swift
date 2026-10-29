import SwiftUI

struct TidalArtistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var tidal: TidalService

    let artist: TidalArtist
    var onDownload: ([TidalAlbum]) -> Void

    @State private var albums: [TidalAlbum] = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.displayName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(l10n.t("tidal.artist.subtitle"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("settings.done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(l10n.t("tidal.artist.selectAll")) {
                    selected = Set(albums.compactMap(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ltAccent)

                Button(l10n.t("tidal.artist.selectNone")) {
                    selected.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

                Spacer()
                Text("\(selected.count) / \(albums.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("tidal.artist.loading"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.9))
                    Button(l10n.t("row.retry")) { load() }
                        .buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(albums) { album in
                            albumRow(album)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            }

            HStack {
                Spacer()
                Button {
                    let chosen = albums.filter { album in
                        guard let id = album.id else { return false }
                        return selected.contains(id)
                    }
                    onDownload(chosen)
                    dismiss()
                } label: {
                    Label(l10n.t("tidal.artist.download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540, height: 620)
        .onAppear { load() }
    }

    private func albumRow(_ album: TidalAlbum) -> some View {
        let id = album.id ?? 0
        let isSelected = selected.contains(id)
        return Button {
            if isSelected { selected.remove(id) } else { selected.insert(id) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                    if let url = TidalConfig.coverURL(album.cover, width: 320, height: 320) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "square.stack")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "square.stack")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !album.year.isEmpty { Text(album.year) }
                        if let count = album.numberOfTracks { Text("· \(count)") }
                        if let quality = album.audioQuality, !quality.isEmpty {
                            Text("· \(quality)")
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.ltAccent : Color.secondary.opacity(0.5))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.ltAccent.opacity(0.10) : Color.primary.opacity(0.035))
            )
        }
        .buttonStyle(.plain)
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let found = try await tidal.artistAlbums(artist)
                await MainActor.run {
                    albums = found
                    selected = Set(found.compactMap(\.id))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = tidal.message(for: error)
                }
            }
        }
    }
}
