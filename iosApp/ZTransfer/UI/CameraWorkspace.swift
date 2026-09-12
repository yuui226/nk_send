import Foundation
import SwiftUI
import UIKit
import Combine
import ZTransferShared

/// UIKit/persistence adapter only. The home and file/queue pages are the shared Compose product UI.
@MainActor
final class CameraWorkspaceBridge: NSObject, ObservableObject, NativeConnectionHomePlatform {
    let session: CameraHandshakeProbe
    @Published var diagnosticShare: DiagnosticShareRequest?
    private var diagnosticPreview: String?
    private(set) lazy var model = NativeConnectionHomeModel(platform: self)
    private var discovery: CameraDiscoveryCoordinator?
    private var discoveryObservation: AnyCancellable?
    private var observations = Set<AnyCancellable>()
    private var closed = false
    private var expectedResponderGUID: String?
    private let connectionPreferences: CameraConnectionPreferences
    private let backgroundLease: SessionBackgroundLease
    private var foreground = true
    private var clearingRecovery = false

    init(session: CameraHandshakeProbe? = nil, connectionPreferences: CameraConnectionPreferences? = nil,
         backgroundLease: SessionBackgroundLease? = nil) {
        self.session = session ?? CameraHandshakeProbe()
        self.connectionPreferences = connectionPreferences ?? CameraConnectionPreferences()
        self.backgroundLease = backgroundLease ?? SessionBackgroundLease()
        self.session.recoveryJournal = TransferRecoveryJournal.application
        super.init()
        self.session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.session.$productState.sink { [weak self] value in
            guard let self, let value, !self.closed else { return }
            _ = self.model.publish(requestId: value.requestID, phase: value.phase, message: value.message)
            self.session.diagnostics.phase(value.phase, message: value.message)
            if value.phase == "failed" { self.model.publishRecoveryNotice(code: "disconnected") }
        }.store(in: &observations)
        self.session.$running.sink { [weak self] running in
            if !running { self?.backgroundLease.end() }
        }.store(in: &observations)
    }

    func diagnosticReport() -> String {
        guard !closed else { return "" }
        let report = session.diagnostics.report()
        diagnosticPreview = report
        return report
    }
    func clearDiagnostics() { if !closed { session.diagnostics.clear() } }
    func shareDiagnostics() -> Bool {
        guard !closed, foreground, diagnosticShare == nil,
              session.filesPage == nil, session.queuePage == nil, let diagnosticPreview else { return false }
        diagnosticShare = DiagnosticShareRequest(text: diagnosticPreview)
        return true
    }
    func loadRecoveryRecord() async {
        guard !closed else { return }
        do {
            guard let journal = session.recoveryJournal else { throw TransferRecoveryJournal.Failure.unavailable }
            let value = try await journal.read()
            guard !closed else { return }
            model.publishRecoveryRecord(names: value?.pending.map(\.name) ?? [], completed: Int32(clamping: value?.completed ?? 0),
                unavailable: false, truncated: value?.truncated ?? false)
        } catch { if !closed { model.publishRecoveryRecord(names: [], completed: 0, unavailable: true, truncated: false) } }
    }
    func clearRecoveryRecord(completion: NativeQueueActionCompletion) {
        guard !closed, !session.running, !clearingRecovery, let journal = session.recoveryJournal else {
            completion.complete(succeeded: false); return
        }
        clearingRecovery = true
        Task { [weak self] in
            var success = false
            do { try await journal.resetAfterConfirmation(); success = true } catch {}
            guard let self else { return }
            self.clearingRecovery = false
            if !self.closed { completion.complete(succeeded: success) }
        }
    }

    func readConnectionMode() -> String? { connectionPreferences.read() }
    func canOpenPhotoEffects() -> Bool { !closed && session.photoEffectsHandler != nil }
    func openPhotoEffects() { guard !closed else { return }; session.photoEffectsHandler?() }
    func saveConnectionMode(stationMode: Bool) -> Bool { connectionPreferences.save(stationMode ? "sta" : "ap") }
    func resetConnectionModeAfterConfirmation() -> Bool {
        guard !closed, !session.running, !clearingRecovery else { return false }
        return connectionPreferences.resetAfterConfirmation()
    }

