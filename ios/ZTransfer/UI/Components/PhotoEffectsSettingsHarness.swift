#if DEBUG
import SwiftUI

/// Uses the production settings view/store and the same root runtime handoff;
/// only preferences and directory are isolated from the user's workspace.
@MainActor
struct PhotoEffectsSettingsHarness: View {
    @StateObject private var effects: PhotoEffectsStore
    @StateObject private var directory: DirectoryAccessStore
    @State private var draft: PhotoEffectsSettings
    @State private var chooser = PhotoFilterChooserState()
    @State private var hint: PhotoEffectsHint?
    @State private var gate = "pending"
    private let queue: TransferQueue
    init() {
        let name = "EffectsMasterUITest"
        if ProcessInfo.processInfo.arguments.contains("--reset-effects-master") {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        let defaults = UserDefaults(suiteName: name)!
        let store = PhotoEffectsStore(defaults: defaults)
        if ProcessInfo.processInfo.arguments.contains("--reset-effects-master") {
            var settings = store.settings; settings.photoFrameEnabled = true
            store.update(settings)
        }
        _effects = StateObject(wrappedValue: store)
        _directory = StateObject(wrappedValue: DirectoryAccessStore(defaults: defaults))
        _draft = State(initialValue: store.settings)
        queue = TransferQueue(defaults: UserDefaults(suiteName: name)!)
    }
    var body: some View {
        SettingsView(showPhotoEffectsEntry: true, effectsStore: effects, directory: directory,
            effectsDraft: $draft, filterChooser: $chooser, effectsHint: $hint, dismissalRequested: false)
            .overlay(alignment: .top) {
                Text("gate=\(gate);recipe=\(effects.settings.photoFrameEnabled)")
                    .font(.system(size: 9)).allowsHitTesting(false)
                    .accessibilityIdentifier("effects-master-test-state")
            }
            .task(id: effects.isEnabled) {
                await queue.setPhotoEffectsEnabled(effects.isEnabled)
                guard !Task.isCancelled else { return }
                gate = effects.isEnabled ? "on" : "off"
            }
    }
}
#endif
