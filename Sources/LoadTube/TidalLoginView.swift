import SwiftUI
import AppKit

struct TidalLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var l10n: Localization
    @EnvironmentObject private var tidal: TidalService

    @State private var login: TidalDeviceLogin?
    @State private var errorMessage: String?
    @State private var isStarting = false
    @State private var secondsLeft = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.t("tidal.login.title"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(l10n.t("tidal.login.subtitle"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("settings.done")) { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isStarting {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("tidal.login.starting"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 26)
            } else if let login {
                codeCard(login)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(l10n.t("tidal.login.failed"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Button(l10n.t("tidal.login.retry")) { start() }
                        .buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(l10n.t("tidal.login.note"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 390)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func codeCard(_ login: TidalDeviceLogin) -> some View {
        VStack(spacing: 14) {
            Text(l10n.t("tidal.login.codeHint"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Text(login.userCode)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .kerning(3)
                .textSelection(.enabled)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            HStack(spacing: 10) {
                Button {
                    copy(login.userCode)
                } label: {
                    Label(l10n.t("tidal.login.copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ltAccent)

                Spacer()

                Button {
                    NSWorkspace.shared.open(login.verificationURL)
                } label: {
                    Label(l10n.t("tidal.login.open"), systemImage: "safari")
                }
                .buttonStyle(AccentButtonStyle())
            }

            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(secondsLeft > 0
                     ? l10n.f("tidal.login.waitingTime", secondsLeft)
                     : l10n.t("tidal.login.waiting"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func start() {
        stop()
        errorMessage = nil
        isStarting = true
        login = nil

        Task {
            do {
                let value = try await tidal.startLogin()
                await MainActor.run {
                    login = value
                    isStarting = false
                    secondsLeft = max(0, Int(value.expiresAt.timeIntervalSinceNow))
                    copy(value.userCode)
                    startCountdown()
                    startPolling(value)
                }
            } catch {
                await MainActor.run {
                    isStarting = false
                    errorMessage = tidal.message(for: error)
                }
            }
        }
    }

    private func startPolling(_ login: TidalDeviceLogin) {
        pollTask = Task {
            do {
                _ = try await tidal.waitForLogin(login)
                await MainActor.run {
                    stop()
                    dismiss()
                }
            } catch is CancellationError {
                // Окно закрыли.
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        errorMessage = tidal.message(for: error)
                        self.login = nil
                    }
                }
            }
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard let login else { return }
                    secondsLeft = max(0, Int(login.expiresAt.timeIntervalSinceNow))
                    if secondsLeft == 0 {
                        errorMessage = l10n.t("tidal.login.expired")
                        self.login = nil
                        pollTask?.cancel()
                    }
                }
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        countdownTask?.cancel()
        pollTask = nil
        countdownTask = nil
    }

    private func close() {
        stop()
        dismiss()
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
