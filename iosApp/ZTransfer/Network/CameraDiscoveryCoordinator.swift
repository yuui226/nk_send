import Combine
import Foundation

struct CameraKnownProfile: Identifiable {
    let responderGUID: String
    let displayName: String
    let address: String?
    let paired: Bool
    var id: String { responderGUID }
}

struct CameraConnectionChoice {
    let host: String
    let service: CameraBonjourService?
    let expectedResponderGUID: String?
}

/// Presentation adapter only: owns discovery and metadata, never a camera socket/session/queue.
/// Selecting a row returns an explicit choice to the existing CameraHandshakeProbe owner.
@MainActor final class CameraDiscoveryCoordinator: ObservableObject {
    @Published private(set) var services: [CameraBonjourService] = []
    @Published private(set) var profiles: [CameraKnownProfile] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    /// Alternate advertised endpoints remain explicitly selectable, never automatic auth fallback.
    var selectableServices: [CameraBonjourService] { services.flatMap { [$0] + $0.selectableAlternatives } }
    private let history: CameraEndpointHistory
    private let profileStore: StationProfileStore
    private let discoveryFactory: () -> CameraBonjourDiscovery
    private var discovery: CameraBonjourDiscovery?
    private var observer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var profileIssue: String?
    init(history: CameraEndpointHistory, profiles: StationProfileStore,
         discoveryFactory: @escaping () -> CameraBonjourDiscovery = { CameraBonjourDiscovery() }) {
        self.history = history; profileStore = profiles; self.discoveryFactory = discoveryFactory
        reloadProfiles()
    }
    static func applicationCoordinator() throws -> CameraDiscoveryCoordinator {
        try CameraDiscoveryCoordinator(history: CameraEndpointHistory.applicationDiscoveryStore(), profiles: StationProfileStore.applicationStore())
    }
    deinit { observer?.cancel(); discovery?.stop() }
    func start() {
        stop()
        generation &+= 1
        let current = generation
        searching = true; message = profileIssue; services = []
        let discovery = discoveryFactory()
        self.discovery = discovery
        observer = Task { [weak self, discovery] in
            for await snapshot in discovery.updates {
                guard !Task.isCancelled, let self, self.generation == current else { break }
                self.services = snapshot.services; self.searching = snapshot.searching
                let messages = [self.profileIssue, snapshot.message].compactMap { $0 }
                self.message = messages.isEmpty ? nil : messages.joined(separator: "；")
            }
        }
        discovery.start()
    }
    func stop() {
        generation &+= 1
        observer?.cancel(); observer = nil
        discovery?.stop(); discovery = nil; searching = false
    }
    func reloadProfiles() {
        // Metadata and trust have independent failure domains. Corrupt address history must not
        // hide a valid pairing identity; address-only rows never grant pairing authority.
        var issues: [String] = []
        var entries: [CameraEndpointRecord] = []
        var paired = Set<String>()
        do { entries = try history.entries() } catch { issues.append(error.localizedDescription) }
        do { paired = Set(try profileStore.pairedResponderGUIDs()) } catch { issues.append(error.localizedDescription) }
        profiles = entries.map { CameraKnownProfile(responderGUID: $0.responderGUID, displayName: $0.displayName,
            address: $0.address.host, paired: paired.contains($0.responderGUID)) }
        let represented = Set(entries.map(\.responderGUID))
        profiles += paired.subtracting(represented).sorted().map {
            CameraKnownProfile(responderGUID: $0, displayName: "已配对相机 · \($0.suffix(8))", address: nil, paired: true)
        }
        profileIssue = issues.isEmpty ? nil : issues.joined(separator: "；")
        message = profileIssue
    }
    func selectService(id: String, expectedResponderGUID: String? = nil) -> CameraConnectionChoice? {
        guard let service = selectableServices.first(where: { $0.id == id }) else { return nil }
        if let expectedResponderGUID, !profiles.contains(where: { $0.responderGUID == expectedResponderGUID }) {
            message = CameraEndpointError.invalidIdentity.localizedDescription; return nil
        }
        stop()
        return CameraConnectionChoice(host: "", service: service, expectedResponderGUID: expectedResponderGUID)
    }
    func selectProfile(responderGUID: String) -> CameraConnectionChoice? {
        do {
            guard let entry = try history.select(responderGUID: responderGUID) else {
                message = "此相机尚无成功连接的地址；请明确选择 Bonjour 服务或输入地址后连接，不会自动扫描网段。"
                return nil
            }
            let address = try CameraEndpointAddress.parse(entry.address.host)
            stop()
            return CameraConnectionChoice(host: address.host, service: nil, expectedResponderGUID: entry.responderGUID)
        } catch { message = error.localizedDescription; return nil }
    }
    func forgetProfile(responderGUID: String, confirmed: Bool) throws {
        guard confirmed else { throw CameraEndpointError.confirmationRequired }
        // Remove the trust marker first. A failed history write may leave a harmless address hint,
        // but must never leave an allegedly-forgotten pairing trusted. Other identities are intact.
        do {
            try profileStore.forgetResponder(responderGUID)
            try history.forget(responderGUID: responderGUID)
        } catch {
            reloadProfiles() // A failed metadata write must not display an already-removed trust marker.
            throw error
        }
        reloadProfiles()
    }
    @discardableResult func resetHistoryAfterConfirmation(confirmed: Bool) throws -> URL? {
        let archive = try history.reset(confirmed: confirmed)
        reloadProfiles()
        return archive
    }
}
