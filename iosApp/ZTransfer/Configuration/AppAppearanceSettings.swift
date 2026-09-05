import Foundation
import SwiftUI
import UIKit
import ZTransferShared

/// Independent of per-camera browse documents, so saving a filter cannot overwrite app appearance.
@MainActor
final class AppearancePreferencesStore {
    static let key = "ztransfer.appearance.preferences"
    private let defaults: UserDefaults
    private struct Document: Codable {
        var version: Int
        var themeName: String?
        var appLanguage: String?
        var skinName: String?
        var hapticsEnabled: Bool?
        var keepScreenOn: Bool?
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func read() -> NativeAppearancePreferences? {
        guard let raw = defaults.object(forKey: Self.key) else { return NativeAppearancePreferences.companion.defaults() }
        guard let data = raw as? Data, data.count <= 16 * 1024,
              let value = try? JSONDecoder().decode(Document.self, from: data), value.version == 1 else { return nil }
        return NativeAppearancePreferences(themeName: value.themeName, appLanguage: value.appLanguage ?? "system",
            skinName: value.skinName, hapticsEnabled: value.hapticsEnabled ?? true, keepScreenOn: value.keepScreenOn ?? true)
    }

    func save(_ value: NativeAppearancePreferences) -> Bool {
        guard read() != nil else { return false } // Future/corrupt data is not silently replaced.
        let document = Document(version: 1, themeName: value.themeName, appLanguage: value.appLanguage,
            skinName: value.skinName, hapticsEnabled: value.hapticsEnabled, keepScreenOn: value.keepScreenOn)
        guard let data = try? JSONEncoder().encode(document), data.count <= 16 * 1024 else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.data(forKey: Self.key) == data // Defaults acknowledgement, not a disk fsync.
    }
}

/// Single app owner. File/queue sheets borrow model; their dismissal never resets settings or idle state.
@MainActor
final class AppAppearanceSettings: NSObject, ObservableObject, NativeAppearancePlatform {
    static let shared = AppAppearanceSettings()
    private let store: AppearancePreferencesStore
    private let notifications: NotificationCenter
    private let systemLanguage: () -> String
    private let screenAwake: (Bool) -> Void
    private let isApplicationActive: () -> Bool
    private var started = false
    private var closed = false
    @Published private(set) var themeName = "SYSTEM"
    private(set) lazy var model = NativeAppearanceModel(platform: self, systemLanguageTag: systemLanguage())

    var colorScheme: ColorScheme? {
        switch themeName { case "DARK": return .dark; case "LIGHT": return .light; default: return nil }
    }

    init(defaults: UserDefaults = .standard, notifications: NotificationCenter = .default,
         systemLanguage: @escaping () -> String = { Locale.preferredLanguages.first ?? "en" },
         screenAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         isApplicationActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        store = AppearancePreferencesStore(defaults: defaults)
        self.notifications = notifications; self.systemLanguage = systemLanguage
        self.screenAwake = screenAwake; self.isApplicationActive = isApplicationActive
        super.init()
        themeName = model.currentPreferences().themeName
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        notifications.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(willResignActive), name: UIApplication.didEnterBackgroundNotification, object: nil)
        notifications.addObserver(self, selector: #selector(localeChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        model.updateSystemLanguage(languageTag: systemLanguage())
        model.setApplicationActive(value: isApplicationActive())
    }

    // UIKit lifecycle notifications are synchronous on the main thread: do not enqueue a stale "active" Task.
    @objc private func didBecomeActive(_ notification: Notification) {
        guard !closed else { return }
        model.updateSystemLanguage(languageTag: systemLanguage())
        model.setApplicationActive(value: true)
    }
    @objc private func willResignActive(_ notification: Notification) {
        guard !closed else { return }
        model.setApplicationActive(value: false)
    }
    @objc nonisolated private func localeChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.model.updateSystemLanguage(languageTag: self.systemLanguage())
        }
    }

    func readAppearance() -> NativeAppearancePreferences? { store.read() }
    func saveAppearance(value: NativeAppearancePreferences) -> Bool {
        guard !closed else { return false }
        themeName = value.themeName // Live shell changes even if persistence is unavailable.
        return store.save(value)
    }
    func setScreenAwake(enabled: Bool) { screenAwake(enabled) }

    func close() {
        guard !closed else { return }
        closed = true
        notifications.removeObserver(self)
        model.close() // Releases idle timer and breaks the platform/model retain cycle.
    }
}
