import SwiftUI

enum AppLocalized {
    /// Uses the Android string resources as the source of truth. The maps are
    /// generated from app/src/main/res/values*/strings.xml; do not hand-edit
    /// or add alternate translations here.
    static func text(_ value: String) -> String {
        let tag = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language: String
        if tag == "en" || (tag == "system" && Locale.current.language.languageCode?.identifier == "en") {
            language = "en"
        } else if tag == "zh-Hant" || (tag == "system" && Locale.current.language.script?.identifier == "Hant") {
            language = "hant"
        } else {
            language = "zh"
        }
        switch language {
        case "en": return AndroidLocalization.en[value] ?? value
        case "hant": return AndroidLocalization.hant[value] ?? value
        default: return value
        }
    }

    static func resource(_ name: String) -> String {
        let tag = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language: String
        if tag == "en" || (tag == "system" && Locale.current.language.languageCode?.identifier == "en") {
            language = "en"
        } else if tag == "zh-Hant" || (tag == "system" && Locale.current.language.script?.identifier == "Hant") {
            language = "hant"
        } else {
            language = "zh"
        }
        return AndroidLocalization.byResource[name]?[language] ?? name
    }

    static func versionText(_ version: String) -> String {
        resource("version_label").replacingOccurrences(of: "%1$s", with: version)
    }

    static func settingState(_ enabled: Bool) -> String {
        resource(enabled ? "setting_on" : "setting_off")
    }
}

struct RootView: View {
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var effectsStore = PhotoEffectsStore()
    @StateObject private var gpsCoordinator = GPSCoordinator()
    @StateObject private var directoryStore = DirectoryAccessStore()
    @State private var transferQueue = TransferQueue()
    @AppStorage("themeMode") private var themeMode = "自动"
    @AppStorage("appLanguage") private var appLanguage = "system"

    private var locale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "zh-Hant": return Locale(identifier: "zh-Hant")
        default: return .current
        }
    }
    var body: some View {
        Group {
            if let session = connectionModel.cameraSession {
                PhotoListView(session: session, queue: transferQueue, directory: directoryStore) {
                    Task { await connectionModel.disconnectCamera() }
                }
            } else {
                HomeWorkspacePagerIOS(connection: connectionModel, effectsStore: effectsStore, gpsCoordinator: gpsCoordinator, directory: directoryStore)
            }
        }
        .preferredColorScheme(themeMode == "深色" ? .dark : themeMode == "浅色" ? .light : nil)
        .environment(\.locale, locale)
        .task {
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
        }
        .onDisappear {
            connectionModel.stopUSBDiscovery()
            connectionModel.stopWiFiDiscovery()
        }
    }
}


/// Android HomeWorkspacePager equivalent. The workbench is the page below the
/// connection page; it is never presented as a sheet or a modal route.
private struct HomeWorkspacePagerIOS: View {
    @ObservedObject var connection: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    @ObservedObject var gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    @State private var page = 0

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $page) {
                ConnectionPage(model: connection, effectsStore: effectsStore, gpsCoordinator: gpsCoordinator, directory: directory, onOpenWorkspace: {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) { page = 1 }
                })
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .tag(0)
                LocalPhotoEffectsView(onNavigateUp: {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) { page = 0 }
                })
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .tag(1)
            }
            .rotationEffect(.degrees(90))
            .frame(width: proxy.size.height, height: proxy.size.width)
            .offset(x: (proxy.size.width - proxy.size.height) / 2, y: (proxy.size.height - proxy.size.width) / 2)
            .background(ZTransferColors.background)
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
        }
        .background(ZTransferColors.background.ignoresSafeArea())
    }
}
