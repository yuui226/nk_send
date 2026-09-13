import Foundation
import CommonCrypto

/// Nikon Smart Device pairing packet.  The wire layout is deliberately explicit
/// so it does not depend on the host's integer alignment or endianness.
struct NikonGPSPairingPacket: Equatable, Sendable {
    let stage: UInt8
    let timestamp: UInt64
    let device: UInt32
    let nonce: UInt32

    func encode() -> Data {
        var data = Data([stage])
        data.append(contentsOf: timestamp.littleEndianBytes)
        data.append(contentsOf: device.littleEndianBytes)
        data.append(contentsOf: nonce.littleEndianBytes)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count == 17 else { return nil }
        var reader = ByteReader(data)
        guard let stage = reader.readByte(), let timestamp = reader.readUInt64(),
              let device = reader.readUInt32(), let nonce = reader.readUInt32() else { return nil }
        return Self(stage: stage, timestamp: timestamp, device: device, nonce: nonce)
    }
}

/// The four-message Nikon GPS pairing transform.  CommonCrypto supplies the
/// platform Blowfish primitive; all word packing and salt order mirrors the
/// Android implementation exactly.
final class NikonGPSPairingProtocol: @unchecked Sendable {
    private let key: Data = Data([0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00])
    private var generator = SystemRandomNumberGenerator()

    func newStage1(deviceOverride: UInt32? = nil, nonceOverride: UInt32? = nil) -> NikonGPSPairingPacket {
        let randomDevice = (UInt32.random(in: 0...UInt32.max, using: &generator) & 0xFFFF_FF00) | 1
        return NikonGPSPairingPacket(
            stage: 1,
            timestamp: UInt64.random(in: 0...UInt64.max, using: &generator),
            device: deviceOverride ?? randomDevice,
            nonce: nonceOverride ?? UInt32.random(in: 0...UInt32.max, using: &generator),
        )
    }

    func stage3(for stage1: NikonGPSPairingPacket, stage2: NikonGPSPairingPacket) -> NikonGPSPairingPacket? {
        guard let salt = salts.first(where: { salt in
            let expected = hash(words: [salt.0, salt.1, beHalves(stage2.timestamp).0, beHalves(stage2.timestamp).1,
                                         beHalves(stage1.timestamp).0, beHalves(stage1.timestamp).1])
            return expected.0 == reverse(stage2.device) && expected.1 == reverse(stage2.nonce)
        }) else { return nil }
        let a = beHalves(stage1.timestamp), b = beHalves(stage2.timestamp)
        let result = hash(words: [salt.0, salt.1, a.0, a.1, b.0, b.1])
        return NikonGPSPairingPacket(stage: 3, timestamp: stage1.timestamp,
                                     device: reverse(result.0), nonce: reverse(result.1))
    }

    private func hash(words: [UInt32]) -> (UInt32, UInt32) {
        var left: UInt32 = 0x01020304, right: UInt32 = 0x05060708
        for index in stride(from: 0, to: words.count, by: 2) {
            var block = Data(capacity: 8)
            block.append(contentsOf: (words[index] ^ left).bigEndianBytes)
            block.append(contentsOf: (words[index + 1] ^ right).bigEndianBytes)
            var output = [UInt8](repeating: 0, count: 8), outputLength = 0
            let outputCapacity = output.count
            let status = output.withUnsafeMutableBytes { outputBuffer in
                block.withUnsafeBytes { inputBuffer in
                    key.withUnsafeBytes { keyBuffer in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmBlowfish),
                                CCOptions(kCCOptionECBMode), keyBuffer.baseAddress, key.count,
                                nil, inputBuffer.baseAddress, block.count,
                                outputBuffer.baseAddress, outputCapacity, &outputLength)
                    }
                }
            }
            guard status == kCCSuccess, outputLength == 8 else { return (0, 0) }
            left = output.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            right = output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian }
        }
        return (left, right)
    }

    private func beHalves(_ value: UInt64) -> (UInt32, UInt32) {
        (reverse(UInt32(truncatingIfNeeded: value)), reverse(UInt32(truncatingIfNeeded: value >> 32)))
    }
    private func reverse(_ value: UInt32) -> UInt32 { value.byteSwapped }

    private let salts: [(UInt32, UInt32)] = [
        (0x704066e4, 0x0433d552), (0xed4b8fac, 0x15f7e47b),
        (0x24471f11, 0x8b5ea1fc), (0x05960c31, 0x2b8c7f41),
        (0xfda588c1, 0xeba8b1f3), (0x99166056, 0x1bd3d550),
        (0xcd32687f, 0xa9e28a30), (0x2a8fe834, 0xdec7ebf4),
    ]
}

