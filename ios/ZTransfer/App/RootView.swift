import SwiftUI
import UIKit

enum AppLocalized {
    private static func decodeAndroidEscapes(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
    }

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
        case "en": return decodeAndroidEscapes(AndroidLocalization.en[value] ?? value)
        case "hant": return decodeAndroidEscapes(AndroidLocalization.hant[value] ?? value)
        default: return decodeAndroidEscapes(value)
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
        return decodeAndroidEscapes(
            IOSLocalization.byResource[name]?[language]
                ?? AndroidLocalization.byResource[name]?[language]
                ?? name
        )
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
    @AppStorage("keep_screen_on") private var keepScreenOn = true
    @AppStorage("skin_preset") private var skinPreset = "FROSTED_GLASS"
    @AppStorage("thumbnail_columns") private var thumbnailColumns = 3
    @Environment(\.scenePhase) private var scenePhase
    // Keep HomeScreen alive for the connection-success celebration before
    // handing off to the file list. The final hand-off is a short cross-fade,
    // so the icon can disappear cleanly while the first list frame appears.
    @State private var connectionCelebrationActive = false
    @State private var connectionCelebrationStart: Date?
    @State private var connectionPhotoListVisible = false
    // Once established, transport loss must not return the user to connection.
    @State private var establishedSession: CameraSession?
    // The success scene is an entry transition, never a reconnect transition.
    @State private var connectionCelebrationConsumed = false
    @State private var monitorPresented = false

