import Foundation

func parseJpegCropHeader(_ bytes: Data) -> JpegCropSource? {
    let b = [UInt8](bytes); guard b.count >= 4, b[0] == 0xff, b[1] == 0xd8 else { return nil }
    var at = 2, orientation = 1, frame: JpegCropSource?
    func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i+1]) }
    while at + 2 <= b.count {
        guard b[at] == 0xff else { return nil }; at += 1; while at < b.count && b[at] == 0xff { at += 1 }; guard at < b.count else { return nil }
        let marker = b[at]; at += 1; if marker == 0xda { return frame.map { JpegCropSource(width: $0.width, height: $0.height, mcuWidth: $0.mcuWidth, mcuHeight: $0.mcuHeight, orientation: orientation) } }; if marker == 0xd9 { return nil }; if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
        guard at + 2 <= b.count else { return nil }; let length = u16(at); guard length >= 2, at + length <= b.count else { return nil }
        if marker == 0xe1, length >= 8,
           Array(b[(at + 2)..<(at + 8)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
            orientation = parseJpegExifOrientation(b, start: at + 8, end: at + length) ?? 1
        }
        if marker == 0xc0 || marker == 0xc1 || marker == 0xc2 {
            guard length >= 8, b[at+2] == 8 else { return nil }; let h=u16(at+3), w=u16(at+5), components=Int(b[at+7]); guard w > 0, h > 0, components == 1 || components == 3, length == 8 + components * 3 else { return nil }
            var maxH=1, maxV=1; for i in 0..<components { maxH=max(maxH,Int(b[at+9+i*3] >> 4)); maxV=max(maxV,Int(b[at+9+i*3] & 15)) }; frame = JpegCropSource(width:w,height:h,mcuWidth:maxH*8,mcuHeight:maxV*8,orientation:orientation)
        }
        at += length
    }; return nil
}

private func parseJpegExifOrientation(_ b: [UInt8], start: Int, end: Int) -> Int? {
    guard end - start >= 8 else { return nil }
    let little = b[start] == 0x49 && b[start + 1] == 0x49
    guard little || (b[start] == 0x4d && b[start + 1] == 0x4d) else { return nil }
    func value(_ at: Int, _ count: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<count { let shift = little ? i * 8 : (count - 1 - i) * 8; result |= UInt64(b[at + i]) << UInt64(shift) }
        return result
    }
    guard value(start + 2, 2) == 42 else { return nil }
    let offset = value(start + 4, 4)
    guard offset >= 8, offset <= UInt64(end - start - 2) else { return nil }
    let ifd = start + Int(offset); let count = Int(value(ifd, 2))
    guard ifd + 2 + count * 12 <= end else { return nil }
    for i in 0..<count {
        let entry = ifd + 2 + i * 12
        if value(entry, 2) == 0x112 {
            guard value(entry + 2, 2) == 3, value(entry + 4, 4) == 1 else { return nil }
            let result = Int(value(entry + 8, 2)); return (1...8).contains(result) ? result : nil
        }
    }
    return 1
}
