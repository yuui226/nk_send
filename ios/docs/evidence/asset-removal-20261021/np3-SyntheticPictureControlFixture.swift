import Foundation
enum SyntheticPictureControlFixture {
    static var curve: Data {
        var data = Data(repeating: 0, count: 578)
        data[0] = 0x49; data[1] = 0x30
        data[8] = 2; data[9] = 0; data[10] = 0; data[11] = 255; data[12] = 255
        for index in 0...256 {
            let value = index * 32767 / 256
            data[64 + index * 2] = UInt8(value >> 8)
            data[65 + index * 2] = UInt8(value & 255)
        }
        return data
    }
    static func data(name: String = "Test Neutral", withCurve: Bool = true, midRange: Int = 0) -> Data {
        precondition(!name.isEmpty && name.utf8.count <= 19 && (-20...20).contains(midRange))
        var nameBytes = Data(name.utf8)
        nameBytes.append(Data(repeating: 0, count: 20 - nameBytes.count))
        var fields: [(UInt32, Data)] = [
            (0x100, Data("0300".utf8)), (0x200, nameBytes), (0x300, Data([0, 0xC3])),
            (0x400, Data([0, 0])), (0x500, Data([255, 1])),
        ]
        for tag in stride(from: UInt32(0x600), through: 0xB00, by: 0x100) {
            fields.append((tag, Data([128, 4])))
        }
        fields += [(0xC00, Data([255, 0])), (0xD00, Data([255, 0])), (0xE00, Data([255, 4]))]
        for tag in stride(from: UInt32(0xF00), through: 0x1300, by: 0x100) {
            fields.append((tag, Data([255, 1])))
        }
        fields += [(0x1400, Data([128, 1])), (0x1500, Data([255, 10])), (0x1600, Data([UInt8(128 + midRange), 4]))]
        if withCurve { fields.append((2, curve)) }
        func integer(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        var data = Data([78, 67, 80, 0])
        for (tag, value) in fields { data += integer(tag) + integer(UInt32(value.count)) + value }
        data += Data(repeating: 0, count: 4)
        return data
    }
    static func file(withCurve: Bool = true, midRange: Int = 0) throws -> NikonPictureControlFile {
        try NikonPictureControlFile(data(withCurve: withCurve, midRange: midRange))
    }
}
