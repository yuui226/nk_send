import SwiftUI

enum AppLocalized {
    /// Uses the Android string resources as the source of truth. The maps are
    /// generated from app/src/main/res/values*/strings.xml; do not hand-edit
    /// or add alternate translations here.
    static func text(_ value: String) -> String {
        let tag = UserDefaults.standard.string(forKey: "app_language") ?? "system"
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
        let tag = UserDefaults.standard.string(forKey: "app_language") ?? "system"
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

    static func formattedResource(_ name: String, _ replacements: [String: String]) -> String {
        replacements.reduce(resource(name)) { result, pair in
            result.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}

struct RootView: View {
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var effectsStore = PhotoEffectsStore()
    @StateObject private var gpsCoordinator = GPSCoordinator()
    @StateObject private var directoryStore = DirectoryAccessStore()
    @State private var transferQueue = TransferQueue()
    @AppStorage("theme_mode") private var themeMode = "SYSTEM"
    @AppStorage("app_language") private var appLanguage = "system"
    // Android keeps HomeScreen alive for the connection-success celebration
    // (500 ms delay + 760 ms effect) before entering the file list.  Keep the
    // newly-created session in this hand-off state instead of switching views
    // as soon as the transport handshake completes.
    @State private var connectionCelebrationActive = false
    @State private var connectionCelebrationStart: Date?

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
                // Android starts the file scan as soon as the camera session is
                // ready, while HomeScreen remains visible for the 1260 ms
                // success hand-off. Keep the list mounted (but hidden and
                // untouchable) so its scanner/cache lifecycle starts at the
                // same boundary instead of being delayed by the animation.
                ZStack {
                    PhotoListView(session: session,
                                  queue: transferQueue,
                                  directory: directoryStore,
                                  effectsStore: effectsStore) {
                        Task { await connectionModel.disconnectCamera() }
                    }
                    .opacity(connectionCelebrationActive ? 0 : 1)
                    .allowsHitTesting(!connectionCelebrationActive)
                    if connectionCelebrationActive {
                        HomeWorkspacePagerIOS(connection: connectionModel,
                                               effectsStore: effectsStore,
                                               gpsCoordinator: gpsCoordinator,
                                               directory: directoryStore,
                                               celebrationStart: connectionCelebrationStart)
                    }
                }
            } else {
                HomeWorkspacePagerIOS(connection: connectionModel,
                                       effectsStore: effectsStore,
                                       gpsCoordinator: gpsCoordinator,
                                       directory: directoryStore,
                                       celebrationStart: connectionCelebrationStart)
            }
        }
        .preferredColorScheme(themeMode == "DARK" ? .dark : themeMode == "LIGHT" ? .light : nil)
        .environment(\.locale, locale)
        .task {
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
        }
        .onDisappear {
            connectionModel.stopUSBDiscovery()
            connectionModel.stopWiFiDiscovery()
        }
        .onAppear {
            if connectionModel.cameraSession != nil {
                connectionCelebrationStart = Date()
                connectionCelebrationActive = true
            }
        }
        .onChange(of: connectionModel.cameraSession != nil) { connected in
            if connected {
                connectionCelebrationStart = Date()
                connectionCelebrationActive = true
            } else {
                connectionCelebrationStart = nil
                connectionCelebrationActive = false
            }
        }
        .task(id: connectionModel.cameraSession != nil) {
            guard connectionModel.cameraSession != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 1_260_000_000)
                guard !Task.isCancelled, connectionModel.cameraSession != nil else { return }
                connectionCelebrationActive = false
                connectionCelebrationStart = nil
            } catch {
                // A disconnect or a replacement session cancels this hand-off.
            }
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
    let celebrationStart: Date?
    @State private var page = 0

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $page) {
                ConnectionPage(model: connection,
                               effectsStore: effectsStore,
                               gpsCoordinator: gpsCoordinator,
                               directory: directory,
                               celebrationStart: celebrationStart,
                               onOpenWorkspace: {
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