    private var locale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "zh-Hant": return Locale(identifier: "zh-Hant")
        default: return .current
        }
    }

    private var gpsBlockedByAPCamera: Bool {
        guard let session = connectionModel.cameraSession else { return false }
        return !session.isUSB && session.wirelessMode == .ap
    }
    var body: some View {
        Group {
            if let session = connectionModel.cameraSession ?? establishedSession {
                // Start the photo scan as soon as the session is ready, but
                // keep the list visually hidden until the connection scene
                // reaches its final cross-fade. A boolean hand-off keeps the
                // large list out of the per-frame celebration redraw.
                ZStack {
                    PhotoListView(session: session,
                                  queue: transferQueue,
                                  directory: directoryStore,
                                  effectsStore: effectsStore,
                                  isSessionConnected: connectionModel.cameraSession === session,
                                  onRetrySTA: { connectionModel.retrySTAConnection() },
                                  remotePresentation: $monitorPresented,
                                  onTransportLost: { failedSession in
                                      Task { await connectionModel.handleTransportLost(failedSession) }
                                  })
                    // A recovered transport owns a new CameraSession. Force
                    // the list model to bind to that session instead of
                    // retaining the failed repository from the old one.
                    .id(ObjectIdentifier(session))
                    .opacity(connectionCelebrationActive ? (connectionPhotoListVisible ? 1 : 0) : 1)
                    .allowsHitTesting(!connectionCelebrationActive || connectionPhotoListVisible)
                    if connectionCelebrationActive {
                        HomeWorkspacePagerIOS(connection: connectionModel,
                                               effectsStore: effectsStore,
                                               gpsCoordinator: gpsCoordinator,
                                               directory: directoryStore,
                                               celebrationStart: connectionCelebrationStart)
                            .opacity(connectionPhotoListVisible ? 0 : 1)
                            .allowsHitTesting(!connectionPhotoListVisible)
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
        .fullScreenCover(isPresented: $monitorPresented) {
            if let session = connectionModel.cameraSession ?? establishedSession {
                let listModel = PhotoListViewModel.cached(session: session)
                RemoteView(session: session,
                           recordingDirectory: directoryStore.directoryURL,
                           isSessionConnected: connectionModel.cameraSession === session,
                           onRetrySTA: { connectionModel.retrySTAConnection() },
                           onPreparing: { await listModel.pauseForRemote() },
                           onStopped: { transportLost in
                               await listModel.resumeAfterRemote(
                                   isConnected: connectionModel.cameraSession === session && !transportLost)
                           },
                           onTransportLost: {
                               Task { await connectionModel.handleTransportLost(session) }
                           })
                    .id(ObjectIdentifier(session))
            }
        }
        .task {
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
            connectionModel.setGPSConnectionPaused(gpsCoordinator.state.enabled)
        }
        .onDisappear {
            // Full-screen routes can make the root temporarily disappear.
            // Connection ownership remains in the model until its teardown;
            // navigation must not stop discovery or an accepted USB session.
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onAppear {
            let restoredSkin = normalizedSkinPreset(UserDefaults.standard.string(forKey: "skin_preset"))
            if skinPreset != restoredSkin { skinPreset = restoredSkin }
            let restoredColumns = normalizedThumbnailColumns(thumbnailColumns)
            if thumbnailColumns != restoredColumns { thumbnailColumns = restoredColumns }
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
            if connectionModel.cameraSession != nil, !connectionCelebrationConsumed {
                connectionCelebrationConsumed = true
                establishedSession = connectionModel.cameraSession
                connectionCelebrationStart = Date()
                connectionPhotoListVisible = false
                connectionCelebrationActive = true
            }
        }
        .onChange(of: connectionModel.cameraSession.map { ObjectIdentifier($0) }) { sessionID in
            let connected = sessionID != nil
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
            if connected {
                if let previous = establishedSession,
                   let replacement = connectionModel.cameraSession,
                   previous !== replacement {
                    PhotoListViewModel.evict(session: previous)
                }
                establishedSession = connectionModel.cameraSession
                // The queue belongs to the workspace, not to the old camera.
                // A recovered session must replace its download provider.
                if let session = connectionModel.cameraSession {
                    Task {
                        guard connectionModel.cameraSession === session else { return }
                        await transferQueue.attach(session: session, directory: directoryStore.directoryURL)
                        if connectionModel.cameraSession !== session {
                            await transferQueue.detach(ifCurrentSessionIs: session)
                        }
                    }
                }
                if !connectionCelebrationConsumed {
                    connectionCelebrationConsumed = true
                    connectionCelebrationStart = Date()
                    connectionPhotoListVisible = false
                    connectionCelebrationActive = true
                } else {
                    // A transport recovery updates the mounted session in
                    // place; it must never send the user through the entry
                    // scene a second time.
                    connectionCelebrationStart = nil
                    connectionPhotoListVisible = true
                    connectionCelebrationActive = false
                }
            } else {
                // Keep the photo workspace mounted; transport loss is handled
                // in place by the list and queue reconnect flow.
                if let failedSession = establishedSession {
                    Task { await transferQueue.detach(ifCurrentSessionIs: failedSession) }
                }
                connectionCelebrationStart = nil
                connectionPhotoListVisible = true
                connectionCelebrationActive = false
            }
        }
        .onChange(of: connectionModel.cameraSession?.isUSB) { _ in
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
        }
        .onChange(of: connectionModel.cameraSession?.wirelessMode) { _ in
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
        }
        .onChange(of: gpsCoordinator.state.enabled) { enabled in
            connectionModel.setGPSConnectionPaused(enabled)
        }
        .onChange(of: keepScreenOn) { enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled && scenePhase == .active
        }
        .onChange(of: scenePhase) { phase in
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn && phase == .active
            connectionModel.setUSBForegroundActive(phase == .active)
            if phase == .active {
                connectionModel.refreshUSBAuthorization()
            }
        }
        .task(id: connectionModel.cameraSession != nil) {
            guard connectionModel.cameraSession != nil, connectionCelebrationActive else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(CONNECTION_HANDOFF_FADE_START_MS) * 1_000_000)
                guard !Task.isCancelled, connectionModel.cameraSession != nil,
                      connectionCelebrationActive else { return }
                withAnimation(.easeInOut(duration: CONNECTION_HANDOFF_FADE_DURATION_MS / 1_000)) {
                    connectionPhotoListVisible = true
                }
                try await Task.sleep(nanoseconds: UInt64(CONNECTION_HANDOFF_FADE_DURATION_MS) * 1_000_000)
                guard !Task.isCancelled, connectionModel.cameraSession != nil,
                      connectionCelebrationActive else { return }
                connectionCelebrationActive = false
                connectionCelebrationStart = nil
            } catch {
                // A disconnect or a replacement session cancels this hand-off.
            }
        }
    }
}

/// Android keeps a missing value on the current frosted-glass default, while
/// retired or corrupt persisted values migrate to titanium and are written
/// back immediately.
func normalizedSkinPreset(_ stored: String?) -> String {
    guard let stored else { return "FROSTED_GLASS" }
    if stored == "LIQUID_GLASS" {
        if #available(iOS 26.0, *) { return stored }
        return "FROSTED_GLASS"
    }
    return ["FROSTED_GLASS", "WOOD", "CAMERA_CONTROLS", "TITANIUM"].contains(stored)
        ? stored
        : "TITANIUM"
}

private let CONNECTION_HANDOFF_FADE_START_MS = 1_380.0
private let CONNECTION_HANDOFF_FADE_DURATION_MS = 220.0

func workspacePagerUserScrollEnabled(
    gpsEnabled: Bool,
    currentPage: Int,
    gpsPanelPresented: Bool
) -> Bool {
    currentPage == 1 || (!gpsEnabled && !gpsPanelPresented)
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
    @State private var gpsPanelPresented = false

    private var localWorkspaceMustRelease: Bool {
        if connection.cameraSession != nil { return true }
        if case .connecting = connection.state.usbPhase { return true }
        switch connection.state.wifiPhase {
        case .discovering, .pairing, .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        GeometryReader { proxy in
            VerticalWorkspacePager(
                selection: $page,
                // Android blocks entry into the lower workbench for the whole
                // GPS session, while still allowing a page already below to
                // return upward to the connection page.
                isScrollEnabled: workspacePagerUserScrollEnabled(
                    gpsEnabled: gpsCoordinator.state.enabled,
                    currentPage: page,
                    gpsPanelPresented: gpsPanelPresented
                ),
                onInteractiveTransitionBegan: { destination in
                    if destination == 1, !gpsCoordinator.state.enabled {
                        connection.setConnectionDiscoveryPaused(true)
                    }
                },
                onTransitionSettled: { currentPage in
                    if currentPage != 0 { gpsPanelPresented = false }
                    connection.setConnectionDiscoveryPaused(currentPage != 0)
                },
                firstPage: {
                ConnectionPage(model: connection,
                               effectsStore: effectsStore,
                               gpsCoordinator: gpsCoordinator,
                               directory: directory,
                               celebrationStart: celebrationStart,
                               onOpenWorkspace: {
                    navigate(to: 1)
                }, gpsPanelPresented: $gpsPanelPresented)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                },
                secondPage: {
                Group {
                    if localWorkspaceMustRelease {
                        ZTransferColors.background
                    } else {
                        LocalPhotoEffectsView(onNavigateUp: {
                            navigate(to: 0)
                        })
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(ZTransferColors.background)
            .onChange(of: page) { currentPage in
                if currentPage != 0 { gpsPanelPresented = false }
                connection.setConnectionDiscoveryPaused(currentPage != 0)
            }
        }
        .background(ZTransferColors.background.ignoresSafeArea())
        .onAppear {
            connection.setConnectionDiscoveryPaused(page != 0)
        }
    }

    private func navigate(to destination: Int) {
        guard destination != page else { return }
        guard destination != 1 || !gpsCoordinator.state.enabled else { return }
        // A presented GPS overflow pauses only the connection-page pager.
        // Clear it before changing selection so a stale scroll lock cannot
        // swallow the workbench's explicit back button.
        if gpsPanelPresented { gpsPanelPresented = false }
        // VerticalWorkspacePager owns the native animated transition. A
        // SwiftUI animation transaction only changes the selection value and
        // makes UIPageViewController jump, which reads as a screen refresh.
        page = destination
    }
}

/// A vertical UIPageViewController gives programmatic entry/return the same
/// full-page movement as a finger-driven swipe. SwiftUI's page-style TabView
/// does not reliably animate selection changes, even inside withAnimation.
private struct VerticalWorkspacePager<FirstPage: View, SecondPage: View>: UIViewControllerRepresentable {
    @Binding var selection: Int
    let isScrollEnabled: Bool
    let onInteractiveTransitionBegan: (Int) -> Void
    let onTransitionSettled: (Int) -> Void
    let firstPage: FirstPage
    let secondPage: SecondPage

    init(
        selection: Binding<Int>,
        isScrollEnabled: Bool,
        onInteractiveTransitionBegan: @escaping (Int) -> Void,
        onTransitionSettled: @escaping (Int) -> Void,
        @ViewBuilder firstPage: () -> FirstPage,
        @ViewBuilder secondPage: () -> SecondPage
    ) {
        _selection = selection
        self.isScrollEnabled = isScrollEnabled
        self.onInteractiveTransitionBegan = onInteractiveTransitionBegan
        self.onTransitionSettled = onTransitionSettled
        self.firstPage = firstPage()
        self.secondPage = secondPage()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        pager.setViewControllers(
            [context.coordinator.controller(for: selection)],
            direction: .forward,
            animated: false
        )
        context.coordinator.visibleIndex = selection
        updateScrolling(in: pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.first.rootView = firstPage
        coordinator.second.rootView = secondPage
        updateScrolling(in: pager)

        let target = min(1, max(0, selection))
        guard target != coordinator.visibleIndex,
              !coordinator.transitioning else { return }
        let direction: UIPageViewController.NavigationDirection =
            target > coordinator.visibleIndex ? .forward : .reverse
        coordinator.transitioning = true
        pager.setViewControllers(
            [coordinator.controller(for: target)],
            direction: direction,
            animated: true
        ) { finished in
            DispatchQueue.main.async {
                coordinator.transitioning = false
                guard finished else {
                    coordinator.parent.selection = coordinator.visibleIndex
                    return
                }
                coordinator.visibleIndex = target
                coordinator.parent.onTransitionSettled(target)
            }
        }
    }

    private func updateScrolling(in pager: UIPageViewController) {
        for scrollView in pager.view.subviews.compactMap({ $0 as? UIScrollView }) {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalWorkspacePager
        let first: UIHostingController<FirstPage>
        let second: UIHostingController<SecondPage>
        var visibleIndex: Int
        var transitioning = false

        init(parent: VerticalWorkspacePager) {
            self.parent = parent
            first = UIHostingController(rootView: parent.firstPage)
            second = UIHostingController(rootView: parent.secondPage)
            visibleIndex = min(1, max(0, parent.selection))
            super.init()
            first.view.backgroundColor = .clear
            second.view.backgroundColor = .clear
        }

        func controller(for index: Int) -> UIViewController {
            index == 0 ? first : second
        }

        private func index(of controller: UIViewController) -> Int? {
            if controller === first { return 0 }
            if controller === second { return 1 }
            return nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            index(of: viewController) == 1 ? first : nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            index(of: viewController) == 0 ? second : nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            guard let pending = pendingViewControllers.first,
                  let destination = index(of: pending) else { return }
            transitioning = true
            parent.onInteractiveTransitionBegan(destination)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            transitioning = false
            guard let current = pageViewController.viewControllers?.first,
                  let currentIndex = index(of: current) else { return }
            visibleIndex = currentIndex
            if parent.selection != currentIndex {
                parent.selection = currentIndex
            }
            parent.onTransitionSettled(currentIndex)
        }
    }
}
