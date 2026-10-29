import SwiftUI

struct TidalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var tidal: TidalService

    var initialQuery: String = ""
    var onDownload: ([TidalSearchItem]) -> Void
    var onRequestLogin: () -> Void

    @State private var query = ""
    @State private var kind: TidalItemKind = .track
    @State private var results: [TidalSearchItem] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var showingMine = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.t("tidal.search.title"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(l10n.t("tidal.search.subtitle"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("settings.done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !tidal.isSignedIn {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(l10n.t("tidal.search.loginRequired"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Button(l10n.t("tidal.login.action")) {
                        dismiss()
                        onRequestLogin()
                    }
                    .buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchBar
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red.opacity(0.9))
                }
                resultsList
            }

            HStack {
                Text(l10n.f("tidal.search.selected", selected.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let items = results.filter { selected.contains($0.id) }
                    onDownload(items)
                    dismiss()
                } label: {
                    Label(l10n.t("tidal.search.download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 620)
        .onAppear {
            query = initialQuery
            if !query.isEmpty { search() }
        }
        .onChange(of: kind) { _, _ in
            results = []
            selected = []
            showingMine = false
            errorMessage = nil
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(TidalItemKind.searchCases) { item in
                    Text(l10n.t(item.titleKey)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 118)

            TextField(l10n.t("tidal.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { search() }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    selected = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if kind == .playlist {
                Button {
                    loadMine()
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showingMine ? Color.ltAccent : Color.secondary)
                .help(l10n.t("tidal.search.mine"))
                .disabled(isLoading)
            }

            Button {
                search()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ltAccent)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.t("tidal.search.searching"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                } else if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text(showingMine
                             ? l10n.t("tidal.search.myEmpty")
                             : l10n.t("tidal.search.empty"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 34)
                } else {
                    ForEach(results) { item in
                        resultRow(item)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
    }

    private func resultRow(_ item: TidalSearchItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected {
                selected.remove(item.id)
            } else {
                selected.insert(item.id)
            }
        } label: {
            HStack(spacing: 10) {
                artwork(item)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle(for: item))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private func subtitle(for item: TidalSearchItem) -> String {
        let kind = l10n.t(item.kind.titleKey)
        guard !item.subtitle.isEmpty else { return kind }
        return "\(kind) · \(item.subtitle)"
    }

    private func artwork(_ item: TidalSearchItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            if let url = item.artwork {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func loadMine() {
        searchTask?.cancel()
        showingMine = true
        isLoading = true
        errorMessage = nil
        selected = []
        query = ""

        searchTask = Task {
            do {
                let playlists = try await tidal.myPlaylists()
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    results = playlists.map { .playlist($0) }
                    isLoading = false
                }
            } catch is CancellationError {
                // Окно закрыли.
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    results = []
                    isLoading = false
                    errorMessage = tidal.message(for: error)
                }
            }
        }
    }

    private func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchTask?.cancel()
        showingMine = false
        isLoading = true
        errorMessage = nil
        selected = []

        searchTask = Task {
            do {
                let found = try await tidal.search(value, kind: kind)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    results = found
                    isLoading = false
                }
            } catch is CancellationError {
                // Новый поиск отменил предыдущий.
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    results = []
                    isLoading = false
                    errorMessage = tidal.message(for: error)
                }
            }
        }
    }
}
