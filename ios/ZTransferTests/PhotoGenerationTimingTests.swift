import XCTest
@testable import ZTransfer

final class PhotoGenerationTimingTests: XCTestCase {
    private func item() -> TransferQueueItem {
        TransferQueueItem(id: UUID(), file: CameraFile(id: 1, storageID: 1, format: 0x3801,
            size: 10, fileName: "DSC.JPG", captureDate: nil, isProtected: false))
    }
    func testPreparationDoesNotStartClockAndOnlyComputeIsRecorded() {
        var task = item()
        task.queueFrameGeneration()
        XCTAssertTrue(task.isGeneratingFrame)
        XCTAssertNil(task.displayedFrameGenerationElapsedMs(now: 5_000))
        task.startFrameGeneration(now: 5_000)
        XCTAssertEqual(task.displayedFrameGenerationElapsedMs(now: 5_250), 250)
        task.finishFrameGeneration(now: 5_500, savedOutput: true)
        XCTAssertEqual(task.frameGenerationElapsedMs, 500)
        XCTAssertEqual(task.displayedFrameGenerationElapsedMs(now: 99_000), 500)
    }
    func testCropPauseAndResumeAccumulateOnlyActiveIntervals() {
        var task = item()
        task.queueFrameGeneration()
        task.startFrameGeneration(now: 1_000)
        task.pauseFrameGeneration(now: 1_200)
        XCTAssertTrue(task.isGeneratingFrame)
        XCTAssertEqual(task.frameGenerationAccumulatedMs, 200)
        XCTAssertNil(task.displayedFrameGenerationElapsedMs(now: 4_000))
        task.startFrameGeneration(now: 5_000)
        XCTAssertEqual(task.displayedFrameGenerationElapsedMs(now: 5_100), 300)
        task.finishFrameGeneration(now: 5_300, savedOutput: true)
        XCTAssertEqual(task.frameGenerationElapsedMs, 500)
    }
    func testFailureAndExistingOutputDoNotKeepCompletedTimeAndRetryResets() {
        var task = item()
        task.queueFrameGeneration()
        task.startFrameGeneration(now: 1_000)
        task.finishFrameGeneration(now: 9_000, savedOutput: false)
        XCTAssertNil(task.frameGenerationElapsedMs)
        XCTAssertNil(task.displayedFrameGenerationElapsedMs(now: 10_000))
        task.queueFrameGeneration()
        XCTAssertEqual(task.frameGenerationAccumulatedMs, 0)
        XCTAssertNil(task.frameGenerationStartedAtElapsedMs)
        task.finishFrameGeneration(now: 20_000, savedOutput: true)
        XCTAssertNil(task.frameGenerationElapsedMs)
    }
    func testFinishingInactiveDoesNotOverwriteSavedTimeAndBackwardInputsClamp() {
        var task = item()
        task.startFrameGeneration(now: 1_000)
        XCTAssertEqual(task.displayedFrameGenerationElapsedMs(now: 900), 0)
        task.finishFrameGeneration(now: 3_500, savedOutput: true)
        let completed = task
        task.finishFrameGeneration(now: 20_000, savedOutput: false)
        XCTAssertEqual(task, completed)
    }
}
