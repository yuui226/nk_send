import XCTest
@testable import ZTransfer

final class NikonPictureControlSelectionTests: XCTestCase {
    private var descriptor: Data {
        let hex = Array("00D20400010800050002250001000200030004000500060007000800650066006700680069006A006B006C006D006E006F00700071007200730074007500760077007800C900CA00CB00CC00CD00CE00CF00D000D100")
        return Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! })
    }
    func testRealDescriptorConfirmsNineSlotsWithoutConfusingActivePreset() throws {
        let selection = try NikonPictureControlSelection(descriptor)
        XCTAssertTrue(selection.writable)
        XCTAssertEqual(selection.current, 5)
        XCTAssertEqual(selection.choices.count, 37)
        XCTAssertEqual(selection.confirmedLastCustomSlot, 209)
        var partial = descriptor.dropLast(2)
        partial[10] = 36
        XCTAssertNil(try NikonPictureControlSelection(Data(partial)).confirmedLastCustomSlot)
        XCTAssertFalse(try NikonPictureControlSelection(Data(partial)).supportsSlot(209))
    }
    func testTruncatedWrongTypedAndDuplicateDescriptorsCannotAuthorizeWrites() throws {
        for length in 0..<descriptor.count {
            XCTAssertThrowsError(try NikonPictureControlSelection(Data(descriptor.prefix(length))))
        }
        for offset in [0, 2, 4] {
            var invalid = descriptor; invalid[offset] = 3
            XCTAssertThrowsError(try NikonPictureControlSelection(invalid))
        }
        var duplicate = descriptor; duplicate[14] = duplicate[12]
        XCTAssertThrowsError(try NikonPictureControlSelection(duplicate))
        var readOnly = descriptor; readOnly[4] = 0
        XCTAssertFalse(try NikonPictureControlSelection(readOnly).writable)
    }
    func testUserDialRequiresEffectivePSAMAndKeepsUnconfirmedProgramsRaw() {
        for program in 1...4 { XCTAssertTrue(NikonPictureControlExposure.permitsAdjustment(program: program, userMode: nil)) }
        for program in 0x8050...0x8052 {
            XCTAssertTrue(NikonPictureControlExposure.needsUserMode(program))
            for mode in 0...30 {
                XCTAssertEqual(NikonPictureControlExposure.permitsAdjustment(program: program, userMode: mode), (19...22).contains(mode))
            }
            XCTAssertFalse(NikonPictureControlExposure.permitsAdjustment(program: program, userMode: nil))
        }
        XCTAssertFalse(NikonPictureControlExposure.permitsAdjustment(program: 0x8010, userMode: 19))
        for (value, label) in [(UInt64(0x8050), "U1"), (0x8051, "U2"), (0x8052, "U3"), (0x8018, "0x8018")] {
            XCTAssertEqual(RemoteExposureParameters.format(.exposureProgram, raw: value), label)
        }
    }
}
