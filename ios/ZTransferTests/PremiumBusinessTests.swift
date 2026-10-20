import XCTest
import UIKit
import PhotosUI
import Photos
import SwiftUI
import Combine
@testable import ZTransfer

@MainActor
final class PremiumBusinessTests: XCTestCase {
    func testCancelledPickerAndRepeatedRequestsDuringPermissionDoNotPublishOrDuplicateWork() async throws {
        let authorization = PremiumPhotoAuthorizationGate()
        let saved = expectation(description: "Every selected photo saved once")
        saved.expectedFulfillmentCount = 3
        saved.assertForOverFulfill = true
        let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime),
            requestAuthorization: { await authorization.request() },
            generatePhoto: { _, _ in saved.fulfill() })
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        let settings = watermarkSettings()
        for _ in 0..<120 { model.select([]); model.generate(settings: settings) }
        XCTAssertEqual(publications, 0)
        let selection = (1...3).map { PhotosPickerItem(itemIdentifier: "selected-\($0)") }
        model.select(selection)
        XCTAssertEqual(publications, 1)
        model.generate(settings: settings)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await authorization.isWaiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await authorization.isWaiting
        XCTAssertTrue(waiting)
        let before = publications
        for _ in 0..<120 {
            model.select([])
            model.select([PhotosPickerItem(itemIdentifier: "replacement")])
            model.generate(settings: settings)
        }
        XCTAssertEqual(publications, before)
        XCTAssertEqual(model.state.photos, selection)
        XCTAssertEqual(model.state.progress.completed, 0)
        await authorization.finish(.authorized)
        await fulfillment(of: [saved], timeout: 3)
        let completedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.state.generating, ContinuousClock.now < completedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state.phase, .complete)
        XCTAssertEqual(model.state.progress, PhotoEffectsBatchProgress(total: 3, completed: 3, saved: 3))
        XCTAssertEqual(publications - before, 4, "Three settled items and one terminal phase; initial zero progress is unchanged")
        let completed = publications
        for _ in 0..<120 { model.select([]); model.generate(settings: settings) }
        XCTAssertEqual(publications, completed)
        // A real new selection still replaces the old terminal result and timer.
        model.select(selection)
        XCTAssertEqual(model.state.phase, .ready)
        XCTAssertEqual(model.state.photos, selection)
        XCTAssertEqual(publications, completed + 1)
        withExtendedLifetime(observation) {}
    }

    func testTwelveMegapixelConcurrentExportEntrypointsAcrossFrameModes() async throws {
        let (_, _, directory) = try fixture()
        let source = directory.appendingPathComponent("large-concurrent.png")
        let original = try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
                UIColor.red.setFill(); context.fill(CGRect(x: 2000, y: 0, width: 2000, height: 3000))
            }
            return try XCTUnwrap(image.pngData())
        }
        try original.write(to: source)
        for mode in 0..<4 {
            var settings = PhotoEffectsSettings()
            settings.photoFilterEnabled = true
            settings.selectedFilter = .init(preset: settings.orderedFilters[0], intensityPercent: 80)
            settings.photoFrameEnabled = mode != 0
            settings.photoFrameBorderEnabled = mode >= 2
            settings.photoFramePreset = mode == 2 ? .immersive : .minimal
            settings.watermark.enabled = mode == 1
            settings.watermark.text = "Resource test"
            settings.watermark.position = .photoBottomRight
            let recipe = settings
            let baseline = try previewTestPhysicalFootprint()
            let sampler = Task.detached(priority: .utility) { () throws -> (UInt64, Int) in
                var peak = baseline, count = 0
                while !Task.isCancelled {
                    peak = max(peak, try previewTestPhysicalFootprint()); count += 1
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
                }
                return (peak, count)
            }
            defer { sampler.cancel() }
            let started = ProcessInfo.processInfo.systemUptime
            async let local = LocalPhotoOutput.render(sourceURL: source, settings: recipe, availableMemory: { .max })
            async let queued = TransferQueue.renderFrameFile(source: source, settings: recipe,
                directory: directory, metadata: .empty, availableMemory: { .max })
            let (localData, outputURL) = try await (local, queued)
            sampler.cancel()
            let (peak, samples) = try await sampler.value
            try autoreleasepool {
                let first = try XCTUnwrap(UIImage(data: localData))
                let second = try XCTUnwrap(UIImage(contentsOfFile: outputURL.path))
                XCTAssertEqual(first.size, second.size)
                XCTAssertGreaterThanOrEqual(first.size.width, 4000)
                XCTAssertGreaterThanOrEqual(first.size.height, 3000)
                if mode < 3 { XCTAssertEqual(first.size, CGSize(width: 4000, height: 3000)) }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertGreaterThan(samples, 1)
            print("F110 concurrent12MP mode=\(mode) baseline=\(baseline) peak=\(peak) delta=\(peak-baseline) samples=\(samples) seconds=\(ProcessInfo.processInfo.systemUptime-started)")
        }
    }

    func testQueueFrameExportUsesLivePlaceGateEvenWithCachedResult() async throws {
        let (_, _, directory) = try fixture()
        let source = directory.appendingPathComponent("place-input.png")
        let original = try samplePNG()
        try original.write(to: source)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.metadata.showCity = true
        settings.metadata.showRegion = true
        let metadata = PhotoFrameMetadata(make: "Nikon", model: "Z8", lensModel: nil,
            focalLength: nil, aperture: nil, shutter: nil, iso: nil,
            exposureCompensation: nil, dateTime: nil, latitude: 30, longitude: 120,
            altitude: nil, city: "Stale city", region: "Stale region")
        let backend = QueuePlaceQueryCounter()
        let resolver = PhotoFramePlaceResolver { _, _, _ in await backend.query() }
        var renderedImages: [Data] = []
        for (allowed, expectedCalls) in [(false, 0), (true, 1), (false, 1)] {
            let output = try await TransferQueue.renderFrameFile(source: source, settings: settings,
                directory: directory, metadata: metadata, availableMemory: { .max },
                placeResolver: resolver, placeAllowed: { allowed })
            let image = try XCTUnwrap(UIImage(contentsOfFile: output.path))
            renderedImages.append(try XCTUnwrap(image.pngData()))
            let calls = await backend.calls
            XCTAssertEqual(calls, expectedCalls)
        }
        XCTAssertEqual(renderedImages[0], renderedImages[2], "Cached place must not appear in offline exports")
        XCTAssertNotEqual(renderedImages[0], renderedImages[1], "Online export must actually render the resolved place")
        let calls = await backend.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testConcurrentFileExportEntrypointsRejectLowBudgetAndRecover() async throws {
        let (_, _, directory) = try fixture()
        let source = directory.appendingPathComponent("budget-input.png")
        let original = try samplePNG()
        try original.write(to: source)
        let settings = effectivePhotoEffectsSettings(watermarkSettings(), isPro: true)
        let failures = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                do {
                    _ = try await LocalPhotoOutput.render(sourceURL: source, settings: settings, availableMemory: { 0 })
                    return false
                } catch is PhotoAllocationRejected { return true }
                catch { return false }
            }
            group.addTask {
                do {
                    _ = try await TransferQueue.renderFrameFile(source: source, settings: settings,
                        directory: directory, metadata: nil, availableMemory: { 0 })
                    return false
                } catch is PhotoAllocationRejected { return true }
                catch { return false }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(failures, [true, true])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ZTFrames").path))
        async let local = LocalPhotoOutput.render(sourceURL: source, settings: settings, availableMemory: { .max })
        async let queued = TransferQueue.renderFrameFile(source: source, settings: settings,
            directory: directory, metadata: nil, availableMemory: { .max })
        let (localData, outputURL) = try await (local, queued)
        XCTAssertNotNil(UIImage(data: localData))
        XCTAssertNotNil(UIImage(contentsOfFile: outputURL.path))
        XCTAssertEqual(UIImage(data: localData)?.size, UIImage(contentsOfFile: outputURL.path)?.size)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExplicitModuleHideDoesNotReactivateAfterShowingOrRestoring() throws {
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            for isPro in [false, true] {
                let suite = "module-hide-\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let access = PremiumAccess(.lifetime)
                let store = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: access)
                var initial = watermarkSettings()
                initial.watermark.enabled = true
                initial.watermark.text = "Preserve my parameters"
                initial.photoFrameBorderEnabled = true
                initial.selectedFilter = .init(preset: try XCTUnwrap(PhotoFilterCatalog.presets.first), intensityPercent: 64)
                initial.photoFilterEnabled = true
                store.update(initial)
                if !isPro { access.replace(with: .free) }
                var draft = store.beginDraft()
                draft.applyModuleVisibility(PhotoEffectModule.lut.rawValue, isPro: isPro)
                XCTAssertFalse(draft.photoFilterEnabled)
                XCTAssertFalse(draft.photoFrameBorderEnabled)
                XCTAssertFalse(draft.watermark.enabled)
                XCTAssertFalse(draft.photoFrameEnabled)
                // Camera persists module choices before the full draft commit.
                store.persistEditorPreferences(from: draft)
                XCTAssertFalse(store.settings.watermark.enabled)
                XCTAssertFalse(store.settings.photoFilterEnabled)
                XCTAssertEqual(store.settings.watermark.text, initial.watermark.text)
                draft.applyModuleVisibility(allPhotoEffectModules, isPro: isPro)
                store.updateFromEditor(draft)
                let restored = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: access).settings
                XCTAssertFalse(restored.photoFilterEnabled)
                XCTAssertFalse(restored.photoFrameBorderEnabled)
                XCTAssertFalse(restored.watermark.enabled)
                XCTAssertFalse(restored.photoFrameEnabled)
                XCTAssertEqual(restored.watermark.text, initial.watermark.text)
                XCTAssertEqual(restored.photoFramePreset, initial.photoFramePreset)
                XCTAssertEqual(restored.selectedFilter?.preset.id, initial.selectedFilter?.preset.id)
            }
        }
    }

    func testWatermarkOnlyEditorSettingsRestoreAndRenderWithoutBorder() throws {
        let source = try XCTUnwrap(UIImage(data: samplePNG()))
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let suite = "watermark-only-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PhotoEffectsStore(defaults: defaults, scope: scope,
                                          premiumAccess: PremiumAccess(.lifetime))
            var draft = watermarkSettings()
            draft.photoEffectModules = PhotoEffectModule.watermark.rawValue
            // A stale border preference must not add a frame in this module.
            draft.photoFrameBorderEnabled = true
            draft.watermark.enabled = true
            draft.watermark.text = "First signature"
            store.updateFromEditor(draft)
            let first = effectivePhotoEffectsSettings(store.settings, isPro: true)
            XCTAssertTrue(first.photoFrameEnabled)
            XCTAssertTrue(first.watermark.enabled)
            XCTAssertFalse(first.photoFrameBorderEnabled)
            let firstImage = try PhotoEffectsRenderer.render(source, settings: first)
            XCTAssertEqual(firstImage.size, source.size)
            var off = first
            off.watermark.enabled = false
            let unmarked = try PhotoEffectsRenderer.render(source, settings: off)
            XCTAssertNotEqual(try XCTUnwrap(firstImage.pngData()), try XCTUnwrap(unmarked.pngData()))
            draft.watermark.text = "Changed signature"
            store.updateFromEditor(draft)
            let restored = PhotoEffectsStore(defaults: defaults, scope: scope,
                                             premiumAccess: PremiumAccess(.lifetime))
            let second = effectivePhotoEffectsSettings(restored.settings, isPro: true)
            XCTAssertEqual(second.watermark.text, "Changed signature")
            XCTAssertTrue(second.watermark.enabled)
            XCTAssertFalse(second.photoFrameBorderEnabled)
            let secondImage = try PhotoEffectsRenderer.render(source, settings: second)
            XCTAssertEqual(secondImage.size, source.size)
            XCTAssertNotEqual(try XCTUnwrap(firstImage.pngData()), try XCTUnwrap(secondImage.pngData()))
        }
    }

    func testLocalBatchReleasesOnlyItsHoldAfterPreferenceAndForegroundChanges() async throws {
        for finalPreference in [false, true] {
            var awake = false
            let coordinator = ScreenAwakeCoordinator { awake = $0 }
            coordinator.setForeground(true)
            coordinator.setPreference(!finalPreference)
            let authorization = PremiumPhotoAuthorizationGate()
            let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime),
                screenAwake: coordinator, requestAuthorization: { await authorization.request() },
                generatePhoto: { _, _ in })
            model.select([PhotosPickerItem(itemIdentifier: "held-batch")])
            model.generate(settings: watermarkSettings())
            XCTAssertTrue(awake)
            for _ in 0..<300 {
                if await authorization.isWaiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let waiting = await authorization.isWaiting
            XCTAssertTrue(waiting)
            coordinator.setPreference(finalPreference)
            let anotherOwner = coordinator.acquire()
            coordinator.setForeground(false)
            XCTAssertFalse(awake)
            await authorization.finish(.authorized)
            for _ in 0..<300 {
                if !model.state.generating { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.state.phase, .complete)
            XCTAssertFalse(awake, "Batch completion cannot restore a foreground snapshot while backgrounded")
            coordinator.setForeground(true)
            XCTAssertTrue(awake, "Another owner's hold survives batch completion")
            coordinator.release(anotherOwner)
            XCTAssertEqual(awake, finalPreference)
        }
    }

    // Android LocalPhotoBatchViewModel keeps the selection after failure and
    // permits a new batch after 2400 ms. Exercise the iOS permission boundary
    // changing between those batches without recreating the model or selection.
    func testLocalBatchRecoversAfterPhotoPermissionIsGrantedWithoutReselection() async throws {
        let authorization = PremiumPhotoAuthorizationGate()
        let saved = expectation(description: "Recovered batch saves each selected photo once")
        saved.expectedFulfillmentCount = 2
        saved.assertForOverFulfill = true
        let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime),
            requestAuthorization: { await authorization.request() },
            generatePhoto: { _, _ in saved.fulfill() })
        let selection = (1...2).map { PhotosPickerItem(itemIdentifier: "permission-recovery-\($0)") }
        model.select(selection)
        for status in [PHAuthorizationStatus.denied, .authorized] {
            model.generate(settings: watermarkSettings())
            let permissionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await authorization.isWaiting), ContinuousClock.now < permissionDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let waiting = await authorization.isWaiting
            XCTAssertTrue(waiting, "Every new batch must recheck the current permission")
            await authorization.finish(status)
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.state.phase != .ready, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.state.phase, .ready)
            XCTAssertEqual(model.state.photos, selection)
            XCTAssertEqual(model.state.progress.failed, status == .denied ? 2 : 0)
            XCTAssertEqual(model.state.progress.saved, status == .denied ? 0 : 2)
            if status == .authorized { XCTAssertTrue(model.state.progress.failures.isEmpty) }
        }
        await fulfillment(of: [saved], timeout: 1)
    }

    func testLocalBatchPermissionDetailsSurviveReadyAndUseAndroidText() async throws {
        let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime),
            requestAuthorization: { .denied }, generatePhoto: { _, _ in
                XCTFail("Denied authorization must not invoke the renderer")
            })
        model.select((1...6).map { PhotosPickerItem(itemIdentifier: "denied-\($0)") })
        model.generate(settings: watermarkSettings())
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.state.phase != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state.phase, .ready)
        XCTAssertEqual(model.state.progress.failed, 6)
        XCTAssertEqual(model.state.progress.failures.count, 5)
        let failure = try XCTUnwrap(model.state.progress.failures.first)
        XCTAssertEqual(failure.stage, "save")
        XCTAssertEqual(failure.kind, "permission")
        let previous = UserDefaults.standard.object(forKey: "app_language")
        defer { UserDefaults.standard.set(previous, forKey: "app_language") }
        for (language, title, reason) in [
            ("en", "Photo \(failure.number) · Saving to album", "Photo access was denied. Select the photo again and check photo permissions."),
            ("zh", "第 \(failure.number) 张 · 保存到相册", "照片访问被拒绝，请重新选择照片并检查照片访问权限。"),
            ("zh-Hant", "第 \(failure.number) 張 · 儲存至相簿", "照片存取遭拒，請重新選擇照片並檢查照片存取權限。")
        ] {
            UserDefaults.standard.set(language, forKey: "app_language")
            XCTAssertEqual(localPhotoFailureText(failure), title + "\n" + reason + "\n" + failure.detail)
        }
        model.select([PhotosPickerItem(itemIdentifier: "next-selection")])
        XCTAssertTrue(model.state.progress.failures.isEmpty)
    }

    private func fixture() throws -> (UserDefaults, FreeUsageStore, URL) {
        let name = "PremiumBusinessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return (defaults, FreeUsageStore(defaults: defaults), directory)
    }

    private func file(_ id: UInt32, size: UInt64 = 10) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: size,
                   fileName: "premium-\(id).JPG", captureDate: nil, isProtected: false)
    }

    private func settled(_ queue: TransferQueue) async throws -> TransferQueueSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let value = await queue.snapshot()
            if !value.isTransferring { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.validationMissingMandatoryProperty)
    }

    #if DEBUG
    func testSimulatedPurchaseUnblocksExhaustedQueueWithoutResettingUsage() async throws {
        let (defaults, usage, directory) = try fixture()
        for _ in 0..<25 { usage.recordTransfer(id: UUID(), isPro: false) }
        let access = PremiumAccess(.free)
        let entitlement = PremiumEntitlementStore(access: access)
        entitlement.enableDevelopmentPurchases(defaults: defaults)
        let queueSuite = "SimulatedPurchaseQueue.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: queueSuite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: queueSuite)!,
                                  premiumAccess: access, freeUsage: usage)
        let camera = PremiumTestCamera()
        await queue.enqueue([file(1)])
        await queue.start(session: camera, directory: directory)
        let blocked = try await settled(queue)
        XCTAssertEqual(blocked.items.first?.status, .failed)
        XCTAssertEqual(blocked.items.first?.error, AppLocalized.resource("transfer_limit_reached"))

        entitlement.simulatePurchase(.lifetime)
        entitlement.publish(.free) // A concurrent real StoreKit refresh must not relock it.
        _ = await queue.retry(id: try XCTUnwrap(blocked.items.first?.id))
        await queue.start(session: camera, directory: directory)
        let completed = try await settled(queue)
        XCTAssertEqual(completed.items.first?.status, .completed)
        XCTAssertEqual(usage.snapshot().transfers, 25)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file(1).fileName).path))

        entitlement.endSimulatedPurchase()
        await queue.enqueue([file(2)])
        await queue.start(session: camera, directory: directory)
        let relocked = try await settled(queue)
        XCTAssertEqual(relocked.items.last?.status, .failed)
        XCTAssertEqual(relocked.items.last?.error, AppLocalized.resource("transfer_limit_reached"))
        XCTAssertEqual(usage.snapshot().transfers, 25)
        let requests = await camera.requests
        XCTAssertEqual(requests, [1])
    }
    #endif

    func testQuotaCountsOnlyRealSuccessAndDoesNotBlockLocalShortcuts() async throws {
        let (defaults, usage, directory) = try fixture()
        for _ in 0..<24 { usage.recordTransfer(id: UUID(), isPro: false) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueLegacy.\(UUID())")!, premiumAccess: PremiumAccess(.free), freeUsage: usage)
        let camera = PremiumTestCamera()
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        let video = CameraFile(id: 2, storageID: 1, format: 0x300D, size: 10,
                               fileName: "premium-2.MP4", captureDate: nil, isProtected: false)
        let partial = directory.appendingPathComponent(transferPartialFileName(size: 10, captureDate: nil, fileName: video.fileName))
        try Data(repeating: 1, count: 10).write(to: partial)
        await queue.enqueue([file(1), video, file(3), file(4)])
        await queue.start(session: camera, directory: directory)
        let done = try await settled(queue)
        XCTAssertEqual(done.items.map(\.status), [.completed, .completed, .completed, .failed])
        XCTAssertEqual(done.items.last?.error, AppLocalized.resource("transfer_limit_reached"))
        XCTAssertEqual(usage.snapshot().transfers, 25)
        let requests = await camera.requests
        XCTAssertEqual(requests, [3])
    }

    func testSizeLimitAllowsBoundaryAndRejectsUnknownLargeSizeWithoutBlockingNext() async throws {
        let (defaults, usage, directory) = try fixture()
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueLegacy.\(UUID())")!, premiumAccess: PremiumAccess(.free), freeUsage: usage)
        let camera = PremiumTestCamera()
        await queue.enqueue([file(1, size: FreeUsageStore.maximumFileBytes + 1),
                             file(2, size: UInt64(UInt32.max)),
                             file(3, size: FreeUsageStore.maximumFileBytes), file(4)])
        await queue.start(session: camera, directory: directory)
        let done = try await settled(queue)
        XCTAssertEqual(done.items.map(\.status), [.failed, .failed, .completed, .completed])
        XCTAssertEqual(usage.snapshot().transfers, 2)
        let requests = await camera.requests
        XCTAssertEqual(requests, [3, 4])
    }

    func testQueuedAndRetriedWatermarksStayFrozenButNewTasksUseCurrentAccess() async throws {
        let (defaults, usage, directory) = try fixture()
        let access = PremiumAccess(.lifetime)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueLegacy.\(UUID())")!, premiumAccess: access, freeUsage: usage)
        var preference = PhotoEffectsSettings()
        preference.photoFrameEnabled = true
        preference.watermark.text = "Paid logo"
        let enqueued = await queue.enqueue(file(1), effects: preference)
        let id = try XCTUnwrap(enqueued)
        await queue.withdraw(id: id)
        access.replace(with: .free)
        preference.watermark.text = "Edited later"
        await queue.attach(session: nil, directory: directory)
        _ = await queue.retry(id: id)
        _ = try await settled(queue)
        await queue.enqueueAutomatic([file(2)], effects: preference)
        let state = await queue.snapshot()
        XCTAssertEqual(state.items[0].effects?.watermark.text, "Paid logo")
        XCTAssertEqual(state.items[1].effects?.watermark.text, PhotoFrameWatermark.defaultText)
        XCTAssertEqual(state.items[1].effects?.watermark.opacityPercent, 80)
        XCTAssertEqual(usage.snapshot().transfers, 0)
    }

    func testEditorAndPendingImageImportPreservePreferencesAfterRefund() throws {
        let (defaults, _, _) = try fixture()
        let access = PremiumAccess(.lifetime)
        let store = PhotoEffectsStore(defaults: defaults, premiumAccess: access)
        var original = store.settings
        original.watermark.text = "Personal signature"
        store.updateFromEditor(original)
        let generation = try XCTUnwrap(store.beginWatermarkImageImport())
        access.replace(with: .free)
        var lateDraft = original
        lateDraft.watermark.text = "Late edit"
        lateDraft.photoFrameEnabled = true
        store.updateFromEditor(lateDraft)
        XCTAssertEqual(store.settings.watermark.text, "Personal signature")
        XCTAssertTrue(store.settings.photoFrameEnabled)
        XCTAssertFalse(store.finishWatermarkImageImport(generation: generation, hash: String(repeating: "a", count: 64)))
        XCTAssertFalse(store.watermarkImageImporting)
        XCTAssertNil(store.beginWatermarkImageImport())
        XCTAssertEqual(effectivePhotoEffectsSettings(store.settings, isPro: false).watermark.text, PhotoFrameWatermark.defaultText)
    }

    func testImmediateDraftPersistencePreservesPaidFavoritesAfterRefund() throws {
        let (defaults, _, _) = try fixture()
        let access = PremiumAccess(.lifetime)
        let store = PhotoEffectsStore(defaults: defaults, premiumAccess: access)
        var original = store.settings
        original.watermark.text = "Saved signature"
        original.watermark.sizePercent = 180
        original.watermark.opacityPercent = 55
        original.favoriteFrameEffects = [.init(preset: .minimal, watermark: original.watermark)]
        original.favoriteFramePresets = [.minimal]
        store.updateFromEditor(original)
        let saved = store.settings
        var draft = saved
        draft.photoFrameEnabled = true
        draft.photoFrameBorderEnabled = true
        draft.photoFramePreset = .minimal
        draft.watermark.text = "Late text edit"
        draft.favoriteFrameEffects[0].watermark.sizePercent = 30
        draft.favoriteFrameEffects[0].watermark.opacityPercent = 10
        let filter = try XCTUnwrap(Np3FilterCatalog.presets.first)
        draft.toggleFilterFavorite(filter.id)
        access.replace(with: .free)
        store.persistEditorPreferences(from: draft)
        XCTAssertEqual(store.settings.watermark, saved.watermark)
        XCTAssertEqual(store.settings.favoriteFrameEffects, saved.favoriteFrameEffects)
        XCTAssertTrue(store.settings.favoriteFilterIDs.contains(PhotoEffectsSettings.filterKey(filter.id)))
        XCTAssertEqual(store.settings.photoFrameEnabled, saved.photoFrameEnabled, "Preference persistence must not apply the active effects draft")
        let reopened = PhotoEffectsStore(defaults: defaults, premiumAccess: access)
        XCTAssertEqual(reopened.settings.favoriteFrameEffects, saved.favoriteFrameEffects)
        XCTAssertEqual(reopened.settings.watermark, saved.watermark)
    }

    func testFreeFavoritesUseDefaultWatermarkAndKeepExistingPaidPreferencesInBothScopes() throws {
        for scope in [PhotoEffectsStore.Scope.cameraTransfer, .localPhotos] {
            let (defaults, _, _) = try fixture()
            let access = PremiumAccess(.lifetime)
            let store = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: access)
            var original = store.settings
            original.photoFrameEnabled = true
            original.photoFrameBorderEnabled = true
            original.photoFramePreset = .minimal
            original.watermark.sizePercent = 220
            original.watermark.opacityPercent = 42
            original.favoriteFrameEffects = [.init(preset: .minimal, watermark: original.watermark)]
            original.favoriteFramePresets = [.minimal]
            store.updateFromEditor(original)
            let saved = store.settings
            access.replace(with: .free)
            var draft = saved
            draft.favoriteFrameEffects[0].watermark.sizePercent = 5
            draft.favoriteFrameEffects.append(.init(preset: .mist, watermark: original.watermark))
            draft.favoriteFramePresets.insert(.mist)
            store.updateFromEditor(draft)
            XCTAssertEqual(store.settings.watermark, saved.watermark)
            XCTAssertEqual(store.settings.favoriteFrameEffects.first { $0.preset == .minimal }, saved.favoriteFrameEffects.first)
            let added = try XCTUnwrap(store.settings.favoriteFrameEffects.first { $0.preset == .mist })
            XCTAssertEqual(added.watermark, effectivePhotoFrameWatermark(isPro: false, preference: original.watermark))

            // Removing a favorite remains free; only its paid watermark data
            // is protected. Re-upgrading preserves the original preference.
            var removal = store.settings
            removal.favoriteFrameEffects.removeAll { $0.preset == .minimal }
            removal.favoriteFramePresets.remove(.minimal)
            store.updateFromEditor(removal)
            XCTAssertFalse(store.settings.favoriteFramePresets.contains(.minimal))
            access.replace(with: .lifetime)
            let reopened = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: access)
            XCTAssertEqual(reopened.settings.watermark, saved.watermark)
            XCTAssertEqual(reopened.settings.favoriteFrameEffects, store.settings.favoriteFrameEffects)
        }
    }

    /// Uses the production queue, renderer and JPEG writer (no renderer stub).
    /// A free/premium reference must differ, so an omitted watermark cannot
    /// accidentally satisfy the snapshot assertion.
    func testRenderedWatermarksStayFrozenAcrossRefundAndUpgrade() async throws {
        let (defaults, usage, directory) = try fixture()
        let access = PremiumAccess(.lifetime)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: directory.lastPathComponent)!, premiumAccess: access, freeUsage: usage)
        let data = try samplePNG()
        let cameraFile = file(1, size: UInt64(data.count))
        let source = directory.appendingPathComponent(cameraFile.fileName)
        try data.write(to: source)
        var preference = watermarkSettings()
        preference.watermark.text = "Original signature"
        let paid = effectivePhotoEffectsSettings(preference, isPro: true)
        await queue.enqueue(cameraFile, effects: preference)
        access.replace(with: .free)
        preference.watermark.text = "Edited after refund"
        await queue.start(session: nil, directory: directory)
        let first = try await rendered(queue)
        let firstURL = try XCTUnwrap(first.items[0].frameURL)
        let paidBytes = try renderedJPEG(source: source, settings: paid)
        let free = effectivePhotoEffectsSettings(preference, isPro: false)
        let freeBytes = try renderedJPEG(source: source, settings: free)
        XCTAssertNotEqual(paidBytes, freeBytes)
        XCTAssertEqual(try Data(contentsOf: firstURL), paidBytes)

        // The task created while free must retain its default watermark even
        // when an upgrade arrives before the real renderer starts.
        await queue.enqueue(cameraFile, effects: preference)
        access.replace(with: .lifetime)
        await queue.start(session: nil, directory: directory)
        let second = try await rendered(queue)
        let secondURL = try XCTUnwrap(second.items[1].frameURL)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: secondURL), freeBytes)

        // A new task uses current paid preferences and gets a separate output.
        await queue.enqueue(cameraFile, effects: preference)
        await queue.start(session: nil, directory: directory)
        let third = try await rendered(queue)
        let thirdURL = try XCTUnwrap(third.items[2].frameURL)
        let latestBytes = try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: true))
        XCTAssertNotEqual(latestBytes, paidBytes)
        XCTAssertNotEqual(latestBytes, freeBytes)
        XCTAssertEqual(try Data(contentsOf: thirdURL), latestBytes)
        XCTAssertEqual(try Data(contentsOf: firstURL), paidBytes, "New jobs must not overwrite old output")
        XCTAssertEqual(third.items.map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(usage.snapshot().transfers, 0, "Offline derivatives do not consume transfer quota")
        attachJPEG(paidBytes, name: "queued-paid-watermark-after-refund")
        attachJPEG(freeBytes, name: "queued-free-watermark-after-upgrade")
    }

    func testMissingOrCorruptWatermarkKeepsOriginalAndRetriesFrozenAsset() async throws {
        for missing in [true, false] {
            let (defaults, usage, directory) = try fixture()
            let access = PremiumAccess(.lifetime)
            let queue = TransferQueue(defaults: UserDefaults(suiteName: directory.lastPathComponent)!, premiumAccess: access, freeUsage: usage)
            let store = PhotoEffectsStore(defaults: defaults, premiumAccess: access)
            let hash = try XCTUnwrap(store.importWatermarkImage(data: samplePNG(color: .red, unique: true)))
            let asset = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZTransfer/Watermarks/\(hash).png")
            let originalAsset = try Data(contentsOf: asset)
            addTeardownBlock {
                PhotoEffectsStore.resetWatermarkImageCache()
                try? FileManager.default.removeItem(at: asset)
            }
            var preference = watermarkSettings()
            preference.watermark.content = .image; preference.watermark.imageHash = hash
            store.updateFromEditor(preference)
            let locked = effectivePhotoEffectsSettings(store.settings, isPro: true)
            let data = try samplePNG()
            let cameraFile = file(1, size: UInt64(data.count))
            let source = directory.appendingPathComponent(cameraFile.fileName)
            try data.write(to: source)
            let enqueued = await queue.enqueue(cameraFile, effects: store.settings)
            let id = try XCTUnwrap(enqueued)
            if missing { try FileManager.default.removeItem(at: asset) }
            else { try Data("corrupt watermark".utf8).write(to: asset, options: .atomic) }
            PhotoEffectsStore.resetWatermarkImageCache()
            await queue.start(session: nil, directory: directory)
            let failed = try await rendered(queue)
            XCTAssertEqual(failed.items[0].status, .completed) // Published original remains complete; frameError reports derivative failure.
            XCTAssertNotNil(failed.items[0].frameError)
            XCTAssertNil(failed.items[0].frameURL)
            XCTAssertEqual(try Data(contentsOf: source), data)
            XCTAssertEqual(failed.items[0].effects?.watermark.imageHash, hash)

            preference.watermark.content = .text; preference.watermark.text = "New preference"
            store.updateFromEditor(preference)
            try originalAsset.write(to: asset, options: .atomic)
            PhotoEffectsStore.resetWatermarkImageCache()
            let retried = await queue.retry(id: id)
            XCTAssertNotNil(retried)
            let completed = try await rendered(queue)
            XCTAssertEqual(completed.items[0].status, .completed)
            XCTAssertNil(completed.items[0].frameError)
            XCTAssertEqual(completed.items[0].effects?.watermark.imageHash, hash)
            let output = try XCTUnwrap(completed.items[0].frameURL)
            XCTAssertEqual(try Data(contentsOf: output), try renderedJPEG(source: source, settings: locked))
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }

    func testImageWatermarkRetryKeepsOriginalAssetAfterReplacementAndRefund() async throws {
        let (defaults, usage, directory) = try fixture()
        let access = PremiumAccess(.lifetime)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: directory.lastPathComponent)!, premiumAccess: access, freeUsage: usage)
        let store = PhotoEffectsStore(defaults: defaults, premiumAccess: access)
        let originalHash = try XCTUnwrap(store.importWatermarkImage(data: samplePNG(color: .red, unique: true)))
        let replacementHash = try XCTUnwrap(store.importWatermarkImage(data: samplePNG(color: .blue, unique: true)))
        addTeardownBlock {
            PhotoEffectsStore.resetWatermarkImageCache()
            let assets = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZTransfer/Watermarks")
            for hash in [originalHash, replacementHash] {
                try? FileManager.default.removeItem(at: assets.appendingPathComponent("\(hash).png"))
            }
        }
        var preference = watermarkSettings()
        preference.watermark.content = .image
        preference.watermark.imageHash = originalHash
        store.updateFromEditor(preference)
        let locked = effectivePhotoEffectsSettings(store.settings, isPro: true)
        let data = try samplePNG()
        let cameraFile = file(1, size: UInt64(data.count))
        let source = directory.appendingPathComponent(cameraFile.fileName)
        // Preserve identity and size while causing a real decode failure.
        try Data(repeating: 0, count: data.count).write(to: source)
        let enqueued = await queue.enqueue(cameraFile, effects: store.settings)
        let originalID = try XCTUnwrap(enqueued)
        await queue.start(session: nil, directory: directory)
        let failed = try await rendered(queue)
        XCTAssertEqual(failed.items[0].status, .completed) // Published original remains complete; frameError reports derivative failure.
        XCTAssertNotNil(failed.items[0].frameError)
        XCTAssertNil(failed.items[0].frameURL)

        preference.watermark.imageHash = replacementHash
        store.updateFromEditor(preference)
        access.replace(with: .free)
        PhotoEffectsStore.resetWatermarkImageCache() // Prove the old disk asset survives.
        try data.write(to: source, options: .atomic)
        let retried = await queue.retry(id: originalID)
        XCTAssertNotNil(retried)
        let completed = try await rendered(queue)
        let output = try XCTUnwrap(completed.items[0].frameURL)
        let expected = try renderedJPEG(source: source, settings: locked)
        XCTAssertEqual(try Data(contentsOf: output), expected)
        XCTAssertNotEqual(expected, try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: false)))
        XCTAssertNotEqual(expected, try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: true)))
        XCTAssertEqual(completed.items[0].status, .completed)
        XCTAssertNil(completed.items[0].frameError)
        XCTAssertEqual(usage.snapshot().transfers, 0)
        attachJPEG(expected, name: "retried-original-image-watermark-after-refund")
    }

    func testNewCameraDownloadRendersEnqueuedWatermarkAfterMidDownloadRefund() async throws {
        let (_, usage, directory) = try fixture()
        let access = PremiumAccess(.lifetime)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: directory.lastPathComponent)!,
                                  premiumAccess: access, freeUsage: usage)
        let bytes = try samplePNG()
        let camera = PremiumRenderingCamera(bytes: bytes, access: access)
        var preference = watermarkSettings()
        preference.watermark.text = "Before camera transfer"
        let cameraFile = file(1, size: UInt64(bytes.count))
        await queue.enqueue(cameraFile, effects: preference)
        await queue.start(session: camera, directory: directory)
        let result = try await rendered(queue)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .completed)
        XCTAssertNil(item.frameError)
        XCTAssertFalse(access.isPro)
        let source = try XCTUnwrap(item.outputURL)
        let derived = try XCTUnwrap(item.frameURL)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let expected = try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: true))
        XCTAssertEqual(try Data(contentsOf: derived), expected)
        XCTAssertNotEqual(expected, try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: false)))
        XCTAssertEqual(usage.snapshot().transfers, 1, "One original completed while free; the derivative is not a second transfer")
        attachJPEG(expected, name: "camera-watermark-after-mid-download-refund")
    }

    private func rendered(_ queue: TransferQueue) async throws -> TransferQueueSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let value = await queue.snapshot()
            if !value.isTransferring && value.items.allSatisfy({ !$0.isGeneratingFrame }) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.validationMissingMandatoryProperty)
    }

    func testLocalBatchKeepsPaidWatermarkWhenRefundedDuringAuthorization() async throws {
        try await verifyLocalBatchSnapshot(startingPro: true)
    }

    func testLocalBatchKeepsFreeWatermarkWhenUpgradedDuringAuthorization() async throws {
        try await verifyLocalBatchSnapshot(startingPro: false)
    }

    func testLocalLUTBatchKeepsCapturedSnapshotAndAdjustmentsThroughEditorReplacementAndPruning() async throws {
        let (_, _, directory) = try fixture()
        let suite = "local-lut-batch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoLUTStore(role: .local, defaults: defaults, directory: directory.appendingPathComponent("lut"))
        let old = try CubeLUTParser.parse(Data(("TITLE local-old\nLUT_3D_SIZE 2\n"
            + String(repeating: "0.1 0.2 0.3\n", count: 8)).utf8))
        let new = try CubeLUTParser.parse(Data(("TITLE local-new\nLUT_3D_SIZE 2\n"
            + String(repeating: "1 0 0\n", count: 8)).utf8))
        let authorization = PremiumPhotoAuthorizationGate()
        let source = directory.appendingPathComponent("lut-source.png")
        try samplePNG().write(to: source)
        let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime),
            requestAuthorization: { await authorization.request() },
            generatePhoto: { item, settings in
                let bytes = try await LocalPhotoOutput.render(sourceURL: source, settings: settings)
                guard let id = item.itemIdentifier else { throw CocoaError(.fileReadUnknown) }
                try bytes.write(to: directory.appendingPathComponent("\(id).jpg"), options: .atomic)
            })
        let photos = (0..<3).map { PhotosPickerItem(itemIdentifier: "lut-batch-\($0)") }
        model.select(photos)
        var preference = PhotoEffectsSettings()
        preference.selectedFilter = try store.selectLUT(old, name: "Old", sourceIdentifier: "old.cube")
        preference.selectedFilter?.intensityPercent = 64
        preference.selectedFilter?.lutAdjustments = .init(contrast: 20, saturation: -30, highlights: 25, shadows: -15)
        preference.photoFilterEnabled = true
        let expected = try await LocalPhotoOutput.render(sourceURL: source, settings: preference)
        weak var oldOwner = preference.selectedFilter?.snapshotOwner
        model.generate(settings: preference)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await authorization.isWaiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await authorization.isWaiting
        XCTAssertTrue(waiting)
        preference.selectedFilter = try store.selectLUT(new, name: "New", sourceIdentifier: "new.cube")
        preference.selectedFilter?.intensityPercent = 100
        await store.pruneSnapshots()
        PhotoLUTRuntime.purgeMemoryCache()
        XCTAssertNotNil(oldOwner, "The running batch must own its captured LUT after the editor replaces it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lut/\(old.digest).bin").path))
        let changed = try await LocalPhotoOutput.render(sourceURL: source, settings: preference)
        XCTAssertNotEqual(expected, changed)
        await authorization.finish(.authorized)
        let finishDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.state.generating, ContinuousClock.now < finishDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state.phase, .complete)
        XCTAssertEqual(model.state.progress, PhotoEffectsBatchProgress(total: 3, completed: 3, saved: 3))
        for photo in photos {
            let output = directory.appendingPathComponent("\(try XCTUnwrap(photo.itemIdentifier)).jpg")
            XCTAssertEqual(try Data(contentsOf: output), expected)
        }
        model.select(photos) // End the terminal-result lifetime and release the captured recipe.
        for _ in 0..<100 {
            if oldOwner == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(oldOwner)
        await store.pruneSnapshots()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lut/\(old.digest).bin").path))
    }

    private func verifyLocalBatchSnapshot(startingPro: Bool) async throws {
        let (_, _, directory) = try fixture()
        let access = PremiumAccess(startingPro ? .lifetime : .free)
        let authorization = PremiumPhotoAuthorizationGate()
        let source = directory.appendingPathComponent("source.png")
        try samplePNG().write(to: source)
        // Only Photos authorization, picking and the final library write are
        // substituted. The production model, two-worker runner, image decoder,
        // watermark renderer and JPEG encoder all execute.
        let model = LocalPhotoBatchViewModel(premiumAccess: access, requestAuthorization: {
            await authorization.request()
        }, generatePhoto: { item, settings in
            let bytes = try await LocalPhotoOutput.render(sourceURL: source, settings: settings)
            guard let id = item.itemIdentifier else { throw CocoaError(.fileReadUnknown) }
            try bytes.write(to: directory.appendingPathComponent("\(id).jpg"), options: .atomic)
        })
        let photos = (0..<3).map { PhotosPickerItem(itemIdentifier: "batch-\($0)") }
        model.select(photos)
        var preference = watermarkSettings()
        preference.watermark.text = "Batch original"
        let expected = try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: startingPro))
        let idleBefore = UIApplication.shared.isIdleTimerDisabled
        model.generate(settings: preference)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await authorization.isWaiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await authorization.isWaiting
        XCTAssertTrue(waiting, "The real model must reach the authorization boundary")
        XCTAssertEqual(model.state.phase, .generating)
        XCTAssertEqual(model.state.progress.completed, 0)
        access.replace(with: startingPro ? .free : .lifetime)
        preference.watermark.text = "Later preference"
        // Duplicate clicks / a replacement selection cannot replace the batch
        // while its permission request is outstanding.
        model.generate(settings: preference)
        model.select([PhotosPickerItem(itemIdentifier: "replacement")])
        await authorization.finish(.authorized)
        let finishDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.state.generating, ContinuousClock.now < finishDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state.phase, .complete)
        XCTAssertEqual(model.state.photos, photos)
        XCTAssertEqual(model.state.progress, PhotoEffectsBatchProgress(total: 3, completed: 3, saved: 3))
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, idleBefore)
        let changed = try renderedJPEG(source: source, settings: effectivePhotoEffectsSettings(preference, isPro: !startingPro))
        XCTAssertNotEqual(expected, changed)
        for photo in photos {
            let output = directory.appendingPathComponent("\(try XCTUnwrap(photo.itemIdentifier)).jpg")
            XCTAssertEqual(try Data(contentsOf: output), expected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replacement.jpg").path))
        attachJPEG(expected, name: startingPro ? "local-batch-paid-after-refund" : "local-batch-free-after-upgrade")
        model.select(photos) // Cancel the terminal-result timer after verification.
    }

    private func watermarkSettings() -> PhotoEffectsSettings {
        var value = PhotoEffectsSettings()
        value.photoFrameEnabled = true
        value.photoFrameBorderEnabled = false
        value.watermark.color = .white
        value.watermark.sizePercent = 120
        value.watermark.opacityPercent = 100
        return value
    }

    private func samplePNG(color: UIColor = .darkGray, unique: Bool = false) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 384), format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
            if unique {
                (UUID().uuidString as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.white
                ])
            }
        }
        return try XCTUnwrap(image.pngData())
    }

    private func renderedJPEG(source: URL, settings: PhotoEffectsSettings) throws -> Data {
        let input = try XCTUnwrap(UIImage(contentsOfFile: source.path))
        let image = try PhotoEffectsRenderer.render(input, settings: settings)
        return try XCTUnwrap(PhotoEffectsJPEGEncoder.encode(image, copyingMetadataFrom: source))
    }

    private func attachJPEG(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.jpeg")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMonitoringWaitsForReadyAndExhaustsExactlyOnce() throws {
        let (_, usage, _) = try fixture()
        usage.consumeMonitoring(179, isPro: false)
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.free))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        var ended = 0
        meter.onExhausted = { ended += 1 }
        meter.tick(uptime: 1_000)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 179)
        meter.markReady()
        let base = ProcessInfo.processInfo.systemUptime
        meter.tick(uptime: base + 1.1)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 180)
        XCTAssertEqual(ended, 1)
        meter.tick(uptime: base + 10)
        meter.stop()
        XCTAssertEqual(ended, 1)
    }

    func testMonitoringExpiresAtVerifiedDeadlineWithoutAnotherStoreKitPublication() async throws {
        let (_, usage, _) = try fixture()
        usage.consumeMonitoring(179, isPro: false)
        let until = Date().addingTimeInterval(0.25)
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.annual(until: until, gracePeriod: false)))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        defer { meter.stop() }
        var losses = 0
        var exhausted = 0
        meter.onLostPremium = { losses += 1 }
        meter.onExhausted = { exhausted += 1 }
        meter.markReady()
        XCTAssertTrue(meter.isPro)
        // No publication or manual tick: a delayed StoreKit refresh must not
        // keep monitoring/recording in Pro after its already-known deadline.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while exhausted == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(losses, 1, "Expiry must notify the recording safety callback")
        XCTAssertFalse(meter.isPro)
        XCTAssertEqual(exhausted, 1, "The remaining free second must start counting after expiry")
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 180)
        XCTAssertEqual(entitlements.entitlement, .annual(until: until, gracePeriod: false),
                       "This scenario intentionally receives no new StoreKit publication")
    }

    func testMonitoringRenewalAndLifetimeReplaceTheOldDeadline() async throws {
        let (_, usage, _) = try fixture()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(
            .annual(until: Date().addingTimeInterval(0.15), gracePeriod: false)))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        defer { meter.stop() }
        var losses = 0
        meter.onLostPremium = { losses += 1 }
        meter.markReady()
        entitlements.publish(.annual(until: Date().addingTimeInterval(0.8), gracePeriod: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(meter.isPro, "The previous expiry cannot revoke a verified extension")
        XCTAssertEqual(losses, 0)
        entitlements.publish(.lifetime)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(meter.isPro, "Lifetime must not inherit the former annual/grace deadline")
        XCTAssertEqual(losses, 0)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 0)
    }

    func testMonitoringInactiveExpiryNotifiesWithoutConsumingTrial() async throws {
        let (_, usage, _) = try fixture()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(
            .annual(until: Date().addingTimeInterval(0.15), gracePeriod: true)))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        defer { meter.stop() }
        var losses = 0
        meter.onLostPremium = { losses += 1 }
        meter.markReady()
        meter.setActive(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while losses == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(losses, 1)
        XCTAssertFalse(meter.isPro)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 0, "Inactive time never consumes trial time")
    }

    func testMonitoringStopCancelsTheDeadlineCallback() async throws {
        let (_, usage, _) = try fixture()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(
            .annual(until: Date().addingTimeInterval(0.15), gracePeriod: false)))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        var losses = 0
        meter.onLostPremium = { losses += 1 }
        meter.markReady()
        meter.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(losses, 0, "An exited monitor must not retain a deadline task")
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 0)
    }

    func testMonitoringRefundDoesNotBackchargePaidTimeAndBackgroundDoesNotConsume() throws {
        let (_, usage, _) = try fixture()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.lifetime))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage)
        var lost = 0
        meter.onLostPremium = { lost += 1 }
        meter.markReady()
        let base = ProcessInfo.processInfo.systemUptime
        meter.tick(uptime: base + 100)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 0)
        entitlements.publish(.free)
        let refund = ProcessInfo.processInfo.systemUptime
        meter.tick(uptime: refund + 1)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, 1, accuracy: 0.05)
        XCTAssertEqual(lost, 1)
        meter.setActive(false)
        let consumed = usage.snapshot().monitoringSeconds
        meter.tick(uptime: refund + 100)
        XCTAssertEqual(usage.snapshot().monitoringSeconds, consumed)
        meter.stop()
    }

    func testMonitoringSplitsMidnightAndUsesUptimeInsteadOfWallClockJump() throws {
        let (defaults, _, _) = try fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let usage = FreeUsageStore(defaults: defaults, calendar: calendar)
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.free))
        let meter = RemoteUsageMeter(entitlements: entitlements, usage: usage, calendar: calendar)
        meter.markReady()
        let base = ProcessInfo.processInfo.systemUptime
        let midnight = calendar.startOfDay(for: Date()).addingTimeInterval(86_400)
        meter.tick(now: midnight.addingTimeInterval(-0.5), uptime: base)
        meter.tick(now: midnight.addingTimeInterval(0.5), uptime: base + 1)
        XCTAssertEqual(usage.snapshot(at: midnight.addingTimeInterval(0.5)).monitoringSeconds, 0.5, accuracy: 0.02)
        meter.tick(now: midnight.addingTimeInterval(3_600.5), uptime: base + 2)
        XCTAssertEqual(usage.snapshot(at: midnight.addingTimeInterval(3_600.5)).monitoringSeconds, 1.5, accuracy: 0.02)
        meter.stop()
    }
}

