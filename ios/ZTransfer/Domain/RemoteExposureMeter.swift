import Foundation

enum RemoteExposureMeter {
    static let nikonLightMeter: UInt32 = 0xD10A
    static let nikonExposureIndicate: UInt32 = 0xD1B1

    static func ev(property: UInt32, dataType: UInt16, writable: Bool, current: Int64) -> Float? {
        guard dataType == 1, !writable else { return nil }
        switch property {
        case nikonLightMeter where (-60...60).contains(current): return Float(current) / 12
        case nikonExposureIndicate where (-128...127).contains(current): return Float(current) / 3
        default: return nil
        }
    }

    static func decode(property: UInt32, dataType: UInt16, writable: Bool,
                      responseOK: Bool, data: Data) -> Int64? {
        guard property == nikonLightMeter || property == nikonExposureIndicate,
              dataType == 1, !writable, responseOK, data.count == 1 else { return nil }
        return Int64(Int8(bitPattern: data[data.startIndex]))
    }

    static func isFresh(startedAt: Int64, now: Int64) -> Bool {
        now >= startedAt && now - startedAt < 1_500
    }
}
