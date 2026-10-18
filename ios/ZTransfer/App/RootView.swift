import SwiftUI
import UIKit
import Combine

enum AppLocalized {
    private static func decodeAndroidEscapes(_ value: String) -> String {
        var result = ""
        var characters = value.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let escaped = characters.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\", "'", "\"": result.append(escaped)
            default: result.append("\\"); result.append(escaped)
            }
        }
        return result
    }

    /// Resolve supported resources in preferred-language order, then use Android's
    /// unqualified English resources. Explicit choices never mutate system locale.
    static func resourceLanguage(tag: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let candidates = tag == "system" ? preferredLanguages : [tag]
        for candidate in candidates {
            let locale = Locale(identifier: candidate)
            switch locale.language.languageCode?.identifier {
            case "en": return "en"
            case "zh":
                let script = locale.language.script?.identifier
                let traditional = script == "Hant" || (script != "Hans" && ["TW", "HK", "MO"].contains(locale.region?.identifier ?? ""))
                return traditional ? "hant" : "zh"
            default: continue
            }
        }
        return "en"
    }

    static func locale(for tag: String, preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        let language = resourceLanguage(tag: tag, preferredLanguages: preferredLanguages)
        return Locale(identifier: language == "hant" ? "zh-Hant" : language == "zh" ? "zh-Hans" : "en")
    }

    private static var currentResourceLanguage: String {
        resourceLanguage(tag: UserDefaults.standard.string(forKey: "app_language") ?? "system")
    }

    /// Uses the generated Android resources for both text and named lookups.
    static func text(_ value: String) -> String { text(value, language: currentResourceLanguage) }

    static func text(_ value: String, language: String) -> String {
        switch language {
        case "en": return decodeAndroidEscapes(AndroidLocalization.en[value] ?? value)
        case "hant": return decodeAndroidEscapes(AndroidLocalization.hant[value] ?? value)
        default: return decodeAndroidEscapes(value)
        }
    }

    static func resource(_ name: String) -> String { resource(name, language: currentResourceLanguage) }

    static func resource(_ name: String, language: String) -> String {
        decodeAndroidEscapes(
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

/// Own the services once, but publish only inputs consumed by the root route.
/// Android HomeWorkspacePager similarly projects enabled/release bits before
/// observing; GPS fixes, connection-card details and editor drafts stay local.
@MainActor
final class RootPresentationModel: ObservableObject {
    struct Snapshot: Equatable {
        var session: CameraSession?
        var mode: CameraPresentationMode
        var effectsEnabled: Bool
        var gpsEnabled: Bool
        var directoryURL: URL?
        var directoryRestoring: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.session === rhs.session && lhs.mode == rhs.mode &&
            lhs.effectsEnabled == rhs.effectsEnabled && lhs.gpsEnabled == rhs.gpsEnabled &&
            lhs.directoryURL == rhs.directoryURL && lhs.directoryRestoring == rhs.directoryRestoring
        }
    }

    let connection: ConnectionViewModel
    let effects: PhotoEffectsStore
    let gps: GPSCoordinator
    let directory: DirectoryAccessStore
    let queue: TransferQueue
    @Published private(set) var snapshot: Snapshot
    private var observations = Set<AnyCancellable>()

    init(connection: ConnectionViewModel? = nil, effects: PhotoEffectsStore? = nil,
         gps: GPSCoordinator? = nil, directory: DirectoryAccessStore? = nil,
         queue: TransferQueue = TransferQueue()) {
        let connection = connection ?? ConnectionViewModel()
        let effects = effects ?? PhotoEffectsStore()
        let gps = gps ?? GPSCoordinator()
        let directory = directory ?? DirectoryAccessStore()
        self.connection = connection; self.effects = effects; self.gps = gps
        self.directory = directory; self.queue = queue
        snapshot = Snapshot(session: connection.cameraSession,
            mode: connection.state.presentationMode(transport: nil, isSTA: false),
            effectsEnabled: effects.isEnabled, gpsEnabled: gps.state.enabled,
            directoryURL: directory.directoryURL, directoryRestoring: directory.isRestoring)
        // Use Published's incoming values, not a willSet-time read of the model.
        connection.$cameraSession.sink { [weak self] in self?.update(\.session, $0) }.store(in: &observations)
        connection.$state.map { $0.presentationMode(transport: nil, isSTA: false) }.removeDuplicates()
            .sink { [weak self] in self?.update(\.mode, $0) }.store(in: &observations)
        effects.$isEnabled.removeDuplicates()
            .sink { [weak self] in self?.update(\.effectsEnabled, $0) }.store(in: &observations)
        gps.$state.map(\.enabled).removeDuplicates()
            .sink { [weak self] in self?.update(\.gpsEnabled, $0) }.store(in: &observations)
        directory.$directoryURL.removeDuplicates()
            .sink { [weak self] in self?.update(\.directoryURL, $0) }.store(in: &observations)
        directory.$isRestoring.removeDuplicates()
            .sink { [weak self] in self?.update(\.directoryRestoring, $0) }.store(in: &observations)
    }

    private func update<Value>(_ key: WritableKeyPath<Snapshot, Value>, _ value: Value) {
        var next = snapshot
        next[keyPath: key] = value
        if next != snapshot { snapshot = next }
    }
}

struct RootView: View {
    #if DEBUG
    var didRender: (() -> Void)?
    #endif
    @StateObject private var presentation: RootPresentationModel
    private var connectionModel: ConnectionViewModel { presentation.connection }
    private var effectsStore: PhotoEffectsStore { presentation.effects }
    private var gpsCoordinator: GPSCoordinator { presentation.gps }
    private var directoryStore: DirectoryAccessStore { presentation.directory }
    private var transferQueue: TransferQueue { presentation.queue }

    init(presentation: @autoclosure @escaping () -> RootPresentationModel = RootPresentationModel()) {
        _presentation = StateObject(wrappedValue: presentation())
    }
    @AppStorage("theme_mode") private var themeMode = "SYSTEM"
    @AppStorage("app_language") private var appLanguage = "system"
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
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
    @State private var workspaceViewID = UUID()
    // The success scene is an entry transition, never a reconnect transition.
    @State private var connectionCelebrationConsumed = false
    // Android starts a new task at Home (MainActivity's NavHost). Retain the
    // workspace on transport loss within this run, never across a cold launch.
    // SceneStorage restored an offline photo/monitor page before any connection.
    @State private var workspaceEntered = false
    @State private var monitorPresented = false

    private var workspaceSession: CameraSession? { presentation.snapshot.session ?? establishedSession }
    private var workspaceConnected: Bool { workspaceSession != nil && presentation.snapshot.session === workspaceSession }
    private var restoredPresentationMode: CameraPresentationMode {
        presentation.snapshot.mode
    }

    private var locale: Locale { AppLocalized.locale(for: appLanguage) }

    private var gpsBlockedByAPCamera: Bool {
        guard let session = connectionModel.cameraSession else { return false }
        return !session.isUSB && session.wirelessMode == .ap
    }
    @State private var recordingSaveHint = PhotoListHintState()

    private func presentRecordingSaveFailure() {
        guard !monitorPresented, let message = RemoteRecordingSaveNotice.shared.take() else { return }
        recordingSaveHint.show(message, duration: .seconds(3))
    }

    var body: some View {
        #if DEBUG
        let _ = didRender?()
        #endif
        Group {
            if workspaceSession != nil || workspaceEntered {
                let session = workspaceSession
                // Start the photo scan as soon as the session is ready, but
                // keep the list visually hidden until the connection scene
                // reaches its final cross-fade. A boolean hand-off keeps the
                // large list out of the per-frame celebration redraw.
                ZStack {
                    PhotoListView(session: session, presentationMode: restoredPresentationMode,
                                  queue: transferQueue,
                                  directory: directoryStore,
                                  effectsStore: effectsStore,
                                  isSessionConnected: workspaceConnected,
                                  onRetrySTA: { connectionModel.retrySTAConnection() },
                                  remotePresentation: $monitorPresented,
                                  onTransportLost: { failedSession in
                                      Task { await connectionModel.handleTransportLost(failedSession) }
                                  })
                    // Same-body recovery keeps page state while its observed
                    // list model and transport dependencies are replaced.
                    .id(workspaceViewID)
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
        // Restoring used to block RootView's initialization. Keep the same
        // startup admission boundary while letting its existing scene render;
        // no action may mistake an unresolved saved folder for an unset one.
        .allowsHitTesting(!presentation.snapshot.directoryRestoring)
        .accessibilityHidden(presentation.snapshot.directoryRestoring)
        .preferredColorScheme(themeMode == "DARK" ? .dark : themeMode == "LIGHT" ? .light : nil)
        .environment(\.locale, locale)
        .overlay { PhotoListHint(state: recordingSaveHint) }
        .onReceive(NotificationCenter.default.publisher(for: RemoteRecordingSaveNotice.changed, object: RemoteRecordingSaveNotice.shared)) { _ in
            presentRecordingSaveFailure()
        }
        .fullScreenCover(isPresented: $monitorPresented, onDismiss: {
            RemoteTrialNotice.returnedToList()
            presentRecordingSaveFailure()
        }) {
            let session = workspaceSession
            let listModel = session.map { live in
                PhotoListViewModel.cached(session: live, onTransportLost: {
                    Task { await connectionModel.handleTransportLost(live) }
                })
            }
            RemoteView(session: session, presentationMode: restoredPresentationMode,
                       recordingDirectory: presentation.snapshot.directoryURL,
                       isSessionConnected: workspaceConnected,
                       onRetrySTA: { connectionModel.retrySTAConnection() },
                       onPreparing: { await listModel?.pauseForRemote() },
                       onStopped: { transportLost in
                           await listModel?.resumeAfterRemote(isConnected: workspaceConnected && !transportLost)
                       },
                       onTransportLost: {
                           if let session { Task { await connectionModel.handleTransportLost(session) } }
                       })
                .id(session.map(ObjectIdentifier.init))
        }
        .task(id: presentation.snapshot.effectsEnabled) {
            await transferQueue.setPhotoEffectsEnabled(presentation.snapshot.effectsEnabled)
        }
        .task {
            do { try await directoryStore.waitUntilRestored() } catch { return }
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
            connectionModel.setGPSConnectionPaused(gpsCoordinator.state.enabled)
        }
        .onAppear {
            presentRecordingSaveFailure()
            let restoredSkin = normalizedSkinPreset(UserDefaults.standard.string(forKey: "skin_preset"))
            if skinPreset != restoredSkin { skinPreset = restoredSkin }
            let restoredColumns = normalizedThumbnailColumns(thumbnailColumns)
            if thumbnailColumns != restoredColumns { thumbnailColumns = restoredColumns }
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
            if workspaceEntered { connectionCelebrationConsumed = true }
            if connectionModel.cameraSession != nil, !connectionCelebrationConsumed {
                connectionCelebrationConsumed = true
                establishedSession = connectionModel.cameraSession
                connectionCelebrationStart = Date()
                connectionPhotoListVisible = false
                connectionCelebrationActive = true
            }
        }
        .onChange(of: presentation.snapshot.session.map { ObjectIdentifier($0) }) { sessionID in
            let connected = sessionID != nil
            gpsCoordinator.setAPModeBlocked(gpsBlockedByAPCamera)
            if connected {
                if let previous = establishedSession,
                   let replacement = connectionModel.cameraSession,
                   previous !== replacement {
                    if replacement.recoveredFromSessionID == ObjectIdentifier(previous) {
                        _ = PhotoListViewModel.cached(session: replacement, onTransportLost: {
                            Task { await connectionModel.handleTransportLost(replacement) }
                        })
                    } else {
                        workspaceViewID = UUID()
                    }
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
                if !connectionCelebrationConsumed && !workspaceEntered {
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
        .onChange(of: presentation.snapshot.gpsEnabled) { enabled in
            connectionModel.setGPSConnectionPaused(enabled)
        }
        .onChange(of: scenePhase) { phase in
            connectionModel.setUSBForegroundActive(phase == .active)
            if phase == .active {
                connectionModel.refreshUSBAuthorization()
                StoreKitPurchaseStore.shared.refresh()
            }
        }
        .task(id: presentation.snapshot.session != nil) {
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
                workspaceEntered = true
            } catch {
                // A disconnect or a replacement session cancels this hand-off.
            }
        }
    }
}

/// iOS defaults to liquid glass where supported. Explicit saved choices stay
/// intact; retired or corrupt values retain the existing titanium migration.
func normalizedSkinPreset(_ stored: String?) -> String {
    guard let stored else { return ZTransferButtonSkin.defaultPreset.rawValue }
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


/// HomeWorkspacePager.shouldPauseConnectionDiscovery, with an in-flight target
/// retained while a newer button request is waiting for the native pager.
struct WorkspaceDiscoveryState {
    var settledPage = 0
    var requestedPage = 0
    var transitionTarget: Int?
    var shouldPause: Bool {
        settledPage == 1 || requestedPage == 1 || transitionTarget == 1
    }
    mutating func request(_ page: Int) { requestedPage = page }
    mutating func begin(_ page: Int) { transitionTarget = page }
    mutating func settle(_ page: Int) { settledPage = page; transitionTarget = nil }
}

/// Android HomeWorkspacePager equivalent. The workbench is the page below the
/// connection page; it is never presented as a sheet or a modal route.
@MainActor
final class HomeWorkspacePresentation: ObservableObject {
    @Published private(set) var releaseLocalWorkspace: Bool
    @Published private(set) var gpsEnabled: Bool
    private var observations = Set<AnyCancellable>()

    init(connection: ConnectionViewModel, gps: GPSCoordinator) {
        releaseLocalWorkspace = Self.shouldRelease(state: connection.state, hasSession: connection.cameraSession != nil)
        gpsEnabled = gps.state.enabled
        Publishers.CombineLatest(connection.$state, connection.$cameraSession)
            .map { Self.shouldRelease(state: $0.0, hasSession: $0.1 != nil) }.removeDuplicates()
            .sink { [weak self] value in
                if self?.releaseLocalWorkspace != value { self?.releaseLocalWorkspace = value }
            }.store(in: &observations)
        gps.$state.map(\.enabled).removeDuplicates().sink { [weak self] value in
            if self?.gpsEnabled != value { self?.gpsEnabled = value }
        }.store(in: &observations)
    }

    static func shouldRelease(state: ConnectionState, hasSession: Bool) -> Bool {
        if hasSession { return true }
        if case .connecting = state.usbPhase { return true }
        switch state.wifiPhase {
        case .discovering, .pairing, .connecting, .reconnecting: return true
        default: return false
        }
    }
}

struct HomeWorkspacePagerIOS: View {
    #if DEBUG
    var didRender: (() -> Void)?
    #endif
    let connection: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    let gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    let celebrationStart: Date?
    @StateObject private var presentation: HomeWorkspacePresentation
    @State private var page = 0
    @State private var discovery = WorkspaceDiscoveryState()
    @State private var gpsPanelPresented = false

    init(connection: ConnectionViewModel, effectsStore: PhotoEffectsStore,
         gpsCoordinator: GPSCoordinator, directory: DirectoryAccessStore, celebrationStart: Date?) {
        self.connection = connection; self.effectsStore = effectsStore
        self.gpsCoordinator = gpsCoordinator; self.directory = directory
        self.celebrationStart = celebrationStart
        _presentation = StateObject(wrappedValue: HomeWorkspacePresentation(connection: connection, gps: gpsCoordinator))
    }

    var body: some View {
        #if DEBUG
        let _ = didRender?()
        #endif
        GeometryReader { proxy in
            VerticalWorkspacePager(
                selection: $page,
                // Android blocks entry into the lower workbench for the whole
                // GPS session, while still allowing a page already below to
                // return upward to the connection page.
                isScrollEnabled: workspacePagerUserScrollEnabled(
                    gpsEnabled: presentation.gpsEnabled,
                    currentPage: page,
                    gpsPanelPresented: gpsPanelPresented
                ),
                onTransitionBegan: { destination in
                    discovery.begin(destination)
                    connection.setConnectionDiscoveryPaused(discovery.shouldPause)
                },
                onTransitionSettled: { currentPage in
                    if currentPage != 0 { gpsPanelPresented = false }
                    discovery.request(page)
                    discovery.settle(currentPage)
                    connection.setConnectionDiscoveryPaused(discovery.shouldPause)
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
                    if presentation.releaseLocalWorkspace {
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
                discovery.request(currentPage)
                connection.setConnectionDiscoveryPaused(discovery.shouldPause)
            }
        }
        .background(ZTransferColors.background.ignoresSafeArea())
        .onAppear {
            discovery.request(page)
            connection.setConnectionDiscoveryPaused(discovery.shouldPause)
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
        // keeps the pager transition separate from the SwiftUI state transaction.
        discovery.request(destination)
        connection.setConnectionDiscoveryPaused(discovery.shouldPause)
        page = destination
    }
}

/// Compose Foundation 1.7.6 final snap: below 400dp/s use the strict 50%
/// positional threshold; otherwise choose the adjacent bound in fling direction.
/// This pager has exactly two pages and no inter-page spacing.
func shouldEnterWorkspace(distance: CGFloat, upwardVelocity: CGFloat,
                          dragTranslation: CGFloat? = nil, pageHeight: CGFloat = 1_000) -> Bool {
    guard distance > 0 else { return false }
    if distance >= 1 { return true }
    if abs(upwardVelocity) >= 400 { return upwardVelocity > 0 }
    let height = max(1, pageHeight)
    let delta = -(dragTranslation ?? -distance * height) / height
    let forward = delta > 0
    if abs(delta.truncatingRemainder(dividingBy: 1)) > 0.50 { return forward }
    if abs(delta) >= min(56, height / 2) / height { return !forward }
    // A tiny new drag interrupting an existing transition snaps to the nearest
    // current bound, instead of treating the inherited offset as fresh travel.
    return distance >= 0.50
}

/// Android's return decision is positional, with a distance-qualified downward fling.
func shouldReturnFromWorkspace(distance: CGFloat, downwardVelocity: CGFloat) -> Bool {
    distance >= 0.30 || (distance >= 0.15 && downwardVelocity >= 1_200)
}

private struct VerticalWorkspacePager<FirstPage: View, SecondPage: View>: UIViewControllerRepresentable {
    @Binding var selection: Int
    let isScrollEnabled: Bool
    let onTransitionBegan: (Int) -> Void
    let onTransitionSettled: (Int) -> Void
    let firstPage: FirstPage
    let secondPage: SecondPage

    init(selection: Binding<Int>, isScrollEnabled: Bool,
         onTransitionBegan: @escaping (Int) -> Void, onTransitionSettled: @escaping (Int) -> Void,
         @ViewBuilder firstPage: () -> FirstPage, @ViewBuilder secondPage: () -> SecondPage) {
        _selection = selection
        self.isScrollEnabled = isScrollEnabled
        self.onTransitionBegan = onTransitionBegan
        self.onTransitionSettled = onTransitionSettled
        self.firstPage = firstPage()
        self.secondPage = secondPage()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> WorkspacePagingController {
        let controller = WorkspacePagingController(pages: [context.coordinator.first, context.coordinator.second], initialPage: selection)
        controller.began = { [weak coordinator = context.coordinator] in coordinator?.parent.onTransitionBegan($0) }
        controller.settled = { [weak coordinator = context.coordinator] page in
            guard let coordinator else { return }
            coordinator.requestedPage = page
            coordinator.parent.selection = page
            coordinator.parent.onTransitionSettled(page)
        }
        controller.userScrollEnabled = isScrollEnabled
        return controller
    }
    func updateUIViewController(_ controller: WorkspacePagingController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.first.rootView = firstPage
        context.coordinator.second.rootView = secondPage
        controller.userScrollEnabled = isScrollEnabled
        let coordinator = context.coordinator
        let target = selection
        guard target != coordinator.requestedPage else { return }
        coordinator.requestedPage = target
        // Ignore superseded requests and avoid publishing during SwiftUI update.
        DispatchQueue.main.async {
            guard coordinator.requestedPage == target else { return }
            controller.requestPage(target)
        }
    }
    final class Coordinator {
        var parent: VerticalWorkspacePager
        var requestedPage: Int
        let first: UIHostingController<FirstPage>
        let second: UIHostingController<SecondPage>
        init(parent: VerticalWorkspacePager) {
            self.parent = parent
            requestedPage = parent.selection
            first = UIHostingController(rootView: parent.firstPage)
            second = UIHostingController(rootView: parent.secondPage)
            first.view.backgroundColor = .clear
            second.view.backgroundColor = .clear
        }
    }
}

/// Owns the scroll delegate instead of replacing UIPageViewController's private delegate.
@MainActor
final class WorkspacePagingController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let pages: [UIViewController]
    private let scroll = WorkspacePagingScrollView()
    private(set) var currentPage: Int
    private var destination: Int
    private enum Motion { case idle, dragging, nested, settling, programmatic, interrupted }
    private var motion = Motion.idle
    private var moving = false
    private var lastHeight: CGFloat = 0
    private var nestedScroll: UIScrollView?
    private var nestedStartOffset: CGFloat = 0
    private var nestedLastTranslation: CGFloat = 0
    private var nestedClaimed = false
    private var nestedWasEnabled = true
    private lazy var nestedPan = UIPanGestureRecognizer(target: self, action: #selector(handleNestedPan(_:)))
    var began: ((Int) -> Void)?
    var settled: ((Int) -> Void)?
    var userScrollEnabled = true {
        didSet {
            if !userScrollEnabled, motion == .dragging || motion == .nested {
                motion = .interrupted
                // This property is also updated from SwiftUI; settle outside that update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.motion == .interrupted else { return }
                    self.restoreNestedScroll()
                    self.motion = .settling
                    self.settle(to: self.currentPage, animated: self.view.window != nil)
                }
            }
            scroll.isScrollEnabled = userScrollEnabled && !nestedClaimed
            nestedPan.isEnabled = userScrollEnabled
        }
    }

    init(pages: [UIViewController], initialPage: Int) {
        self.pages = pages
        currentPage = min(1, max(0, initialPage))
        destination = currentPage
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.delegate = self
        scroll.decelerationRate = .fast
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bounces = false
        view.addSubview(scroll)
        for page in pages {
            addChild(page)
            scroll.addSubview(page.view)
            page.didMove(toParent: self)
        }
        nestedPan.delegate = self
        nestedPan.cancelsTouchesInView = false
        view.addGestureRecognizer(nestedPan)
        // A child-scroll gesture is observed first; the outer native pan handles
        // only gestures for which that observer fails admission.
        scroll.panGestureRecognizer.require(toFail: nestedPan)
        scroll.isScrollEnabled = userScrollEnabled
        nestedPan.isEnabled = userScrollEnabled
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = view.bounds.height
        let fraction = lastHeight > 0 ? scroll.contentOffset.y / lastHeight : CGFloat(currentPage)
        scroll.frame = view.bounds
        scroll.contentSize = CGSize(width: view.bounds.width, height: height * 2)
        for (index, page) in pages.enumerated() {
            page.view.frame = CGRect(x: 0, y: CGFloat(index) * height, width: view.bounds.width, height: height)
        }
        if height != lastHeight {
            scroll.contentOffset.y = (moving ? fraction : CGFloat(currentPage)) * height
            if nestedClaimed {
                nestedStartOffset = nestedLastTranslation - (1 - fraction) * height
            }
            lastHeight = height
            // UIKit's pending deceleration/animation target uses the old bounds.
            // Re-anchor only after layout, and never override a new drag or request.
            if height > 0, moving, motion == .settling || motion == .programmatic {
                let target = destination
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastHeight == height, self.moving,
                          self.destination == target,
                          self.motion == .settling || self.motion == .programmatic else { return }
                    self.scroll.setContentOffset(self.scroll.contentOffset, animated: false)
                    self.settle(to: target, animated: self.view.window != nil)
                }
            }
        }
    }
    func requestPage(_ page: Int) {
        let target = min(1, max(0, page))
        let takingOverGesture = motion == .dragging || motion == .nested || motion == .interrupted
        guard takingOverGesture || (moving ? target != destination : target != currentPage) else { return }
        // Invalidate gesture callbacks before cancelling their recognizers.
        motion = .programmatic
        restoreNestedScroll()
        nestedPan.isEnabled = false
        scroll.panGestureRecognizer.isEnabled = false
        nestedPan.isEnabled = userScrollEnabled
        scroll.panGestureRecognizer.isEnabled = userScrollEnabled
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        settle(to: target, animated: view.window != nil)
    }
    private func begin(_ target: Int) {
        let changed = destination != target
        destination = target
        if !moving || changed { moving = true; began?(target) }
    }
    private func settle(to target: Int, animated: Bool) {
        begin(target)
        let offset = CGPoint(x: 0, y: CGFloat(target) * view.bounds.height)
        if !animated || abs(scroll.contentOffset.y - offset.y) < 0.5 {
            scroll.setContentOffset(offset, animated: false)
            finish()
        } else {
            scroll.setContentOffset(offset, animated: true)
        }
    }
    private func finish() {
        guard moving, abs(scroll.contentOffset.y - CGFloat(destination) * view.bounds.height) < 0.5 else { return }
        currentPage = destination
        moving = false
        motion = .idle
        settled?(currentPage)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard userScrollEnabled else { return }
        motion = .dragging
        begin(1 - currentPage)
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = endPageDrag(in: scrollView,
            downwardVelocity: scrollView.panGestureRecognizer.velocity(in: view).y,
            translation: scrollView.panGestureRecognizer.translation(in: view).y)
    }
    func endPageDrag(in scrollView: UIScrollView, downwardVelocity: CGFloat, translation: CGFloat) -> CGPoint {
        let height = max(1, scrollView.bounds.height)
        guard motion == .dragging else { return CGPoint(x: 0, y: CGFloat(destination) * height) }
        motion = .settling
        if currentPage == 1 {
            destination = shouldReturnFromWorkspace(distance: (height - scrollView.contentOffset.y) / height,
                downwardVelocity: downwardVelocity) ? 0 : 1
        } else {
            destination = shouldEnterWorkspace(distance: scrollView.contentOffset.y / height,
                upwardVelocity: -downwardVelocity, dragTranslation: translation, pageHeight: height) ? 1 : 0
        }
        return CGPoint(x: 0, y: CGFloat(destination) * height)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard motion == .settling else { return }
        if !decelerate { settle(to: destination, animated: view.window != nil) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finish() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finish() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === nestedPan, userScrollEnabled, currentPage == 1 else { return false }
        if nestedPan.numberOfTouches > 0 { return nestedScroll != nil }
        guard !WheelDragRegionView.contains(touch.location(in: view), in: view) else {
            restoreNestedScroll()
            return false
        }
        return prepareNestedDrag(from: touch.view)
    }
    func prepareNestedDrag(from touchedView: UIView?) -> Bool {
        // A tap may fail recognition without an action callback; discard its candidate.
        restoreNestedScroll()
        guard userScrollEnabled, currentPage == 1 else { return false }
        // Capture before slop/child scrolling consumes any part of the touch translation.
        var candidate = touchedView
        while let child = candidate, child !== scroll {
            if let inner = child as? UIScrollView, inner.isScrollEnabled,
               inner.contentSize.height > inner.bounds.height {
                beginNestedDrag(in: inner)
                return true
            }
            candidate = child.superview
        }
        return false
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let accepts = gestureRecognizer === nestedPan && acceptsNestedDirection(nestedPan.velocity(in: view))
        if !accepts { restoreNestedScroll() }
        return accepts
    }
    func acceptsNestedDirection(_ velocity: CGPoint) -> Bool {
        userScrollEnabled && currentPage == 1 && nestedScroll != nil && abs(velocity.y) > abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === nestedPan && otherGestureRecognizer === nestedScroll?.panGestureRecognizer
    }
    func beginNestedDrag(in inner: UIScrollView) {
        guard userScrollEnabled, currentPage == 1 else { return }
        restoreNestedScroll()
        nestedScroll = inner
        nestedStartOffset = max(0, inner.contentOffset.y + inner.adjustedContentInset.top)
        nestedLastTranslation = 0
    }
    func updateNestedDrag(translation: CGFloat) {
        guard let inner = nestedScroll, motion != .programmatic, motion != .interrupted else { return }
        nestedLastTranslation = translation
        let remainder = max(0, translation - nestedStartOffset)
        if remainder > 0, !nestedClaimed {
            nestedClaimed = true
            motion = .nested
            nestedWasEnabled = inner.isScrollEnabled
            inner.isScrollEnabled = false
            inner.contentOffset.y = -inner.adjustedContentInset.top
            scroll.isScrollEnabled = false
            begin(0)
        }
        if nestedClaimed { scroll.contentOffset.y = max(0, view.bounds.height - remainder) }
    }
    func endNestedDrag(translation: CGFloat, downwardVelocity: CGFloat, cancelled: Bool) {
        guard nestedScroll != nil, motion != .programmatic, motion != .interrupted else { return }
        let remainder = max(0, translation - nestedStartOffset)
        let claimed = nestedClaimed
        let target = !cancelled && shouldReturnFromWorkspace(
            distance: remainder / max(1, view.bounds.height), downwardVelocity: downwardVelocity) ? 0 : 1
        restoreNestedScroll()
        if claimed {
            motion = .settling
            settle(to: target, animated: view.window != nil)
        }
    }
    @objc private func handleNestedPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            updateNestedDrag(translation: pan.translation(in: view).y)
        case .ended, .cancelled, .failed:
            endNestedDrag(translation: pan.translation(in: view).y,
                downwardVelocity: pan.velocity(in: view).y, cancelled: pan.state != .ended)
        default: break
        }
    }
    private func restoreNestedScroll() {
        if nestedClaimed { nestedScroll?.isScrollEnabled = nestedWasEnabled }
        nestedScroll = nil
        nestedClaimed = false
        scroll.isScrollEnabled = userScrollEnabled
    }
}

/// The outer pan must also reject a wheel touch after nestedPan rejects it.
final class WorkspacePagingScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let position = panGestureRecognizer.location(in: self)
            let translation = panGestureRecognizer.translation(in: self)
            let origin = CGPoint(x: position.x - translation.x, y: position.y - translation.y)
            if WheelDragRegionView.contains(origin, in: self) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