private actor PremiumTestCamera: TransferDownloading {
    var requests: [UInt32] = []
    nonisolated var allowsBackgroundTransferContinuation: Bool { false }
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        requests.append(file.id)
        let url = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 1, count: 10).write(to: url)
        return url
    }
}

private actor PremiumPhotoAuthorizationGate {
    private var continuation: CheckedContinuation<PHAuthorizationStatus, Never>?
    var isWaiting: Bool { continuation != nil }
    func request() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ status: PHAuthorizationStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private actor PremiumRenderingCamera: TransferDownloading {
    let bytes: Data
    let access: PremiumAccess
    nonisolated var allowsBackgroundTransferContinuation: Bool { false }
    init(bytes: Data, access: PremiumAccess) {
        self.bytes = bytes
        self.access = access
    }
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let output = directory.appendingPathComponent(file.fileName)
        try bytes.write(to: output, options: .atomic)
        // The queue has passed its start gate, but has not scheduled the
        // derivative yet. This models a refund notification during transfer.
        access.replace(with: .free)
        return output
    }
}

private actor QueuePlaceQueryCounter {
    private(set) var calls = 0
    func query() -> PhotoFramePlace? {
        calls += 1
        return PhotoFramePlace(city: "Hangzhou", region: "Xihu")
    }
}
