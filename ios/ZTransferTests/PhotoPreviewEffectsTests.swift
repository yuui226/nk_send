import XCTest
@testable import ZTransfer

final class PhotoPreviewEffectsTests: XCTestCase {
    private func photo(_ ext: String) -> CameraFile {
        .init(id: 1, storageID: 1, format: 0x3801, size: 1000, fileName: "DSC_0001." + ext, captureDate: nil, isProtected: false)
    }
    func testOnlyJPEGWithMasterOnOutsideReviewExposesEditor() {
        for ext in ["JPG", "JPEG", "jpg", "jpeg"] {
            XCTAssertTrue(showPreviewPhotoEffects(enabled: true, isReview: false, file: photo(ext)))
            XCTAssertFalse(showPreviewPhotoEffects(enabled: false, isReview: false, file: photo(ext)))
            XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: true, file: photo(ext)))
        }
        for ext in ["NEF", "MOV", "MP4", "PNG"] {
            XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: false, file: photo(ext)))
        }
        XCTAssertFalse(showPreviewPhotoEffects(enabled: true, isReview: false, file: nil))
    }
    func testDraftMasksInactiveFrameChildrenWithoutChangingStoredRecipe() {
        var stored = PhotoEffectsSettings()
        stored.photoFrameEnabled = false; stored.photoFrameBorderEnabled = true; stored.watermark.enabled = true
        stored.watermark.text = ""
        let draft = photoEffectsEditorDraft(stored)
        XCTAssertFalse(draft.photoFrameBorderEnabled); XCTAssertFalse(draft.watermark.enabled)
        XCTAssertEqual(draft.watermark.text, stored.watermark.displayText)
        XCTAssertTrue(stored.photoFrameBorderEnabled); XCTAssertTrue(stored.watermark.enabled)
        stored.photoFrameEnabled = true
        XCTAssertTrue(photoEffectsEditorDraft(stored).photoFrameBorderEnabled)
        XCTAssertTrue(photoEffectsEditorDraft(stored).watermark.enabled)
    }
    func testMissingSelectionUsesFirstFilterWithoutEnablingItOrChangingStore() throws {
        var stored = PhotoEffectsSettings()
        let first = try XCTUnwrap(PhotoFilterCatalog.presets.first)
        stored.filterIntensities[PhotoEffectsSettings.filterKey(first.id)] = 64
        let draft = photoEffectsEditorDraft(stored)
        XCTAssertEqual(draft.selectedFilter?.preset.id, first.id)
        XCTAssertEqual(draft.selectedFilter?.intensityPercent, 64)
        XCTAssertFalse(draft.photoFilterEnabled)
        XCTAssertNil(stored.selectedFilter)
    }
}
