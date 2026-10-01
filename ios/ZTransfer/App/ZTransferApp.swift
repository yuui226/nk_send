import SwiftUI

@main
struct ZTransferApp: App {
    init() {
        // Application-scoped, not owned by a settings/purchase popup.
        StoreKitPurchaseStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
