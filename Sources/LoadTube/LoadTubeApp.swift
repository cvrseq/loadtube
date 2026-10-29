import SwiftUI
import AppKit

@main
struct LoadTubeApp: App {
    @StateObject private var dependencies = DependencyManager()
    @StateObject private var localization = Localization.shared
    @StateObject private var updates = UpdateManager()
    @AppStorage("theme") private var themeRaw = AppTheme.dark.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dependencies)
                .environmentObject(localization)
                .environmentObject(updates)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
                .frame(minWidth: 700, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(Localization.shared.t("update.checkMenu")) {
                    Task { await updates.checkManually() }
                }
                .disabled(updates.isChecking)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var dependencies: DependencyManager
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var updates: UpdateManager
    @StateObject private var tidal = TidalService.shared

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .environmentObject(tidal)
        .environmentObject(updates)
        .sheet(isPresented: $updates.showPrompt) {
            UpdateView()
        }
        .task {
            dependencies.check()
            Notifier.requestAuthorization()
            await tidal.bootstrap()
            await updates.checkAutomatically()
        }
        .onAppear {
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dependencies.phase {
        case .ready:
            MainView(
                ytDlp: dependencies.ytDlpPath ?? "",
                ffmpegPath: dependencies.ffmpegPath ?? ""
            )
        case .checking:
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(l10n.t("app.checking"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        default:
            InstallView()
        }
    }
}

// MARK: - Общие элементы оформления

extension Color {
    static let ltAccent = Color(red: 0.99, green: 0.29, blue: 0.26)
    static let ltAccentWarm = Color(red: 1.0, green: 0.62, blue: 0.15)
}

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.055, green: 0.055, blue: 0.075),
                       Color(red: 0.09, green: 0.09, blue: 0.11)]
                    : [Color(red: 0.96, green: 0.96, blue: 0.975),
                       Color(red: 1, green: 1, blue: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.ltAccent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.ltAccentWarm.opacity(scheme == .dark ? 0.08 : 0.06), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

struct LogoView: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.ltAccent, .ltAccentWarm],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.ltAccent.opacity(0.35), radius: size * 0.2, y: size * 0.08)
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.06), radius: 18, y: 8)
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [.ltAccent, .ltAccentWarm],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(isEnabled ? 1 : 0.35)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.ltAccent.opacity(isEnabled ? 0.30 : 0), radius: 9, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08))
            )
            .foregroundStyle(.secondary)
            .contentShape(Circle())
    }
}
