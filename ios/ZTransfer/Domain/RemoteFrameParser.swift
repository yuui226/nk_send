import Foundation

/// Nikon's GetLiveViewImg payload can contain a proprietary prefix and trailing
/// bytes around the JPEG. Android locates the JPEG SOI before decoding; keep the
/// same rule here instead of passing the whole PTP payload to UIImage.
enum RemoteFrameParser {
    static func jpegData(from payload: Data) -> Data? {
        guard let range = jpegRange(in: payload) else { return nil }
        return Data(payload[range])
    }

    static func jpegRange(in payload: Data) -> Range<Data.Index>? {
        guard payload.count >= 4 else { return nil }
        let start = payload.indices.dropLast().first { index in
            payload[index] == 0xFF && payload[payload.index(after: index)] == 0xD8
        }
        guard let start else { return nil }
        var index = payload.index(start, offsetBy: 2)
        while index < payload.index(before: payload.endIndex) {
            if payload[index] == 0xFF {
                let next = payload.index(after: index)
                if payload[next] == 0xD9 {
                    return start..<payload.index(next, offsetBy: 1)
                }
            }
            index = payload.index(after: index)
        }
        return nil
    }
}
