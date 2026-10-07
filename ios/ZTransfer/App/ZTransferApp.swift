import SwiftUI

@main
struct ZTransferApp: App {
    init() {
        // Application-scoped, not owned by a settings/purchase popup.
        StoreKitPurchaseStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--remote-tools-ui-test") {
                RemoteToolsInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--photo-preview-ui-test") {
                PhotoPreviewInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--button-motion-ui-test") {
                ButtonInteractionTestHarness()
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
        }
    }
}
