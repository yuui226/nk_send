import Foundation

enum STAInitiatorIdentity: String, Sendable, CaseIterable {
    case pairedComputer = "PAIRED_COMPUTER"
    case albumExplorer = "ALBUM_EXPLORER"
    var alternate: Self { self == .pairedComputer ? .albumExplorer : .pairedComputer }
    var preferenceKey: String { self == .pairedComputer ? "initiator_id" : "sta_album_explorer_id" }
}

struct STACameraProfile: Equatable, Sendable {
    let responderGUID: String
    let lastIP: String?
    let identity: STAInitiatorIdentity
    let pairingConfirmed: Bool
    let lastSeen: Double
    let model: String?
}

/// Port of StaCameraProfileStore.kt. The pairing marker and routing hints have
/// separate lifetimes; finding an album never writes a pairing marker.
final class STAProfileStore: @unchecked Sendable {
    private let preferences: UserDefaults
    private let pairing: UserDefaults
    private let lock = NSRecursiveLock()
    private let now: @Sendable () -> Double
    private static let marker = "sta_paired_"
    private static let prefix = "sta_camera_profile_v1."
    private static let registry = "sta_camera_profile_guids_v1"
    private static let migration = "sta_camera_profile_migration_v1"

    init(preferences: UserDefaults = UserDefaults(suiteName: "sta_connection")!,
         pairing: UserDefaults = UserDefaults(suiteName: "ptpip_identity")!,
         now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.preferences = preferences; self.pairing = pairing; self.now = now
        migrate()
    }

