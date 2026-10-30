import Foundation
import Combine
import Sparkle

/// Мягкое (необязательное) обновление через Sparkle 2.
/// Sparkle сам проверяет appcast и показывает окно с описанием изменений;
/// обновление скачивается и устанавливается только после явного согласия.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    @Published private(set) var hasUnseenUpdate = false

    let currentVersion: String

    lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private static let autoCheckKey = "autoUpdateCheck"

    override init() {
        currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
        super.init()

        controller.updater.automaticallyChecksForUpdates = Self.autoCheckEnabled
        controller.startUpdater()
    }

    private static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
    }

    /// Ручная проверка обновлений (пункт меню и кнопка в настройках).
    func checkManually() {
        controller.checkForUpdates(nil)
    }

    /// Синхронизация переключателя автопроверки со Sparkle.
    func setAutoCheck(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.autoCheckKey)
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            hasUnseenUpdate = true
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            hasUnseenUpdate = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice == .skip else { return }
        Task { @MainActor in
            hasUnseenUpdate = false
        }
    }
}
