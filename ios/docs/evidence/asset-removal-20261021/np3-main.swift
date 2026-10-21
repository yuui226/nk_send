import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Accepted: " + label) } catch { checks += 1 }
}
for withCurve in [false, true] {
    let bytes = SyntheticPictureControlFixture.data(withCurve: withCurve)
    let file = try NikonPictureControlFile(bytes)
    check(file.data == bytes, "Container must preserve bytes")
    check(file.name == "Test Neutral", "User filename")
    let z = try file.encodeClassicPictureControl()
    let v2 = try file.encodePictureControl(format: .legacyV2)
    check(z.count == (withCurve ? 614 : 36), "Classic size")
    check(v2.count == (withCurve ? 610 : 32), "V2 size")
    check(v2[2] == 1, "Custom registration")
    check(try! NikonPictureControlData(item: 209, responseCode: 0x2001, data: z).name == file.name, "Classic name")
    check(try! NikonPictureControlData(item: 209, responseCode: 0x2001, data: v2, format: .legacyV2).name == file.name, "V2 name")
    if withCurve {
        check(z.subdata(in: 36..<614) == SyntheticPictureControlFixture.curve, "Z identity curve")
        check(v2.subdata(in: 32..<610) == SyntheticPictureControlFixture.curve, "V2 identity curve")
        check(try! NikonPictureControlToneCurve(SyntheticPictureControlFixture.curve).samples == (0...256).map { $0 * 32767 / 256 }, "All257 samples")
    }
    for length in 0..<bytes.count { rejects("truncation") { _ = try NikonPictureControlFile(Data(bytes.prefix(length))) } }
    for version in ["0301", "0310", "0399"] {
        var changed = bytes; changed.replaceSubrange(12..<16, with: version.utf8)
        let parsed = try NikonPictureControlFile(changed)
        rejects("new version encoding") { _ = try parsed.encodeClassicPictureControl() }
    }
    let input = InputStream(data: bytes); input.open()
    check(try! NikonPictureControlFile.read(input).data == bytes, "User stream")
    input.close()
    let cancelled = InputStream(data: bytes); cancelled.open()
    rejects("cancelled stream") { _ = try NikonPictureControlFile.read(cancelled) { throw CancellationError() } }
    check(try! NikonPictureControlFile.read(cancelled).data == bytes, "Cancelled read consumes no bytes")
    cancelled.close()
}
let unsupported = try SyntheticPictureControlFixture.file(midRange: 4)
_ = try unsupported.encodeClassicPictureControl()
do { _ = try unsupported.encodePictureControl(format: .legacyV2); fatalError("V2 must reject midrange") }
catch NikonPictureControlError.presetUnsupported { checks += 1 }
let oversized = InputStream(data: Data(repeating: 0, count: 100_000)); oversized.open()
rejects("oversized stream") { _ = try NikonPictureControlFile.read(oversized) }
oversized.close()
print("PASS: \(checks) assertions using actual NikonPictureControl.swift and generated neutral test fixtures")
