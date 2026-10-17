import XCTest
@testable import ZTransfer

final class RemoteDispModeTests: XCTestCase {
    func testDispCyclesCameraExposureClean() {
        XCTAssertEqual(RemoteDispMode.camera.next, .exposure)
        XCTAssertEqual(RemoteDispMode.exposure.next, .clean)
        XCTAssertEqual(RemoteDispMode.clean.next, .camera)
    }

    func testDispInformationVisibility() {
        XCTAssertTrue(RemoteDispMode.camera.showsCameraInformation)
        XCTAssertTrue(RemoteDispMode.camera.showsExposureInformation)
        XCTAssertFalse(RemoteDispMode.exposure.showsCameraInformation)
        XCTAssertTrue(RemoteDispMode.exposure.showsExposureInformation)
        XCTAssertFalse(RemoteDispMode.clean.showsCameraInformation)
        XCTAssertFalse(RemoteDispMode.clean.showsExposureInformation)
    }

    func testMovieFormatUsesOnlyVerifiedPackedD0A0Layouts() {
        func packed(width: UInt64, height: UInt64, rate: UInt64, flags: UInt64 = 0) -> UInt64 {
            (width << 48) | (height << 32) | (rate << 16) | flags
        }
        XCTAssertEqual(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 1920, height: 1080, rate: 60)), "1080 60p")
        XCTAssertEqual(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 3840, height: 2160, rate: 30)), "4K 30p")
        XCTAssertEqual(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 1280, height: 720, rate: 120)), "720 120p")
        XCTAssertNil(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0002, raw: packed(width: 1920, height: 1080, rate: 60)))
        XCTAssertNil(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 1920, height: 1080, rate: 60, flags: 1)))
        XCTAssertNil(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 1920, height: 1080, rate: 0)))
        XCTAssertNil(RemoteMonitorTelemetry.movieFormatLabel(
            dataType: 0x0008, raw: packed(width: 2560, height: 1440, rate: 60)))
    }

    func testRemainingTimeAndStorageDecodersRejectUnknownValues() {
        XCTAssertEqual(RemoteMonitorTelemetry.remainingTimeLabel(seconds: 0), "00:00")
        XCTAssertEqual(RemoteMonitorTelemetry.remainingTimeLabel(seconds: 3_599), "59:59")
        XCTAssertEqual(RemoteMonitorTelemetry.remainingTimeLabel(seconds: 3_600), "1:00:00")
        XCTAssertEqual(RemoteMonitorTelemetry.remainingTimeLabel(seconds: 86_400), "24:00:00")
        XCTAssertNil(RemoteMonitorTelemetry.remainingTimeLabel(seconds: -1))
        XCTAssertNil(RemoteMonitorTelemetry.remainingTimeLabel(seconds: 86_401))

        func payload(capacity: Int64, free: Int64) -> Data {
            var bytes = Data(repeating: 0, count: 26)
            func write(_ value: Int64, at offset: Int) {
                let bits = UInt64(bitPattern: value)
                for index in 0..<8 { bytes[offset + index] = UInt8((bits >> UInt64(index * 8)) & 0xff) }
            }
            write(capacity, at: 6); write(free, at: 14)
            return bytes
        }
        XCTAssertEqual(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: 128_000_000_000, free: 101_000_000_000)), 101_000_000_000)
        XCTAssertEqual(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: 128, free: 0)), 0)
        XCTAssertNil(RemoteMonitorTelemetry.parseMonitorFreeBytes(Data(repeating: 0, count: 25)))
        XCTAssertNil(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: -1, free: -1)))
        XCTAssertNil(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: 128, free: -1)))
        XCTAssertNil(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: 128, free: 129)))
        XCTAssertNil(RemoteMonitorTelemetry.parseMonitorFreeBytes(payload(capacity: 0, free: 0)))
    }

    func testCameraDispTopRowOrderingAndStandbyGate() {
        XCTAssertEqual(
            RemoteMonitorTelemetry.cameraTopRowItems(
                storage: ["Storage 1 · 12.3 GB", "Storage 2 · 8.7 GB"],
                movie: true, movieFormat: "4K 30p", remaining: "[01:22]", batteryPercent: 87
            ),
            ["Storage 1 · 12.3 GB", "Storage 2 · 8.7 GB", "4K 30p [01:22]", "87%"]
        )
        XCTAssertEqual(
            RemoteMonitorTelemetry.cameraTopRowItems(
                storage: ["12.3 GB"], movie: false, movieFormat: "1080 60p",
                remaining: "[00:22]", batteryPercent: nil
            ),
            ["12.3 GB"]
        )
        XCTAssertTrue(RemoteMonitorTelemetry.cameraShowsStandby(movie: true, recording: false))
        XCTAssertFalse(RemoteMonitorTelemetry.cameraShowsStandby(movie: true, recording: true))
        XCTAssertFalse(RemoteMonitorTelemetry.cameraShowsStandby(movie: false, recording: false))
    }

    func testCameraDispLayoutMatchesAndroidInsetsAndStandbyReservation() {
        XCTAssertEqual(RemoteDispLayout.horizontalInset, 12)
        XCTAssertEqual(RemoteDispLayout.verticalInset, 10)
        XCTAssertEqual(RemoteDispLayout.standbyTrailingReservation, 100)
        XCTAssertEqual(RemoteDispLayout.bottomCellSpacing, 16)
        XCTAssertEqual(RemoteDispLayout.bottomMaxWidth, 400)
        XCTAssertEqual(RemoteDispLayout.topTextWidth(containerWidth: 400), 276)
        XCTAssertEqual(RemoteDispLayout.topTextWidth(containerWidth: 100), 0)
    }
}
