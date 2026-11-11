#if DEBUG
import SwiftUI

/// Uses the production settings view/store and the same root runtime handoff;
/// only preferences and directory are isolated from the user's workspace.
@MainActor
struct PhotoEffectsSettingsHarness: View {
    @StateObject private var effects: PhotoEffectsStore
    @StateObject private var directory: DirectoryAccessStore
    @StateObject private var filterLifetime: PhotoFilterEditorLifetime
    private let usesImportedFixture = ProcessInfo.processInfo.arguments.contains("--effects-np3-fixture")
    private let localEntry = ProcessInfo.processInfo.arguments.contains("--effects-np3-local")
    private let popupEntry = ProcessInfo.processInfo.arguments.contains("--effects-popup-motion")
    @State private var popupPresented = false
    @State private var draft: PhotoEffectsSettings
    @State private var hint: PhotoEffectsHint?
    @State private var gate = "pending"
    private let queue: TransferQueue
    init() {
        let name = "EffectsMasterUITest"
        if ProcessInfo.processInfo.arguments.contains("--reset-effects-master") {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        let defaults = UserDefaults(suiteName: name)!
        let local = ProcessInfo.processInfo.arguments.contains("--effects-np3-local")
        let store = PhotoEffectsStore(defaults: defaults, scope: local ? .localPhotos : .cameraTransfer)
        if ProcessInfo.processInfo.arguments.contains("--reset-effects-master") {
            var settings = store.settings; settings.photoFrameEnabled = true
            store.update(settings)
        }
        _effects = StateObject(wrappedValue: store)
        _directory = StateObject(wrappedValue: DirectoryAccessStore(defaults: defaults))
        if ProcessInfo.processInfo.arguments.contains("--effects-np3-fixture") &&
            !ProcessInfo.processInfo.arguments.contains("--effects-np3-fixture-no-folder") {
            store.np3Store.replaceFolder(DebugPhotoFilterFixture.folder, bookmark: Data([1]))
        }
        _filterLifetime = StateObject(wrappedValue: PhotoFilterEditorLifetime(
            PhotoFilterEditorSession(store: store.np3Store, role: local ? .local : .transfer, source: DebugPhotoFilterFixture.source)))
        _draft = State(initialValue: store.settings)
        queue = TransferQueue(defaults: UserDefaults(suiteName: name)!)
    }
    var body: some View {
        Group {
            if popupEntry {
                Color.gray.opacity(0.15)
                    .overlay(alignment: .topLeading) {
                        Button { popupPresented = true } label: {
                            Text("Effects").frame(width: 80, height: 36)
                        }
                        .buttonStyle(ZTransferGlassButtonStyle())
                        .accessibilityIdentifier("photo-effects-test-popup-open")
                        .geniePopupAnchor(.settings)
                        .padding(12)
                    }
                    .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
                        if let anchor = anchors[.settings] {
                            SettingsPopupOverlay(isPresented: $popupPresented, showPhotoEffectsEntry: true,
                                effectsStore: effects, directory: directory, anchor: anchor)
                        }
                    }
            } else if localEntry {
                LocalPhotoEffectsView(onNavigateUp: {}, effectsStore: effects, photoFilterSession: filterLifetime.session)
            } else {
                SettingsView(showPhotoEffectsEntry: true, effectsStore: effects, directory: directory,
                    effectsDraft: $draft, effectsHint: $hint, dismissalRequested: false,
                    photoFilterSession: usesImportedFixture ? filterLifetime.session : nil)
            }
        }
            .photoEffectsExpandedPresentation()
            .overlay {
                // The production SettingsPopupOverlay owns this outer host.
                // Match it when injecting a session into the standalone harness.
                if usesImportedFixture && !localEntry {
                    PhotoNP3ChooserPresentation(session: filterLifetime.session, draft: $draft)
                }
            }
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
            .onAppear {
                if usesImportedFixture && !localEntry { filterLifetime.session.begin(draft: $draft, active: false) {} }
            }
            .onDisappear { if usesImportedFixture && !localEntry { filterLifetime.session.end() } }
    }
}
#endif