/// Nikon's 41-byte GEO payload, matching Android GeoPayloadEncoder byte for byte.
enum NikonGeoPayloadEncoder {
    private static let header: UInt16 = 0x007F

    static func encode(latitude: Double, longitude: Double, altitudeMeters: Double,
                       satellites: Int, timestamp: Date = Date()) -> Data? {
        guard latitude.isFinite, latitude >= -90, latitude <= 90,
              longitude.isFinite, longitude >= -180, longitude <= 180 else { return nil }
        let lat = coordinate(latitude, positive: 0x4E, negative: 0x53, maxDegrees: 90)
        let lon = coordinate(longitude, positive: 0x45, negative: 0x57, maxDegrees: 180)
        let altitude = altitudeMeters.isFinite ? altitudeMeters : 0
        let altitudeRef: UInt8 = altitude < 0 ? 0x4D : 0x50 // M/P
        let altitudeAbs = UInt16(min(abs(altitude), 65_535))
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!,
                                                                          from: timestamp)
        guard let year = components.year, let month = components.month, let day = components.day,
              let hour = components.hour, let minute = components.minute, let second = components.second else { return nil }
        var data = Data(capacity: 41)
        data.append(contentsOf: header.littleEndianBytes)
        data.append(contentsOf: [lat.direction, UInt8(lat.degrees), UInt8(lat.minutes), UInt8(lat.subMinutes1), UInt8(lat.subMinutes2)])
        data.append(contentsOf: [lon.direction, UInt8(lon.degrees), UInt8(lon.minutes), UInt8(lon.subMinutes1), UInt8(lon.subMinutes2)])
        data.append(UInt8(satellites.clamped(to: 0...99)))
        data.append(altitudeRef)
        data.append(contentsOf: altitudeAbs.littleEndianBytes)
        data.append(contentsOf: UInt16(year).littleEndianBytes)
        data.append(contentsOf: [UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second), 0, 1])
        data.append(contentsOf: Data("WGS-84".utf8))
        data.append(contentsOf: repeatElement(0, count: 10))
        return data.count == 41 ? data : nil
    }

    private struct Coordinate { let direction: UInt8; let degrees, minutes, subMinutes1, subMinutes2: Int }
    private static func coordinate(_ value: Double, positive: UInt8, negative: UInt8, maxDegrees: Int) -> Coordinate {
        let absolute = abs(value)
        var degrees = min(Int(floor(absolute)), maxDegrees)
        let minuteValue = (absolute - Double(degrees)) * 60
        var minutes = Int(floor(minuteValue))
        var sub1 = Int(floor((minuteValue - Double(minutes)) * 100 + 1e-9))
        var sub2 = Int(floor((((minuteValue - Double(minutes)) * 100) - Double(sub1)) * 100 + 1e-9))
        if sub2 >= 100 { sub2 = 99 }
        if sub1 >= 100 { sub1 = 99 }
        if minutes >= 60 { minutes = 0; degrees = min(degrees + 1, maxDegrees) }
        return Coordinate(direction: value < 0 ? negative : positive, degrees: degrees, minutes: minutes, subMinutes1: sub1, subMinutes2: sub2)
    }
}

enum NikonGPSUpdateFrequency: Int, CaseIterable, Codable, Sendable {
    case thirtySeconds = 30, oneMinute = 60, twoMinutes = 120, fiveMinutes = 300
    static let `default`: Self = .oneMinute
    var interval: TimeInterval { TimeInterval(rawValue) }
    var locationSamplingInterval: TimeInterval {
        switch self { case .thirtySeconds: return 5; case .oneMinute: return 10; case .twoMinutes: return 20; case .fiveMinutes: return 30 }
    }
    var networkSamplingInterval: TimeInterval {
        switch self { case .thirtySeconds, .oneMinute: return 15; case .twoMinutes: return 20; case .fiveMinutes: return 30 }
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func readByte() -> UInt8? { guard offset < data.count else { return nil }; defer { offset += 1 }; return data[data.startIndex + offset] }
    mutating func readUInt32() -> UInt32? { readFixed(UInt32.self) }
    mutating func readUInt64() -> UInt64? { readFixed(UInt64.self) }
    mutating private func readFixed<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        defer { offset += size }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }

    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

private extension BinaryInteger {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
