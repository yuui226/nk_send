import Foundation

/// Strict UINT16 descriptor; occupied list positions never substitute for C1–C9 IDs.
struct NikonPictureControlSelection: Equatable, Sendable {
    let writable: Bool
    let current: Int
    let choices: [Int]
    func supportsSlot(_ slot: Int) -> Bool { NikonPictureControlData.customSlots.contains(slot) && choices.contains(slot) }
    var confirmedLastCustomSlot: Int? { NikonPictureControlData.customSlots.allSatisfy(choices.contains) ? 209 : nil }

    init(_ data: Data, property: UInt16 = 0xD200) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NikonPictureControlError.invalid(message) }
        }
        let bytes = [UInt8](data)
        try require(property == 0xD200 || property == 0xD237, "Unknown Picture Control selection property")
        try require(bytes.count >= 10, "Truncated Picture Control descriptor")
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        try require(u16(0) == property && u16(2) == 4, "Unexpected Picture Control property/type")
        try require(bytes[4] <= 1, "Invalid Picture Control access flag")
        writable = bytes[4] == 1
        current = u16(7)
        switch bytes[9] {
        case 0:
            try require(bytes.count == 10, "Trailing Picture Control descriptor data")
            choices = []
        case 2:
            try require(bytes.count >= 12, "Truncated Picture Control enumeration")
            let count = u16(10)
            try require(bytes.count - 12 == count * 2, "Invalid Picture Control enumeration length")
            choices = (0..<count).map { u16(12 + $0 * 2) }
            try require(Set(choices).count == choices.count, "Duplicate Picture Control choice")
        default: throw NikonPictureControlError.invalid("Unrecognized Picture Control descriptor form")
        }
    }
}

/// NikonPictureControlWriter requires effective PSAM even when the dial reads U1/U2/U3.
enum NikonPictureControlExposure {
    static func needsUserMode(_ program: Int) -> Bool { (0x8050...0x8052).contains(program) }
    static func permitsAdjustment(program: Int, userMode: Int?) -> Bool {
        (1...4).contains(program) || (needsUserMode(program) && userMode.map { (19...22).contains($0) } == true)
    }
}
