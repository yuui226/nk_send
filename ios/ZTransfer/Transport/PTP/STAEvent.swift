import Foundation

struct STAEvent: Equatable, Sendable {
    let code: UInt16
    let handle: UInt32
    static func socket(_ payload: Data) -> STAEvent? {
        var reader = PTPDataReader(payload)
        guard let code = reader.readUInt16(), reader.skipBytes(count: 4) else { return nil }
        return STAEvent(code: code, handle: reader.readUInt32() ?? 0)
    }
    static func polled(_ payload: Data, extended: Bool) -> [STAEvent]? {
        var reader = PTPDataReader(payload)
        guard let count = reader.readUInt16() else { return nil }
        if count == 0 { return [] }
        if extended && !reader.skipBytes(count: 2) { return nil }
        guard Int(count) <= reader.remaining / (extended ? 4 : 6) else { return nil }
        var result: [STAEvent] = []
        for _ in 0..<count {
            guard let code = reader.readUInt16() else { return nil }
            let parameters: Int
            if extended {
                guard let count = reader.readUInt16(), count <= 5 else { return nil }
                parameters = Int(count)
            } else { parameters = 1 }
            guard parameters * 4 <= reader.remaining else { return nil }
            let first: UInt32 = parameters > 0 ? reader.readUInt32()! : 0
            if parameters > 1 { _ = reader.skipBytes(count: (parameters - 1) * 4) }
            result.append(STAEvent(code: code, handle: first))
        }
        return result
    }
}
