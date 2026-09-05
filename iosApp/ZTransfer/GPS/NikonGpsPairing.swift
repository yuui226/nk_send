import Foundation
import CommonCrypto
import Security
import ZTransferShared

enum GpsPairingError: Error { case invalidPacket, invalidIdentity, notStarted, randomFailure(OSStatus), cipherFailure(Int32) }

/// The fixed cipher/key are required by the existing Nikon wire protocol, not new app-security
/// choices. Only this eight-byte primitive is platform-specific; salts/hash/transitions stay shared.
private final class AppleGpsBlockEncryptor: NSObject, NikonGpsPairingBlockEncryptor {
    private(set) var failure: Error?
    private let key: [UInt8] = [0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00]

    func resetFailure() { failure = nil }
    func encrypt(block: KotlinByteArray) -> KotlinByteArray {
        // The Kotlin callback is non-throwing. Record failure out-of-band and return a fixed-size
        // sentinel so Kotlin never throws across ObjC. The caller MUST discard the decision when
        // failure is set; sentinel bytes can never result in publishing a successful handshake.
        guard block.size == 8 else {
            failure = GpsPairingError.invalidPacket
            return KotlinByteArray(size: 8)
        }
        let input = (0..<8).map { UInt8(bitPattern: block.get(index: Int32($0))) }
        var output = [UInt8](repeating: 0, count: 8)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmBlowfish), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil, inputBytes.baseAddress, input.count,
                        outputBytes.baseAddress, 8, &written)
                }
            }
        }
        guard status == kCCSuccess, written == 8 else {
            failure = GpsPairingError.cipherFailure(status)
            return KotlinByteArray(size: 8)
        }
        return NikonGpsPairing.native(Data(output))
    }
}

/// One four-stage handshake. No Bluetooth or persistence inside; a BLE owner serializes the actor
/// results and writes only packetToWrite. Protocol ACCEPT_STAGE4 does not prove OS bonding/GEO ready.
actor NikonGpsPairing {
    private let encryptor = AppleGpsBlockEncryptor()
    private var state: NikonGpsPairingState?

    func begin(savedDevice: Int64? = nil, savedNonce: Int64? = nil) throws -> NikonGpsPairingDecision {
        guard (savedDevice == nil) == (savedNonce == nil),
              savedDevice.map({ (0...0xFFFF_FFFF).contains($0) }) ?? true,
              savedNonce.map({ (0...0xFFFF_FFFF).contains($0) }) ?? true else { throw GpsPairingError.invalidIdentity }
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw GpsPairingError.randomFailure(status) }
        func value(_ range: Range<Int>) -> UInt64 {
            range.enumerated().reduce(UInt64(0)) { $0 | UInt64(bytes[$1.element]) << ($1.offset * 8) }
        }
        let decision = NativeGpsBridge.shared.beginPairing(
            deviceEntropy: Int32(bitPattern: UInt32(truncatingIfNeeded: value(0..<4))),
            timestampEntropy: Int64(bitPattern: value(4..<12)),
            nonceEntropy: Int32(bitPattern: UInt32(truncatingIfNeeded: value(12..<16))),
            hasSavedIdentity: savedDevice != nil, savedDevice: savedDevice ?? 0, savedNonce: savedNonce ?? 0)
        state = decision.state
        return decision
    }

    func receive(_ bytes: Data) throws -> NikonGpsPairingDecision {
        guard let state else { throw GpsPairingError.notStarted }
        guard bytes.count == 17, let packet = NikonGpsPairingPacketCodec.shared.decode(bytes: Self.native(bytes)) else {
            throw GpsPairingError.invalidPacket
        }
        let decision = try Self.advance(state: state, packet: packet, encryptor: encryptor)
        self.state = decision.state
        return decision
    }

    /// Independent captured-vector test entry: same production primitive and shared handshake.
    static func capturedResponse(stage1: Data, stage2: Data) throws -> Data? {
        guard let first = NikonGpsPairingPacketCodec.shared.decode(bytes: native(stage1)),
              let second = NikonGpsPairingPacketCodec.shared.decode(bytes: native(stage2)) else { throw GpsPairingError.invalidPacket }
        let initial = NikonGpsPairingState(stage1: first, stage3Sent: false, stage4Accepted: false)
        let decision = try advance(state: initial, packet: second, encryptor: AppleGpsBlockEncryptor())
        return decision.packetToWrite.map { data(NikonGpsPairingPacketCodec.shared.encode(packet: $0)) }
    }

    private static func advance(state: NikonGpsPairingState, packet: NikonGpsPairingPacket,
                                encryptor: AppleGpsBlockEncryptor) throws -> NikonGpsPairingDecision {
        encryptor.resetFailure()
        let decision = NikonGpsPairingHandshake.shared.advance(state: state, incoming: packet, encryptor: encryptor)
        if let failure = encryptor.failure { throw failure }
        return decision
    }

    static func encoded(_ packet: NikonGpsPairingPacket) -> Data { data(NikonGpsPairingPacketCodec.shared.encode(packet: packet)) }
    static func native(_ data: Data) -> KotlinByteArray {
        let bytes = KotlinByteArray(size: Int32(data.count))
        for (index, value) in data.enumerated() { bytes.set(index: Int32(index), value: Int8(bitPattern: value)) }
        return bytes
    }
    private static func data(_ bytes: KotlinByteArray) -> Data {
        Data((0..<Int(bytes.size)).map { UInt8(bitPattern: bytes.get(index: Int32($0))) })
    }
}
