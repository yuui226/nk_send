import XCTest
import UIKit
import PhotosUI
import Photos
import SwiftUI
@testable import ZTransfer

@MainActor
final class PremiumBusinessTests: XCTestCase {
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

    func testQuotaCountsOnlyRealSuccessAndDoesNotBlockLocalShortcuts() async throws {
        let (defaults, usage, directory) = try fixture()
        for _ in 0..<24 { usage.recordTransfer(id: UUID(), isPro: false) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueLegacy.\(UUID())")!, premiumAccess: PremiumAccess(.free), freeUsage: usage)
        let camera = PremiumTestCamera()
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        let partial = directory.appendingPathComponent(transferPartialFileName(size: 10, captureDate: nil, fileName: file(2).fileName))
        try Data(repeating: 1, count: 10).write(to: partial)
        await queue.enqueue([file(1), file(2), file(3), file(4)])
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
        XCTAssertEqual(failed.items[0].status, .failed)
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
