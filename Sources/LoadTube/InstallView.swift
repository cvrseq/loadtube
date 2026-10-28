import SwiftUI

struct InstallView: View {
    @EnvironmentObject private var dependencies: DependencyManager
    @EnvironmentObject private var l10n: Localization

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            LogoView(size: 74)

            VStack(spacing: 7) {
                Text(l10n.t("install.title"))
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(l10n.t("install.desc"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            content

            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch dependencies.phase {
        case .installing:
            VStack(spacing: 12) {
                if dependencies.progress >= 0 {
                    progressBlock
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.t("install.installing"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                LogConsole(text: dependencies.log)
            }
            .padding(.top, 4)

        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)

                if !dependencies.log.isEmpty {
                    LogConsole(text: dependencies.log)
                }

                HStack(spacing: 12) {
                    Button(l10n.t("install.tryAgain")) { dependencies.install() }
                        .buttonStyle(AccentButtonStyle())

                    if dependencies.brewPath != nil {
                        Button(l10n.t("install.brewFallback")) { dependencies.installViaHomebrew() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Button(l10n.t("install.checkAgain")) { dependencies.check() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

        default:
            VStack(spacing: 12) {
                Button {
                    dependencies.install()
                } label: {
                    Label(l10n.t("install.install"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(AccentButtonStyle())

                Text(l10n.t("install.sizeHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    Button(l10n.t("install.checkAgain")) { dependencies.check() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    if dependencies.brewPath != nil {
                        Button(l10n.t("install.brewFallback")) { dependencies.installViaHomebrew() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ltAccent)
                    }
                }
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 7) {
            HStack {
                Text(l10n.t("install.downloading"))
                Spacer()
                Text("\(Int((dependencies.progress * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.ltAccent, .ltAccentWarm],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * max(0, min(1, dependencies.progress))))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: 470)
    }
}

struct LogConsole: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(9)
                    .id("log-bottom")
            }
            .frame(height: 150)
            .frame(maxWidth: 470)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(scheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.05))
            )
            .onChange(of: text) { _, _ in
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }
}