    static func normalizeGUID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.count == 32, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }

    func initiatorID(_ identity: STAInitiatorIdentity) -> Data {
        locked {
            var id = pairing.string(forKey: identity.preferenceKey)
            if id?.count != 16 || id?.allSatisfy({ "0123456789abcdef".contains($0) }) != true {
                id = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
                pairing.set(id, forKey: identity.preferenceKey)
                pairing.synchronize()
            }
            return Data(id!.utf8)
        }
    }

    func isPaired(_ guid: String?) -> Bool {
        locked { Self.normalizeGUID(guid).map { pairing.bool(forKey: Self.marker + $0) } ?? false }
    }

    func markPaired(_ guid: String?) {
        locked {
            guard let guid = Self.normalizeGUID(guid) else { return }
            pairing.set(true, forKey: Self.marker + guid)
            pairing.synchronize() // Before the optional event wait/service restart.
        }
    }

    var lastUsedIP: String? { locked { nonblank(preferences.string(forKey: "last_sta_camera_ip")) } }
    var hasReusableProfile: Bool {
        locked { profiles.contains(where: \.pairingConfirmed) || preferences.bool(forKey: "sta_reusable_profile") || lastUsedIP != nil }
    }
    var pairedCameraCount: Int { profiles.filter(\.pairingConfirmed).count }
    var pairedCameraModels: [String] {
        profiles.filter(\.pairingConfirmed).sorted { $0.lastSeen > $1.lastSeen }.compactMap(\.model)
    }
    var mostRecentGUID: String? {
        locked {
            let confirmed = profiles.filter(\.pairingConfirmed)
            if let saved = Self.normalizeGUID(preferences.string(forKey: "last_sta_responder_guid_v1")),
               confirmed.contains(where: { $0.responderGUID == saved }) { return saved }
            if let ip = lastUsedIP, let match = confirmed.filter({ $0.lastIP == ip }).max(by: { $0.lastSeen < $1.lastSeen }) {
                return match.responderGUID
            }
            return confirmed.filter { $0.lastSeen > 0 }.max { $0.lastSeen < $1.lastSeen }?.responderGUID
        }
    }

    func preferredIdentity(for ip: String) -> STAInitiatorIdentity {
        profiles.filter { $0.pairingConfirmed && $0.lastIP == ip }.max { $0.lastSeen < $1.lastSeen }?.identity ?? .pairedComputer
    }
    func hasReusableProfile(using identity: STAInitiatorIdentity) -> Bool {
        profiles.contains { $0.pairingConfirmed && $0.identity == identity }
    }
    func isKnown(ip: String, guid: String? = nil) -> Bool {
        locked {
            if let guid { return isPaired(guid) }
            let match = profiles.filter { $0.lastIP == ip }.max { $0.lastSeen < $1.lastSeen }
            return match?.pairingConfirmed == true || (lastUsedIP == ip && preferences.bool(forKey: "sta_reusable_profile"))
        }
    }

    func remember(guid: String?, ip: String, identity: STAInitiatorIdentity, model: String? = nil) {
        locked {
            preferences.set(true, forKey: "sta_reusable_profile")
            preferences.set(ip, forKey: "last_sta_camera_ip")
            preferences.set(identity.rawValue, forKey: "sta_last_initiator_identity")
            if let guid = Self.normalizeGUID(guid) {
                preferences.set(Array(storedGUIDs.union([guid])), forKey: Self.registry)
                preferences.set(guid, forKey: "last_sta_responder_guid_v1")
                preferences.set(ip, forKey: key(guid, "last_ip"))
                preferences.set(identity.rawValue, forKey: key(guid, "identity"))
                preferences.set(now(), forKey: key(guid, "last_seen"))
                if let model = nonblank(model) { preferences.set(model, forKey: key(guid, "device_model")) }
            } else { preferences.removeObject(forKey: "last_sta_responder_guid_v1") }
            preferences.synchronize()
        }
    }

    func resetPairing() {
        locked {
            for key in ["sta_reusable_profile", "last_sta_camera_ip", "last_sta_responder_guid_v1",
                        "sta_last_initiator_identity", Self.registry] { preferences.removeObject(forKey: key) }
            for key in preferences.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
                preferences.removeObject(forKey: key)
            }
            preferences.set(true, forKey: Self.migration)
            preferences.synchronize()
            for key in pairing.dictionaryRepresentation().keys { pairing.removeObject(forKey: key) }
            pairing.synchronize()
        }
    }

    var profiles: [STACameraProfile] {
        locked {
            storedGUIDs.union(markerGUIDs).sorted().map { guid in
                STACameraProfile(responderGUID: guid, lastIP: nonblank(preferences.string(forKey: key(guid, "last_ip"))),
                    identity: STAInitiatorIdentity(rawValue: preferences.string(forKey: key(guid, "identity")) ?? "") ?? .pairedComputer,
                    pairingConfirmed: isPaired(guid), lastSeen: preferences.double(forKey: key(guid, "last_seen")),
                    model: nonblank(preferences.string(forKey: key(guid, "device_model"))))
            }
        }
    }

    private var storedGUIDs: Set<String> {
        Set((preferences.stringArray(forKey: Self.registry) ?? []).compactMap(Self.normalizeGUID))
    }
    private var markerGUIDs: Set<String> {
        Set(pairing.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(Self.marker), pairing.bool(forKey: key) else { return nil }
            return Self.normalizeGUID(String(key.dropFirst(Self.marker.count)))
        })
    }
    private func migrate() {
        guard !preferences.bool(forKey: Self.migration) else { return }
        let markers = markerGUIDs, known = storedGUIDs.union(markers)
        let only = known.count == 1 ? known.first : nil
        if !markers.isEmpty { preferences.set(Array(known), forKey: Self.registry) }
        if let only { preferences.set(only, forKey: "last_sta_responder_guid_v1") }
        for guid in markers {
            preferences.set(true, forKey: key(guid, "paired")) // Legacy field; never used as proof.
            if preferences.object(forKey: key(guid, "identity")) == nil {
                let legacy = STAInitiatorIdentity(rawValue: preferences.string(forKey: "sta_last_initiator_identity") ?? "") ?? .pairedComputer
                preferences.set((guid == only ? legacy : .pairedComputer).rawValue, forKey: key(guid, "identity"))
            }
            if guid == only, let ip = lastUsedIP, preferences.object(forKey: key(guid, "last_ip")) == nil {
                preferences.set(ip, forKey: key(guid, "last_ip"))
            }
        }
        preferences.set(true, forKey: Self.migration)
        preferences.synchronize()
    }
    private func key(_ guid: String, _ field: String) -> String { Self.prefix + guid + "." + field }
    private func nonblank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return operation()
    }
}
