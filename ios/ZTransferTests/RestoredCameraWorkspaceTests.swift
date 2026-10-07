import XCTest
@testable import ZTransfer

@MainActor
final class RestoredCameraWorkspaceTests: XCTestCase {
    func testRestoredCatalogCannotStartOrClaimACompletedScan() async {
        for mode in CameraPresentationMode.allCases {
            let model = PhotoListViewModel(disconnected: mode)
            model.load()
            await model.reload()
            await model.pauseForRemote()
            await model.resumeAfterRemote(isConnected: false)
            model.wakeThumbnailFill()
            await model.pauseForRemote()
            await model.resumeAfterRemote(isConnected: true)
            XCTAssertEqual(model.loadState, .idle)
            XCTAssertFalse(model.isLoadingFiles)
            XCTAssertFalse(model.hasCompletedFileScan)
            XCTAssertTrue(model.availableFiles.isEmpty)
            XCTAssertTrue(model.sections.isEmpty)
        }
    }

    func testUnavailableRemoteNeverPretendsCommandsSucceeded() async {
        for usb in [false, true] {
            let camera = DisconnectedRemoteCamera(isUSB: usb)
            XCTAssertEqual(camera.isUSB, usb)
            let control = await camera.hasRemoteControlMode()
            let movie = await camera.hasMovieApplicationMode()
            XCTAssertFalse(control)
            XCTAssertFalse(movie)
            await assertDisconnected { try await camera.startLiveView() }
            await assertDisconnected { _ = try await camera.liveViewFrame() }
            await assertDisconnected { try await camera.capturePhoto() }
            await assertDisconnected { _ = try await camera.remoteProperty(.exposureProgram) }
            await assertDisconnected { _ = try await camera.startMovieRecording() }
            await assertDisconnected { _ = try await camera.setRemoteControlMode(true) }
            await assertDisconnected { try await camera.ensureMovieApplicationMode() }
            // Teardown is safe even though no underlying session ever existed.
            await camera.endLiveView()
            await camera.setRemoteActive(false)
            await camera.clearMovieApplicationMode(force: true)
        }
    }

    private func assertDisconnected(_ action: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Unavailable camera operation reported success", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CameraTransportError, .disconnected, file: file, line: line)
        }
    }
}