    func connectCamera(address: String, stationMode: Bool, allowPairing: Bool, requestId: Int64) -> Bool {
        guard !closed, foreground, !session.running, !clearingRecovery else { return false }
        guard let normalized = NativeCameraEndpointAddress.shared.normalize(raw: address) else {
            _ = model.publish(requestId: requestId, phase: "failed", message: "@ztr|invalid_address")
            return false
        }
        stopDiscovering()
        armBackgroundLease()
        let started = session.connectProduct(host: normalized, stationMode: stationMode, allowPairing: allowPairing, requestID: requestId,
                                      expectedResponder: stationMode ? expectedResponderGUID : nil)
        if !started { backgroundLease.end() }
        return started
    }
    func cancelConnection(requestId: Int64) {
        guard session.productState?.requestID == requestId else { return }
        session.cancel() // Cancels automatic admission synchronously before any async queue teardown.
    }
    func disconnectCamera(requestId: Int64) {
        guard !closed, session.productState?.requestID == requestId else { return }
        session.disconnect()
    }
    func openCameraFiles() {
        guard !closed, model.isReady(), session.sessionReady else { return }
        session.openSharedFiles() // Ready navigation may show incremental rows from the existing scan.
    }
    func openTransferQueue() {
        guard !closed, model.isReady(), session.sessionReady else { return }
        session.openSharedQueue()
    }
    func openNetworkSettings() {
        guard !closed, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        // Public app-settings URL only. The guidance explicitly tells the user to join Wi-Fi manually.
        UIApplication.shared.open(url)
    }
    func discoverCameras() {
        guard !closed, !session.running else { return }
        do {
            if discovery == nil {
                let value = try CameraDiscoveryCoordinator.applicationCoordinator()
                discovery = value
                discoveryObservation = value.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.publishDiscovery() }
                }
            }
            discovery?.reloadProfiles()
            discovery?.start()
            publishDiscovery()
        } catch {
            model.publishChoices(values: [], searching: false, message: TransferFailureMessage.describe(error))
        }
    }
    func stopDiscovering() { discovery?.stop() }
    private func publishDiscovery() {
        guard !closed, let discovery else { return }
        let profiles = discovery.profiles.map { profile in
            NativeStationChoice(id: profile.responderGUID, title: profile.displayName,
                detail: profile.address.map { (profile.paired ? "@ztr|paired_prefix|" : "@ztr|history_prefix|") + $0 }
                    ?? "@ztr|find_service", paired: true)
        }
        let services = discovery.selectableServices.map {
            NativeStationChoice(id: $0.id, title: $0.name, detail: "@ztr|bonjour", paired: false)
        }
        model.publishChoices(values: profiles + services, searching: discovery.searching, message: discovery.message)
    }
    func connectChoice(id: String, paired: Bool, allowPairing: Bool, requestId: Int64) -> Bool {
        guard !closed, foreground, !session.running, let discovery else { return false }
        if paired {
            guard let profile = discovery.profiles.first(where: { $0.responderGUID == id }) else { return false }
            expectedResponderGUID = profile.responderGUID
            model.publishExpectedCamera(description: profile.displayName + " · " + String(profile.responderGUID.suffix(8)))
        }
        let choice = paired ? discovery.selectProfile(responderGUID: id)
            : discovery.selectService(id: id, expectedResponderGUID: expectedResponderGUID)
        guard let choice else {
            _ = model.publish(requestId: requestId, phase: "failed", message: discovery.message ?? "@ztr|stale_choice")
            return false
        }
        stopDiscovering()
        armBackgroundLease()
        let started = session.connectProduct(host: choice.host, stationMode: true, allowPairing: allowPairing, requestID: requestId,
                                      expectedResponder: choice.expectedResponderGUID, service: choice.service)
        if !started { backgroundLease.end() }
        return started
    }
    func clearExpectedCamera() {
        guard !closed, !session.running else { return }
        expectedResponderGUID = nil
    }
    func forgetCameraProfile(id: String) -> Bool {
        guard !closed, !session.running, let discovery else { return false }
        do {
            try discovery.forgetProfile(responderGUID: id, confirmed: true)
            if expectedResponderGUID == id {
                expectedResponderGUID = nil; model.publishExpectedCamera(description: nil)
            }
            publishDiscovery()
            return true
        } catch {
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: TransferFailureMessage.describe(error))
            return false
        }
    }
    func resetCameraHistory() -> Bool {
        guard !closed, !session.running, !clearingRecovery else { return false }
        do {
            let backup = try CameraEndpointHistory.resetApplicationHistory(confirmed: true)
            discovery?.stop(); discovery = nil; discoveryObservation = nil
            expectedResponderGUID = nil
            model.publishChoices(values: [], searching: false,
                message: backup.map { _ in "@ztr|history_reset" } ?? "@ztr|history_reset")
            return true
        } catch {
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: TransferFailureMessage.describe(error))
            return false
        }
    }
    private func currentDiscoveryRows() -> [NativeStationChoice] {
        guard let discovery else { return [] }
        return discovery.profiles.map { NativeStationChoice(id: $0.responderGUID, title: $0.displayName,
            detail: $0.address ?? "@ztr|no_address", paired: true) }
    }
    func recoverCameraIdentity() -> Bool {
        guard !closed, !session.running, !clearingRecovery else { return false }
        do {
            let backup = try StationProfileStore.recoverApplicationIdentity(confirmed: true)
            discovery?.stop(); discovery = nil; discoveryObservation = nil
            expectedResponderGUID = nil
            model.publishChoices(values: [], searching: false, message: backup.map { _ in
                "@ztr|identity_reset"
            } ?? "@ztr|identity_valid")
            return true
        } catch {
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: TransferFailureMessage.describe(error))
            return false
        }
    }
    private func armBackgroundLease() {
        backgroundLease.begin { [weak self] in self?.session.forceAbortForBackgroundExpiration() }
    }
    func enterBackground() {
        guard !closed else { return }
        foreground = false
        stopDiscovering()
        if session.running { model.publishRecoveryNotice(code: "background") }
        session.cancel() // Grace is for cleanup, not for an unlimited download.
        if !backgroundLease.isActive { session.forceAbortForBackgroundExpiration() }
    }
    func enterForeground() {
        guard !closed else { return }
        foreground = true
        if !session.running { backgroundLease.end() }
        // No connect/start here. The existing user action obtains a fresh route and responder.
    }
    func close() {
        guard !closed else { return }
        model.close(); closed = true
        diagnosticPreview = nil; diagnosticShare = nil
        discovery?.stop(); discoveryObservation = nil
        session.cancel(); backgroundLease.end(); observations.removeAll()
    }
}

