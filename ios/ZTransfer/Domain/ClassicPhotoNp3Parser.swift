import Foundation

/// Android ClassicPhotoNp3Parser: known classic controls only, including 0310
/// containers with neutral Flexible fields. Never infer a recipe from its name.
enum ClassicPhotoNp3Parser {
    static func parse(_ values: [UInt32: [UInt8]], version: String) throws -> ClassicNp3FilterParameters {
        try requireNp3(version == "0300" || version == "0310", "Unsupported classic NP3 version", reason: .unsupported)
        let fields = PhotoNp3Fields(values: values, prefix: "classic NP3")
        try fields.known(through: version == "0300" ? 0x1600 : 0x2000)
        func raw(_ tag: UInt32, _ encoding: UInt8) throws -> Int {
            let value = try fields.field(tag)
            try requireNp3(value[1] == encoding, "Unsupported classic NP3 encoding 0x\(String(tag, radix: 16))", reason: .unsupported)
            return Int(value[0])
        }
        func inactive(_ tag: UInt32, _ encoding: UInt8) throws {
            let value = try raw(tag, encoding)
            try requireNp3(value == 255 || value == 128, "Unsupported classic NP3 adjustment 0x\(String(tag, radix: 16))", reason: .unsupported)
        }
        let baseBytes = try fields.field(0x0300)
        let baseID = Int(baseBytes[0]) << 8 | Int(baseBytes[1])
        guard let base = ClassicNp3Style(rawValue: baseID) else {
            throw PhotoNp3Error(reason: .unsupported, message: "Unsupported classic NP3 base")
        }
        try requireNp3(fields.field(0x0400) == [0, 0], "Unsupported classic NP3 adjustment mode", reason: .unsupported)
        try inactive(0x0500, 1)
        for tag in stride(from: UInt32(0x0f00), through: 0x1300, by: 0x100) { try inactive(tag, 1) }
        let curve = try fields.toneCurve(classic: true)
        func scalar(_ tag: UInt32, _ range: ClosedRange<Int>, auto: Bool = false, curveOwned: Bool = false) throws -> Int {
            let value = try raw(tag, 4)
            if value == 255 { return 0 }
            if value == 0 && auto { return ClassicNp3FilterParameters.automatic }
            if value == 1 && curveOwned {
                try requireNp3(curve != nil, "Classic NP3 curve-owned adjustment has no curve")
                return 0
            }
            let decoded = value - 128
            try requireNp3(range.contains(decoded), "Classic NP3 adjustment is out of range 0x\(String(tag, radix: 16))")
            return curveOwned && curve != nil ? 0 : decoded
        }
        _ = try scalar(0x0600, -12...36, auto: true)
        _ = try scalar(0x0700, -20...20, auto: true)
        _ = try scalar(0x1600, -20...20, auto: true)
        let quick = try raw(0x1400, 1)
        try requireNp3(quick == 0 || quick == 255 || (-2...2).contains(quick - 128), "Invalid classic NP3 quick sharpening")
        let contrast = try scalar(0x0800, -12...12, auto: true, curveOwned: true)
        let brightness = try scalar(0x0900, -6...6, curveOwned: true)
        let saturation = try scalar(0x0a00, -12...12, auto: true)
        let hue = try scalar(0x0b00, -12...12)
        if base.isMonochrome {
            try requireNp3(saturation == 0 && hue == 0, "Unsupported classic monochrome color adjustment", reason: .unsupported)
        }
        func enumeration(_ tag: UInt32, _ range: ClosedRange<Int>) throws -> Int {
            let value = try raw(tag, 0)
            if value == 255 { return 0 }
            let decoded = value - 128
            try requireNp3(range.contains(decoded), "Invalid classic NP3 monochrome adjustment")
            return decoded
        }
        let filter = try enumeration(0x0c00, 0...4)
        let toning = try enumeration(0x0d00, 0...9)
        let density = try scalar(0x0e00, 0...28)
        if !base.isMonochrome {
            try requireNp3(filter == 0 && toning == 0 && density == 0, "Unsupported classic color preset monochrome adjustment", reason: .unsupported)
        }
        if (0x080d...0x0810).contains(baseID) {
            try requireNp3(toning == 0, "Unsupported classic fixed-tone override", reason: .unsupported)
        }
        let effect = try raw(0x1500, 10), effectLevel: Int
        if base.isCreative {
            try requireNp3((128...138).contains(effect), "Invalid classic NP3 creative effect level")
            effectLevel = (effect - 128) * 10
        } else {
            try requireNp3(effect == 255 || effect == 128, "Unexpected classic NP3 creative effect level", reason: .unsupported)
            effectLevel = 100
        }
        if version == "0310" {
            try inactive(0x1700, 4); try inactive(0x1800, 4)
            for tag in stride(from: UInt32(0x1900), through: 0x1d00, by: 0x100) {
                let value = try raw(tag, 1)
                try requireNp3(value == 128 || value == 1 && curve != nil, "Unsupported additional classic NP3 tonal adjustment", reason: .unsupported)
            }
            try requireNp3(raw(0x1e00, 1) == 128, "Unsupported additional classic NP3 saturation", reason: .unsupported)
            let mixer = try fields.field(0x1f00, size: 28)
            try requireNp3(mixer.prefix(24).allSatisfy { $0 == 128 } && Array(mixer[24..<28]) == [1, 1, 1, 0],
                "Unsupported additional classic NP3 mixer", reason: .unsupported)
            try neutralGrading(fields.field(0x2000, size: 20))
        }
        try fields.validateComment()
        return try ClassicNp3FilterParameters(base: base, contrastQuarter: contrast, brightnessQuarter: brightness,
            saturationQuarter: saturation, hueQuarter: hue, filterEffect: filter, toningEffect: toning,
            toningDensityQuarter: density, effectLevel: effectLevel, toneCurve: curve)
    }
    private static func neutralGrading(_ bytes: [UInt8]) throws {
        try requireNp3(Array(bytes[12..<16]) == [1, 1, 1, 0] && bytes[17] == 1 && bytes[19] == 1,
            "Unsupported classic NP3 grading encoding", reason: .unsupported)
        for offset in [0, 4, 8] {
            let hue = (Int(bytes[offset]) - 128) << 8 | Int(bytes[offset + 1])
            try requireNp3((0...360).contains(hue), "Invalid classic NP3 grading hue")
            try requireNp3(bytes[offset + 2] == 128 && bytes[offset + 3] == 128,
                "Unsupported additional classic NP3 grading", reason: .unsupported)
        }
        try requireNp3((0...100).contains(Int(bytes[16]) - 128) && (-100...100).contains(Int(bytes[18]) - 128),
            "Invalid classic NP3 grading blend")
    }
}
