import XCTest
@testable import ZTransfer

final class ButtonMaterialElevationTests: XCTestCase {
    func testRemoteEntryOverrideSurvivesActiveStateAndCollapsesByMaterial() {
        for active in [false, true] {
            for skin in [ZTransferButtonSkin.titanium, .wood, .cameraControls] {
                XCTAssertEqual(ZTransferButtonElevation.value(skin: skin, active: active, panel: false,
                    override: 6, pressProgress: 0), 6)
                XCTAssertEqual(ZTransferButtonElevation.value(skin: skin, active: active, panel: false,
                    override: 6, pressProgress: 1), skin == .cameraControls ? 1.08 : 2.04, accuracy: 0.000001)
            }
        }
    }

    func testFrostedBranchIgnoresElevationAndDefaultPanelsAreFlat() {
        for active in [false, true] {
            for pressed in [CGFloat(0), 0.5, 1] {
                XCTAssertEqual(ZTransferButtonElevation.value(skin: .frostedGlass, active: active, panel: false,
                    override: 6, pressProgress: pressed), 0)
                XCTAssertEqual(ZTransferButtonElevation.value(skin: .wood, active: active, panel: true,
                    override: nil, pressProgress: pressed), 0)
            }
        }
    }

    func testDefaultPhysicalHeightTracksActiveState() {
        for (skin, height) in [(ZTransferButtonSkin.titanium, CGFloat(7)), (.wood, 8), (.cameraControls, 9)] {
            XCTAssertEqual(ZTransferButtonElevation.value(skin: skin, active: false, panel: false,
                override: nil, pressProgress: 0), height)
            XCTAssertEqual(ZTransferButtonElevation.value(skin: skin, active: true, panel: false,
                override: nil, pressProgress: 0), height + 2)
        }
    }
}