/// Presentation preference only. Never persist pairing permission, selected identity or a ready state.
@MainActor final class CameraConnectionPreferences {
    static let key = "ztransfer.connection.preferences"
    private struct Document: Codable { let version: Int; let mode: String }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func resetAfterConfirmation() -> Bool {
        if let raw = defaults.object(forKey: Self.key) { defaults.set(raw, forKey: Self.key + ".recoveryBackup") }
        defaults.removeObject(forKey: Self.key)
        return save("ap")
    }
    func read() -> String? {
        guard let raw = defaults.object(forKey: Self.key) else { return "ap" }
        guard let bytes = raw as? Data, bytes.count <= 4096,
              let value = try? JSONDecoder().decode(Document.self, from: bytes),
              value.version == 1, ["ap", "sta"].contains(value.mode) else { return nil }
        return value.mode
    }
    func save(_ mode: String) -> Bool {
        guard read() != nil, ["ap", "sta"].contains(mode),
              let bytes = try? JSONEncoder().encode(Document(version: 1, mode: mode)) else { return false }
        defaults.set(bytes, forKey: Self.key)
        return defaults.data(forKey: Self.key) == bytes
    }
}

private struct CameraWorkspaceController: UIViewControllerRepresentable {
    let bridge: CameraWorkspaceBridge
    func makeUIViewController(context: Context) -> UIViewController {
        NativeConnectionHomeController.shared.create(model: bridge.model, appearance: AppAppearanceSettings.shared.model)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@MainActor
struct CameraWorkspace: View {
    @ObservedObject var bridge: CameraWorkspaceBridge
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        CameraWorkspaceController(bridge: bridge).ignoresSafeArea()
            .task { await bridge.loadRecoveryRecord() }
            .sheet(item: $bridge.diagnosticShare) { DiagnosticShareSheet(request: $0) }
            .sheet(item: Binding(get: { bridge.session.filesPage }, set: { bridge.session.filesPage = $0 })) {
                OriginalFilesPage(bridge: $0)
            }
            .sheet(item: Binding(get: { bridge.session.queuePage }, set: { bridge.session.queuePage = $0 })) {
                OriginalQueuePage(bridge: $0)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background { bridge.enterBackground() }
                else if phase == .active { bridge.enterForeground() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                bridge.session.releasePreviewMemory()
            }
    }
}


/// One balanced finite UIKit lease per live session, armed while still in the foreground.
/// Injectable callbacks cover expiration-before-registration and late-generation delivery.
@MainActor final class SessionBackgroundLease {
    typealias Begin = (@escaping () -> Void) -> Int
    private let start: Begin
    private let finish: (Int) -> Void
    private var identifier: Int?
    private var generation: UInt64 = 0
    private(set) var isActive = false
    init(start: @escaping Begin = { expired in
        UIApplication.shared.beginBackgroundTask(withName: "Close camera session", expirationHandler: expired).rawValue
    }, finish: @escaping (Int) -> Void = { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) }) {
        self.start = start; self.finish = finish
    }
    func begin(expiration: @escaping () -> Void) {
        guard !isActive else { return }
        generation &+= 1; let token = generation
        isActive = true
        let id = start { [weak self] in
            guard let self, self.generation == token, self.isActive else { return }
            self.end(); expiration()
        }
        guard id != UIBackgroundTaskIdentifier.invalid.rawValue else { isActive = false; return }
        if isActive && generation == token { identifier = id }
        else { finish(id) } // Expiration may run synchronously before the identifier returns.
    }
    func end() {
        generation &+= 1; isActive = false
        let ended = identifier; identifier = nil
        if let ended { finish(ended) }
    }
}
