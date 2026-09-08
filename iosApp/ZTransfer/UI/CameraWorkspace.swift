import Foundation
import SwiftUI
import UIKit
import Combine
import ZTransferShared

/// UIKit/persistence adapter only. The home and file/queue pages are the shared Compose product UI.
@MainActor
final class CameraWorkspaceBridge: NSObject, ObservableObject, NativeConnectionHomePlatform {
    let session: CameraHandshakeProbe
    private(set) lazy var model = NativeConnectionHomeModel(platform: self)
    private var discovery: CameraDiscoveryCoordinator?
    private var discoveryObservation: AnyCancellable?
    private var observations = Set<AnyCancellable>()
    private var closed = false
    private var expectedResponderGUID: String?
    private let connectionPreferences: CameraConnectionPreferences

    init(session: CameraHandshakeProbe? = nil, connectionPreferences: CameraConnectionPreferences? = nil) {
        self.session = session ?? CameraHandshakeProbe()
        self.connectionPreferences = connectionPreferences ?? CameraConnectionPreferences()
        super.init()
        self.session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.session.$productState.sink { [weak self] value in
            guard let self, let value, !self.closed else { return }
            _ = self.model.publish(requestId: value.requestID, phase: value.phase, message: value.message)
        }.store(in: &observations)
    }

    func readConnectionMode() -> String? { connectionPreferences.read() }
    func saveConnectionMode(stationMode: Bool) -> Bool { connectionPreferences.save(stationMode ? "sta" : "ap") }
    func resetConnectionModeAfterConfirmation() -> Bool {
        guard !closed, !session.running else { return false }
        return connectionPreferences.resetAfterConfirmation()
    }

    func connectCamera(address: String, stationMode: Bool, allowPairing: Bool, requestId: Int64) -> Bool {
        guard !closed else { return false }
        guard let normalized = NativeCameraEndpointAddress.shared.normalize(raw: address) else {
            _ = model.publish(requestId: requestId, phase: "failed", message: "相机地址无效。 / Invalid camera address.")
            return false
        }
        stopDiscovering()
        return session.connectProduct(host: normalized, stationMode: stationMode, allowPairing: allowPairing, requestID: requestId,
                                      expectedResponder: stationMode ? expectedResponderGUID : nil)
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
            model.publishChoices(values: [], searching: false, message: error.localizedDescription)
        }
    }
    func stopDiscovering() { discovery?.stop() }
    private func publishDiscovery() {
        guard !closed, let discovery else { return }
        let profiles = discovery.profiles.map { profile in
            NativeStationChoice(id: profile.responderGUID, title: profile.displayName,
                detail: (profile.paired ? "已配对 / Paired · " : "历史地址 / History · ") +
                    (profile.address ?? "请查找相机后选择服务。 / Find the camera service to reconnect."), paired: true)
        }
        let services = discovery.selectableServices.map {
            NativeStationChoice(id: $0.id, title: $0.name, detail: "Bonjour · 连接时验证相机 / verified when connecting", paired: false)
        }
        model.publishChoices(values: profiles + services, searching: discovery.searching, message: discovery.message)
    }
    func connectChoice(id: String, paired: Bool, allowPairing: Bool, requestId: Int64) -> Bool {
        guard !closed, let discovery else { return false }
        if paired {
            guard let profile = discovery.profiles.first(where: { $0.responderGUID == id }) else { return false }
            expectedResponderGUID = profile.responderGUID
            model.publishExpectedCamera(description: profile.displayName + " · " + String(profile.responderGUID.suffix(8)))
        }
        let choice = paired ? discovery.selectProfile(responderGUID: id)
            : discovery.selectService(id: id, expectedResponderGUID: expectedResponderGUID)
        guard let choice else {
            _ = model.publish(requestId: requestId, phase: "failed", message: discovery.message ?? "相机候选已失效，请重新查找。")
            return false
        }
        stopDiscovering()
        return session.connectProduct(host: choice.host, stationMode: true, allowPairing: allowPairing, requestID: requestId,
                                      expectedResponder: choice.expectedResponderGUID, service: choice.service)
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
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: error.localizedDescription)
            return false
        }
    }
    func resetCameraHistory() -> Bool {
        guard !closed, !session.running else { return false }
        do {
            let backup = try CameraEndpointHistory.resetApplicationHistory(confirmed: true)
            discovery?.stop(); discovery = nil; discoveryObservation = nil
            expectedResponderGUID = nil
            model.publishChoices(values: [], searching: false,
                message: backup.map { "地址历史已备份：\($0.lastPathComponent)" } ?? "地址历史已重置，配对身份保持不变。")
            return true
        } catch {
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: error.localizedDescription)
            return false
        }
    }
    private func currentDiscoveryRows() -> [NativeStationChoice] {
        guard let discovery else { return [] }
        return discovery.profiles.map { NativeStationChoice(id: $0.responderGUID, title: $0.displayName,
            detail: $0.address ?? "无已验证地址", paired: true) }
    }
    func recoverCameraIdentity() -> Bool {
        guard !closed, !session.running else { return false }
        do {
            let backup = try StationProfileStore.recoverApplicationIdentity(confirmed: true)
            discovery?.stop(); discovery = nil; discoveryObservation = nil
            expectedResponderGUID = nil
            model.publishChoices(values: [], searching: false, message: backup.map {
                "配对身份已备份并恢复（\($0.lastPathComponent)），请重新在相机完成电脑模式配对。"
            } ?? "现有配对身份有效，未进行重置。")
            return true
        } catch {
            model.publishChoices(values: currentDiscoveryRows(), searching: false, message: error.localizedDescription)
            return false
        }
    }
    func enterBackground() {
        stopDiscovering()
        session.cancel()
    }
    func close() {
        guard !closed else { return }
        model.close(); closed = true
        discovery?.stop(); discoveryObservation = nil
        session.cancel(); observations.removeAll()
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
            .sheet(item: Binding(get: { bridge.session.filesPage }, set: { bridge.session.filesPage = $0 })) {
                OriginalFilesPage(bridge: $0)
            }
            .sheet(item: Binding(get: { bridge.session.queuePage }, set: { bridge.session.queuePage = $0 })) {
                OriginalQueuePage(bridge: $0)
            }
            .onChange(of: scenePhase) { if $0 == .background { bridge.enterBackground() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                bridge.session.releasePreviewMemory()
            }
    }
}
