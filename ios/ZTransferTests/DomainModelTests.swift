import XCTest
import Combine
import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import Darwin
import CoreLocation
@testable import ZTransfer

func previewTestPhysicalFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    XCTAssertEqual(result, KERN_SUCCESS)
    return info.phys_footprint
}

final class DomainModelTests: XCTestCase {
    func testLargeCameraPreviewSequentialDecodeWithFiveRetainedPages() async throws {
        @Sendable func footprint() throws -> UInt64 { try previewTestPhysicalFootprint() }
        let data: Data = try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 4000,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            for x in stride(from: 0, to: 6000, by: 100) {
                context.setFillColor(UIColor(hue: CGFloat(x) / 6000, saturation: 0.8, brightness: 0.7, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: 0, width: 100, height: 4000))
            }
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }
        let baseline = try footprint()
        let sampler = Task.detached(priority: .utility) { () throws -> (peak: UInt64, samples: Int) in
            var peak = baseline
            var samples = 0
            while !Task.isCancelled {
                peak = max(peak, try footprint())
                samples += 1
                do { try await Task.sleep(nanoseconds: 2_000_000) }
                catch { break }
            }
            return (peak, samples)
        }
        defer { sampler.cancel() }
        let mainThreadProbe = Task { @MainActor () -> (ticks: Int, maximumGap: TimeInterval) in
            var ticks = 0
            var previous = ProcessInfo.processInfo.systemUptime
            var maximumGap: TimeInterval = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000) }
                catch { break }
                XCTAssertTrue(Thread.isMainThread)
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous)
                previous = now
                ticks += 1
            }
            return (ticks, maximumGap)
        }
        defer { mainThreadProbe.cancel() }
        var peak = baseline
        var retained: [CameraPhotoPreviewContent] = []
        var maximumDuration: TimeInterval = 0
        for _ in 0..<24 {
            let start = ProcessInfo.processInfo.systemUptime
            let loaded = try await loadCameraPhotoPreviewContent(data)
            let content = try XCTUnwrap(loaded)
            maximumDuration = max(maximumDuration, ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(content.image.cgImage?.width, 1920)
            XCTAssertEqual(content.image.cgImage?.height, 1280)
            XCTAssertNotNil(content.histogram)
            retained.append(content)
            if retained.count > 5 { retained.removeFirst() }
            peak = max(peak, try footprint())
            let retainedBytes = retained.reduce(0) { $0 + ($1.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
            XCTAssertLessThanOrEqual(retainedBytes, 5 * 1920 * 1280 * 4)
        }
        mainThreadProbe.cancel()
        let responsiveness = await mainThreadProbe.value
        XCTAssertGreaterThan(responsiveness.ticks, 24)
        sampler.cancel()
        let inFlight = try await sampler.value
        peak = max(peak, inFlight.peak)
        XCTAssertGreaterThan(inFlight.samples, 24)
        // Polling can miss spikes shorter than its interval; report observed peak,
        // not an absolute allocation bound or a device performance contract.
        print("F046 24x24MP decode: baseline=\(baseline), sampledPeak=\(peak), delta=\(peak - baseline), maxSeconds=\(maximumDuration), inFlightSamples=\(inFlight.samples), requestedIntervalMs=2")
        print("F046 main-thread probe: ticks=\(responsiveness.ticks), maximumGapSeconds=\(responsiveness.maximumGap), requestedIntervalMs=5")
    }

    @MainActor
    func testFrameFavoriteCapturesUpdatesAndAppliesOnlyPresentationParameters() throws {
        for scope: PhotoEffectsStore.Scope in [.cameraTransfer, .localPhotos] {
            let suite = "favorite-apply-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var metadata = PhotoFrameMetadataSettings.defaults(for: .mist)
            metadata.widthPercent = 60
            metadata.backgroundBlurPercent = 0
            metadata.backgroundMaskPercent = 200
            var watermark = PhotoFrameWatermark()
            watermark.text = "Historical text"
            var favorite = PhotoFrameFavorite(preset: .mist, watermark: watermark, metadata: metadata)
            XCTAssertEqual(favorite.frameWidthPercent, 60)
            XCTAssertEqual(favorite.backgroundBlurPercent, 0)
            XCTAssertEqual(favorite.backgroundMaskPercent, 200)
            metadata.widthPercent = 200
            metadata.backgroundBlurPercent = 180
            metadata.backgroundMaskPercent = 0
            favorite.updateFrameMetadata(metadata)
            let store = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: PremiumAccess(.lifetime))
            var settings = store.settings
            settings.favoriteFrameEffects = [favorite]
            store.updateFromEditor(settings)
            let restored = try XCTUnwrap(PhotoEffectsStore(defaults: defaults, scope: scope,
                premiumAccess: PremiumAccess(.lifetime)).settings.favoriteFrameEffects.first)
            var currentMetadata = PhotoFrameMetadataSettings.defaults(for: .mist)
            currentMetadata.showDate = false
            currentMetadata.datePattern = "MM-dd-yyyy"
            let applied = restored.applying(to: currentMetadata)
            XCTAssertEqual(applied.widthPercent, 200)
            XCTAssertEqual(applied.backgroundBlurPercent, 180)
            XCTAssertEqual(applied.backgroundMaskPercent, 0)
            XCTAssertFalse(applied.showDate)
            XCTAssertEqual(applied.datePattern, "MM-dd-yyyy")
            watermark.text = "Current text"
            watermark.imageHash = String(repeating: "b", count: 64)
            let appliedWatermark = try XCTUnwrap(restored.applying(to: watermark))
            XCTAssertEqual(appliedWatermark.text, "Current text")
            XCTAssertEqual(appliedWatermark.imageHash, watermark.imageHash)
        }
    }

    @MainActor
    func testFrameFavoriteLegacyWidthAndBackdropFormatsRoundTrip() throws {
        let base = "MIST,true,TEXT,CALLIGRAPHY,100,AUTO,ADAPTIVE,100,AUTO"
        for (suffix, width, blur, mask) in [("", 100, 100, 100), (",60", 60, 100, 100),
                                          (",200,0,200", 200, 0, 200), (",140,0,180", 140, 0, 180)] {
            let suite = "frame-favorite-codec-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: "photo_frame_enabled")
            defaults.set(base + suffix, forKey: "favorite_frame_effects_v1")
            let store = PhotoEffectsStore(defaults: defaults)
            let favorite = try XCTUnwrap(store.settings.favoriteFrameEffects.first)
            XCTAssertEqual(favorite.frameWidthPercent, width)
            XCTAssertEqual(favorite.backgroundBlurPercent, blur)
            XCTAssertEqual(favorite.backgroundMaskPercent, mask)
            let expected = base + ",\(width)" + (blur == 100 && mask == 100 ? "" : ",\(blur),\(mask)")
            XCTAssertEqual(defaults.string(forKey: "favorite_frame_effects_v1"), expected)
            XCTAssertEqual(PhotoEffectsStore(defaults: defaults).settings.favoriteFrameEffects, [favorite])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(favorite)) as? [String: Any])
            for key in ["frameWidthPercent", "backgroundBlurPercent", "backgroundMaskPercent"] { json.removeValue(forKey: key) }
            let legacy = try JSONDecoder().decode(PhotoFrameFavorite.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(legacy.frameWidthPercent, 100)
            XCTAssertEqual(legacy.backgroundBlurPercent, 100)
            XCTAssertEqual(legacy.backgroundMaskPercent, 100)
        }
    }

    func testModuleToggleMatchesAndroidForEveryNonemptyMask() {
        for mask in 1...allPhotoEffectModules {
            for module in PhotoEffectModule.allCases {
                let pro = togglePhotoEffectModule(mask, module: module, isPro: true)
                XCTAssertEqual(pro, mask == module.rawValue ? mask : mask ^ module.rawValue)
                XCTAssertTrue((1...15).contains(pro))
                let free = togglePhotoEffectModule(mask, module: module, isPro: false)
                XCTAssertTrue((1...15).contains(free))
                XCTAssertEqual(photoEffectModuleIsVisible(free, .frame), photoEffectModuleIsVisible(free, .watermark))
                let current = effectivePhotoEffectModules(mask, isPro: false)
                if current == 12 && (module == .frame || module == .watermark) {
                    XCTAssertEqual(free, current)
                }
            }
        }
        XCTAssertEqual(togglePhotoEffectModule(13, module: .watermark, isPro: false), 1)
        XCTAssertEqual(togglePhotoEffectModule(1, module: .frame, isPro: false), 13)
        XCTAssertEqual(togglePhotoEffectModule(1, module: .filter, isPro: false), 1)
        XCTAssertEqual(togglePhotoEffectModule(0, module: .filter, isPro: true), 14)
    }

    func testQueueFlightHoldsOnlyDownloadsAndNeverDelayRealCompletion() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "A.JPG", captureDate: nil, isProtected: false)
        var items = (0..<12).map { _ in TransferQueueItem(id: UUID(), file: file) }
        XCTAssertEqual(QueuePillTaskSummary(items: items).displayRemaining(heldCount: 2), 10)
        items[0].status = .completed
        let concurrent = QueuePillTaskSummary(items: items)
        XCTAssertEqual(concurrent.displayRemaining(heldCount: 2), 9)
        XCTAssertEqual(concurrent.displayRemaining(heldCount: 1), 10)
        XCTAssertEqual(concurrent.displayRemaining(heldCount: 99), 0)
        XCTAssertFalse(concurrent.allDone)
        for index in items.indices { items[index].status = .completed }
        items[0].isGeneratingFrame = true
        let generation = QueuePillTaskSummary(items: items)
        XCTAssertEqual(generation.displayRemaining(heldCount: 2), 1)
        XCTAssertFalse(generation.allDone)
        items[0].isGeneratingFrame = false
        XCTAssertTrue(QueuePillTaskSummary(items: items).allDone)
        XCTAssertEqual(QueuePillTaskSummary(items: items).displayRemaining(heldCount: 2), 0)
    }

    func testPhotoHistogramPreferencesRestoreWithoutChangingMonitorScope() throws {
        let suite = "photo-histogram-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: "preview_histogram_enabled")
        store.set("RGB", forKey: "remote_histogram_mode")
        let preferences = PhotoPreviewHistogramPreferences(store: store)
        XCTAssertEqual(preferences.mode, .luma)
        preferences.mode = preferences.mode.next
        XCTAssertEqual(store.string(forKey: "preview_histogram_mode"), "OFF")
        XCTAssertTrue(store.bool(forKey: "preview_histogram_enabled"))
        for expected in [RemoteHistogramMode.rgb, .luma, .off] {
            preferences.mode = preferences.mode.next
            let reopened = PhotoPreviewHistogramPreferences(store: store)
            XCTAssertEqual(reopened.mode, expected)
            XCTAssertEqual(store.string(forKey: "remote_histogram_mode"), "RGB")
        }
    }

    @MainActor
    func testCachedHistogramReplacesPendingThumbnailWithoutReanalysis() async {
        let gate = PreviewHistogramTestGate()
        let model = PhotoPreviewHistogramModel { _ in PhotoPreviewHistogram(luma: await gate.calculate()) }
        model.load(fileID: 7, image: UIImage())
        while await gate.count < 1 { await Task.yield() }
        let cached = PhotoPreviewHistogram(luma: [0.9], rgb: [[0.2], [0.4], [0.6]])
        model.show(fileID: 7, cached: cached)
        await gate.finish(0, bars: [0.1])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.bars, [0.9])
        XCTAssertEqual(model.result.rgb, cached.rgb)
        model.clear()
        model.show(fileID: 7, cached: cached)
        XCTAssertEqual(model.fileID, 7)
        XCTAssertEqual(model.result.rgb, cached.rgb)
        let calls = await gate.count
        XCTAssertEqual(calls, 1, "Cached presentation must not analyse or decode again")
    }

    func testJPEGHistogramAnalysisIsBoundedAndScansTinyHighlights() async throws {
        for edge in [256, 512, 513, 1920, 4096] {
            let context = try XCTUnwrap(CGContext(data: nil, width: edge, height: edge,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
            let image = UIImage(cgImage: try XCTUnwrap(context.makeImage()))
            let data = try XCTUnwrap(image.jpegData(compressionQuality: 1))
            let analysis = try XCTUnwrap(decodePhotoPreviewAnalysisImage(data))
            let expected = [256: 256, 512: 512, 513: 257, 1920: 480, 4096: 512][edge]!
            let cg = try XCTUnwrap(analysis.cgImage)
            if edge == 513 {
                // ImageIO may round an odd JPEG's sampled dimension down.
                // The ceil division is a decode budget, not an output promise.
                XCTAssertTrue((256...expected).contains(cg.width))
                XCTAssertEqual(cg.width, cg.height)
            } else {
                XCTAssertEqual(cg.width, expected)
                XCTAssertEqual(cg.height, expected)
            }
            let content = try await loadCameraPhotoPreviewContent(data)
            let histogram = try XCTUnwrap(content?.histogram)
            XCTAssertEqual(histogram.rgb.count, 3)
            XCTAssertEqual(histogram.luma.count, 256)
            if edge <= 512 {
                XCTAssertGreaterThan(histogram.luma[200...255].reduce(0, +), 0,
                                     "Exhaustive analysis must retain an isolated bright pixel")
            }
        }
        XCTAssertNil(decodePhotoPreviewAnalysisImage(Data()))
    }

    func testPhotoHistogramModeMigrationAndCycle() {
        XCTAssertEqual(RemoteHistogramMode.off.next, .rgb)
        XCTAssertEqual(RemoteHistogramMode.rgb.next, .luma)
        XCTAssertEqual(RemoteHistogramMode.luma.next, .off)
        for old in [false, true] {
            for raw in [nil, "", "invalid", "rgb"] as [String?] {
                XCTAssertEqual(RemoteHistogramMode.restore(saved: raw, previouslyEnabled: old), old ? .luma : .off)
            }
            for mode in RemoteHistogramMode.allCases {
                XCTAssertEqual(RemoteHistogramMode.restore(saved: mode.rawValue, previouslyEnabled: old), mode)
            }
        }
    }

    func testPhotoHistogramRGBUsesSharedPeak() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (x, color) in [UIColor.red, .red, .green, .blue].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        let image = UIImage(cgImage: try XCTUnwrap(context.makeImage()))
        let result = calculatePhotoPreviewHistogram(image)
        XCTAssertEqual(result.rgb.count, 3)
        XCTAssertEqual(result.rgb[0][255], 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.rgb[1][255], 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.rgb[2][255], 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.luma[53], 1)
        XCTAssertEqual(result.luma[182], 0.5)
        XCTAssertEqual(result.luma[18], 0.5)
    }

    func testPhotoHistogramExcludesVideoCoversAndCollections() {
        for video in [".mov", ".MOV", ".mp4", ".MP4"] {
            XCTAssertFalse(photoPreviewHistogramCanAnalyze(enabled: true, fileExtension: video))
        }
        XCTAssertFalse(photoPreviewHistogramCanAnalyze(enabled: true, fileExtension: nil))
        for photo in [".jpg", ".JPEG", ".nef", ".NEF"] {
            XCTAssertTrue(photoPreviewHistogramCanAnalyze(enabled: true, fileExtension: photo))
            XCTAssertFalse(photoPreviewHistogramCanAnalyze(enabled: false, fileExtension: photo))
        }
    }

    @MainActor
    func testHistogramReplacementAndExitDiscardLateResults() async throws {
        let gate = PreviewHistogramTestGate()
        let model = PhotoPreviewHistogramModel { _ in PhotoPreviewHistogram(luma: await gate.calculate()) }
        let image = UIImage()
        model.load(fileID: 1, image: image)
        while await gate.count < 1 { await Task.yield() }
        // Same handle, new image: file identity alone cannot reject the old result.
        // Use a distinct bitmap object; repeated delivery of the same source is shared.
        model.load(fileID: 1, image: UIImage())
        while await gate.count < 2 { await Task.yield() }
        await gate.finish(1, bars: [0.8])
        for _ in 0..<1000 where model.fileID == nil { await Task.yield() }
        XCTAssertEqual(model.bars, [0.8])
        await gate.finish(0, bars: [0.2])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.bars, [0.8])
        model.load(fileID: 2, image: image)
        while await gate.count < 3 { await Task.yield() }
        model.clear()
        await gate.finish(2, bars: [1])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.fileID)
        XCTAssertTrue(model.bars.isEmpty)
    }

    @MainActor
    func testBackgroundCameraPreviewReturnsBoundedPixelsAndRejectsCancellation() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2560, height: 1440,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let source = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(UIImage(cgImage: source).jpegData(compressionQuality: 0.8))
        let decoded = try await loadCameraPhotoPreview(data)
        XCTAssertEqual(decoded?.cgImage?.width, 1920)
        XCTAssertEqual(decoded?.cgImage?.height, 1080)
        let invalid = try await loadCameraPhotoPreview(Data())
        XCTAssertNil(invalid)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loadCameraPhotoPreview(data)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled decode must not publish a result")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testCameraPreviewBoundsLargeJPEGWithoutUpscalingOrHonoringOrientation() throws {
        let dimensions = [(640, 480, 640, 480), (1920, 1080, 1920, 1080),
                          (2560, 1440, 1920, 1080), (4096, 3072, 1920, 1440),
                          (3072, 4096, 1440, 1920)]
        for (width, height, expectedWidth, expectedHeight) in dimensions {
            try autoreleasepool {
                let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.setFillColor(UIColor.red.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let sourceImage = try XCTUnwrap(context.makeImage())
                let data = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, sourceImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let image = try XCTUnwrap(decodeCameraPhotoPreview(data as Data))
                XCTAssertEqual(image.cgImage?.width, expectedWidth)
                XCTAssertEqual(image.cgImage?.height, expectedHeight)
                XCTAssertEqual(image.imageOrientation, .up)
                XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1920)
            }
        }
    }

    func testCameraPreviewIgnoresJPEGExifOrientationAndKeepsManualRotationPixels() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
            UIColor.green.setFill(); context.fill(CGRect(x: 24, y: 0, width: 24, height: 16))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 16, width: 24, height: 16))
            UIColor.yellow.setFill(); context.fill(CGRect(x: 24, y: 16, width: 24, height: 16))
        }
        func rendered(_ image: UIImage, quarterTurns: Int) -> Data? {
            let size = quarterTurns.isMultiple(of: 2) ? CGSize(width: 48, height: 32) : CGSize(width: 32, height: 48)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
                context.cgContext.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
                image.draw(in: CGRect(x: -24, y: -16, width: 48, height: 32))
            }.pngData()
        }
        var reference: [Data] = []
        for orientation in 1...8 {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(raw.cgImage), [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, orientation)
            let content = try await loadCameraPhotoPreviewContent(data as Data)
            XCTAssertEqual(content?.orientation, orientation)
            XCTAssertEqual(content?.image.imageOrientation, .up)
            let preview = try XCTUnwrap(decodeCameraPhotoPreview(data as Data))
            XCTAssertEqual(preview.imageOrientation, .up)
            XCTAssertEqual(preview.size, CGSize(width: 48, height: 32))
            for turn in 0..<4 {
                let pixels = try XCTUnwrap(rendered(preview, quarterTurns: turn))
                if orientation == 1 { reference.append(pixels) }
                else { XCTAssertEqual(pixels, reference[turn], "EXIF \(orientation), turn \(turn)") }
            }
            let ordinaryUIKit = try XCTUnwrap(UIImage(data: data as Data))
            XCTAssertEqual(ordinaryUIKit.imageOrientation == .up, orientation == 1,
                           "Effect-preview decoding must retain its independent EXIF behavior")
        }
        XCTAssertNil(decodeCameraPhotoPreview(Data()))
    }

    func testPhotoFilterDateEditorKeepsGregorianComponentsAcrossSystemCalendars() throws {
        for identifier: Calendar.Identifier in [.gregorian, .buddhist, .chinese, .islamicCivil] {
            for zone in ["Asia/Shanghai", "America/Los_Angeles"] {
                var system = Calendar(identifier: identifier)
                system.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                let dates = PhotoFilterDates(systemCalendar: system)
                XCTAssertEqual(dates.calendar.identifier, .gregorian)
                XCTAssertEqual(dates.calendar.timeZone, system.timeZone)
                let leap = try XCTUnwrap(dates.date(from: "20240229"))
                XCTAssertEqual(dates.calendar.component(.year, from: leap), 2024)
                XCTAssertEqual(dates.calendar.component(.month, from: leap), 2)
                XCTAssertEqual(dates.calendar.component(.day, from: leap), 29)
                XCTAssertEqual(dates.calendar.range(of: .day, in: .month, for: leap)?.count, 29)
                XCTAssertEqual(dates.shortDate(leap), "24/02/29")
                XCTAssertEqual(dates.key(leap), "20240229")
                XCTAssertEqual(dates.key(dates.clamped(year: 2023, month: 2, day: 29)), "20230228")
                XCTAssertEqual(dates.key(dates.clamped(year: 2024, month: 4, day: 31)), "20240430")
                let later = dates.clamped(year: 2024, month: 3, day: 31)
                XCTAssertEqual(dates.range(start: later, end: leap), PhotoDateRange(start: "20240229", end: "20240331"))
                let now = try XCTUnwrap(dates.date(from: "20261016"))
                XCTAssertEqual(dates.years(start: leap, end: later, now: now), Array(1990...2027))
                let old = try XCTUnwrap(dates.date(from: "19801231"))
                let future = try XCTUnwrap(dates.date(from: "20300101"))
                XCTAssertEqual(dates.years(start: old, end: future, now: now), Array(1980...2030))
            }
        }
    }

    func testWorkspaceDiscoveryRemainsPausedUntilReturnSettles() {
        var state = WorkspaceDiscoveryState()
        XCTAssertFalse(state.shouldPause)
        state.request(1)
        XCTAssertTrue(state.shouldPause)
        state.begin(1)
        state.settle(1)
        state.request(0)
        XCTAssertTrue(state.shouldPause)
        state.begin(0)
        XCTAssertTrue(state.shouldPause)
        state.settle(0)
        XCTAssertFalse(state.shouldPause)
    }

    func testWorkspaceDiscoveryHandlesCancelledGesturesAndQueuedReversal() {
        var state = WorkspaceDiscoveryState()
        state.request(1)
        state.request(0) // request withdrawn before the native transition begins
        XCTAssertFalse(state.shouldPause)
        state.begin(1)
        XCTAssertTrue(state.shouldPause)
        state.settle(0) // cancelled entry
        XCTAssertFalse(state.shouldPause)
        state.request(1)
        state.begin(1)
        state.request(0) // reverse request before entry has finished
        XCTAssertTrue(state.shouldPause)
        state.settle(1)
        XCTAssertTrue(state.shouldPause)
        state.begin(0)
        state.request(1) // cancelled return or queued reentry
        state.settle(0)
        XCTAssertTrue(state.shouldPause)
        state.begin(1)
        state.settle(1)
        state.request(0)
        state.begin(0)
        state.request(1)
        state.settle(1) // cancelled return remains on workbench
        XCTAssertTrue(state.shouldPause)
    }

    func testQueueItemPlacementUsesPhysicalPixelSpringAndPreservesPositionOnInterruption() {
        var motion = QueueItemPlacementMotion()
        motion.place(at: CGPoint(x: 12, y: 100), scale: 3)
        XCTAssertEqual(motion.offset, .zero)
        XCTAssertFalse(motion.isRunning)
        motion.place(at: CGPoint(x: 12, y: 200), scale: 3)
        XCTAssertEqual(motion.offset, CGSize(width: 0, height: -100))
        motion.advance(0)
        motion.advance(100_000_000)
        let omega = sqrt(500.0)
        let expectedPixels = floor(-300 * (1 + omega * 0.1) * exp(-omega * 0.1) + 0.5)
        XCTAssertEqual(motion.offset.height, expectedPixels / 3)
        // Unchanged content coordinates (including ordinary scrolling) must
        // not restart a placement spring.
        var uninterrupted = motion
        motion.place(at: CGPoint(x: 12, y: 200), scale: 3)
        motion.advance(150_000_000)
        uninterrupted.advance(150_000_000)
        XCTAssertEqual(motion.offset, uninterrupted.offset)
        let displayedY = 200 + motion.offset.height
        motion.place(at: CGPoint(x: 32, y: 150), scale: 3)
        XCTAssertEqual(150 + motion.offset.height, displayedY, accuracy: 0.00001)
        XCTAssertEqual(32 + motion.offset.width, 12)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.offset, .zero)
        XCTAssertFalse(motion.isRunning)
        motion.reset()
        motion.place(at: CGPoint(x: 12, y: 900), scale: 3)
        XCTAssertEqual(motion.offset, .zero)
        XCTAssertFalse(motion.isRunning)
    }

    func testQueueItemPlacementSamplesShortAxisUntilVectorFinishes() {
        var motion = QueueItemPlacementMotion()
        motion.place(at: .zero, scale: 1)
        motion.place(at: CGPoint(x: 10, y: 300), scale: 1)
        motion.advance(0)
        motion.advance(200_000_000)
        // x alone has already crossed the 1px finish threshold. IntOffset's
        // vector duration is set by y, so x still samples -0.625... -> -1px.
        XCTAssertTrue(motion.isRunning)
        XCTAssertEqual(motion.offset.width, -1)
        let omega = sqrt(500.0)
        let velocity = 10 * 500 * 0.2 * exp(-omega * 0.2)
        motion.place(at: CGPoint(x: 20, y: 300), scale: 1)
        XCTAssertEqual(motion.offset.width, -11)
        motion.advance(250_000_000)
        let displacement = -11.0
        let expected = floor((displacement + (velocity + omega * displacement) * 0.05)
                             * exp(-omega * 0.05) + 0.5)
        XCTAssertEqual(motion.offset.width, expected)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.offset, .zero)
        XCTAssertFalse(motion.isRunning)
    }

    func testQueueCardContentSizeUses250msAndRoundedInterruption() {
        var motion = QueueCardContentSizeMotion()
        motion.measure(CGSize(width: 100, height: 92), scale: 3)
        XCTAssertEqual(motion.size, CGSize(width: 100, height: 92))
        XCTAssertFalse(motion.isRunning)
        motion.measure(CGSize(width: 120, height: 150), scale: 3)
        motion.advance(0)
        motion.advance(125_000_000)
        // FastOutSlowIn(.5)=.7755613, rounded independently in physical pixels.
        XCTAssertEqual(motion.size, CGSize(width: 347.0 / 3, height: 137))
        let before = motion.size
        motion.measure(CGSize(width: 100, height: 100), scale: 3)
        XCTAssertEqual(motion.size, before)
        motion.advance(250_000_000)
        XCTAssertEqual(motion.size, CGSize(width: 311.0 / 3, height: 325.0 / 3))
        motion.advance(375_000_000)
        XCTAssertEqual(motion.size, CGSize(width: 100, height: 100))
        XCTAssertFalse(motion.isRunning)
    }

    func testQueueCardContentSizeRetainedNodeRestartsAfterDetachment() {
        var motion = QueueCardContentSizeMotion()
        motion.measure(CGSize(width: 100, height: 92), scale: 3)
        motion.measure(CGSize(width: 120, height: 150), scale: 3)
        motion.advance(0)
        motion.advance(125_000_000)
        let displayed = motion.size
        motion.suspend()
        XCTAssertEqual(motion.size, displayed)
        XCTAssertFalse(motion.isRunning)
        motion.advance(10_000_000_000)
        XCTAssertEqual(motion.size, displayed)
        // Same natural target must restart, despite no new preference value.
        motion.measure(CGSize(width: 120, height: 150), scale: 3)
        XCTAssertTrue(motion.isRunning)
        motion.advance(20_000_000_000)
        XCTAssertEqual(motion.size, displayed)
        motion.advance(20_125_000_000)
        XCTAssertEqual(motion.size, CGSize(width: 119, height: 147))
        motion.advance(20_250_000_000)
        XCTAssertEqual(motion.size, CGSize(width: 120, height: 150))
        XCTAssertFalse(motion.isRunning)
        motion.suspend()
        motion.measure(CGSize(width: 120, height: 150), scale: 3)
        XCTAssertFalse(motion.isRunning)
    }

    func testLiquidPathUsesFloatPixelControlPoints() {
        // Independent C reference: 370.2 x 113.1 px, 43%, phase .19,
        // seed .63, amplitude 6px, eight segments; contraction disabled.
        let expected: [(Float, Float)] = [
            (0,0),(157.064056,0),
            (157.064056,0),(157.878906,7.0687499),
            (158.693756,14.1374998),(159.761948,21.2062492),
            (160.830139,28.2749996),(161.400085,35.34375),
            (161.970016,42.4124985),(162.425018,49.4812469),
            (162.880005,56.5499992),(160.32196,63.6187515),
            (157.763901,70.6875),(156.263474,77.7562485),
            (154.763046,84.8249969),(156.309875,91.8937531),
            (157.856689,98.9625015),(157.951355,106.03125),
            (158.046036,113.099998),(158.046036,113.099998),(0,113.099998)
        ]
        let rect = CGRect(x: 2.25, y: -3.5, width: 123.4, height: 37.7)
        let path = LiquidTransferShape(progress: 0.43, phase: 0.19, seed: 0.63,
            amplitude: 2, segments: 8, spatialScale: 1, pixelScale: 3).path(in: rect)
        var points: [CGPoint] = []
        var closed = false
        path.cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint: points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[0]); points.append(element.points[1])
            case .closeSubpath: closed = true
            default: XCTFail("Unexpected curve type")
            }
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(points.count, expected.count)
        for (point, expected) in zip(points, expected) {
            // SwiftUI Path stores point-space coordinates as Float; converting
            // back to pixels can add a second rounding. Compare at its boundary.
            XCTAssertEqual(point.x, CGFloat(Float(rect.minX + CGFloat(expected.0) / 3)))
            XCTAssertEqual(point.y, CGFloat(Float(rect.minY + CGFloat(expected.1) / 3)))
        }
    }

    func testLiquidHarmonicsFloatReferenceClampsAndCycleContinuity() {
        // Independent C ordered-float reference, contraction disabled.
        let samples: [(Float, Float, Float, Float, UInt32)] = [
            (0, 0, 0, 1, 0x00000000), (0.25, 0.19, 0.63, 1, 0x3e9acf0c),
            (0.75, 0.63, 0.19, 0.55, 0x3ed8c4c0), (1, 1, 1, 0.55, 0xbe9a1f8a),
            (-0.2, 0.4, 0.3, 1, 0xbf0ed4bd), (1.2, 0.4, 0.3, 1, 0xbf4712d6),
            (0.5, 0.4, 0.3, -1, 0xbf0ed4bd)
        ]
        for (y, phase, seed, scale, expected) in samples {
            XCTAssertEqual(liquidProgressWaveUnitOffset(normalizedY: y, phaseTurns: phase,
                seedTurns: seed, spatialScale: scale).bitPattern, expected)
        }
        // Android LiquidProgressWaveTest's full nominal-domain sweep.
        for scale: Float in [0.55, 1] {
            for seed: Float in [0, 0.19, 0.63, 1] {
                for step in 0...40 {
                    let y = Float(step) / 40
                    let start = liquidProgressWaveUnitOffset(normalizedY: y, phaseTurns: 0,
                        seedTurns: seed, spatialScale: scale)
                    let end = liquidProgressWaveUnitOffset(normalizedY: y, phaseTurns: 1,
                        seedTurns: seed, spatialScale: scale)
                    XCTAssertEqual(start, end, accuracy: 0.0001)
                    for phaseStep in 0...20 {
                        let value = liquidProgressWaveUnitOffset(normalizedY: y,
                            phaseTurns: Float(phaseStep) / 20, seedTurns: seed, spatialScale: scale)
                        XCTAssertLessThanOrEqual(abs(value), 1.0001)
                    }
                }
            }
        }
    }

    func testLiquidEnvelopeUsesAndroidFloatRounding() {
        // Independent C float reference, clang -O0 -ffp-contract=off;
        // same ordered arithmetic as LiquidProgressFill.kt smoothStep.
        let samples: [(Double, UInt32)] = [
            (0.05, 0x00000000), (0.06, 0x3d0c7761), (0.08, 0x3e84bd9f),
            (0.10, 0x3f153edb), (0.13, 0x3f773889), (0.14, 0x3f800000),
            (0.90, 0x3f800000), (0.91, 0x3f74fffa), (0.94, 0x3f000000),
            (0.97, 0x3d2fffe0), (0.98, 0x00000000)
        ]
        for (progress, expected) in samples {
            XCTAssertEqual(Float(liquidProgressWaveEnvelope(progress)).bitPattern, expected,
                           "progress=\(progress)")
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(liquidProgressWaveEnvelope(invalid), 0)
        }
    }

    func testQueuePillSummarySeparatesCropGenerationAndProgressOwnership() {
        func item(_ id: UInt32, _ status: TransferStatus, generating: Bool = false) -> TransferQueueItem {
            var item = TransferQueueItem(id: UUID(), file: CameraFile(id: id, storageID: 1, format: 0x3801,
                size: 2048, fileName: "TEST.JPG", captureDate: nil, isProtected: false))
            item.status = status
            item.isGeneratingFrame = generating
            return item
        }
        let waiting = item(1, .waiting)
        let crop = item(2, .transferring, generating: true)
        let download = item(3, .transferring)
        let cancelled = item(4, .cancelled)
        let cropOnly = QueuePillTaskSummary(items: [crop])
        XCTAssertEqual(cropOnly.downloadRemaining, 0)
        XCTAssertEqual(cropOnly.generationRemaining, 1)
        XCTAssertNil(cropOnly.activeDownload)
        XCTAssertEqual(cropOnly.progressOwner?.id, crop.id)
        XCTAssertTrue(cropOnly.hasActive)
        let mixed = QueuePillTaskSummary(items: [waiting, crop, download, cancelled])
        XCTAssertEqual(mixed.downloadRemaining, 2)
        XCTAssertEqual(mixed.generationRemaining, 1)
        XCTAssertEqual(mixed.activeDownload?.id, download.id)
        XCTAssertEqual(mixed.progressOwner?.id, download.id)
        XCTAssertTrue(mixed.hasCancelled)
        var completedGeneration = crop
        completedGeneration.status = .completed
        let generating = QueuePillTaskSummary(items: [waiting, completedGeneration])
        XCTAssertEqual(generating.progressOwner?.id, crop.id)
        XCTAssertEqual(generating.downloadRemaining, 1)
        let waitingOnly = QueuePillTaskSummary(items: [waiting])
        XCTAssertEqual(waitingOnly.progressOwner?.id, waiting.id)
        XCTAssertFalse(waitingOnly.hasActive)
        let terminal = QueuePillTaskSummary(items: [cancelled])
        XCTAssertNil(terminal.progressOwner)
        XCTAssertFalse(terminal.hasActive)
    }

    func testLiquidWavePhaseStartsOnFirstFrameAndRestartsAfterRemount() {
        var phase = LiquidWavePhaseMotion()
        phase.advance(9_000_000_000, cycleMilliseconds: 2200)
        XCTAssertEqual(phase.phase, 0)
        phase.advance(10_100_000_000, cycleMilliseconds: 2200)
        XCTAssertEqual(phase.phase, 0.5)
        phase.advance(11_200_000_000, cycleMilliseconds: 2200)
        XCTAssertEqual(phase.phase, 0)
        phase.advance(11_750_000_000, cycleMilliseconds: 2200)
        XCTAssertEqual(phase.phase, 0.25)
        phase.advance(11_750_000_001, cycleMilliseconds: 2200)
        XCTAssertEqual(phase.phase, CGFloat(Float(550_000_001) / Float(2_200_000_000)))
        phase = .init()
        phase.advance(30_000_000_000, cycleMilliseconds: 2600)
        XCTAssertEqual(phase.phase, 0)
        phase.advance(31_300_000_000, cycleMilliseconds: 2600)
        XCTAssertEqual(phase.phase, 0.5)
    }

    func testLiquidProgressDisabledWaveIsRectangularAndEnvelopeHasQuietEdges() {
        XCTAssertEqual(liquidProgressWaveEnvelope(.nan), 0)
        XCTAssertEqual(liquidProgressWaveEnvelope(0.05), 0)
        XCTAssertEqual(liquidProgressWaveEnvelope(0.14), 1, accuracy: 0.000001)
        XCTAssertEqual(liquidProgressWaveEnvelope(0.98), 0)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 36)
        for phase: CGFloat in [0, 0.25, 0.75] {
            let path = LiquidTransferShape(progress: 0.5, phase: phase, amplitude: 0).path(in: rect)
            XCTAssertEqual(path.boundingRect, CGRect(x: 0, y: 0, width: 100, height: 36))
            XCTAssertTrue(path.contains(CGPoint(x: 99.9, y: 18)))
            XCTAssertFalse(path.contains(CGPoint(x: 100.1, y: 18)))
        }
    }

    func testQueuePillSameModeDataChangeRetargetsWithoutRemounting() {
        var motion = QueuePillContentMotion(.init(mode: .paused, count: 8, speed: nil))
        motion.update(.init(mode: .counting, count: 8, speed: 1_048_576))
        motion.advance(0)
        motion.advance(100_000_000)
        let before = motion.layers.last!.fade.alpha
        motion.update(.init(mode: .counting, count: 7, speed: 2_097_152))
        XCTAssertEqual(motion.layers.map(\.id), [.paused, .counting])
        // Retarget samples the spring at t=0; Float subtraction/addition can round by one ULP.
        XCTAssertEqual(motion.layers.last!.fade.alpha.value, before.value, accuracy: before.value.ulp)
        motion.advance(120_000_000)
        let r = sqrt(1500.0)
        let delta = Double(before.value) - 1
        let expected = 1 + (delta + (Double(before.velocity) + r * delta) * 0.02) * exp(-r * 0.02)
        XCTAssertEqual(Double(motion.layers.last!.fade.alpha.value), expected, accuracy: 0.00001)
        XCTAssertEqual(motion.layers.last!.presentation.count, 7)
    }

    func testQueuePillSettledSpeedSamplesDoNotRestartModeAnimation() {
        var motion = QueuePillContentMotion(.init(mode: .counting, count: 8, speed: 1_048_576))
        for speed in [Int64(2_097_152), 800_000, 10_380_902, 1_048_576] {
            motion.update(.init(mode: .counting, count: 7, speed: speed))
            XCTAssertFalse(motion.isRunning, "Only the numeric glyphs should animate in a settled mode")
            XCTAssertEqual(motion.layers.count, 1)
            XCTAssertEqual(motion.layers[0].presentation.speed, speed)
            XCTAssertEqual(motion.layers[0].fade.alpha.value, 1)
        }
        let lastReadout = motion.layers[0].presentation
        motion.update(.init(mode: .done, count: 0, speed: nil))
        XCTAssertTrue(motion.isRunning)
        XCTAssertEqual(motion.layers[0].presentation, lastReadout, "Done must retain the outgoing readout")
        motion.advance(0)
        motion.advance(300_000_000)
        XCTAssertEqual(motion.layers.map(\.id), [.done])
        XCTAssertFalse(motion.isRunning)
    }

    func testQueuePillParentSegmentRebuildsUnchangedExitTarget() {
        var fade = QueuePillFadeMotion(initiallyVisible: true)
        fade.setVisible(false)
        fade.advance(0)
        fade.advance(50_000_000)
        let value = Double(fade.alpha.value)
        let velocity = Double(fade.alpha.velocity)
        fade.setVisible(false, atFrameNanos: 50_000_000, force: true)
        XCTAssertEqual(Double(fade.alpha.value), value, accuracy: 0.000001)
        fade.advance(70_000_000)
        let r = sqrt(1500.0)
        let expected = (value + (velocity + r * value) * 0.02) * exp(-r * 0.02)
        XCTAssertEqual(Double(fade.alpha.value), expected, accuracy: 0.00001)
    }

    func testQueuePillCountRetainsIntermediateNumbersAndReusesReversal() {
        var motion = QueuePillCountMotion(count: 10, heightPixels: 60)
        XCTAssertFalse(motion.isRunning)
        motion.update(9)
        motion.advance(0)
        motion.advance(50_000_000)
        motion.update(8)
        XCTAssertEqual(motion.layers.map(\.count), [10, 9, 8])
        motion.advance(70_000_000)
        let before = motion.layers[1].motion.offset.value
        motion.update(9)
        XCTAssertEqual(motion.layers.map(\.count), [10, 9, 8])
        XCTAssertEqual(motion.layers[1].motion.offset.value, floor(before + 0.5))
        let oldTarget = motion.layers[0].motion.offset.target
        motion.update(12)
        XCTAssertEqual(motion.layers[0].motion.offset.target, oldTarget,
                       "An older exiting number must retain its original exit direction")
        motion.advance(3_000_000_000)
        XCTAssertEqual(motion.layers.map(\.count), [12])
        XCTAssertFalse(motion.isRunning)
    }

    func testQueuePillCountSlideUsesIntegerHalfHeightAndOutlivesFade() {
        var entering = QueuePillCountLayerMotion(initiallyVisible: false, heightPixels: 61, direction: 1)
        XCTAssertEqual(entering.displayedOffsetPixels, 30)
        entering.setVisible(true, direction: 1)
        entering.advance(0)
        entering.advance(50_000_000)
        let expected = 30.0 * (1 + 20 * 0.05) * exp(-20 * 0.05)
        XCTAssertEqual(Double(entering.offset.value), expected, accuracy: 0.00001)
        XCTAssertEqual(entering.displayedOffsetPixels, Float(floor(expected + 0.5)))
        let increasing = QueuePillCountLayerMotion(initiallyVisible: false, heightPixels: 61, direction: -1)
        XCTAssertEqual(increasing.displayedOffsetPixels, -30)

        var exiting = QueuePillCountLayerMotion(initiallyVisible: true, heightPixels: 61, direction: 1)
        exiting.setVisible(false, direction: 1)
        exiting.advance(0)
        exiting.advance(120_000_000)
        XCTAssertEqual(exiting.fade.alpha.value, 0)
        XCTAssertTrue(exiting.offset.isRunning)
        XCTAssertFalse(exiting.exitFinished)
        exiting.advance(2_000_000_000)
        XCTAssertTrue(exiting.exitFinished)
        XCTAssertEqual(exiting.displayedOffsetPixels, -30)
    }

    func testQueuePillFadeDelayExitAndReverseSpring() {
        var entry = QueuePillFadeMotion(initiallyVisible: false)
        entry.setVisible(true)
        entry.advance(0)
        entry.advance(35_000_000)
        XCTAssertEqual(entry.alpha.value, 0)
        entry.advance(145_000_000)
        XCTAssertGreaterThan(entry.alpha.value, 0)
        XCTAssertLessThan(entry.alpha.value, 1)
        entry.advance(255_000_000)
        XCTAssertEqual(entry.alpha.value, 1)
        XCTAssertFalse(entry.alpha.isRunning)

        var exit = QueuePillFadeMotion(initiallyVisible: true)
        exit.setVisible(false)
        exit.advance(0)
        exit.advance(50_000_000)
        let value = Double(exit.alpha.value)
        let velocity = Double(exit.alpha.velocity)
        exit.setVisible(true)
        XCTAssertEqual(Double(exit.alpha.value), value, accuracy: 0.000001)
        exit.advance(70_000_000)
        let t = 0.02
        let delta = value - 1
        let expected = 1 + (delta + (velocity + 20 * delta) * t) * exp(-20 * t)
        XCTAssertEqual(Double(exit.alpha.value), expected, accuracy: 0.00001)
        XCTAssertFalse(exit.exitFinished)

        var completedExit = QueuePillFadeMotion(initiallyVisible: true)
        completedExit.setVisible(false)
        completedExit.advance(0)
        completedExit.advance(160_000_000)
        XCTAssertEqual(completedExit.alpha.value, 0)
        XCTAssertTrue(completedExit.exitFinished)
    }

    func testQueuePillInterruptedEntryUsesDefaultFloatSpring() {
        var fade = QueuePillFadeMotion(initiallyVisible: false)
        fade.setVisible(true)
        fade.advance(0)
        fade.advance(145_000_000)
        let value = Double(fade.alpha.value)
        let velocity = Double(fade.alpha.velocity)
        fade.setVisible(false)
        XCTAssertEqual(Double(fade.alpha.value), value, accuracy: 0.000001)
        XCTAssertEqual(Double(fade.alpha.velocity), velocity, accuracy: 0.000001)
        fade.advance(165_000_000)
        let r = sqrt(1500.0)
        let t = 0.02
        let expected = (value + (velocity + r * value) * t) * exp(-r * t)
        XCTAssertEqual(Double(fade.alpha.value), expected, accuracy: 0.00001)
        XCTAssertFalse(fade.exitFinished)
        fade.advance(2_000_000_000)
        XCTAssertTrue(fade.exitFinished)
    }

    func testQueuePillContentRetainsOutgoingSnapshotAndCleansFinishedLayers() {
        let downloading = QueuePillPresentation(mode: .counting, count: 3, speed: 10_380_902)
        var motion = QueuePillContentMotion(downloading)
        let done = QueuePillPresentation(mode: .done, count: 0, speed: nil)
        motion.update(done)
        XCTAssertEqual(motion.layers.first?.presentation, downloading)
        motion.advance(0)
        motion.advance(160_000_000)
        XCTAssertEqual(motion.layers.map(\.id), [.done])
        XCTAssertTrue(motion.isRunning)
        motion.advance(255_000_000)
        XCTAssertFalse(motion.isRunning)
        let resumed = QueuePillPresentation(mode: .counting, count: 8, speed: 1_048_576)
        motion.update(resumed)
        motion.advance(300_000_000)
        motion.advance(350_000_000)
        let before = motion.layers.last!.fade.alpha.value
        motion.update(.init(mode: .counting, count: 7, speed: 2_097_152))
        XCTAssertEqual(motion.layers.last!.fade.alpha.value, before)
        XCTAssertEqual(motion.layers.last!.presentation.count, 7)
        motion.update(done)
        XCTAssertEqual(motion.layers.count, 2, "Reverse reuses the retained Done layer")
        XCTAssertEqual(motion.layers.last!.presentation.count, 7)
    }

    func testQueuePillWidthFirstMeasureAndInterruptedSpring() {
        var motion = QueueTopPillWidthMotion()
        motion.update(width: 40, scale: 3)
        XCTAssertEqual(motion.width, 40)
        XCTAssertFalse(motion.isRunning)
        motion.update(width: 100, scale: 3)
        motion.advance(0)
        motion.advance(50_000_000)
        // Independent solution of x'' + 20x' + 400(x-target) = 0.
        let t = 0.05
        let omega = sqrt(300.0)
        let decay = exp(-10 * t)
        let expected = 100 - 60 * decay * (cos(omega * t) + 10 / omega * sin(omega * t))
        XCTAssertEqual(Double(motion.width!), expected, accuracy: 0.0001)
        let before = motion.width!
        motion.update(width: 60, scale: 3)
        XCTAssertEqual(motion.width!, before, accuracy: 0.00001)
        motion.advance(51_000_000)
        XCTAssertGreaterThan(motion.width!, before, "Retarget must preserve the outward velocity")
        motion.advance(3_000_000_000)
        XCTAssertEqual(motion.width!, 60, accuracy: 0.00001)
        XCTAssertFalse(motion.isRunning)
    }

    func testQueuePillWidthCategoriesReleasePreviousMaximum() {
        let base = QueuePillWidthKey(mode: .counting, speedText: "1.0 MB/s", count: 99)
        XCTAssertEqual(base, .init(mode: .counting, speedText: "9.9 MB/s", count: 99))
        for key in [
            QueuePillWidthKey(mode: .counting, speedText: "999.9 KB/s", count: 99),
            .init(mode: .counting, speedText: "10.0 MB/s", count: 99),
            .init(mode: .counting, speedText: "1.0 MB/s", count: 100),
            .init(mode: .counting, speedText: nil, count: 99),
            .init(mode: .paused, speedText: nil, count: 99)
        ] { XCTAssertNotEqual(base, key) }
        var measurement = QueuePillWidthMeasurement()
        measurement.measure(120, key: base)
        measurement.measure(110, key: base)
        XCTAssertEqual(measurement.width, 120)
        let narrower = QueuePillWidthKey(mode: .counting, speedText: nil, count: 9)
        measurement.measure(48, key: narrower)
        XCTAssertEqual(measurement.width, 48)
        measurement.measure(.nan, key: base)
        XCTAssertEqual(measurement.key, narrower)
        let paused = QueuePillWidthKey(mode: .paused, speedText: nil, count: 9)
        measurement.measure(60, key: paused)
        measurement.measure(48, key: paused)
        XCTAssertEqual(measurement.width, 48)
    }

    func testQueueEmptyMarkRevealAndReverseBreathing() {
        let initial = QueueEmptyMarkMotion.sample(elapsedNanos: 0)
        XCTAssertEqual(initial.opacity, 0)
        XCTAssertEqual(initial.scale, 0.985, accuracy: 0.000001)
        let entering = QueueEmptyMarkMotion.sample(elapsedNanos: 170_000_000)
        XCTAssertGreaterThan(entering.opacity, 0)
        XCTAssertLessThan(entering.opacity, 0.42)
        let peak = QueueEmptyMarkMotion.sample(elapsedNanos: 2_400_000_000)
        XCTAssertEqual(peak.opacity, 0.54, accuracy: 0.000001)
        XCTAssertEqual(peak.scale, 1.015, accuracy: 0.000001)
        let trough = QueueEmptyMarkMotion.sample(elapsedNanos: 4_800_000_000)
        XCTAssertEqual(trough.opacity, 0.42, accuracy: 0.000001)
        XCTAssertEqual(trough.scale, 0.985, accuracy: 0.000001)
        // Reverse must retrace the same curve; endpoint swapping is different.
        let outward = QueueEmptyMarkMotion.sample(elapsedNanos: 600_000_000)
        let returning = QueueEmptyMarkMotion.sample(elapsedNanos: 4_200_000_000)
        XCTAssertEqual(outward.opacity, returning.opacity)
        XCTAssertEqual(outward.scale, returning.scale)
        let repeated = QueueEmptyMarkMotion.sample(elapsedNanos: 5_400_000_000)
        XCTAssertEqual(outward.opacity, repeated.opacity)
        XCTAssertEqual(outward.scale, repeated.scale)
    }

    private func androidGenieRow(progress: CGFloat, fraction: CGFloat,
                                  anchor: CGRect, panel: CGRect,
                                  mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth,
                                  mirroredAlready: Bool = false) -> GeniePopupMotion.Row {
        let p = min(max(progress.isFinite ? progress : 0, 0), 1)
        let v = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if p == 1 {
            return .init(left: panel.minX, right: panel.maxX,
                         y: panel.minY + panel.height * v)
        }
        if !mirroredAlready && anchor.midX > panel.midX {
            let mirrored = CGRect(x: panel.minX + panel.maxX - anchor.maxX,
                                  y: anchor.minY, width: anchor.width, height: anchor.height)
            let row = androidGenieRow(progress: p, fraction: v, anchor: mirrored,
                                      panel: panel, mouthWidth: mouthWidth,
                                      mirroredAlready: true)
            return .init(left: panel.minX + panel.maxX - row.right,
                         right: panel.minX + panel.maxX - row.left,
                         y: row.y, tilt: -row.tilt)
        }
        let dockX = anchor.midX - panel.minX
        let dockY = anchor.maxY - panel.minY
        let length = p * (2 - p)
        let spread = pow(p, 0.85 + 2.1 * (1 - v) * (1 - v))
        let seedWidth = min(anchor.width, panel.width,
                            mouthWidth.isFinite && mouthWidth > 0 ? mouthWidth : anchor.width * 0.5)
        let width = seedWidth + (panel.width - seedWidth) * spread
        let envelope = 16 * p * p * (1 - p) * (1 - p)
        let drift = seedWidth * 0.22 * envelope * (1 - spread) * (0.35 + 0.65 * v)
        let center = dockX + (panel.width / 2 - dockX) * spread + drift
        let bowPhase = max(0, sin(.pi * v))
        let bow = min(min(panel.width * 0.075, min(anchor.width * 0.5, width * 0.2)) * envelope * bowPhase * bowPhase,
                      (width - seedWidth) * 0.3)
        let left = center - width / 2 + bow
        let right = center + width / 2 - bow * 0.15
        let bentV = v + 0.4 * (1 - p) * (v * v - v)
        let mouthTilt = min(seedWidth * 0.14, panel.width * 0.045) * (1 - length)
        let bodyTilt = min(min((right - left) * 0.07, panel.width * 0.035),
                           panel.height * length * 0.12) * envelope * v * v
        let tilt = min(min(mouthTilt + bodyTilt, (right - left) * 0.14), panel.width * 0.045)
        let y = dockY * (1 - length) + panel.height * length * bentV + mouthTilt / 2
        return .init(left: panel.minX + left, right: panel.minX + right,
                     y: panel.minY + y, tilt: tilt)
    }

    private func androidCubicBezier(_ x: Double, x1: Double, y1: Double,
                                    x2: Double, y2: Double) -> CGFloat {
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            if cubic(t, x1, x2) < x { low = t } else { high = t }
        }
        return CGFloat(cubic((low + high) / 2, y1, y2))
    }

    @MainActor
    func testGenieCloseBeforeFirstFrameNotifiesAndAboveAnchorMirrorsInlet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let popup = GeniePopupHostView(frame: CGRect(x: 10, y: 10, width: 200, height: 100))
        defer { popup.stop(); window.isHidden = true }
        popup.host.rootView = AnyView(Color.red.frame(width: 200, height: 100))
        root.view.addSubview(popup)
        root.view.layoutIfNeeded()
        var settled: [CGFloat] = []
        popup.onSettled = { settled.append($0) }
        popup.configure(target: 1, anchorX: 0.5, anchorWidth: 0.1, anchorGap: 8)
        popup.configure(target: 0, anchorX: 0.5, anchorWidth: 0.1, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(settled, [0])
        popup.configure(target: 1, anchorX: 0.5, anchorWidth: 0.1, anchorGap: 8, opensAbove: true)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let layers = try XCTUnwrap(popup.subviews.last?.layer.sublayers)
        XCTAssertEqual(layers.count, GeniePopupMotion.renderBandCount * 2)
        XCTAssertTrue(layers.compactMap { $0.sublayers?.first?.transform.m42 }
            .allSatisfy(\.isFinite))
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
    }

    @MainActor
    func testGenieProgressFollowsRenderedFramesThroughReversal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let popup = GeniePopupHostView(frame: CGRect(x: 10, y: 10, width: 200, height: 100))
        defer { popup.stop(); window.isHidden = true }
        popup.host.rootView = AnyView(Color.red.frame(width: 200, height: 100))
        root.view.addSubview(popup)
        root.view.layoutIfNeeded()
        var frames: [CGFloat] = []
        popup.onProgress = { frames.append($0) }
        func target(_ value: CGFloat) {
            popup.configure(target: value, anchorX: 0.8, anchorWidth: 0.15,
                            anchorGap: 12, opensAbove: true)
            popup.layoutIfNeeded()
        }
        target(1)
        for _ in 0..<100 {
            if frames.contains(where: { $0 > 0 && $0 < 1 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(frames.contains { $0 > 0 && $0 < 1 })
        // Reverse from an actual rendered intermediate frame, then reopen
        // before the next display frame. No old zero endpoint may leak out.
        let reversal = frames.count
        target(0)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(popup.host.view.accessibilityElementsHidden)
        target(1)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(popup.host.view.accessibilityElementsHidden)
        for _ in 0..<100 {
            if frames.last == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(frames.last, 1)
        XCTAssertFalse(frames.dropFirst(reversal).contains(0))
        XCTAssertTrue(popup.host.view.isUserInteractionEnabled)
        XCTAssertFalse(popup.host.view.accessibilityElementsHidden)
        target(0)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(popup.host.view.accessibilityElementsHidden)
        for _ in 0..<100 {
            if frames.last == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(frames.last, 0)
        XCTAssertTrue(popup.host.view.accessibilityElementsHidden)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(frames.allSatisfy { (0...1).contains($0) })
    }

    func testQueueFabVisibilitySpringRetainsExitAndReversesWithVelocity() {
        let initiallyVisible = QueueFabVisibilityMotion(visible: true)
        XCTAssertEqual(initiallyVisible.alpha.value, 1)
        XCTAssertEqual(initiallyVisible.scale.value, 1)
        XCTAssertFalse(initiallyVisible.isRunning)
        var motion = QueueFabVisibilityMotion()
        motion.setVisible(true)
        motion.advance(0)
        motion.advance(100_000_000)
        // Critical spring x(t)=target+(start-target)*(1+20t)*exp(-20t).
        let remaining = Float(3 * exp(-2.0))
        XCTAssertEqual(motion.alpha.value, 1 - remaining, accuracy: 0.00001)
        XCTAssertEqual(motion.scale.value, 1 - 0.4 * remaining, accuracy: 0.00001)
        let alpha = motion.alpha.value, velocity = motion.alpha.velocity
        motion.setVisible(false)
        XCTAssertEqual(motion.alpha.value, alpha)
        XCTAssertEqual(motion.alpha.velocity, velocity)
        XCTAssertTrue(motion.retained)
        motion.advance(180_000_000)
        let reversingValue = motion.alpha.value
        motion.setVisible(true)
        XCTAssertEqual(motion.alpha.value, reversingValue)
        for tick in 19...150 { motion.advance(Int64(tick) * 10_000_000) }
        XCTAssertEqual(motion.alpha.value, 1)
        XCTAssertEqual(motion.scale.value, 1)
        motion.setVisible(false)
        motion.advance(1_600_000_000)
        XCTAssertTrue(motion.retained)
        for tick in 161...250 { motion.advance(Int64(tick) * 10_000_000) }
        XCTAssertFalse(motion.retained)
        XCTAssertEqual(motion.alpha.value, 0)
        XCTAssertEqual(motion.scale.value, 0.6)
    }

    func testQueueFabReversalSharesFrameWhenScaleFinishesBeforeOpacity() {
        var motion = QueueFabVisibilityMotion(visible: true)
        motion.setVisible(false)
        motion.advance(0)
        motion.advance(300_000_000)
        XCTAssertTrue(motion.alpha.isRunning)
        XCTAssertFalse(motion.scale.isRunning)
        motion.setVisible(true)
        motion.advance(310_000_000)
        let expected = Float(0.6 + 0.4 * (1 - 1.2 * exp(-0.2)))
        XCTAssertEqual(motion.scale.value, expected, accuracy: 0.00001)
        XCTAssertGreaterThan(motion.scale.value, 0.6)
    }

    @MainActor
    func testQueueCardColorTweenDurationAndInterruption() {
        let blue: UInt32 = 0xff0277bd, green: UInt32 = 0xff2e7d32, red: UInt32 = 0xffd32f2f
        var motion = ZTransferColorAnimation(blue, durationMilliseconds: 300)
        XCTAssertEqual(motion.value, blue)
        motion.retarget(green)
        motion.advance(0)
        motion.advance(150_000_000)
        XCTAssertTrue(motion.isRunning)
        XCTAssertNotEqual(motion.value, blue)
        XCTAssertNotEqual(motion.value, green)
        motion.retarget(red)
        motion.advance(300_000_000)
        XCTAssertTrue(motion.isRunning)
        motion.advance(450_000_000)
        XCTAssertEqual(motion.value, red)
        XCTAssertFalse(motion.isRunning)
        motion.retarget(red)
        XCTAssertFalse(motion.isRunning)
    }

    func testQueuePillWidthUsesPixelRoundingAnd140msRetargeting() {
        var motion = QueuePillWidthMotion()
        motion.measure(30.2, scale: 3)
        XCTAssertEqual(motion.width!, 91.0 / 3, accuracy: 0.000001)
        XCTAssertFalse(motion.isRunning)
        motion.measure(70, scale: 3)
        motion.advance(0)
        motion.advance(70_000_000)
        let displayed = motion.width!
        XCTAssertGreaterThan(displayed, 30.2)
        XCTAssertLessThan(displayed, 70)
        XCTAssertEqual(displayed * 3, (displayed * 3).rounded(), accuracy: 0.000001)
        motion.measure(40, scale: 3)
        XCTAssertEqual(motion.width!, displayed)
        motion.advance(209_000_000)
        XCTAssertTrue(motion.isRunning)
        motion.advance(210_000_000)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.width!, 40)
        motion.measure(40, scale: 3)
        XCTAssertFalse(motion.isRunning)
        motion.measure(.infinity, scale: 3)
        XCTAssertEqual(motion.width!, 40)
        motion.measure(40.3, scale: 2)
        XCTAssertEqual(motion.width!, 40.5)
        XCTAssertFalse(motion.isRunning)
    }

    func testQueueBadgeStartsQuietAndFinishesFadeBeforePop() {
        var motion = QueueBadgeMotion(state: .waiting)
        motion.update(.waiting)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.layers.count, 1)
        XCTAssertEqual(motion.scale.value, 1)
        motion.update(.transferring)
        XCTAssertEqual(motion.scale.value, 0.62)
        XCTAssertEqual(motion.scale.velocity, 0)
        XCTAssertEqual(motion.layers.map(\.state), [.waiting, .transferring])
        motion.advance(0)
        motion.advance(100_000_000)
        // Compose 1.7.6 StiffnessMediumLow=400, MediumBouncy=.5.
        // Independent equation deliberately does not read production constants.
        let omega = sqrt(400.0), decay = omega * 0.5, damped = omega * sqrt(0.75)
        let expected = 1 - 0.38 * exp(-decay * 0.1) *
            (cos(damped * 0.1) + decay / damped * sin(damped * 0.1))
        XCTAssertEqual(Double(motion.scale.value), expected, accuracy: 0.000001)
        XCTAssertEqual(motion.layers.reduce(0) { $0 + $1.alpha.value }, 1, accuracy: 0.000001)
        motion.advance(180_000_000)
        XCTAssertEqual(motion.layers.map(\.state), [.transferring])
        XCTAssertEqual(motion.layers[0].alpha.value, 1)
        XCTAssertTrue(motion.scale.isRunning)
        for tick in 19...150 { motion.advance(Int64(tick) * 10_000_000) }
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.scale.value, 1)
    }

    func testQueueBadgeInterruptedFadeRetainsLayersAndVelocityButRestartsPop() {
        var motion = QueueBadgeMotion(state: .waiting)
        motion.update(.transferring)
        motion.advance(0)
        motion.advance(60_000_000)
        let old = motion.layers[1].alpha
        let waiting = motion.layers[0].alpha
        motion.update(.failed)
        XCTAssertEqual(motion.layers.map(\.state), [.waiting, .transferring, .failed])
        XCTAssertEqual(motion.layers[0].alpha.value, waiting.value)
        XCTAssertEqual(motion.layers[1].alpha.value, old.value)
        XCTAssertEqual(motion.layers[1].alpha.velocity, old.velocity)
        XCTAssertEqual(motion.scale.value, 0.62)
        XCTAssertEqual(motion.scale.velocity, 0)
        motion.advance(80_000_000)
        let w = sqrt(1500.0), t = 0.02, x = Double(old.value), v = Double(old.velocity)
        let expected = (x + (v + w * x) * t) * exp(-w * t)
        XCTAssertEqual(Double(motion.layers[1].alpha.value), expected, accuracy: 0.000001)
        // WAITING still targets zero, but the whole Transition changed segment.
        // Compose resetAnimations forces this channel onto the interruption
        // spring too; merely continuing its old 180ms tween is incorrect.
        let waitingX = Double(waiting.value), waitingV = Double(waiting.velocity)
        let expectedWaiting = (waitingX + (waitingV + w * waitingX) * t) * exp(-w * t)
        XCTAssertEqual(Double(motion.layers[0].alpha.value), expectedWaiting, accuracy: 0.000001)
        // Returning to a retained key must reuse it rather than duplicate it.
        let retained = motion.layers[0].alpha.value
        motion.update(.waiting)
        XCTAssertEqual(motion.layers.count, 3)
        XCTAssertEqual(motion.layers[0].alpha.value, retained)
        let unchanged = motion.layers[0].alpha.velocity
        motion.update(.waiting)
        XCTAssertEqual(motion.layers[0].alpha.velocity, unchanged)
        for tick in 9...150 { motion.advance(Int64(tick) * 10_000_000) }
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.layers.map(\.state), [.waiting])
        XCTAssertEqual(motion.layers[0].alpha.value, 1)
        // Remount/new identity has no inherited fade or pop.
        motion = .init(state: .failed)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.scale.value, 1)
        XCTAssertEqual(motion.layers.map(\.state), [.failed])
    }

    func testTransferCardVisualStatePrioritizesActiveWorkOverRetainedError() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "STATE.JPG", captureDate: nil, isProtected: false)
        let cases: [(TransferStatus, TransferCardVisualState, TransferCardVisualState)] = [
            (.waiting, .waiting, .waiting), (.transferring, .transferring, .transferring),
            (.completed, .completed, .failed), (.failed, .failed, .failed),
            (.cancelled, .cancelled, .failed)
        ]
        for (status, ordinary, withError) in cases {
            var item = TransferQueueItem(id: UUID(), file: file)
            item.status = status
            XCTAssertEqual(TransferCardVisualState(item: item), ordinary)
            item.frameError = "retained generation error"
            XCTAssertEqual(TransferCardVisualState(item: item), withError)
            item.isGeneratingFrame = true
            XCTAssertEqual(TransferCardVisualState(item: item), .generating)
        }
    }

    func testTransferPillResponseOnlyRunsOnRisingEdgeAndCancelsInPlace() {
        var initial = TransferPillResponseMotion(responding: true)
        initial.update(true)
        XCTAssertFalse(initial.scale.isRunning)
        XCTAssertEqual(initial.scale.value, 1)
        initial.update(false)
        initial.update(true)
        initial.advance(0)
        initial.advance(105_000_000)
        XCTAssertEqual(initial.scale.value, 0.94, accuracy: 0.000001)
        XCTAssertEqual(initial.scale.target, 1)
        initial.advance(155_000_000)
        let omega = sqrt(400.0), decay = omega * 0.5, damped = omega * sqrt(0.75)
        let expected = 1 - 0.06 * exp(-decay * 0.05) *
            (cos(damped * 0.05) + decay / damped * sin(damped * 0.05))
        XCTAssertEqual(Double(initial.scale.value), expected, accuracy: 0.000001)
        let displayed = initial.scale.value
        initial.update(false)
        XCTAssertEqual(initial.scale.value, displayed)
        XCTAssertFalse(initial.scale.isRunning)
        initial.advance(200_000_000)
        XCTAssertEqual(initial.scale.value, displayed)
        initial.update(true)
        XCTAssertEqual(initial.scale.value, 1)
        initial.advance(210_000_000)
        initial.advance(250_000_000)
        XCTAssertLessThan(initial.scale.value, 1)
        let velocity = initial.scale.velocity
        initial.update(true)
        XCTAssertEqual(initial.scale.velocity, velocity)
    }

    func testTransferProgressChangesIdentityWithoutDrainOrDelay() {
        var motion = SmoothTransferProgressMotion()
        motion.update(target: 0.8, key: "first")
        motion.advance(0)
        motion.advance(100_000_000)
        let omega = sqrt(180.0)
        let expected = 0.8 * (1 - (1 + omega * 0.1) * exp(-omega * 0.1))
        XCTAssertEqual(Double(motion.animation.value), expected, accuracy: 0.000001)
        let velocity = motion.animation.velocity
        motion.update(target: 0.9, key: "first")
        XCTAssertEqual(motion.animation.velocity, velocity, accuracy: 0.000001)
        motion.update(target: 0.2, key: "first")
        XCTAssertEqual(motion.accepted, 0.9)
        motion.update(target: .nan, key: "first")
        XCTAssertEqual(motion.accepted, 0.9)

        motion.update(target: 0.4, key: "second")
        XCTAssertEqual(motion.animation.value, 0)
        XCTAssertEqual(motion.animation.velocity, 0)
        motion.advance(110_000_000)
        motion.advance(210_000_000)
        XCTAssertEqual(Double(motion.animation.value), expected / 2, accuracy: 0.000001)
        XCTAssertGreaterThan(motion.animation.value, 0) // Before the old 220ms reset delay.
        motion.update(target: .infinity, key: "third")
        XCTAssertEqual(motion.accepted, 0)
        XCTAssertFalse(motion.animation.isRunning)
        motion.update(target: 2, key: "third")
        XCTAssertEqual(motion.accepted, 1)
    }

    func testTransferTitleFitsStemAndPreservesExtensionAndStyles() throws {
        let measure: (TransferFileTitleText) -> CGFloat = { CGFloat($0.full.utf16.count) }
        XCTAssertEqual(TransferFileTitleText.fit("DSC_12345.JPG", width: 13, measure: measure).full, "DSC_12345.JPG")
        XCTAssertEqual(TransferFileTitleText.fit("DSC_12345.JPG", width: 9, measure: measure).full, "DS…45.JPG")
        XCTAssertEqual(TransferFileTitleText.fit(".hidden", width: 4, measure: measure).full, ".h…n")
        XCTAssertEqual(TransferFileTitleText.fit("capture.raw.JPG", width: 5, measure: measure).full, "….JPG")
        XCTAssertEqual(TransferFileTitleText.fit("照片编号12345.NEF", width: 9, measure: measure).full, "照片…45.NEF")
        let label = TransferFileTitleLabel(frame: CGRect(x: 0, y: 0, width: 140, height: 20))
        let name = "A_VERY_LONG_CAMERA_FILENAME_123456.JPG"
        label.configure(name: name, primary: .black, secondary: .gray)
        label.layoutIfNeeded()
        let text = try XCTUnwrap(label.attributedText)
        XCTAssertTrue(text.string.contains("…"))
        XCTAssertTrue(text.string.hasSuffix(".JPG"))
        XCTAssertLessThanOrEqual(text.size().width, 140)
        XCTAssertEqual(label.accessibilityLabel, name)
        XCTAssertEqual(text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? UIColor, .gray)
        XCTAssertEqual(text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont,
                       UIFont.systemFont(ofSize: 14, weight: .regular))
        label.frame.size.width = 500
        label.setNeedsLayout(); label.layoutIfNeeded()
        XCTAssertEqual(label.attributedText?.string, name)
    }

    func testPreparedGenieGeometryMatchesAndroidCurve() {
        // Android's production equations are the oracle, including padded rows
        // outside the visible panel bounds and right-hand inlet mirroring.
        for size in [CGSize(width: 280, height: 193),
                     CGSize(width: 340, height: 399 + 1.0 / 3),
                     CGSize(width: 378, height: 670)] {
            for source in [CGRect(x: 12, y: -8, width: 20, height: 0),
                           CGRect(x: 240, y: -8, width: 28, height: 0),
                           CGRect(x: 10, y: -10, width: 155, height: 0)] {
                for step in 0...120 {
                    let p = CGFloat(step) / 120
                    let frame = GeniePopupMotion.FrameGeometry(progress: p, source: source, size: size)
                    for index in 0...48 {
                        let fraction = (CGFloat(index) / 48 * (size.height + 24) - 12) / size.height
                        let row = frame.row(at: .init(fraction: fraction))
                        let expected = androidGenieRow(progress: p, fraction: fraction,
                                                        anchor: source,
                                                        panel: CGRect(origin: .zero, size: size))
                        XCTAssertEqual(row.left, expected.left, accuracy: 1e-9)
                        XCTAssertEqual(row.right, expected.right, accuracy: 1e-9)
                        XCTAssertEqual(row.y, expected.y, accuracy: 1e-9)
                        XCTAssertEqual(row.tilt, expected.tilt, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testGeniePopupUsesTriggerShortEdgeAndSharedEndpoints() {
        for button in [CGRect(x: 119, y: 62, width: 40, height: 40),
                       CGRect(x: 12, y: 68, width: 55, height: 36),
                       CGRect(x: 20, y: 450, width: 175, height: 50)] {
            let edge = GeniePopupMotion.attachmentAnchor(for: button, cornerRadius: 20)
            XCTAssertEqual(edge.midX, button.midX)
            XCTAssertEqual(edge.maxY, button.maxY)
            let source = edge.offsetBy(dx: -31, dy: -(button.maxY + 8))
            for height: CGFloat in [193, 400, 670] {
                let size = CGSize(width: 340, height: height)
                for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
                    let collapsed = GeniePopupMotion.row(progress: 0, fraction: fraction, source: source, size: size)
                    let expectedCollapsed = androidGenieRow(progress: 0, fraction: fraction,
                                                             anchor: source,
                                                             panel: CGRect(origin: .zero, size: size))
                    XCTAssertEqual(collapsed.left, expectedCollapsed.left, accuracy: 0.0001)
                    XCTAssertEqual(collapsed.right, expectedCollapsed.right, accuracy: 0.0001)
                    XCTAssertEqual(collapsed.y, expectedCollapsed.y, accuracy: 0.0001)
                    let expanded = GeniePopupMotion.row(progress: 1, fraction: fraction, source: source, size: size)
                    XCTAssertEqual(expanded.left, 0, accuracy: 0.0001)
                    XCTAssertEqual(expanded.right, size.width, accuracy: 0.0001)
                    XCTAssertEqual(expanded.y, height * fraction, accuracy: 0.0001)
                }
            }
        }
    }

    func testGeniePopupBendsCrossSectionsAndBandCorners() {
        let size = CGSize(width: 340, height: 400)
        let source = CGRect(x: 100, y: -8, width: 20, height: 0)
        let mouth = GeniePopupMotion.row(progress: 0.5, fraction: 0, source: source, size: size)
        let tail = GeniePopupMotion.row(progress: 0.5, fraction: 1, source: source, size: size)
        // A real Genie bends and retains length; a uniform scale + mask fails
        // these independent mouth/tail width, center and height constraints.
        XCTAssertLessThan(mouth.right - mouth.left, (tail.right - tail.left) / 2)
        XCTAssertLessThan((mouth.left + mouth.right) / 2, (tail.left + tail.right) / 2)
        XCTAssertGreaterThan(tail.y - mouth.y, size.height * 0.7)
        for p: CGFloat in [0.001, 0.1, 0.5, 0.9, 1] {
            for band in 0..<48 {
                let top = GeniePopupMotion.row(progress: p, fraction: CGFloat(band) / 48, source: source, size: size)
                let bottom = GeniePopupMotion.row(progress: p, fraction: CGFloat(band + 1) / 48, source: source, size: size)
                let bandSize = CGSize(width: 340, height: 400.0 / 48)
                let upper = GeniePopupMotion.bandTransform(size: bandSize, top: top, bottom: bottom, upper: true)
                let lower = GeniePopupMotion.bandTransform(size: bandSize, top: top, bottom: bottom, upper: false)
                for (transform, points) in [
                    (upper, [(CGPoint.zero, CGPoint(x: top.left, y: top.leftY)),
                             (CGPoint(x: bandSize.width, y: 0), CGPoint(x: top.right, y: top.rightY)),
                             (CGPoint(x: 0, y: bandSize.height), CGPoint(x: bottom.left, y: bottom.leftY))]),
                    (lower, [(CGPoint(x: bandSize.width, y: 0), CGPoint(x: top.right, y: top.rightY)),
                             (CGPoint(x: bandSize.width, y: bandSize.height), CGPoint(x: bottom.right, y: bottom.rightY)),
                             (CGPoint(x: 0, y: bandSize.height), CGPoint(x: bottom.left, y: bottom.leftY))])
                ] {
                    for (point, expected) in points {
                        let denominator = transform.m14 * point.x + transform.m24 * point.y + transform.m44
                        XCTAssertEqual((transform.m11 * point.x + transform.m21 * point.y + transform.m41) / denominator,
                                       expected.x, accuracy: 0.0001)
                        XCTAssertEqual((transform.m12 * point.x + transform.m22 * point.y + transform.m42) / denominator,
                                       expected.y, accuracy: 0.0001)
                    }
                }
                XCTAssertGreaterThan(bottom.y, top.y)
            }
        }
    }

    func testGenieTimingAndDurationsMatchAndroid() {
        XCTAssertEqual(GeniePopupMotion.duration(expanding: true), 0.32, accuracy: 1e-12)
        XCTAssertEqual(GeniePopupMotion.duration(expanding: false), 0.35, accuracy: 1e-12)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(GeniePopupMotion.timing(fraction, expanding: true),
                           androidCubicBezier(fraction, x1: 0.16, y1: 0.40, x2: 0.22, y2: 1), accuracy: 1e-6)
            XCTAssertEqual(GeniePopupMotion.timing(fraction, expanding: false),
                           androidCubicBezier(fraction, x1: 0.30, y1: 0.18, x2: 0.60, y2: 1), accuracy: 1e-6)
        }
    }

    func testGenieRightHandMirrorPreservesAndroidTiltRules() {
        let panel = CGRect(x: 0, y: 0, width: 340, height: 400)
        let leftAnchor = CGRect(x: 40, y: -8, width: 40, height: 0)
        let rightAnchor = CGRect(x: 260, y: -8, width: 40, height: 0)
        let left = GeniePopupMotion.row(progress: 0.42, fraction: 0.65,
                                        anchor: leftAnchor, panel: panel)
        let right = GeniePopupMotion.row(progress: 0.42, fraction: 0.65,
                                         anchor: rightAnchor, panel: panel)
        XCTAssertEqual(right.left, panel.maxX - left.right, accuracy: 1e-9)
        XCTAssertEqual(right.right, panel.maxX - left.left, accuracy: 1e-9)
        XCTAssertEqual(right.y, left.y, accuracy: 1e-9)
        XCTAssertEqual(right.tilt, -left.tilt, accuracy: 1e-9)
        XCTAssertNotEqual(left.tilt, 0, accuracy: 1e-9)
    }

    func testGenieAboveAnchorMatchesAndroidReflection() {
        let panel = CGRect(x: 20, y: 30, width: 220, height: 300)
        let anchor = CGRect(x: 40, y: 340, width: 36, height: 36)
        let mirroredAnchor = CGRect(x: anchor.minX, y: -anchor.maxY,
                                    width: anchor.width, height: anchor.height)
        let mirroredPanel = CGRect(x: panel.minX, y: -panel.maxY,
                                   width: panel.width, height: panel.height)
        for progress in stride(from: CGFloat(0), through: 1, by: 0.1) {
            for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
                let actual = GeniePopupMotion.rowAbove(progress: progress, fraction: fraction,
                                                        anchor: anchor, panel: panel)
                let raw = androidGenieRow(progress: progress, fraction: 1 - fraction,
                                          anchor: mirroredAnchor, panel: mirroredPanel)
                XCTAssertEqual(actual.left, raw.left, accuracy: 1e-9)
                XCTAssertEqual(actual.right, raw.right, accuracy: 1e-9)
                XCTAssertEqual(actual.y, panel.maxY - raw.y, accuracy: 1e-9)
                XCTAssertEqual(actual.tilt, -raw.tilt, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testSettingsPopupCaptureKeepsFinalSizeAndOutlineThroughHandoff() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let popup = GeniePopupHostView(frame: CGRect(x: 20, y: 70, width: 340, height: 400))
        let suite = "SettingsPopupCapture.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { popup.stop(); window.isHidden = true; defaults.removePersistentDomain(forName: suite) }
        popup.host.rootView = AnyView(SettingsView(showPhotoEffectsEntry: true,
            effectsStore: PhotoEffectsStore(defaults: defaults), directory: DirectoryAccessStore(defaults: defaults),
            effectsDraft: .constant(PhotoEffectsSettings()), filterChooser: .constant(PhotoFilterChooserState()),
            effectsHint: .constant(nil), dismissalRequested: false, popupMotionPaused: true)
            .environment(\.colorScheme, .light))
        root.view.addSubview(popup)
        popup.configure(target: 1, anchorX: 0.2, anchorWidth: 0.1, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        // Preferences can resize Settings after its initial layout. The mesh
        // must follow that final measured size instead of keeping the old rim.
        popup.frame.size.height = 520
        popup.setNeedsLayout()
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let layers = try XCTUnwrap(popup.subviews.last?.layer.sublayers)
        let images = stride(from: 0, to: layers.count, by: 2).compactMap {
            layers[$0].sublayers?.first?.contents
        }.map { $0 as! CGImage }
        XCTAssertEqual(images.count, GeniePopupMotion.renderBandCount)
        let scale = window.screen.scale
        XCTAssertEqual(images.reduce(0) { $0 + $1.height }, Int((520 + 24) * scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 364, height: 544), format: format)
        let capture = renderer.image { _ in
            var y: CGFloat = 0
            for image in images {
                let height = CGFloat(image.height) / scale
                UIImage(cgImage: image, scale: scale, orientation: .up)
                    .draw(in: CGRect(x: 0, y: y, width: 364, height: height))
                y += height
            }
        }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(popup.subviews.last?.isHidden == true)
        let live = renderer.image { context in
            context.cgContext.translateBy(x: 12, y: 12)
            XCTAssertTrue(popup.host.view.drawHierarchy(in: popup.host.view.bounds, afterScreenUpdates: true))
        }
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let image = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let first = try pixels(capture), second = try pixels(live)
        let width = Int(364 * scale)
        var difference = 0, samples = 0
        for y in Int(60 * scale)..<Int(480 * scale) {
            for x in [Int(12 * scale), Int(13 * scale), Int(350 * scale), Int(351 * scale)] {
                for channel in 0..<4 {
                    let index = (y * width + x) * 4 + channel
                    difference += abs(Int(first[index]) - Int(second[index]))
                    samples += 1
                }
            }
        }
        XCTAssertLessThan(Double(difference) / Double(samples), 3,
                          "The captured settings rim must not change when the live panel takes over")
    }

    @MainActor
    func testGeniePopupHostFirstCaptureAndReversal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let popup = GeniePopupHostView(frame: CGRect(x: 31, y: 110, width: 340, height: 400))
        popup.host.rootView = AnyView(Color.red.frame(width: 340, height: 400))
        root.view.addSubview(popup)
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        popup.configure(target: 1, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let layers = try XCTUnwrap(popup.subviews.last?.layer.sublayers)
        XCTAssertEqual(layers.count, GeniePopupMotion.renderBandCount * 2)
        let images = layers.compactMap { $0.sublayers?.first?.contents }.map { $0 as! CGImage }
        XCTAssertEqual(images.count, GeniePopupMotion.renderBandCount * 2)
        // A transparent first capture made the first animation invisible.
        // Inspect the actual raster used by Core Animation, not a mock image.
        let bandImage = try XCTUnwrap(images.dropFirst(GeniePopupMotion.renderBandCount).first)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bandImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertGreaterThan(pixel[3], 200)
        // A frame skipped because progress is unchanged must still redraw if
        // the button moves in that same frame (e.g. a safe-area/layout update).
        let originalLeft = layers[0].sublayers!.first!.transform.m41
        popup.configure(target: 1, anchorX: 148.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        XCTAssertNotEqual(layers[0].sublayers!.first!.transform.m41, originalLeft)
        popup.configure(target: 1, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        XCTAssertEqual(layers[0].sublayers!.first!.transform.m41, originalLeft, accuracy: 0.0001)
        try await Task.sleep(for: .milliseconds(80))
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        popup.configure(target: 1, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(popup.host.view.layer.opacity, 1)
        XCTAssertTrue(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(popup.subviews.last?.isHidden == true)
        XCTAssertTrue(layers.allSatisfy { $0.sublayers?.first?.contents == nil })
        XCTAssertTrue(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(popup.host.view.layer.opacity, 0)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        popup.stop()
    }

    @MainActor
    func testSTASequentialScanSurvivesTransferPreviewRemoteAndFilterChanges() async throws {
        let harness = SequentialListHarness()
        let files = (1...4).map { remoteLifecycleFile(UInt32($0), name: "\($0).NEF") }
        let model = PhotoListViewModel(
            scanCatalog: { _, _, _, _, onBatch in
                await harness.didStartScan()
                try await onBatch(files)
                return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                                       handleQueriesSucceeded: true, metadataComplete: true)
            },
            prefetchBatch: { ThumbnailBatchResult(settled: await harness.prefetch($0)) },
            canFill: { true },
            setRemoteGate: { await harness.setRemote($0) },
            sequentialLoading: true
        )
        model.load()
        try await waitForRemoteLifecycle { await harness.requested == [1] }
        model.setTransferBusy(true)
        model.pauseForPreview()
        await model.pauseForRemote() // Must not await/cancel the suspended scan.
        model.setFilter(PhotoFilterState(extensions: [".jpg"]))
        model.cancelLoading() // A disappearing UI is not the session owner.
        await model.reload()
        model.load()
        await harness.releaseFirst()
        try await Task.sleep(for: .milliseconds(80))
        var requested = await harness.requested
        XCTAssertEqual(requested, [1])
        XCTAssertTrue(model.isLoadingFiles)
        model.setTransferBusy(false)
        await model.resumeAfterRemote(isConnected: true)
        try await Task.sleep(for: .milliseconds(80))
        requested = await harness.requested
        XCTAssertEqual(requested, [1], "Preview still owns the foreground")
        model.resumeAfterPreview()
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        let scans = await harness.scans
        let gates = await harness.remoteGates
        requested = await harness.requested
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(requested, [1, 2, 3, 4])
        XCTAssertEqual(gates, [true, false])
        XCTAssertEqual(model.availableFiles.map(\.id), [1, 2, 3, 4])
        model.clearFilter()
        try await Task.sleep(for: .milliseconds(20))
        requested = await harness.requested
        XCTAssertEqual(requested, [1, 2, 3, 4])
    }
    @MainActor
    func testInvalidTransferDirectoryBookmarkIsRemovedDuringRestore() async throws {
        let suite = "directory-invalid-bookmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-a-bookmark".utf8), forKey: "transfer_dir")

        let store = DirectoryAccessStore(defaults: defaults)
        try await store.waitUntilRestored()

        XCTAssertNil(store.directoryURL)
        XCTAssertNil(defaults.object(forKey: "transfer_dir"))
    }

    func testGPSLocationFailuresMatchAndroidWaitingPermissionAndUnavailableStates() {
        XCTAssertEqual(gpsLocationFailureAction(for: .locationUnknown), .keepWaiting)
        XCTAssertEqual(gpsLocationFailureAction(for: .denied), .permissionRequired)
        XCTAssertEqual(gpsLocationFailureAction(for: .network), .locationUnavailable)
    }

    func testGPSBackgroundLocationRequiresDeclaredLocationMode() {
        XCTAssertFalse(gpsBackgroundLocationModeEnabled(nil))
        XCTAssertFalse(gpsBackgroundLocationModeEnabled(["audio"]))
        XCTAssertTrue(gpsBackgroundLocationModeEnabled(["location"]))
    }

    func testGPSBlocksOnlyEntryIntoWorkspaceAndPanelOwnsConnectionPageGesture() {
        XCTAssertFalse(workspacePagerUserScrollEnabled(
            gpsEnabled: true,
            currentPage: 0,
            gpsPanelPresented: false
        ))
        XCTAssertTrue(workspacePagerUserScrollEnabled(
            gpsEnabled: true,
            currentPage: 1,
            gpsPanelPresented: false
        ))
        XCTAssertFalse(workspacePagerUserScrollEnabled(
            gpsEnabled: false,
            currentPage: 0,
            gpsPanelPresented: true
        ))
        XCTAssertTrue(workspacePagerUserScrollEnabled(
            gpsEnabled: false,
            currentPage: 0,
            gpsPanelPresented: false
        ))
    }

    func testGPSOnlyReusesLocationsFromAndroidsTwoMinuteWindow() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(isReusableGPSLocation(CLLocation(
            coordinate: .init(latitude: 31, longitude: 121),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-120)
        ), now: now))
        XCTAssertFalse(isReusableGPSLocation(CLLocation(
            coordinate: .init(latitude: 31, longitude: 121),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-121)
        ), now: now))
    }

    func testGPSLocationFixDoesNotHideAndroidErrorOrStableSessionStates() {
        XCTAssertEqual(gpsStatusAfterLocationFix(.error), .error)
        XCTAssertEqual(gpsStatusAfterLocationFix(.ready), .ready)
        XCTAssertEqual(gpsStatusAfterLocationFix(.writing), .writing)
        XCTAssertEqual(gpsStatusAfterLocationFix(.connected), .connected)
        XCTAssertEqual(gpsStatusAfterLocationFix(.waitingFix), .connected)
        XCTAssertEqual(gpsStatusAfterLocationFix(.searching), .connected)
    }

    func testLocalPhotoSelectionMatchesAndroidImageWildcardInputRange() {
        XCTAssertTrue(isSupportedLocalPhoto([.jpeg]))
        XCTAssertTrue(isSupportedLocalPhoto([.png]))
        XCTAssertTrue(isSupportedLocalPhoto([.image, .png]))
        XCTAssertTrue(isSupportedLocalPhoto([.heic]))
        XCTAssertTrue(isSupportedLocalPhoto([.rawImage]))
        XCTAssertTrue(isSupportedLocalPhoto([]))
        XCTAssertFalse(isSupportedLocalPhoto([.movie]))
    }

    func testTransferSpeedMatchesAndroidInvalidAndRetainedSampleRules() {
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 0, elapsedMs: 100), 0)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 1_000), 1_048_576)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 0), 0)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 0), 2_400)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 1_200), 1_200)
    }

    func testTransferCardCompletionFillsBeforeFadingWhileFailuresKeepRealProgress() {
        XCTAssertEqual(transferCardProgressTarget(status: .completed, progress: 0.87), 1)
        XCTAssertEqual(transferCardProgressTarget(status: .failed, progress: 0.87), 0.87)
        XCTAssertEqual(transferCardProgressTarget(status: .cancelled, progress: .nan), 0)
        XCTAssertTrue(transferCardWaveEligible(status: .transferring))
        XCTAssertTrue(transferCardWaveEligible(status: .completed))
        XCTAssertFalse(transferCardWaveEligible(status: .failed))
    }

    func testSkinPreferenceRestorationMatchesAndroidMigration() {
        XCTAssertEqual(normalizedSkinPreset(nil), ZTransferButtonSkin.defaultPreset.rawValue)
        XCTAssertEqual(normalizedSkinPreset("WOOD"), "WOOD")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(normalizedSkinPreset("LIQUID_GLASS"), "LIQUID_GLASS")
        } else {
            XCTAssertEqual(normalizedSkinPreset("LIQUID_GLASS"), "FROSTED_GLASS")
        }
        XCTAssertEqual(normalizedSkinPreset("retired_skin"), "TITANIUM")
    }

    @MainActor
    func testEffectPreviewCandidateSkipsVideoAndUsesNewestCaptureDateThenHandle() {
        let files = [
            CameraFile(id: 9, storageID: 1, format: 0x300E, size: 1,
                       fileName: "new.MP4", captureDate: "20990101T000000", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                       fileName: "older.JPG", captureDate: "20260101T000000", isProtected: false),
            CameraFile(id: 7, storageID: 1, format: 0x3801, size: 1,
                       fileName: "newer.JPG", captureDate: "20260914T000000", isProtected: false),
        ]
        XCTAssertEqual(PhotoListViewModel.latestEffectPreviewFile(in: files)?.id, 7)
    }
    func testCatalogGroupingKeepsFirstSeenDayOrderAndUnknownBucket() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1, fileName: "b.JPG", captureDate: nil, isProtected: false),
            CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1, fileName: "c.JPG", captureDate: "20260913T020304", isProtected: true),
        ]
        let sections = PhotoCatalogGrouping.byCaptureDay(files)
        XCTAssertEqual(sections.map(\.day), ["zzz_unknown", "20260913"])
        XCTAssertEqual(sections[1].files.map(\.id), [3, 1])
    }

    func testCatalogGroupingPreservesCameraOrderForEqualCaptureTimes() {
        let raw = remoteLifecycleFile(0x091961BF, name: "DSC_0001.NEF")
        let jpeg = remoteLifecycleFile(0x291961BF, name: "DSC_0001.JPG")
        XCTAssertEqual(PhotoCatalogGrouping.byCaptureDay([raw, jpeg]).first?.files.map(\.id),
                       [raw.id, jpeg.id])
    }

    func testPhotoDateRangeRejectsInvalidCalendarDates() {
        let range = PhotoDateRange(start: "20260201", end: "20260301")
        XCTAssertFalse(range.contains("20260229T120000"))
        XCTAssertFalse(range.contains("20261301T120000"))
        XCTAssertTrue(range.contains("20260228T235959"))
        XCTAssertTrue(PhotoDateRange(start: "20240229", end: "20240229").contains("20240229T120000"))
        XCTAssertEqual(validPhotoCaptureDay("20260806T010000"), "20260806")
        XCTAssertNil(validPhotoCaptureDay("20260229T120000"))
    }

    func testPreviewVideoMetadataMatchesAndroidWithoutExtraQueries() {
        func file(_ size: UInt64, _ date: String?) -> CameraFile {
            CameraFile(id: 1, storageID: 1, format: 0x300D, size: size,
                       fileName: "DSC_0001.MOV", captureDate: date, isProtected: false)
        }
        XCTAssertEqual(videoPreviewMetadata(file: file(1_572_864, "20260724T123456")),
                       "1.5 MB  ·  2026-07-24 12:34:56")
        XCTAssertEqual(videoPreviewMetadata(file: file(0, "20260724T996099")), "2026-07-24")
        XCTAssertEqual(videoPreviewMetadata(file: file(0, "20261340T120000")), "")
        for size in [UInt64(UInt32.max), UInt64(5) * 1024 * 1024 * 1024] {
            XCTAssertEqual(videoPreviewMetadata(file: file(size, nil)), AppLocalized.resource("video_size_over_4gb"))
        }
    }

    func testLocalPreviewDecodesVisiblePagesIncludingIncomingSwipe() {
        for (x, visible) in [(CGFloat(-400), false), (-399.9, true), (-399, true), (0, true), (399, true), (399.9, true), (400, false)] {
            XCTAssertEqual(localPreviewPageIsVisible(frame: CGRect(x: x, y: 0, width: 400, height: 300),
                                                     viewportWidth: 400), visible)
        }
    }

    func testPreviewContentChangesAtHalfPageWithContinuousOpacity() {
        for (left, expected) in [(CGFloat(0), 0), (-0.49, 0), (-0.51, 1), (-1, 1)] {
            let page = nearestPreviewPage(offsets: [0: left, 1: left + 1])
            XCTAssertEqual(page?.index, expected)
        }
        XCTAssertEqual(previewPageInformationAlpha(-0.5), 0)
        XCTAssertEqual(previewPageInformationAlpha(0.5), 0)
        XCTAssertEqual(previewPageInformationAlpha(0), 1)
        XCTAssertEqual(previewPageInformationAlpha(0.25), 0.5)
        XCTAssertNil(nearestPreviewPage(offsets: [0: .nan, 1: 2]))
    }

    @MainActor
    func testPreviewPinchObserverAttachesOnceAndDetachesFromWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let root = UIViewController()
        window.rootViewController = root
        let marker = PreviewPinchObserver.Marker(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        root.view.addSubview(marker)
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertTrue(marker.recognizer.view === window)
        XCTAssertFalse(marker.isUserInteractionEnabled)
        marker.didMoveToWindow()
        XCTAssertEqual(window.gestureRecognizers?.filter { $0 === marker.recognizer }.count, 1)
        marker.removeFromSuperview()
        XCTAssertNil(marker.recognizer.view)
        XCTAssertFalse(window.gestureRecognizers?.contains { $0 === marker.recognizer } ?? false)
        root.view.addSubview(marker)
        XCTAssertTrue(marker.recognizer.view === window)
        marker.detach()
        marker.detach()
        XCTAssertNil(marker.recognizer.view)
    }

    func testPreviewAnimatedRotationKeepsTargetDirectionInsets() {
        let placement = photoPreviewPlacement(imageSize: CGSize(width: 400, height: 600),
            viewportSize: CGSize(width: 400, height: 800), rotationDegrees: -30,
            infoBottom: 80, targetRotationDegrees: -90)
        XCTAssertEqual(placement.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(placement.center.y, 440, accuracy: 0.001)
    }

    func testPreviewPlacementAndGesturesShareInformationClearance() {
        let viewport = CGSize(width: 400, height: 800)
        let image = CGSize(width: 400, height: 600)
        let placement = photoPreviewPlacement(imageSize: image, viewportSize: viewport,
                                               rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(placement.size.width, 360, accuracy: 0.001)
        XCTAssertEqual(placement.size.height, 540, accuracy: 0.001)
        XCTAssertEqual(placement.center.y, 428, accuracy: 0.001)
        let offset = photoPreviewClampedOffset(CGSize(width: 1000, height: 1000), scale: 2,
                                               imageSize: image, viewportSize: viewport,
                                               rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(offset, CGSize(width: 160, height: 112))
        let centeredTap = photoPreviewDoubleTapOffset(location: placement.center, scale: 2.5,
                                                      imageSize: image, viewportSize: viewport,
                                                      rotationDegrees: 0, infoBottom: 80)
        XCTAssertEqual(centeredTap, .zero)
        let landscape = photoPreviewPlacement(imageSize: image, viewportSize: viewport,
                                               rotationDegrees: -90, infoBottom: 80)
        XCTAssertEqual(landscape.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(landscape.center.y, 440, accuracy: 0.001)
    }

    func testPreviewTouchSamplesPreservePanAndMultiFingerZoom() {
        let sample = previewTouchTransform(
            previous: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)],
            current: [CGPoint(x: 5, y: 10), CGPoint(x: 45, y: 10)])
        XCTAssertEqual(sample.factor, 2)
        XCTAssertEqual(sample.centroid, CGPoint(x: 25, y: 10))
        XCTAssertEqual(sample.pan, CGSize(width: 15, height: 10))
        let remainingFinger = previewTouchTransform(previous: [CGPoint(x: 10, y: 20)],
                                                    current: [CGPoint(x: 14, y: 27)])
        XCTAssertEqual(remainingFinger.factor, 1)
        XCTAssertEqual(remainingFinger.pan, CGSize(width: 4, height: 7))
        let three = previewTouchTransform(
            previous: [CGPoint(x: -10, y: 0), .zero, CGPoint(x: 10, y: 0)],
            current: [CGPoint(x: -20, y: 0), .zero, CGPoint(x: 20, y: 0)])
        XCTAssertEqual(three.factor, 2)
    }

    func testAndroidPreviewPinchPreservesPixelAtExistingZoom() {
        let old = CGSize(width: 30, height: -50)
        let centroid = CGPoint(x: 80, y: 90)
        let result = previewPinchOffset(offset: old, centroidFromCenter: centroid,
                                        factor: 3.0 / 2, pan: .zero)
        XCTAssertEqual((centroid.x - old.width) / 2 * 3 + result.width, centroid.x)
        XCTAssertEqual((centroid.y - old.height) / 2 * 3 + result.height, centroid.y)
    }

    func testAndroidPreviewPanUsesActualRestingCenter() {
        let image = CGSize(width: 400, height: 600)
        let viewport = CGSize(width: 400, height: 800)
        let center = CGPoint(x: 200, y: 340)
        XCTAssertEqual(clampPreviewPan(scale: 2, offset: CGSize(width: 1000, height: 1000),
                                       image: image, viewport: viewport, center: center),
                       CGSize(width: 200, height: 260))
        XCTAssertEqual(clampPreviewPan(scale: 2, offset: CGSize(width: -1000, height: -1000),
                                       image: image, viewport: viewport, center: center),
                       CGSize(width: -200, height: -140))
        XCTAssertEqual(clampPreviewPan(scale: 1, offset: CGSize(width: 90, height: 120),
                                       image: image, viewport: viewport, center: center), .zero)
    }

    func testAndroidPreviewLayoutNormalCropAndSmallViewport() {
        func layout(_ image: CGFloat, _ progress: CGFloat, alignment: CGFloat = 1,
                    top: CGFloat = 60) -> PreviewPhotoLayout {
            previewPhotoLayout(viewportHeight: 800, imageHeight: image, infoBottom: 80,
                               cropTop: top, cropExtraBottom: 84, progress: progress,
                               cropTopAlignment: alignment)
        }
        XCTAssertEqual(layout(400, 0), PreviewPhotoLayout(scale: 1, centerY: 440))
        for height in [CGFloat(400), CGFloat(1200)] {
            let value = layout(height, 1)
            XCTAssertEqual(value.centerY - height * value.scale / 2, 60, accuracy: 0.001)
            XCTAssertLessThanOrEqual(value.centerY + height * value.scale / 2, 716.001)
        }
        let start = layout(1200, 0), end = layout(1200, 1), middle = layout(1200, 0.5)
        XCTAssertEqual(middle.scale, (start.scale + end.scale) / 2, accuracy: 0.001)
        XCTAssertEqual(middle.centerY, (start.centerY + end.centerY) / 2, accuracy: 0.001)
        let small = previewPhotoLayout(viewportHeight: 100, imageHeight: 1200, infoBottom: 112,
                                      cropTop: 140, cropExtraBottom: 84, progress: 1)
        XCTAssertGreaterThan(small.scale, 0)
        XCTAssertTrue(small.centerY.isFinite)
        let landscape = layout(300, 1, alignment: 0.5, top: 140)
        XCTAssertGreaterThan(landscape.centerY, layout(300, 1, top: 140).centerY)
        XCTAssertLessThan(landscape.centerY, layout(300, 0, top: 140).centerY)
        XCTAssertLessThanOrEqual(landscape.centerY + 150 * landscape.scale, 716)
    }

    func testAndroidPreviewFallbackWaitsForCurrentFHDAndExif() {
        for current in [false, true] {
            for unavailable in [false, true] {
                for finished in [false, true] {
                    XCTAssertEqual(allowPreviewRemoteThumbnailFallback(
                        isCurrent: current, fhdUnavailable: unavailable, exifFinished: finished
                    ), current && unavailable && finished)
                }
            }
        }
    }

    func testPreviewCaptureDateFallsBackFromInvalidTimeAndRejectsInvalidDay() {
        XCTAssertEqual(formatPreviewCaptureDate("20260724T123456"), "2026-07-24 12:34:56")
        XCTAssertEqual(formatPreviewCaptureDate("20260724T996099"), "2026-07-24")
        XCTAssertNil(formatPreviewCaptureDate("20261340T120000"))
        XCTAssertNil(formatPreviewCaptureDate("20260229T120000"))
    }

    func testStorageFilterUsesPhysicalSlotsInsteadOfOpaqueStorageIDs() {
        let firstID: UInt32 = 0x0001_0001
        let secondID: UInt32 = 0x0002_0001
        let mapping = photoStorageIDsBySlot([secondID, firstID])
        XCTAssertEqual(mapping[1], [firstID])
        XCTAssertEqual(mapping[2], [secondID])
        let files = [
            CameraFile(id: 1, storageID: firstID, format: 0x3801, size: 1,
                       fileName: "a.JPG", captureDate: nil, isProtected: false,
                       storageIDs: [firstID]),
            CameraFile(id: 2, storageID: secondID, format: 0x3801, size: 1,
                       fileName: "b.JPG", captureDate: nil, isProtected: false,
                       storageIDs: [secondID]),
        ]
        var filter = PhotoFilterState()
        filter.storageSlot = 2
        XCTAssertEqual(PhotoFilter.apply(files, state: filter, storageIDsBySlot: mapping).map(\.id), [2])
        XCTAssertNil(normalizedPhotoStorageSlot(2, available: [1], scanComplete: true))
        XCTAssertEqual(normalizedPhotoStorageSlot(2, available: [], scanComplete: false), 2)
        XCTAssertTrue(isPhotoStorageSlotSelected(nil, slot: 1))
        XCTAssertTrue(isPhotoStorageSlotSelected(nil, slot: 2))
        XCTAssertEqual(toggledPhotoStorageSlot(nil, toggled: 1, available: [1, 2]), 2)
        XCTAssertEqual(toggledPhotoStorageSlot(2, toggled: 2, available: [1, 2]), 2)
        XCTAssertNil(toggledPhotoStorageSlot(2, toggled: 1, available: [1, 2]))
    }

    func testFilterPersistenceMatchesAndroidAndDoesNotRestoreCameraSlot() throws {
        let suite = "photo-filter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PhotoFilterState(extensions: [".jpg"], protectedOnly: true,
                                     burstOnly: true, untransferredOnly: true,
                                     storageSlot: 2,
                                     dateRange: PhotoDateRange(start: "20260901", end: "20260917"))
        PhotoFilterPersistence.save(state, to: defaults)
        let restored = PhotoFilterPersistence.load(from: defaults)
        XCTAssertEqual(restored.extensions, [".jpg"])
        XCTAssertTrue(restored.protectedOnly)
        XCTAssertTrue(restored.burstOnly)
        XCTAssertTrue(restored.untransferredOnly)
        XCTAssertNil(restored.storageSlot)
        XCTAssertEqual(restored.dateRange, state.dateRange)

        defaults.set("2026-09-17", forKey: "filter_date_start")
        defaults.set("2026-09-01", forKey: "filter_date_end")
        XCTAssertEqual(
            PhotoFilterPersistence.load(from: defaults).dateRange,
            PhotoDateRange(start: "20260901", end: "20260917")
        )
        defaults.set("20260901", forKey: "filter_date_start")
        XCTAssertNil(PhotoFilterPersistence.load(from: defaults).dateRange)
        defaults.set("2026-02-29", forKey: "filter_date_start")
        defaults.set("2026-03-01", forKey: "filter_date_end")
        XCTAssertNil(PhotoFilterPersistence.load(from: defaults).dateRange)
    }

    func testRatingLoaderAloneKeepsGridUnfilteredAndConcreteStarMatchesKnownValuesOnly() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                       fileName: "one.JPG", captureDate: nil, isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                       fileName: "two.JPG", captureDate: nil, isProtected: false),
            CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1,
                       fileName: "unknown.JPG", captureDate: nil, isProtected: false),
        ]
        var loaderOnly = PhotoFilterState()
        loaderOnly.ratingEnabled = true
        XCTAssertEqual(PhotoFilter.apply(files, state: loaderOnly,
                                         ratingValues: [1: .known(5), 2: .known(2), 3: .unknown]).map(\.id), [1, 2, 3])

        var concrete = loaderOnly
        concrete.rating = 5
        XCTAssertEqual(PhotoFilter.apply(files, state: concrete,
                                         ratingValues: [1: .known(5), 2: .known(2), 3: .unknown]).map(\.id), [1])

        concrete.ratingEnabled = false
        XCTAssertTrue(PhotoFilter.apply(files, state: concrete,
                                        ratingValues: [1: .known(5), 2: .known(2)]).isEmpty)
    }

    func testRatingRangePersistenceNormalizesOnlyAndroidChoicesAndDoesNotRestoreLoader() throws {
        let suite = "photo-rating-range-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: PhotoFilterPersistence.ratingDaysKey)
        var restored = PhotoFilterPersistence.load(from: defaults)
        XCTAssertEqual(restored.ratingDays, 5)
        XCTAssertFalse(restored.ratingEnabled)
        XCTAssertNil(restored.rating)

        defaults.set(2, forKey: PhotoFilterPersistence.ratingDaysKey)
        restored = PhotoFilterPersistence.load(from: defaults)
        XCTAssertEqual(restored.ratingDays, 5)
        defaults.set(0, forKey: PhotoFilterPersistence.ratingDaysKey)
        XCTAssertEqual(PhotoFilterPersistence.load(from: defaults).ratingDays, 0)
    }

    func testSTADirectStorageLayoutRejectsCrossSlotAggregateMembership() {
        let reliable = analyzeSTADirectStorageLayout([
            (0x0001_0001, [1, 2]),
            (0x0002_0001, [3, 4]),
        ])
        XCTAssertEqual(reliable.storageIDsByHandle[1], [0x0001_0001])
        XCTAssertEqual(reliable.filterStorageIDs, [0x0001_0001, 0x0002_0001])

        let ambiguous = analyzeSTADirectStorageLayout([
            (0x0001_0001, [1, 2]),
            (0x0002_0001, [1, 2]),
        ])
        XCTAssertEqual(ambiguous.crossSlotOverlapCount, 2)
        XCTAssertTrue(ambiguous.storageIDsByHandle.isEmpty)
        XCTAssertTrue(ambiguous.filterStorageIDs.isEmpty)
    }

    func testRemovedPrimaryHandleSwitchesToSurvivingDualCardAlias() {
        let firstID: UInt32 = 0x0001_0001
        let secondID: UInt32 = 0x0002_0001
        let primary = CameraFile(id: 10, storageID: firstID, format: 0x3801, size: 100,
                                 fileName: "same.JPG", captureDate: "20260917T120000",
                                 isProtected: false, storageIDs: [firstID, secondID])
        let alias = CameraFile(id: 20, storageID: secondID, format: 0x3801, size: 100,
                               fileName: "same.JPG", captureDate: "20260917T120000",
                               isProtected: false, storageIDs: [secondID])
        let reconciled = reconcilePublishedCameraFiles([primary], currentHandles: [20], indexedByHandle: [20: alias])
        XCTAssertEqual(reconciled.map(\.id), [20])
        XCTAssertEqual(reconciled.first?.storageIDs, [secondID])
        XCTAssertEqual(PublishedPhotoIdentity(primary), PublishedPhotoIdentity(alias))
    }

    func testExpandedBurstFollowsSurvivingLogicalMembersWhenGroupIDChanges() {
        let first = remoteLifecycleFile(10, name: "DSC_0001.JPG", captureDate: "20260917T120000")
        let second = remoteLifecycleFile(11, name: "DSC_0002.JPG", captureDate: "20260917T120001")
        let third = remoteLifecycleFile(12, name: "DSC_0003.JPG", captureDate: "20260917T120002")
        let replacementFirst = remoteLifecycleFile(20, name: "DSC_0001.JPG", captureDate: "20260917T120000")
        let previous = BurstPhotoGroup(id: "old", files: [first, second, third])
        let current = BurstPhotoGroup(id: "new", files: [replacementFirst, second, third])

        XCTAssertEqual(reconciledExpandedBurstIDs(previousGroups: [previous],
                                                  currentGroups: [current],
                                                  expandedIDs: ["old"]),
                       ["new"])
        XCTAssertEqual(reconciledExpandedBurstIDs(previousGroups: [previous],
                                                  currentGroups: [current],
                                                  expandedIDs: []),
                       [])
    }

    func testCameraRemovalDaysIgnoreInitialAdditionsAndSurvivingAliases() {
        let first = remoteLifecycleFile(10, name: "A.JPG", captureDate: "20260917T120000")
        let second = remoteLifecycleFile(11, name: "B.JPG", captureDate: "20260916T120000")
        let alias = remoteLifecycleFile(20, name: "A.JPG", captureDate: "20260917T120000")

        XCTAssertEqual(publishedCameraRemovalDays(previous: [], current: [first]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first], current: [first, second]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first, second], current: [alias, second]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first, second], current: []),
                       ["20260917", "20260916"])
    }

    func testUntransferredExitOnlyIncludesNewQueueBackedOriginals() {
        let waiting = remoteLifecycleFile(31, name: "WAIT.JPG", captureDate: "20260917T120000")
        let completed = remoteLifecycleFile(32, name: "DONE.JPG", captureDate: "20260917T120001")
        let failed = remoteLifecycleFile(33, name: "FAIL.JPG", captureDate: "20260917T120002")
        let items = [
            TransferQueueItem(id: UUID(), file: waiting, status: .waiting),
            TransferQueueItem(id: UUID(), file: completed, status: .completed),
            TransferQueueItem(id: UUID(), file: failed, status: .failed),
        ]
        XCTAssertEqual(newlyExitingTransferredFileIDs(
            previous: [31], current: [31, 32, 33, 99], queueItems: items, untransferredOnly: true
        ), [32])
        XCTAssertEqual(newlyExitingTransferredFileIDs(
            previous: [], current: [32], queueItems: items, untransferredOnly: false
        ), [])
    }

    func testDualCardHeadSelectionMatchesAndroidMissingDateAndStableTieRules() {
        let dated = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                               fileName: "dated.JPG", captureDate: "20260914T010000", isProtected: false)
        let missing = CameraFile(id: 2, storageID: 2, format: 0x3801, size: 1,
                                 fileName: "missing.JPG", captureDate: nil, isProtected: false)
        XCTAssertEqual(selectNewestPhotoHeadIndex([dated, missing]), 1)

        let sameDateA = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1,
                                   fileName: "a.JPG", captureDate: "20260914T020000", isProtected: false)
        let sameDateB = CameraFile(id: 4, storageID: 2, format: 0x3801, size: 1,
                                   fileName: "b.JPG", captureDate: "20260914T020000", isProtected: false)
        XCTAssertEqual(selectNewestPhotoHeadIndex([sameDateA, sameDateB]), 0)
    }

    func testPhotoScanSnapshotResumeKeepsOnlyUnprocessedHandlesPerCard() {
        let snapshot = PhotoScanSnapshot(
            storageIDs: [1, 2],
            handleOrders: [(storageID: 1, handles: [11, 10]),
                           (storageID: 2, handles: [21, 20])],
            processedHandles: [11, 21],
            handleQueriesSucceeded: true,
        )

        XCTAssertEqual(snapshot.remainingHandles.map(\.storageID), [1, 2])
        XCTAssertEqual(snapshot.remainingHandles.map(\.handles), [[10], [20]])
    }

    @MainActor
    func testRemotePauseSetsGateBeforeWaitingAndResumeUsesFreshHandles() async throws {
        let old = remoteLifecycleFile(1, name: "old.JPG")
        let added = remoteLifecycleFile(2, name: "added.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)

        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }
        await model.pauseForRemote()

        let pausedGates = await harness.gateChanges
        XCTAssertEqual(pausedGates, [true])
        XCTAssertEqual(model.loadState, .idle)
        await harness.setResumeFiles([old, added])
        await model.resumeAfterRemote(isConnected: true)
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }

        let calls = await harness.scanCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], RemoteListLifecycleHarness.ScanCall(preserve: false, hasSnapshot: false, detectNew: false))
        XCTAssertEqual(calls[1], RemoteListLifecycleHarness.ScanCall(preserve: true, hasSnapshot: false, detectNew: true))
        let resumedGates = await harness.gateChanges
        XCTAssertEqual(resumedGates, [true, false])
        XCTAssertEqual(model.availableFiles.map(\.id), [1, 2])
    }

    @MainActor
    func testRemotePauseKeepsAcceptedBatchAndFreshResumeReconcilesIt() async throws {
        let retained = remoteLifecycleFile(11, name: "retained.JPG")
        let removed = remoteLifecycleFile(12, name: "removed.JPG")
        let added = remoteLifecycleFile(13, name: "added.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [retained, removed])
        let model = remoteLifecycleModel(harness)

        model.load()
        try await waitForRemoteLifecycle { model.availableFiles.count == 2 }
        await model.pauseForRemote()
        XCTAssertEqual(model.availableFiles.map(\.id), [11, 12])
        XCTAssertFalse(model.hasCompletedFileScan)

        await harness.setResumeFiles([retained, added], removed: [removed.id], added: [added.id])
        await model.resumeAfterRemote(isConnected: true)
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        XCTAssertEqual(model.availableFiles.map(\.id), [11, 13])
    }

    @MainActor
    func testRemoteDisconnectReleasesGateWithoutStartingOldSessionScan() async throws {
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)
        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }

        await model.pauseForRemote()
        await model.resumeAfterRemote(isConnected: false)
        try await Task.sleep(nanoseconds: 20_000_000)

        let gates = await harness.gateChanges
        let scans = await harness.scanCount
        XCTAssertEqual(gates, [true, false])
        XCTAssertEqual(scans, 1)
        XCTAssertFalse(model.isLoadingFiles)
    }

    @MainActor
    func testRemoteResumeWaitsForActivePreviewBeforeFreshHandleScan() async throws {
        let file = remoteLifecycleFile(21, name: "after-preview.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)
        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }
        await model.pauseForRemote()

        model.pauseForPreview()
        await harness.setResumeFiles([file])
        await model.resumeAfterRemote(isConnected: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        let scansWhilePreviewing = await harness.scanCount
        XCTAssertEqual(scansWhilePreviewing, 1)

        model.resumeAfterPreview()
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        let scansAfterPreview = await harness.scanCount
        XCTAssertEqual(scansAfterPreview, 2)
        XCTAssertEqual(model.availableFiles.map(\.id), [21])
    }

    func testThumbnailFillQueuePreservesSameDateEnumerationOrder() async {
        let queue = PhotoThumbnailFillQueue()
        let first = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                               fileName: "a.JPG", captureDate: "20260914T020000", isProtected: false)
        let second = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                                fileName: "b.JPG", captureDate: "20260914T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([first, second])
        let firstPolled = await queue.poll()
        let secondPolled = await queue.poll()
        XCTAssertEqual(firstPolled?.id, first.id)
        XCTAssertEqual(secondPolled?.id, second.id)
        XCTAssertEqual(firstPolled?.revision, secondPolled?.revision)
    }

    func testThumbnailFillQueueWakeReleasesAnEmptyWorker() async {
        let queue = PhotoThumbnailFillQueue()
        let waiter = Task {
            await queue.waitForWake()
            return true
        }
        await Task.yield()
        await queue.wake()
        let released = await waiter.value
        XCTAssertTrue(released)
    }

    func testThumbnailFillQueueRetriesFailedItemsOnlyAfterWakeBoundary() async {
        let queue = PhotoThumbnailFillQueue()
        let file = CameraFile(id: 31, storageID: 1, format: 0x3801, size: 1,
                              fileName: "retry.JPG", captureDate: "20260914T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([file])
        _ = await queue.poll()
        await queue.markFailed(file.id)
        let beforeWake = await queue.poll()
        XCTAssertNil(beforeWake)
        await queue.wake()
        await queue.waitForWake()
        await queue.retryFailed()
        let retried = await queue.poll()
        XCTAssertEqual(retried?.id, file.id)
    }

    func testThumbnailFillQueueDoesNotRequeueAcrossScanRevision() async {
        let queue = PhotoThumbnailFillQueue()
        let first = CameraFile(id: 11, storageID: 1, format: 0x3801, size: 1,
                               fileName: "first.JPG", captureDate: "20260914T020000", isProtected: false)
        let second = CameraFile(id: 12, storageID: 1, format: 0x3801, size: 1,
                                fileName: "second.JPG", captureDate: "20260914T010000", isProtected: false)
        await queue.beginScan()
        await queue.seed([first])
        let stale = await queue.poll()
        await queue.beginScan()
        await queue.seed([second])
        if let stale { await queue.returnToFront(stale.id, expectedRevision: stale.revision) }
        let next = await queue.poll()
        XCTAssertEqual(next?.id, second.id)
    }

    func testThumbnailFillQueuePreservesDatePriorityAcrossBeginScan() async {
        let queue = PhotoThumbnailFillQueue()
        let inRange = CameraFile(id: 21, storageID: 1, format: 0x3801, size: 1,
                                 fileName: "in-range.JPG", captureDate: "20260914T020000", isProtected: false)
        let outOfRange = CameraFile(id: 22, storageID: 1, format: 0x3801, size: 1,
                                    fileName: "out-of-range.JPG", captureDate: "20260913T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([], priorityRange: PhotoDateRange(start: "20260914", end: "20260914"))
        await queue.beginScan()
        await queue.enqueueNew([outOfRange, inRange])

        let first = await queue.poll()
        let second = await queue.poll()
        XCTAssertEqual(first?.id, inRange.id)
        XCTAssertEqual(second?.id, outOfRange.id)
    }

    func testPhotoLoadingRangeCountsNewestActualShootingDays() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                       fileName: "new.JPG", captureDate: "20261006T120000", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                       fileName: "gap.JPG", captureDate: "20261004T120000", isProtected: false),
            CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1,
                       fileName: "old.JPG", captureDate: "20261001T120000", isProtected: false),
            CameraFile(id: 4, storageID: 1, format: 0x3801, size: 1,
                       fileName: "bad.JPG", captureDate: "20261340T120000", isProtected: false),
        ]
        let range = newestCaptureDaysRange(files, days: 2)
        XCTAssertEqual(range, PhotoDateRange(start: "20261004", end: "20261006"))
        XCTAssertTrue(range?.contains("20261006T000000") == true)
        XCTAssertTrue(range?.contains("20261004T000000") == true)
        XCTAssertFalse(range?.contains("20261001T000000") == true)
        XCTAssertNil(newestCaptureDaysRange(files, days: 0))
    }

    func testPhotoLoadingRangePersistenceNormalizesUnknownValues() {
        let suiteName = "com.ztransfer.photo-loading-range.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhotoFilterPersistence.savePhotoLoadingRange(.five, to: defaults)
        XCTAssertEqual(PhotoFilterPersistence.loadPhotoLoadingRange(from: defaults), .five)
        defaults.set(2, forKey: PhotoFilterPersistence.photoLoadingRangeKey)
        XCTAssertEqual(PhotoFilterPersistence.loadPhotoLoadingRange(from: defaults), .all)
    }

    func testThumbnailLoadingRangeDropsOutOfScopeWorkAndReadmitsOnWiden() async {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                       fileName: "new.JPG", captureDate: "20261006T120000", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                       fileName: "old.JPG", captureDate: "20261001T120000", isProtected: false),
        ]
        let queue = PhotoThumbnailFillQueue(sequential: true)
        await queue.beginScan()
        await queue.seed(files, loadingRange: PhotoDateRange(start: "20261006", end: "20261006"))
        let first = await queue.poll()
        XCTAssertEqual(first?.id, 1)
        if let first { await queue.markSettled(first.id) }
        let outOfScope = await queue.poll()
        XCTAssertNil(outOfScope)

        await queue.updateLoadingRange(files, range: nil)
        await queue.seed(files, loadingRange: nil)
        let admitted = await queue.poll()
        XCTAssertEqual(admitted?.id, 2)
    }

    func testBurstGroupingMatchesConsecutiveNameAndOneSecondRule() {
        let files = (100...102).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(n).JPG", captureDate: "20260913T01020\(n - 100)", isProtected: false)
        }
        XCTAssertEqual(PhotoCatalogGrouping.bursts(in: files).first?.files.map(\.id), [UInt32(100), UInt32(101), UInt32(102)])
    }

    func testPreviewUsesIndependentCollapsedBurstPageAndRestoresMembersOnExpand() {
        let files = (100...103).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(n).JPG", captureDate: n == 103 ? "20260913T010204" : "20260913T01020\(n - 100)", isProtected: false)
        }
        let collapsed = collapsedPhotoPreviewEntries(files: files)
        XCTAssertEqual(collapsed.count, 2)
        guard case .burst(let group) = collapsed[0] else {
            return XCTFail("the first three consecutive shots must be one collection page")
        }
        XCTAssertEqual(group.files.map(\.id), [100, 101, 102])
        let expanded = expandPhotoPreviewBurst(collapsed, at: 0)
        XCTAssertEqual(expanded.compactMap(\.file).map(\.id), [100, 101, 102, 103])
        XCTAssertEqual(photoPreviewCollectionIndex(expanded, memberIndex: 2), 0)
        let collapsedAgain = collapsePhotoPreviewBurst(expanded, burstID: group.id)
        XCTAssertEqual(collapsedAgain, collapsed)
    }

    func testBurstOpeningSnapshotSelectsMemberWithoutExpandingOtherCollections() {
        let files = (1...7).map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(id).JPG", captureDate: "20261016T120000", isProtected: false)
        }
        let membership: [UInt32: String] = [2: "a", 3: "a", 4: "b", 5: "b", 6: "c", 7: "c"]
        let gridExpanded: Set<String> = ["a"]
        let opening = PhotoPreviewOpeningSnapshot(
            files: files, burstIDByFile: membership, collapseBursts: true,
            expandedBurstIDs: gridExpanded.union(["b"]), selectedFileID: 4
        )
        XCTAssertEqual(gridExpanded, ["a"])
        XCTAssertEqual(opening.entries.map(\.id), ["photo_1", "preview_burst_a", "photo_2", "photo_3",
                                                    "preview_burst_b", "photo_4", "photo_5", "preview_burst_c"])
        XCTAssertEqual(opening.index, 5)
        XCTAssertEqual(opening.entries[opening.index].file?.id, 4)
        XCTAssertEqual(photoPreviewCollectionIndex(opening.entries, memberIndex: opening.index), 4)
        let collapsed = collapsePhotoPreviewBurst(opening.entries, burstID: "b")
        XCTAssertEqual(collapsed.compactMap(\.file).map(\.id), [1, 2, 3])
        XCTAssertEqual(opening.entries.count, 8, "Explicit preview changes cannot mutate the opening snapshot")

        let ordinary = PhotoPreviewOpeningSnapshot(files: files, burstIDByFile: membership,
            collapseBursts: true, expandedBurstIDs: gridExpanded, selectedFileID: 3)
        XCTAssertEqual(ordinary.entries[ordinary.index].file?.id, 3)
        XCTAssertFalse(ordinary.entries.contains { $0.file?.id == 4 })
        let ungrouped = PhotoPreviewOpeningSnapshot(files: files, burstIDByFile: membership,
            collapseBursts: false, expandedBurstIDs: [], selectedFileID: 7)
        XCTAssertEqual(ungrouped.entries.compactMap(\.file), files)
        XCTAssertEqual(ungrouped.index, 6)
    }

    func testPreviewDoesNotTreatNonFirstBurstMemberAsCollectionPage() {
        let files = (200...202).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(n).JPG", captureDate: "20260913T02030\(n - 200)", isProtected: false)
        }
        let entries = collapsedPhotoPreviewEntries(files: files)
        XCTAssertEqual(entries.count, 1)
        let expanded = expandPhotoPreviewBurst(entries, at: 0)
        XCTAssertEqual(expanded.compactMap(\.burstID).count, 3)
        XCTAssertNil(photoPreviewCollectionIndex(expanded, memberIndex: 0))
    }

    func testBurstIdentitySurvivesDisablingCollectionsAndFilteringToOneMember() {
        let originals = (300...302).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(number).JPG", captureDate: "20260913T02030\(number - 300)", isProtected: false)
        }
        let group = PhotoCatalogGrouping.bursts(in: originals)[0]
        let membership = Dictionary(uniqueKeysWithValues: group.files.map { ($0.id, group.id) })
        let single = collapsedPhotoPreviewEntries(files: [originals[1]], burstIDByFile: membership)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].burstID, group.id)
        let dispersed = originals.map { PhotoPreviewEntry.photo($0, burstID: membership[$0.id]) }
        XCTAssertEqual(dispersed.compactMap(\.burstID).count, 3)
        XCTAssertTrue(dispersed.allSatisfy { $0.file != nil })
        XCTAssertNil(photoPreviewCollectionIndex(dispersed, memberIndex: 0))
    }

    func testPreviewRetainsOnlyTwoPagesAroundCurrentAndSkipsCollectionBitmap() {
        let files = (1...7).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let collection = BurstPhotoGroup(id: "burst", files: [files[2], files[3]])
        let entries: [PhotoPreviewEntry] = [
            .photo(files[0]), .photo(files[1]), .burst(collection), .photo(files[4]),
            .photo(files[5]), .photo(files[6])
        ]

        XCTAssertEqual(retainedPhotoPreviewIDs(entries: entries, currentIndex: 3), [2, 5, 6, 7])
        XCTAssertEqual(retainedPhotoPreviewIDs(entries: entries, currentIndex: 0), [1, 2])
    }

    func testPreviewRetentionChangesWhenBurstExpandsAtUnchangedCurrentIndex() {
        let files = (1...7).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let group = BurstPhotoGroup(id: "retention-burst", files: Array(files[2...4]))
        let collapsed: [PhotoPreviewEntry] = [.photo(files[0]), .photo(files[1]), .burst(group), .photo(files[5]), .photo(files[6])]
        let expanded = expandPhotoPreviewBurst(collapsed, at: 2)
        XCTAssertEqual(collapsed[1].id, expanded[1].id)
        XCTAssertEqual(retainedPhotoPreviewIDs(entries: collapsed, currentIndex: 1), [1, 2, 6])
        // The collection page remains at index 2; only the first member fits the window.
        XCTAssertEqual(retainedPhotoPreviewIDs(entries: expanded, currentIndex: 1), [1, 2, 3])
        let restored = collapsePhotoPreviewBurst(expanded, burstID: group.id)
        XCTAssertEqual(retainedPhotoPreviewIDs(entries: restored, currentIndex: 1), [1, 2, 6])
    }

    func testPreviewNeighborsUsePreviousThenNextPageOrder() {
        let files = (1...3).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let entries = files.map { PhotoPreviewEntry.photo($0) }
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 1), [0, 2])
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 0), [1])
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 2), [1])
    }

    func testManualQueueAllowsRepeatedExportsOfSameCameraHandle() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueTests.\(UUID())")!)
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: nil, isProtected: false)
        let first = await queue.enqueue(file)
        let second = await queue.enqueue(file)
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
        let snapshot = await queue.snapshots().first(where: { _ in true })
        XCTAssertEqual(snapshot?.items.count, 2)
    }

    func testTransferQueueIgnoresPauseRequestWhileIdle() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueIdlePauseTests")!)
        await queue.pauseAfterCurrentFile()
        let paused = await queue.pauseAfterCurrent
        XCTAssertFalse(paused)
    }

    func testTransferQueueItemKeepsIndependentEffectSnapshotForQueuedExport() {
        let file = CameraFile(id: 44, storageID: 1, format: 0x3801, size: 10,
                              fileName: "snapshot.JPG", captureDate: "20260914T010203", isProtected: false)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFramePreset = .minimal
        effects.watermark.text = "Locked"
        effects.photoFilterEnabled = true
        effects.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "NP3_FILM", name: "Film"), intensityPercent: 63
        )
        let item = TransferQueueItem(id: UUID(), file: file, effects: effects)
        let snapshot = effects
        effects.photoFramePreset = .mist
        effects.watermark.text = "Changed"
        XCTAssertEqual(item.effects, snapshot)
        XCTAssertTrue(item.effects?.hasEffect == true)
    }

    func testQueueDoesNotRestoreLegacyIOSOnlyTaskHistory() async {
        let suite = "TransferQueueLegacyTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.set(Data("[{\"status\":\"transferring\"}]".utf8), forKey: "transferQueue.items.v1")
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let state = await queue.snapshot()
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isTransferring)
        XCTAssertFalse(state.pauseAfterCurrent)
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "transferQueue.items.v1"))
        _ = await queue.enqueue(CameraFile(id: 45, storageID: 1, format: 0x3801, size: 10,
                                          fileName: "queued.JPG", captureDate: nil, isProtected: false))
        let reopened = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let fresh = await reopened.snapshot()
        XCTAssertTrue(fresh.items.isEmpty)
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "transferQueue.items.v1"))
    }

    func testAutomaticQueueDeduplicatesCameraIdentity() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueTests.\(UUID())")!)
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false)
        let first = await queue.enqueueAutomatic(file)
        let second = await queue.enqueueAutomatic(file)
        XCTAssertNotNil(first); XCTAssertNil(second)
        let changedHandle = CameraFile(id: 10, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false)
        let duplicateIdentity = await queue.enqueueAutomatic(changedHandle)
        XCTAssertNil(duplicateIdentity)
    }

    func testTransferQueueUsesExistingDestinationAsSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10, fileName: "same.JPG", captureDate: nil, isProtected: false)
        XCTAssertNil(existingTransferDestination(for: file, in: directory))
        FileManager.default.createFile(atPath: directory.appendingPathComponent(file.fileName).path, contents: Data(repeating: 0, count: 10))
        XCTAssertEqual(existingTransferDestination(for: file, in: directory)?.lastPathComponent, "same.JPG")
        let unknownSize = CameraFile(id: file.id, storageID: file.storageID, format: file.format, size: UInt64(UInt32.max), fileName: file.fileName, captureDate: file.captureDate, isProtected: file.isProtected)
        XCTAssertEqual(existingTransferDestination(for: unknownSize, in: directory)?.lastPathComponent, "same.JPG")
    }

    func testAndroidPhotoFrameOutputNameUsesVersionedRenderingIdentity() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .mist
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_frame_mist_wf1e19ec880e4.jpg"
        )

        settings.photoFrameBorderEnabled = false
        settings.watermark.enabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "NP3_FILM", name: "Film"),
            intensityPercent: 63
        )
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_filter_feba63950i64.jpg"
        )

        settings.watermark.enabled = true
        settings.photoFrameEnabled = false
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_filter_feba63950i64.jpg"
        )
    }

    func testImageWatermarkOutputIdentityUsesItsRenderedPhotoPosition() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.watermark.enabled = true
        settings.watermark.content = .image
        settings.watermark.imageHash = String(repeating: "a", count: 64)
        settings.watermark.position = .left
        let constrained = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        settings.watermark.position = .photoBottomCenter
        let explicit = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        XCTAssertEqual(constrained, explicit)
    }

    func testWatermarkOnlyOutputIdentityIgnoresHiddenFrameMetadata() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = false
        settings.watermark.enabled = true
        let baseline = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        settings.metadataByPreset[PhotoFramePreset.mist.rawValue] = .init(
            showDate: true, showTime: true, showCoordinates: true, showAltitude: true
        )

        XCTAssertEqual(
            baseline,
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)
        )
    }

    func testGeneratedPhotoFrameNameTreatsOccupiedNamesCaseInsensitively() {
        XCTAssertEqual(
            uniquePhotoFrameName(
                "DSC_0123_frame_mist.jpg",
                occupied: ["dsc_0123_FRAME_MIST.JPG", "DSC_0123_frame_mist (1).jpg"]
            ),
            "DSC_0123_frame_mist (2).jpg"
        )
        let occupied = Set(
            ["DSC_0123_frame_mist.jpg"] +
            (1...999).map { "DSC_0123_frame_mist (\($0)).jpg" }
        )
        XCTAssertEqual(
            uniquePhotoFrameName(
                "DSC_0123_frame_mist.jpg", occupied: occupied, fallbackMillis: 12345
            ),
            "DSC_0123_frame_mist_12345.jpg"
        )
    }

    func testTransferDateFolderMatchesAndroidAndFallsBackForInvalidDate() {
        let fallback = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 21))!
        XCTAssertEqual(transferDateFolderName("20260817T142530", fallback: fallback), "ZT2026-08-17")
        XCTAssertEqual(transferDateFolderName("20260231T120000", fallback: fallback), "ZT2026-03-21")
        XCTAssertEqual(transferDateFolderName(nil, fallback: fallback), "ZT2026-03-21")
    }

    func testTransferDestinationDirectoryKeepsRootAndDatedFoldersSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dated = transferDestinationDirectory(root: root, folderName: "ZT2026-08-17")
        XCTAssertEqual(dated.lastPathComponent, "ZT2026-08-17")
        XCTAssertEqual(transferDestinationDirectory(root: root, folderName: nil), root)
    }

    func testStorageModeUsesAndroidTypePrefixAndProviderSafeNames() {
        let jpg = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                             fileName: " DSC_0001.jpg ", captureDate: nil, isProtected: false)
        let noExtension = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 10,
                                     fileName: "DSC_0002", captureDate: nil, isProtected: false)
        XCTAssertEqual(storageTypeFolderName(jpg.fileName, mode: .byType), "ZT-JPG")
        XCTAssertEqual(transferStorageFolderName(file: noExtension, mode: .byType), "ZT-UNKNOWN")
        XCTAssertTrue(isValidTransferFolderName("ZT-JPG"))
        XCTAssertTrue(isValidTransferFolderName("ZT2026-08-17"))
        XCTAssertFalse(isValidTransferFolderName("../JPG"))
        XCTAssertFalse(isValidTransferFolderName(""))
    }

    func testStorageModeMigrationPreservesLegacyDateChoiceAndSavesThreeWayValue() {
        let suite = "StorageModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TransferStorageMode.legacyByDateKey)
        XCTAssertEqual(TransferStorageMode.load(from: defaults), .byDay)
        XCTAssertEqual(defaults.string(forKey: TransferStorageMode.persistenceKey), "BY_DAY")
        TransferStorageMode.byType.save(to: defaults)
        XCTAssertEqual(TransferStorageMode.load(from: defaults), .byType)
        XCTAssertFalse(defaults.bool(forKey: TransferStorageMode.legacyByDateKey))
    }

    func testStorageModeDestinationSnapshotSeparatesQueuedTypeFolders() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "StorageQueueTests.\(UUID())")!)
        let jpg = CameraFile(id: 11, storageID: 1, format: 0x3801, size: 10,
                             fileName: "DSC_0011.JPG", captureDate: "20260817T142530", isProtected: false)
        let nef = CameraFile(id: 12, storageID: 1, format: 0x3801, size: 10,
                             fileName: "DSC_0012.NEF", captureDate: "20260817T142530", isProtected: false)
        await queue.enqueue([jpg, nef], storageMode: .byType)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.destinationFolderName), ["ZT-JPG", "ZT-NEF"])
    }

    func testStorageChildDirectoryExcludesDerivedFramesAndHonorsMode() {
        XCTAssertFalse(transferStorageChildDirectory("ZTFrames", mode: .byType))
        XCTAssertTrue(transferStorageChildDirectory("ZT-JPG", mode: .byType))
        XCTAssertTrue(transferStorageChildDirectory("ZT2026-08-17", mode: .byDay))
        XCTAssertFalse(transferStorageChildDirectory("ZT-JPG", mode: .byDay))
        XCTAssertFalse(transferStorageChildDirectory("root", mode: .unified))
    }

    func testQueueLocksDestinationFolderWhenEnqueued() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferDestinationTests.\(UUID())")!)
        let file = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10,
                              fileName: "same.JPG", captureDate: "20260817T142530", isProtected: false)
        await queue.enqueue(file, organizeByDate: true)
        await queue.enqueue(file, organizeByDate: false)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].destinationFolderName, "ZT2026-08-17")
        XCTAssertNil(snapshot.items[1].destinationFolderName)
    }

    func testTransferPartialIdentityAndResumeBoundaryMatchAndroid() {
        XCTAssertEqual(
            transferPartialFileName(size: 42, captureDate: "20260817T142530", fileName: "A_B.JPG"),
            ".nkpart_42.20260817T142530_A_B.JPG"
        )
        XCTAssertNil(transferResumeOffset(existingSize: 1024, totalSize: 20_000_000, reportedSize: 20_000_000))
        XCTAssertEqual(
            transferResumeOffset(existingSize: 4 * 1024 * 1024 + 7, totalSize: 20_000_000, reportedSize: 20_000_000),
            4 * 1024 * 1024
        )
        XCTAssertEqual(
            transferResumeOffset(existingSize: 8 * 1024 * 1024, totalSize: 8 * 1024 * 1024, reportedSize: 8 * 1024 * 1024),
            8 * 1024 * 1024
        )
    }

    func testTransferChunkStrategyPreservesWirelessThresholdsAndBoundsImageCaptureUSB() {
        XCTAssertTrue(shouldUsePartialObjectDownload(partialObjectSupported: nil, effectiveSize: 1))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: nil,
            effectiveSize: UInt64(UInt32.max)
        ))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            isUSBConnection: true
        ))
        XCTAssertTrue(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            resumeOffset: 4 * 1024 * 1024, isUSBConnection: true
        ))
        XCTAssertTrue(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            isUSBConnection: true, forcePartial: true
        ))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: false, effectiveSize: 1024
        ))
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 1), 4 * 1024 * 1024)
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 600 * 1024 * 1024), 32 * 1024 * 1024)
        // ImageCaptureCore completes pass-through requests with one in-memory
        // Data value; iOS USB deliberately does not copy Android's 64 MiB raw
        // bulk-endpoint chunk.
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 600 * 1024 * 1024, isUSBConnection: true), 4 * 1024 * 1024)
    }

    func testTransferOutputNeverOverwritesAnExistingSameNameFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("DSC_0001.JPG")
        FileManager.default.createFile(atPath: original.path, contents: Data([1]))
        let temporary = directory.appendingPathComponent(".nkpart_test")
        for index in 1...2 {
            try Data([2]).write(to: temporary)
            let output = try finalizeTransferTemporary(temporary: temporary, directory: directory, fileName: "DSC_0001.JPG")
            XCTAssertEqual(output.lastPathComponent, "DSC_0001 (\(index)).JPG")
            XCTAssertEqual(try Data(contentsOf: output), Data([2]))
        }
        XCTAssertEqual(try Data(contentsOf: original), Data([1]))
    }

    func testTransferDirectoryIndexMatchesNameAndSizeAndKeepsPartialSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("DSC_0001 (2).JPG")
        FileManager.default.createFile(atPath: original.path, contents: Data(repeating: 1, count: 10))
        let partial = directory.appendingPathComponent(".nkpart_10.20260817T142530_DSC_0001.JPG")
        FileManager.default.createFile(atPath: partial.path, contents: Data(repeating: 1, count: 4))
        let index = TransferDirectoryIndex.scan(directory: directory)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        XCTAssertEqual(index.existingOriginal(for: file)?.lastPathComponent, "DSC_0001 (2).JPG")
        XCTAssertEqual(index.partials.count, 1)
        let differentSize = CameraFile(id: file.id, storageID: file.storageID, format: file.format,
                                       size: 11, fileName: file.fileName, captureDate: file.captureDate,
                                       isProtected: file.isProtected)
        XCTAssertNil(index.existingOriginal(for: differentSize))
    }

    func testStartupCleanupRemovesOnlyAndroidTemporaryFilesInRootAndDatedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dated = root.appendingPathComponent("ZT2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleRootPart = root.appendingPathComponent(".nkpart_10.20260817T142530_a.JPG")
        let staleRootFrame = root.appendingPathComponent(".nkframe_old_a.jpg")
        let staleDatedPart = dated.appendingPathComponent(".nkpart_20.20260817T142531_b.JPG")
        let ordinary = root.appendingPathComponent("keep.JPG")
        for file in [staleRootPart, staleRootFrame, staleDatedPart, ordinary] {
            FileManager.default.createFile(atPath: file.path, contents: Data([1]))
        }

        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: root), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRootPart.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRootFrame.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDatedPart.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.path))
    }

    func testPhotoFilterAppliesTypeProtectionStorageAndDate() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: true),
            CameraFile(id: 2, storageID: 2, format: 0xB101, size: 1, fileName: "b.NEF", captureDate: "20260912T010203", isProtected: false),
        ]
        let state = PhotoFilterState(extensions: [".jpg"], protectedOnly: true, untransferredOnly: true, storageSlot: 1, dateRange: PhotoDateRange(start: "20260913", end: "20260913"))
        let storageIDsBySlot: [UInt32: Set<UInt32>] = [1: [1], 2: [2]]
        XCTAssertEqual(PhotoFilter.apply(files, state: state, transferredIDs: [],
                                         storageIDsBySlot: storageIDsBySlot).map(\.id), [1])
        XCTAssertTrue(PhotoFilter.apply(files, state: state, transferredIDs: [1],
                                        storageIDsBySlot: storageIDsBySlot).isEmpty)
    }

    func testSTAProtectionFilterIsUnavailableButPreferenceSurvives() {
        let protected = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                                   fileName: "protected.JPG", captureDate: nil, isProtected: true)
        let unprotected = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                                     fileName: "plain.JPG", captureDate: nil, isProtected: false)
        let state = PhotoFilterState(protectedOnly: true)
        XCTAssertEqual(PhotoFilter.apply([protected, unprotected], state: state).map(\.id), [protected.id])
        XCTAssertEqual(PhotoFilter.apply([protected, unprotected], state: state,
                                         protectionAvailable: false).map(\.id), [protected.id, unprotected.id])
        XCTAssertTrue(state.protectedOnly)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.isActive(protectionAvailable: false))
    }

    func testProtectionProbeDiagnosticsPreserveExistingCaptureEntries() {
        PhotoRatingDiagnostics.clear()
        PhotoRatingDiagnostics.setEnabled(true)
        PhotoRatingDiagnostics.note("existing")
        let previous = PhotoRatingDiagnostics.beginProbe(keepExisting: true)
        PhotoRatingDiagnostics.note("probe")
        PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
        let report = PhotoRatingDiagnostics.snapshot()
        XCTAssertTrue(report.contains("existing"))
        XCTAssertTrue(report.contains("probe"))
        PhotoRatingDiagnostics.setEnabled(false)
    }

    func testPhotoEffectsUseAndroidDefaultsAndNormalizeWatermarkText() {
        let settings = PhotoEffectsSettings()
        XCTAssertFalse(settings.photoFrameEnabled)
        XCTAssertEqual(settings.photoFramePreset, .mist)
        XCTAssertEqual(settings.watermark.displayText, "ZTransfer")
        XCTAssertFalse(PhotoFrameMetadataSettings.defaults(for: .galleryMat).showExposure)
        XCTAssertTrue(PhotoFrameMetadataSettings.defaults(for: .plaque).showDate)
        var watermark = PhotoFrameWatermark(text: "  a\nb\t")
        XCTAssertEqual(watermark.displayText, "a b")
        watermark.text = " \n\t "
        XCTAssertEqual(watermark.displayText, PhotoFrameWatermark.defaultText)
        watermark.text = String(repeating: "x", count: 30)
        XCTAssertEqual(watermark.displayText.count, PhotoFrameWatermark.maxTextLength)
        XCTAssertEqual(
            PhotoFrameWatermark.limitText("line one\nline two\t\u{0007}"),
            "line one line two "
        )
        XCTAssertEqual(
            PhotoFrameWatermark.limitText(String(repeating: "😀", count: 25)).unicodeScalars.count,
            PhotoFrameWatermark.maxTextLength
        )
    }

    @MainActor
    func testWatermarkImportUsesOriginalBytesAndAndroidSizeLimit() throws {
        PhotoEffectsStore.resetWatermarkImageCache()
        defer { PhotoEffectsStore.resetWatermarkImageCache() }
        let suite = "effects-watermark-import-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoEffectsStore(defaults: defaults, premiumAccess: PremiumAccess(.lifetime))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_300, height: 12))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_300, height: 12))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.73))
        let expectedHash = SHA256.hash(data: original)
            .map { String(format: "%02x", $0) }.joined()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-import-test-\(UUID().uuidString).jpg")
        try original.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let generation = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.watermarkImageImporting)
        XCTAssertNil(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(generation: generation, hash: nil))
        XCTAssertFalse(store.watermarkImageImporting)
        XCTAssertFalse(store.finishWatermarkImageImport(generation: generation &+ 1, hash: nil))
        XCTAssertEqual(PhotoEffectsStore.importWatermarkImageFile(sourceURL), expectedHash)
        XCTAssertEqual(store.importWatermarkImage(data: original), expectedHash)
        let successfulGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: successfulGeneration, hash: expectedHash
        ))
        XCTAssertEqual(store.settings.watermark.content, .image)
        XCTAssertEqual(store.settings.watermark.imageHash, expectedHash)
        XCTAssertEqual(store.lastImportedWatermarkHash, expectedHash)
        XCTAssertEqual(store.watermarkImportRevision, 1)
        let repeatedGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: repeatedGeneration, hash: expectedHash
        ))
        XCTAssertEqual(store.watermarkImportRevision, 2)
        let decoded = try XCTUnwrap(PhotoEffectsStore.watermarkImage(hash: expectedHash))
        XCTAssertLessThanOrEqual(
            max(decoded.size.width, decoded.size.height),
            CGFloat(PhotoEffectsStore.maximumWatermarkImagePixelDimension)
        )
        XCTAssertTrue(decoded === PhotoEffectsStore.watermarkImage(hash: expectedHash))
        XCTAssertEqual(PhotoEffectsStore.watermarkImageCacheCount, 1)
        for color in [UIColor.red, .green, .blue] {
            let extra = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let data = try XCTUnwrap(extra.pngData())
            let hash = try XCTUnwrap(PhotoEffectsStore.importWatermarkImageData(data))
            XCTAssertNotNil(PhotoEffectsStore.watermarkImage(hash: hash))
        }
        XCTAssertEqual(PhotoEffectsStore.watermarkImageCacheCount, 3)
        XCTAssertFalse(decoded === PhotoEffectsStore.watermarkImage(hash: expectedHash))

        let rejectedHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let rejectedGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: rejectedGeneration, hash: rejectedHash
        ))
        XCTAssertNil(store.lastImportedWatermarkHash)
        XCTAssertEqual(store.watermarkImportRevision, 2)
        XCTAssertEqual(store.settings.watermark.content, .text)
        XCTAssertNil(store.settings.watermark.imageHash)
        XCTAssertNil(store.importWatermarkImage(data: Data()))
        XCTAssertNil(store.importWatermarkImage(
            data: Data(count: PhotoEffectsStore.maximumWatermarkImageBytes + 1)
        ))
    }

    func testWatermarkStoredNumbersAreNotMistakenForBooleans() {
        let suite = "watermark-number-types-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [0, 1, 2, 72, 100] {
            defaults.set(value, forKey: "value")
            let stored = defaults.object(forKey: "value")
            XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent(stored), max(1, value))
            XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(stored, content: .text), max(1, value))
        }
        for value in [false, true] {
            defaults.set(value, forKey: "value")
            let stored = defaults.object(forKey: "value")
            XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent(stored), 72)
            XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(stored, content: .text), 80)
        }
    }

    @MainActor
    func testLegacyWatermarkSizeAndOpacityMigrateWithoutVisualJump() {
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(nil, content: .text), 80)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("SMALL", content: .text), 9)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("MEDIUM", content: .text), 26)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("SMALL", content: .image), 1)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("MEDIUM", content: .image), 20)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("LARGE", content: .image), 51)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(200, content: .text, usesLegacyScale: true), 151)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(300, content: .text), 300)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("SUBTLE"), 40)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("STANDARD"), 72)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("STRONG"), 100)

        let suite = "effects-watermark-scale-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ZTransfer", forKey: "photo_frame_watermark_text")
        defaults.set("MEDIUM", forKey: "photo_frame_watermark_size")
        defaults.set("SUBTLE", forKey: "photo_frame_watermark_opacity")
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.watermark.sizePercent, 26)
        XCTAssertEqual(restored.watermark.opacityPercent, 40)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_size"), 26)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_opacity"), 40)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_size_scale_version"), 2)
    }

    @MainActor
    func testFavoriteFrameWatermarkRestoreNormalizesSizeAndOpacity() {
        let suite = "effects-frame-favorite-normalization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "photo_frame_enabled")
        defaults.set("MIST,true,TEXT,CALLIGRAPHY,999,AUTO,ADAPTIVE,-2,AUTO", forKey: "favorite_frame_effects_v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.favoriteFrameEffects.count, 1)
        XCTAssertEqual(restored.favoriteFrameEffects[0].watermark.sizePercent, 300)
        XCTAssertEqual(restored.favoriteFrameEffects[0].watermark.opacityPercent, 1)
        XCTAssertEqual(
            defaults.string(forKey: "favorite_frame_effects_v1"),
            "MIST,true,TEXT,CALLIGRAPHY,300,AUTO,ADAPTIVE,1,AUTO,100"
        )
    }

    func testRemoteDesqueezeRestoresWithinAndroidRange() {
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(0.25), 1)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(1.33), 1.33)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(9), 1)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(.infinity), 1)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(.nan), 1)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 1.2), 1.5)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 9), 1.33)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 1.7), 2)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 2), 1)
    }

    func testThumbnailColumnsRestoreWithinAndroidRange() {
        XCTAssertEqual(normalizedThumbnailColumns(-1), 2)
        XCTAssertEqual(normalizedThumbnailColumns(1), 2)
        XCTAssertEqual(normalizedThumbnailColumns(3), 3)
        XCTAssertEqual(normalizedThumbnailColumns(8), 4)
    }

    func testPreviewReturnOnlyTreatsCompleteCellAsVisible() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 700)

        XCTAssertTrue(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 120, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertTrue(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 99.75, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 99, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 700, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(.zero, in: viewport))
    }

    func testPhotoPreviewHoldAndHistogramMatchPresentationContract() throws {
        XCTAssertEqual(photoPreviewLongPressDuration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewRotationDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewZoomPanMinimumDistance, 8, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewDoubleTapDuration, 0.24, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewDoubleTapZoom, 2.5, accuracy: 0.0001)

        let viewport = CGSize(width: 400, height: 800)
        XCTAssertEqual(
            photoPreviewRotationFitScale(
                imageSize: CGSize(width: 200, height: 400),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewRotationFitScale(
                imageSize: CGSize(width: 200, height: 400),
                viewportSize: viewport,
                rotationDegrees: -90
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 2, height: -20)),
            .upward
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 20, height: -2)),
            .rejected
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 9, height: -9)),
            .undecided
        )
        XCTAssertEqual(
            photoPreviewQueueVisualOffset(upwardDistance: 200),
            -118.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewDisplaySize(
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: -90
            ),
            CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(
            photoPreviewClampedOffset(
                CGSize(width: 500, height: -1_000),
                scale: 2.5,
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            CGSize(width: 300, height: 0)
        )
        XCTAssertEqual(
            photoPreviewDoubleTapOffset(
                location: CGPoint(x: 300, y: 400),
                scale: 2.5,
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            CGSize(width: -150, height: 0)
        )
        XCTAssertEqual(
            photoPreviewMaximumZoom(
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            4,
            accuracy: 0.0001
        )
        XCTAssertTrue(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: 42,
            histogramFileID: 42,
            binCount: 256
        ))
        XCTAssertFalse(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: nil,
            histogramFileID: 42,
            binCount: 256
        ))
        XCTAssertTrue(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: 42,
            histogramFileID: 42,
            binCount: 256
        ))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 1),
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.white.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }

        let histogram = previewLuminanceHistogram(image)
        XCTAssertEqual(histogram.count, 256)
        XCTAssertEqual(histogram[0], 1, accuracy: 0.0001)
        XCTAssertEqual(histogram[255], 1, accuracy: 0.0001)
        XCTAssertEqual(histogram[128], 0, accuracy: 0.0001)
    }
}

private actor SequentialListHarness {
    private(set) var requested: [UInt32] = []
    private(set) var scans = 0
    private(set) var remoteGates: [Bool] = []
    private var firstReleased = false
    func didStartScan() { scans += 1 }
    func setRemote(_ active: Bool) { remoteGates.append(active) }
    func releaseFirst() { firstReleased = true }
    func prefetch(_ files: [CameraFile]) async -> Set<UInt32> {
        for file in files {
            requested.append(file.id)
            while file.id == 1 && !firstReleased {
                do { try await Task.sleep(for: .milliseconds(1)) }
                catch { return [] }
            }
        }
        return Set(files.map(\.id))
    }
}

private actor RemoteListLifecycleHarness {
    struct ScanCall: Equatable, Sendable {
        let preserve: Bool
        let hasSnapshot: Bool
        let detectNew: Bool
    }

    private let firstBatch: [CameraFile]
    private var remoteGate = false
    private var resumedFiles: [CameraFile] = []
    private var resumedRemoved: Set<UInt32> = []
    private var resumedAdded: Set<UInt32> = []
    private(set) var scanCalls: [ScanCall] = []
    private(set) var gateChanges: [Bool] = []
    var scanCount: Int { scanCalls.count }

    init(firstBatch: [CameraFile]) {
        self.firstBatch = firstBatch
    }

    func setGate(_ active: Bool) {
        remoteGate = active
        gateChanges.append(active)
    }

    func setResumeFiles(_ files: [CameraFile], removed: Set<UInt32> = [], added: Set<UInt32> = []) {
        resumedFiles = files
        resumedRemoved = removed
        resumedAdded = added
    }

    func scan(
        preserve: Bool,
        snapshot: PhotoScanSnapshot?,
        detectNew: Bool,
        onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void
    ) async throws -> PhotoScanResult {
        scanCalls.append(ScanCall(preserve: preserve, hasSnapshot: snapshot != nil, detectNew: detectNew))
        if scanCalls.count == 1 {
            if !firstBatch.isEmpty { try await onBatch(firstBatch) }
            while !remoteGate {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw CameraRepositoryError.foregroundPreempted
        }
        if !resumedFiles.isEmpty { try await onBatch(resumedFiles) }
        return PhotoScanResult(files: resumedFiles,
                               removedHandles: resumedRemoved,
                               addedHandles: resumedAdded,
                               handleQueriesSucceeded: true,
                               metadataComplete: true)
    }
}

@MainActor
private func remoteLifecycleModel(_ harness: RemoteListLifecycleHarness) -> PhotoListViewModel {
    PhotoListViewModel(
        scanCatalog: { preserve, snapshot, detectNew, _, onBatch in
            try await harness.scan(preserve: preserve, snapshot: snapshot,
                                   detectNew: detectNew, onBatch: onBatch)
        },
        setRemoteGate: { active in await harness.setGate(active) }
    )
}

private func remoteLifecycleFile(_ id: UInt32, name: String,
                                 captureDate: String = "20260917T120000") -> CameraFile {
    CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
               fileName: name, captureDate: captureDate, isProtected: false)
}

@MainActor
private func waitForRemoteLifecycle(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for remote/list lifecycle state")
    throw CocoaError(.coderReadCorrupt)
}

extension DomainModelTests {
    func testPhotoFramePresetFilmNegativeAndParameterPosterMatchAndroidDefaults() throws {
        XCTAssertEqual(PhotoFramePreset(rawValue: "FILM_NEGATIVE"), .filmNegative)
        XCTAssertEqual(PhotoFramePreset(rawValue: "PARAMETER_POSTER"), .parameterPoster)
        let negative = PhotoFrameMetadataSettings.defaults(for: .filmNegative)
        XCTAssertTrue(negative.showDate && !negative.showTime)
        XCTAssertTrue(negative.showFocalLength && negative.showExposure && negative.showBrand && negative.showModel)
        let poster = PhotoFrameMetadataSettings.defaults(for: .parameterPoster)
        XCTAssertTrue(poster.showFocalLength && poster.showExposure && poster.showBrand && poster.showModel)
        XCTAssertFalse(poster.showLensModel || poster.showCoordinates || poster.showCity || poster.showRegion)
    }

    func testPhotoFramePresetFilmNegativeAndParameterPosterRenderPixelPreservingPhoto() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 50), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 50))
            for (color, point) in [(UIColor.red, CGPoint(x: 10, y: 10)),
                                   (UIColor.green, CGPoint(x: 65, y: 35)),
                                   (UIColor.blue, CGPoint(x: 40, y: 25))] {
                color.setFill(); context.fill(CGRect(origin: point, size: CGSize(width: 3, height: 3)))
            }
        }
        func markerCenters(_ image: UIImage) throws -> [CGPoint] {
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return try (0..<3).map { channel in
                let points = (0..<(cg.width * cg.height)).compactMap { pixel -> CGPoint? in
                    let i = pixel * 4
                    guard bytes[i + channel] > 250,
                          bytes[i + (channel + 1) % 3] < 5, bytes[i + (channel + 2) % 3] < 5 else { return nil }
                    return CGPoint(x: pixel % cg.width, y: pixel / cg.width)
                }
                XCTAssertEqual(points.count, 9, "Original 3×3 marker must retain all pixels")
                let minX = try XCTUnwrap(points.map(\.x).min()), maxX = try XCTUnwrap(points.map(\.x).max())
                let minY = try XCTUnwrap(points.map(\.y).min()), maxY = try XCTUnwrap(points.map(\.y).max())
                XCTAssertEqual(maxX - minX, 2); XCTAssertEqual(maxY - minY, 2)
                return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            }
        }
        let originalCenters = try markerCenters(source)
        let metadata = PhotoFrameMetadata(make: "Nikon", model: "Z 8", lensModel: "24-70mm",
                                          focalLength: "50mm", aperture: "f/2.8", shutter: "1/125",
                                          iso: "ISO100", exposureCompensation: nil,
                                          dateTime: "2026:10:12 01:00:00")
        for preset in [PhotoFramePreset.filmNegative, .parameterPoster] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true
            settings.photoFrameBorderEnabled = true
            settings.photoFramePreset = preset
            settings.watermark.enabled = false
            settings.metadata = .defaults(for: preset)
            let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata)
            let size = output.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            XCTAssertNotNil(size)
            XCTAssertGreaterThan(size?.width ?? 0, 80)
            XCTAssertGreaterThan(size?.height ?? 0, 50)
            // Android's measured layouts expand around metadata. The original
            // fixed canvas expectations predated that rule; verify the actual
            // no-resize/no-crop contract with independent photo landmarks.
            let centers = try markerCenters(output)
            for index in 1..<centers.count {
                XCTAssertEqual(centers[index].x - centers[0].x,
                               originalCenters[index].x - originalCenters[0].x)
                XCTAssertEqual(centers[index].y - centers[0].y,
                               originalCenters[index].y - originalCenters[0].y)
            }
        }
    }

    func testRenderedJPEGPreservesExifAndRewritesOrientationDimensionsAndCameraGPS() throws {
        func image(width: Int, height: Int, color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height), format: format
            ).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let sourceImage = image(width: 6, height: 4, color: .red)
        let sourceData = NSMutableData()
        let sourceDestination = try XCTUnwrap(CGImageDestinationCreateWithData(
            sourceData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let sourceProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                kCGImagePropertyTIFFModel: "Z 30",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:17 12:34:56",
                kCGImagePropertyExifFNumber: 1.7,
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 1.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.0,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(sourceDestination, try XCTUnwrap(sourceImage.cgImage),
                                   sourceProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(sourceDestination))

        let rendered = image(width: 20, height: 30, color: .blue)
        let camera = PhotoFrameMetadata(
            make: nil, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil, latitude: -31.5, longitude: 121.25, altitude: -12
        )
        let output = try XCTUnwrap(PhotoEffectsJPEGEncoder.encode(
            rendered, copyingMetadataFrom: sourceData as Data, cameraMetadata: camera
        ))
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as NSDictionary?
        )
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 30)
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? NSDictionary)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "NIKON CORPORATION")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "Z 30")
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? NSDictionary)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2026:09:17 12:34:56")
        XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, 30)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? NSDictionary)
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue, 31.5)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual((gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue, 121.25)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual((gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue, 12)
        XCTAssertEqual((gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue, 1)
    }

    func testPhotoEffectsLayoutUsesExifOrientedSourceDimensions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        }
        let oriented = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: .right)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.photoFramePreset = .plaque
        settings.watermark.enabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )

        let output = try PhotoEffectsRenderer.render(oriented, settings: settings)

        XCTAssertEqual(output.imageOrientation, .up)
        XCTAssertEqual(output.cgImage?.width, 4)
        XCTAssertEqual(output.cgImage?.height, 7)
    }

    func testBorderedFilterPreservesMirroredAndRotatedPixelOrientation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let raw = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 48), format: format
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor.green.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 24, width: 32, height: 24))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 32, y: 24, width: 32, height: 24))
        }
        let filter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )

        func bytes(_ image: CGImage) throws -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &result, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return result
        }

        for orientation in [UIImage.Orientation.right, .rightMirrored, .leftMirrored, .downMirrored] {
            let source = UIImage(
                cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: orientation
            )
            var filterOnly = PhotoEffectsSettings()
            filterOnly.photoFilterEnabled = true
            filterOnly.selectedFilter = filter
            let reference = try PhotoEffectsRenderer.render(source, settings: filterOnly)
            let referenceImage = try XCTUnwrap(reference.cgImage)

            var bordered = filterOnly
            bordered.photoFrameEnabled = true
            bordered.photoFrameBorderEnabled = true
            bordered.photoFramePreset = .plaque
            bordered.watermark.enabled = false
            let output = try PhotoEffectsRenderer.render(source, settings: bordered)
            let outputImage = try XCTUnwrap(output.cgImage)
            let photoLayer = try XCTUnwrap(outputImage.cropping(to: CGRect(
                x: 0, y: 0, width: referenceImage.width, height: referenceImage.height
            )))

            XCTAssertEqual(try bytes(photoLayer), try bytes(referenceImage), "\(orientation)")
        }
    }

    func testPhotoFilterDoesNotRecolorFrameBackdrop() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 48), format: format
        ).image { context in
            UIColor(red: 0.92, green: 0.16, blue: 0.08, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            UIColor(red: 0.04, green: 0.25, blue: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        }
        var unfiltered = PhotoEffectsSettings()
        unfiltered.photoFrameEnabled = true
        unfiltered.photoFrameBorderEnabled = true
        unfiltered.photoFramePreset = .cinema
        unfiltered.watermark.enabled = false
        var filtered = unfiltered
        filtered.photoFilterEnabled = true
        let preset = Np3FilterCatalog.presets[0]
        filtered.selectedFilter = PhotoFilterSelection(
            preset: .init(id: preset.id, name: preset.name), intensityPercent: 100
        )

        let plainOutput = try PhotoEffectsRenderer.render(source, settings: unfiltered)
        var filterOnly = PhotoEffectsSettings()
        filterOnly.photoFilterEnabled = true
        filterOnly.selectedFilter = filtered.selectedFilter
        let preparedFilter = try PhotoEffectsRenderer.render(source, settings: filterOnly)
        var decorationOnly = filtered
        decorationOnly.photoFilterEnabled = false
        let filteredOutput = try PhotoEffectsRenderer.render(
            preparedFilter, settings: decorationOnly, backdropSource: source
        )
        let exportFilteredOutput = try PhotoEffectsRenderer.render(source, settings: filtered)

        func bytes(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            var result = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &result, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                             width: cgImage.width, height: cgImage.height))
            return result
        }
        let plainBytes = try bytes(plainOutput)
        let filteredBytes = try bytes(filteredOutput)
        let exportFilteredBytes = try bytes(exportFilteredOutput)
        let width = try XCTUnwrap(plainOutput.cgImage).width
        let height = try XCTUnwrap(plainOutput.cgImage).height
        func pixel(_ data: [UInt8], x: Int, y: Int) -> ArraySlice<UInt8> {
            let offset = (y * width + x) * 4
            return data[offset..<(offset + 4)]
        }

        XCTAssertEqual(pixel(plainBytes, x: 0, y: 0),
                       pixel(filteredBytes, x: 0, y: 0))
        XCTAssertEqual(pixel(plainBytes, x: 0, y: 0),
                       pixel(exportFilteredBytes, x: 0, y: 0))
        XCTAssertNotEqual(pixel(plainBytes, x: width / 2, y: height / 2),
                          pixel(filteredBytes, x: width / 2, y: height / 2))
        XCTAssertEqual(pixel(filteredBytes, x: width / 2, y: height / 2),
                       pixel(exportFilteredBytes, x: width / 2, y: height / 2))
    }

    func testPhotoEffectsFilterTilesUseAndroidPixelBudget() {
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 4_096), 1_024)
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 6_000), 699)
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 5_000_000), 1)
    }

    func testCancelledPreviewFilterReleasesPixelWorkersPromptly() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 4_096, height: 3_072), format: format
        ).image { context in
            UIColor(red: 0.24, green: 0.52, blue: 0.76, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 3_072))
        }
        let cgImage = try XCTUnwrap(source.cgImage)
        let preset = Np3FilterCatalog.presets[0]
        let task = Task.detached(priority: .userInitiated) {
            try Np3BitmapFilter.apply(
                cgImage, parameters: preset.parameters, intensityPercent: 80
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preview pixel work unexpectedly completed")
        } catch is CancellationError {}
        XCTAssertLessThan(
            cancelledAt.duration(to: .now), .seconds(1),
            "A stale filter preview must not keep the shared render gate occupied"
        )
    }

    func testPhotoEffectsBorderPreviewUsesAndroid1920PixelLayout() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 300), format: format
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        func renderedSize(_ preset: PhotoFramePreset) throws -> CGSize {
            try autoreleasepool {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true
                settings.photoFrameBorderEnabled = true
                settings.photoFramePreset = preset
                settings.watermark.enabled = false
                let output = try XCTUnwrap(PhotoEffectsRenderer.render(
                    source, settings: settings, previewLongEdge: 1_920
                ).cgImage)
                return CGSize(width: output.width, height: output.height)
            }
        }

        XCTAssertEqual(try renderedSize(.mist), CGSize(width: 1_920, height: 1_440))
        XCTAssertEqual(try renderedSize(.plaque), CGSize(width: 1_920, height: 1_670))
        XCTAssertEqual(try renderedSize(.classicSignature), CGSize(width: 1_920, height: 1_802))
        // Android caps immersive previews but never upscales them.
        XCTAssertEqual(try renderedSize(.immersive), CGSize(width: 400, height: 300))
    }

    func testPhotoEffectsPreviewIdentityIgnoresNonPixelEditorPreferences() {
        var current = PhotoEffectsSettings()
        current.photoFrameEnabled = true
        current.photoFrameBorderEnabled = true
        current.photoFramePreset = .mist
        current.photoFilterEnabled = true
        current.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )
        var preferences = current
        preferences.favoriteFilterIDs = [
            PhotoEffectsSettings.filterKey(PhotoFilterCatalog.presets[1].id)
        ]
        preferences.filterIntensities[
            PhotoEffectsSettings.filterKey(PhotoFilterCatalog.presets[2].id)
        ] = 42
        preferences.favoriteFramePresets = [.cinema]
        preferences.metadataByPreset[PhotoFramePreset.cinema.rawValue] = .defaults(for: .cinema)

        XCTAssertEqual(photoEffectsPreviewPixelSettings(current),
                       photoEffectsPreviewPixelSettings(preferences))

        preferences.metadata.showModel.toggle()
        XCTAssertNotEqual(photoEffectsPreviewPixelSettings(current),
                          photoEffectsPreviewPixelSettings(preferences))
    }

    func testPhotoEffectsPreviewUsesAndroidMetadataPlaceholdersFieldByField() throws {
        var settings = PhotoFrameMetadataSettings()
        settings.showDate = true
        settings.showTime = true
        settings.showLensModel = true
        settings.showCoordinates = true
        settings.showAltitude = true
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: 12
        )))
        let empty = PhotoFrameMetadata(
            make: nil, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil
        )

        let preview = presentedPhotoFrameMetadata(
            empty, settings: settings, preview: true, now: now
        )
        XCTAssertEqual(preview.make, "NIKON")
        XCTAssertEqual(preview.model, "Z 233")
        XCTAssertEqual(preview.lensModel, "1-800mm f/0.1")
        XCTAssertEqual(preview.focalLength, "5100mm")
        XCTAssertEqual(preview.aperture, "f/0.1")
        XCTAssertEqual(preview.shutter, "1/99999")
        XCTAssertEqual(preview.iso, "ISO999999")
        XCTAssertEqual(preview.dateTime, "2026-08-18 25:61:61")
        XCTAssertEqual(preview.latitude, 66.6666)
        XCTAssertEqual(preview.longitude, 66.6666)
        XCTAssertEqual(preview.altitude, 23_333)

        let exported = presentedPhotoFrameMetadata(empty, settings: settings)
        XCTAssertNil(exported.make)
        XCTAssertNil(exported.model)
        XCTAssertNil(exported.lensModel)
        XCTAssertNil(exported.focalLength)
        XCTAssertNil(exported.aperture)
        XCTAssertNil(exported.shutter)
        XCTAssertNil(exported.iso)
        XCTAssertNil(exported.dateTime)
        XCTAssertNil(exported.latitude)
        XCTAssertNil(exported.longitude)
        XCTAssertNil(exported.altitude)
    }

    func testPhotoEffectsMetadataInfersBrandFromModelLikeAndroid() {
        let metadata = PhotoFrameMetadata(
            make: nil, model: "NIKON Z 8", lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil
        )
        var settings = PhotoFrameMetadataSettings()
        settings.showBrand = true
        settings.showModel = false

        let presented = presentedPhotoFrameMetadata(metadata, settings: settings)

        XCTAssertEqual(presented.make, "NIKON")
        XCTAssertNil(presented.model)
    }

    func testFilterSelectionUsesOwnRememberedIntensityAndOffKeepsSelection() {
        let first = PhotoFilterCatalog.presets[0]
        let next = PhotoFilterCatalog.presets[1]
        var settings = PhotoEffectsSettings()
        settings.selectFilter(first.id)
        settings.filterIntensities[PhotoEffectsSettings.filterKey(first.id)] = 22
        settings.selectedFilter = .init(preset: first, intensityPercent: 22)
        settings.selectFilter(next.id)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 80)
        settings.selectFilter(first.id)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 22)
        settings.selectFilter(nil)
        XCTAssertFalse(settings.photoFilterEnabled)
        XCTAssertEqual(settings.selectedFilter?.preset.id, first.id)
    }

    @MainActor
    func testEffectFavoritesKeepAdditionOrderAcrossPersistenceAndRetoggling() {
        let suite = "effects-order-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = PhotoFilterCatalog.presets[0], c = PhotoFilterCatalog.presets[2]
        var settings = PhotoEffectsSettings()
        settings.selectFilter(a.id)
        settings.toggleFilterFavorite(c.id)
        settings.toggleFilterFavorite(a.id)
        settings.favoriteFrameEffects = [.init(preset: .cinema, watermark: .init()), .init(preset: .mist, watermark: .init())]
        let store = PhotoEffectsStore(defaults: defaults)
        store.update(settings)
        var restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(Array(restored.orderedFilters.prefix(2)).map(\.id), [c.id, a.id])
        XCTAssertEqual(restored.favoriteFrameEffects.map(\.preset), [.cinema, .mist])
        XCTAssertEqual(Array(restored.orderedFramePresets.prefix(3)), [.cinema, .mist, .minimal])
        XCTAssertEqual(restored.selectedFilter, settings.selectedFilter)
        restored.toggleFilterFavorite(c.id)
        restored.toggleFilterFavorite(c.id)
        XCTAssertEqual(Array(restored.orderedFilters.prefix(2)).map(\.id), [a.id, c.id])
    }

    @MainActor
    func testEffectsRestoreNormalizesWatermarkAndLocalMetadata() {
        let cameraSuite = "effects-normalize-camera-\(UUID())"
        let localSuite = "effects-normalize-local-\(UUID())"
        let cameraDefaults = UserDefaults(suiteName: cameraSuite)!
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer {
            cameraDefaults.removePersistentDomain(forName: cameraSuite)
            localDefaults.removePersistentDomain(forName: localSuite)
        }

        var camera = PhotoEffectsSettings()
        camera.watermark.content = .image
        camera.watermark.imageHash = String(repeating: "z", count: 64)
        camera.watermark.text = "  abc\n\tdef  "
        camera.watermark.sizePercent = 999
        camera.watermark.opacityPercent = -2
        camera.metadataByPreset[PhotoFramePreset.mist.rawValue] = .init(
            showCoordinates: true, showAltitude: true,
            datePattern: " invalid ", timePattern: " invalid "
        )
        let cameraStore = PhotoEffectsStore(defaults: cameraDefaults)
        cameraStore.update(camera)
        let restoredCamera = PhotoEffectsStore(defaults: cameraDefaults).settings
        XCTAssertEqual(restoredCamera.watermark.content, .text)
        XCTAssertNil(restoredCamera.watermark.imageHash)
        XCTAssertEqual(restoredCamera.watermark.text, "abc def")
        XCTAssertEqual(restoredCamera.watermark.sizePercent, 300)
        XCTAssertEqual(restoredCamera.watermark.opacityPercent, 1)
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.datePattern, "yyyy-MM-dd")
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.timePattern, "HH:mm:ss")
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showCoordinates, true)

        var local = camera
        local.watermark.text = "  abc\n\tdef  "
        let localStore = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos)
        localStore.update(local)
        let restoredLocal = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos).settings
        XCTAssertEqual(restoredLocal.watermark.text, "  abc def  ")
        XCTAssertEqual(restoredLocal.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showCoordinates, false)
        XCTAssertEqual(restoredLocal.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showAltitude, false)
    }

    @MainActor
    func testEffectsRestoreEveryAndroidMetadataPreferenceGeneration() {
        let suite = "effects-metadata-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            // Original six flags + two patterns.
            "MIST|true|false|true|true|true|true|yyyy/MM/dd|HH:mm",
            // Lens-model generation.
            "CINEMA|false|false|true|true|true|true|true|yyyy.MM.dd|HH.mm",
            // Former location generation with the now-removed address slot.
            "PLAQUE|true|true|true|true|true|true|false|true|true|true|MM-dd-yyyy|HH.mm.ss",
        ].joined(separator: ";"), forKey: "photo_frame_metadata_settings_v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings.metadataByPreset

        XCTAssertEqual(restored[PhotoFramePreset.mist.rawValue]?.showLensModel, false)
        XCTAssertEqual(restored[PhotoFramePreset.mist.rawValue]?.datePattern, "yyyy/MM/dd")
        XCTAssertEqual(restored[PhotoFramePreset.cinema.rawValue]?.showLensModel, true)
        XCTAssertEqual(restored[PhotoFramePreset.cinema.rawValue]?.timePattern, "HH.mm")
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.showCoordinates, true)
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.showAltitude, true)
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.datePattern, "MM-dd-yyyy")
    }

    @MainActor
    func testLocalEffectsFirstRunMigratesOnlyLegacyFavoritesOnce() {
        let legacySuite = "effects-legacy-\(UUID())"
        let localSuite = "effects-local-migration-\(UUID())"
        let legacy = UserDefaults(suiteName: legacySuite)!
        let local = UserDefaults(suiteName: localSuite)!
        defer {
            legacy.removePersistentDomain(forName: legacySuite)
            local.removePersistentDomain(forName: localSuite)
        }
        let a = PhotoFilterCatalog.presets[0]
        var old = PhotoEffectsSettings()
        old.selectFilter(a.id)
        old.toggleFilterFavorite(a.id)
        old.favoriteFrameEffects = [.init(preset: .cinema, watermark: .init())]
        old.favoriteFramePresets = [.cinema]
        old.photoFrameEnabled = true
        old.photoFramePreset = .filmEdge
        PhotoEffectsStore(defaults: legacy).update(old)

        let migrated = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertEqual(migrated.favoriteFilterIDs, [PhotoEffectsSettings.filterKey(a.id)])
        XCTAssertEqual(migrated.favoriteFrameEffects.map(\.preset), [.cinema])
        XCTAssertFalse(migrated.photoFrameEnabled)
        XCTAssertEqual(migrated.photoFramePreset, .mist)

        legacy.set("", forKey: "favorite_photo_filters_v1")
        legacy.set("", forKey: "favorite_frame_effects_v1")
        let reopened = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertEqual(reopened.favoriteFilterIDs, migrated.favoriteFilterIDs)
        XCTAssertEqual(reopened.favoriteFrameEffects.map(\.preset), [.cinema])
    }

    @MainActor
    func testLocalEffectsFirstRunPersistsIndependentScopeWithoutEdits() {
        let legacySuite = "effects-empty-legacy-\(UUID())"
        let localSuite = "effects-empty-local-\(UUID())"
        let legacy = UserDefaults(suiteName: legacySuite)!
        let local = UserDefaults(suiteName: localSuite)!
        defer {
            legacy.removePersistentDomain(forName: legacySuite)
            local.removePersistentDomain(forName: localSuite)
        }

        let first = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                      legacyDefaults: legacy).settings
        XCTAssertEqual(local.integer(forKey: "settings_version"), 3)
        XCTAssertTrue(first.favoriteFilterIDs.isEmpty)

        let preset = PhotoFilterCatalog.presets[0]
        var camera = PhotoEffectsSettings()
        camera.toggleFilterFavorite(preset.id)
        PhotoEffectsStore(defaults: legacy).update(camera)

        let reopened = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertTrue(reopened.favoriteFilterIDs.isEmpty)
    }

    @MainActor
    func testAndroidIntensityCodecKeepsFirstDuplicateAndNormalizesValues() {
        let suite = "effects-codec-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = Np3FilterCatalog.presets[0], b = Np3FilterCatalog.presets[1]
        defaults.set(a.id, forKey: "photo_filter_selected_id")
        defaults.set("\(a.catalogKey),79;missing,60;\(a.catalogKey),22;\(b.catalogKey),101;broken", forKey: "photo_filter_intensities_v1")
        defaults.set("\(b.catalogKey),71;missing;\(a.catalogKey);\(b.catalogKey),92", forKey: "favorite_photo_filters_v1")
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.filterIntensities, [a.catalogKey: 80, b.catalogKey: 100])
        XCTAssertEqual(restored.favoriteFilterIDs, [b.catalogKey, a.catalogKey])
    }

    @MainActor
    func testTransferEffectsRestoreImmediateEditorPreferencesWithoutCommittedDraft() {
        let suite = "effects-partial-editor-persistence-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Np3FilterCatalog.presets[0]
        defaults.set("\(first.catalogKey),63", forKey: "photo_filter_intensities_v1")
        defaults.set(
            "CINEMA,true,TEXT,CALLIGRAPHY,80,AUTO,ADAPTIVE,72,AUTO",
            forKey: "favorite_frame_effects_v1"
        )

        let restored = PhotoEffectsStore(defaults: defaults).settings

        XCTAssertEqual(restored.selectedFilter?.preset.id, first.id)
        XCTAssertEqual(restored.selectedFilter?.intensityPercent, 64)
        XCTAssertEqual(restored.filterIntensities[first.catalogKey], 64)
        XCTAssertFalse(restored.photoFilterEnabled)
        XCTAssertEqual(restored.favoriteFrameEffects.map(\.preset), [.cinema])
    }

    @MainActor
    func testLocalEffectsKeepValidIntensityMapWhenSelectedFilterWasRemoved() {
        let suite = "local-effects-removed-filter-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Np3FilterCatalog.presets[0]

        defaults.set(3, forKey: "settings_version")
        defaults.set("removed-filter", forKey: "filter_id")
        defaults.set(true, forKey: "filter_enabled")
        defaults.set("\(first.catalogKey),63;removed-key,42", forKey: "filter_intensities_v1")

        let restored = PhotoEffectsStore(defaults: defaults, scope: .localPhotos).settings
        XCTAssertNil(restored.selectedFilter)
        XCTAssertFalse(restored.photoFilterEnabled)
        XCTAssertEqual(restored.filterIntensities, [first.catalogKey: 64])
        XCTAssertEqual(defaults.string(forKey: "filter_intensities_v1"), "\(first.catalogKey),64")
    }

    @MainActor
    func testLegacyEffectsJSONDropsRemovedFilterIntensityKeys() throws {
        let suite = "effects-json-intensity-normalization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PhotoFilterCatalog.presets[0]
        let validKey = PhotoEffectsSettings.filterKey(first.id)
        var legacy = PhotoEffectsSettings()
        legacy.filterIntensities = [validKey: 63, "removed-key": 42]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "photoEffectsSettings.v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.filterIntensities, [validKey: 64])
    }

    @MainActor
    func testLegacyCurrentFilterIntensityMigratesIntoPerFilterMap() {
        let transferSuite = "effects-transfer-intensity-migration-\(UUID())"
        let localSuite = "effects-local-intensity-migration-\(UUID())"
        let transferDefaults = UserDefaults(suiteName: transferSuite)!
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer {
            transferDefaults.removePersistentDomain(forName: transferSuite)
            localDefaults.removePersistentDomain(forName: localSuite)
        }
        let preset = Np3FilterCatalog.presets[0]

        transferDefaults.set(preset.id, forKey: "photo_filter_selected_id")
        transferDefaults.set(37, forKey: "photo_filter_intensity")
        let transfer = PhotoEffectsStore(defaults: transferDefaults).settings
        let transferIntensity = Np3FilterEngine.normalizeIntensity(37)
        XCTAssertEqual(transfer.selectedFilter?.intensityPercent, transferIntensity)
        XCTAssertEqual(transfer.filterIntensities[preset.catalogKey], transferIntensity)
        XCTAssertNil(transferDefaults.object(forKey: "photo_filter_intensity"))
        XCTAssertEqual(transferDefaults.string(forKey: "photo_filter_intensities_v1"), "\(preset.catalogKey),\(transferIntensity)")

        localDefaults.set(3, forKey: "settings_version")
        localDefaults.set(preset.id, forKey: "filter_id")
        localDefaults.set(42, forKey: "filter_intensity")
        let local = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos).settings
        let localIntensity = Np3FilterEngine.normalizeIntensity(42)
        XCTAssertEqual(local.selectedFilter?.intensityPercent, localIntensity)
        XCTAssertEqual(local.filterIntensities[preset.catalogKey], localIntensity)
        XCTAssertNil(localDefaults.object(forKey: "filter_intensity"))
        XCTAssertEqual(localDefaults.string(forKey: "filter_intensities_v1"), "\(preset.catalogKey),\(localIntensity)")
    }

    func testFrameFavoriteUsesCurrentContentAndRejectsMissingLogo() throws {
        let historical = PhotoFrameWatermark(content: .image, text: "historical", imageHash: String(repeating: "a", count: 64), sizePercent: 242, opacityPercent: 1)
        let favorite = PhotoFrameFavorite(preset: .minimal, watermark: historical)
        let current = PhotoFrameWatermark(text: "current", imageHash: String(repeating: "b", count: 64))
        let applied = try XCTUnwrap(favorite.applying(to: current))
        XCTAssertEqual(applied.text, "current")
        XCTAssertEqual(applied.imageHash, current.imageHash)
        XCTAssertEqual(applied.sizePercent, 242)
        XCTAssertEqual(applied.opacityPercent, 1)
        XCTAssertNil(favorite.applying(to: .init()))
    }

    @MainActor
    func testWatermarkFullAndroidRangeSurvivesSaveAndReopen() {
        let suite = "effects-watermark-range-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoEffectsStore(defaults: defaults)
        var settings = store.settings
        settings.watermark.sizePercent = 300
        settings.watermark.opacityPercent = 1
        store.update(settings)
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.watermark.sizePercent, 300)
        XCTAssertEqual(restored.watermark.opacityPercent, 1)
    }

    func testTransferDraftPreferencesPersistWithoutApplyingActiveEffects() {
        let first = PhotoFilterCatalog.presets[0], next = PhotoFilterCatalog.presets[1]
        var saved = PhotoEffectsSettings()
        saved.selectFilter(first.id)
        var draft = saved
        draft.selectFilter(next.id)
        draft.photoFramePreset = .minimal
        draft.metadataByPreset[PhotoFramePreset.minimal.rawValue] = .init(showCoordinates: true)
        draft.toggleFilterFavorite(next.id)
        let result = saved.persistingEditorPreferences(from: draft)
        XCTAssertEqual(result.selectedFilter, saved.selectedFilter)
        XCTAssertEqual(result.photoFramePreset, .mist)
        XCTAssertEqual(result.favoriteFilterIDs, draft.favoriteFilterIDs)
        XCTAssertEqual(result.metadataByPreset, draft.metadataByPreset)
        XCTAssertEqual(result.filterIntensities, draft.filterIntensities)
    }
}

extension DomainModelTests {
    private func putBE16(_ data: inout Data, _ offset: Int, _ value: Int) {
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private func livePacket(judgement: Int = 2, frameCount: Int = 1,
                           selected: Int = 0, headerSize: Int = 512) -> Data {
        var data = Data(repeating: 0, count: headerSize + 32)
        putBE16(&data, 0, 1); putBE16(&data, 2, 0)
        putBE16(&data, 8, 0); data[8] = 0; data[9] = 0; data[10] = UInt8((headerSize >> 8) & 0xFF); data[11] = UInt8(headerSize & 0xFF)
        data[12] = 0; data[13] = 0; data[14] = 0; data[15] = 32
        putBE16(&data, 16, 5568); putBE16(&data, 18, 3712)
        putBE16(&data, 28, 1024); putBE16(&data, 30, 680)
        data[42] = UInt8(judgement); data[44] = UInt8(frameCount); data[45] = UInt8(selected)
        putBE16(&data, 48, 484); putBE16(&data, 50, 314); putBE16(&data, 52, 2784); putBE16(&data, 54, 878)
        data[headerSize] = 0xFF; data[headerSize + 1] = 0xD8; data[headerSize + 2] = 0xFF
        return data
    }

    func testAndroidLiveViewMetadataKeepsUnknownStateAndAllVisibleFrames() {
        var data = livePacket(judgement: 99, frameCount: 2, selected: 1)
        putBE16(&data, 48, 120); putBE16(&data, 50, 80); putBE16(&data, 52, 200); putBE16(&data, 54, 160)
        putBE16(&data, 56, 300); putBE16(&data, 58, 180); putBE16(&data, 60, 700); putBE16(&data, 62, 420)
        let result = RemoteFrameParser.metadata(from: data, jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx)
        XCTAssertEqual(result?.focusJudgement, .unknown)
        XCTAssertEqual(result?.focusFrames.count, 2)
        XCTAssertEqual(result?.selectedFocusFrame, result?.focusFrames[1])
        XCTAssertEqual(result?.focusFrameStatus, "full-frame")
    }

    func testAndroidLiveViewMetadataRejectsInvalidTableWithoutDiscardingAudio() {
        var data = livePacket(frameCount: 43)
        data[388] = 11; data[389] = 9; data[390] = 7; data[391] = 4
        let result = RemoteFrameParser.metadata(from: data, jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx)
        XCTAssertEqual(result?.focusFrameStatus, "invalid-table")
        XCTAssertTrue(result?.focusFrames.isEmpty == true)
        XCTAssertEqual(result?.soundLevels?.currentLeft, 7)
    }

    func testAndroidLiveViewMetadataClipsVisibleAreaAndDoesNotShiftOffscreenBox() {
        let area = RemoteLiveViewDisplayArea(left: 0.25, top: 0.25, width: 0.5, height: 0.5)
        let centered = RemoteFrameParser.mapLiveViewFocusFrame(
            RemoteLiveViewFocusFrame(centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.1), area: area)
        XCTAssertEqual(Double(centered?.centerX ?? -1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Double(centered?.width ?? -1), 0.2, accuracy: 0.0001)
        XCTAssertNil(RemoteFrameParser.mapLiveViewFocusFrame(
            RemoteLiveViewFocusFrame(centerX: 0.1, centerY: 0.1, width: 0.1, height: 0.1), area: area))
    }

    func testAndroidLiveViewFocusDiagnosticIsPassiveBoundedAndChangeOnly() {
        let diagnostic = RemoteLiveViewFocusDiagnostic()
        let bytes = livePacket()
        diagnostic.start(nowMs: 0, description: "Z30")
        for index in 0...300 {
            diagnostic.sample(packet: RemoteLiveViewPacket(bytes: bytes, jpegOffset: 512,
                                                           operation: PTPConstants.getLiveViewImageEx,
                                                           receivedAtUptime: Double(index) * 0.2),
                             metadata: nil, context: "photo")
        }
        XCTAssertFalse(diagnostic.running)
        XCTAssertLessThanOrEqual(diagnostic.report().utf8.count, 6000)
        XCTAssertTrue(diagnostic.report().hasPrefix("Focus diagnostic v2 Z30"))
        XCTAssertTrue(diagnostic.report().contains("end=60s samples=300"))
        diagnostic.start(nowMs: 70_000, description: "new")
        diagnostic.stop()
        XCTAssertFalse(diagnostic.report().contains("Z30"))
    }
}


extension DomainModelTests {
    @MainActor
    func testBundledWatermarkFontsResolveWithoutSystemFallback() throws {
        let paths = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            let url = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing registered font: \(path)")
        }
        for name in ["GreatVibes-Regular", "BebasNeue-Regular", "CormorantGaramond-MediumItalic"] {
            let font = try XCTUnwrap(UIFont(name: name, size: 24), "Watermark would fall back to a system font: \(name)")
            XCTAssertEqual(font.fontName, name)
        }
    }
}

/// Android TransferStateTest + processQueue/withdraw/retry scenarios. These use
/// controlled camera/render operations so task-boundary races are repeatable.
@MainActor
final class TransferQueueScenarioTests: XCTestCase {
    func testBatchRemovalRetainsNewRetriedAndActiveTasksAndPublishesFinalOrder() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue((1...500).map { file(UInt32($0)) })
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items.first?.status == .transferring }
        await queue.withdrawPending()
        let retryResult = await queue.retry(id: ids[1])
        let retried = try XCTUnwrap(retryResult)
        let enqueued = await queue.enqueue(file(501))
        let newID = try XCTUnwrap(enqueued)
        let stream = await queue.snapshots()
        var snapshots = stream.makeAsyncIterator()
        _ = await snapshots.next()
        let removed = await queue.remove(ids: Set(ids))
        XCTAssertEqual(removed, Set(ids.dropFirst(2)))
        let remaining = await snapshots.next()
        XCTAssertEqual(remaining?.items.map(\.id), [ids[0], retried, newID])
        XCTAssertEqual(remaining?.items.map(\.status), [.transferring, .waiting, .waiting])
        let again = await queue.remove(ids: Set(ids))
        XCTAssertTrue(again.isEmpty)
        await queue.withdrawPending()
        await camera.finish(1)
        _ = try await wait(queue) { !$0.isTransferring }
        await queue.removeCleared()
        let final = await snapshot(queue)
        XCTAssertTrue(final.items.isEmpty)
        let requests = await camera.requests
        XCTAssertEqual(requests, [1])
    }

    func testLateCardRemovalCannotWithdrawActiveTransferButWaitingCardCanLeave() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2)])
        let model = TransferQueueViewModel(queue: queue)
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        // Same commands used by the card's swipe/accessibility callback,
        // delivered after its previously-waiting item has become active.
        model.withdraw(id: ids[0])
        let activeRemoved = await model.remove(id: ids[0])
        XCTAssertFalse(activeRemoved)
        model.withdraw(id: ids[1])
        _ = try await wait(queue) { $0.items[1].status == .cancelled }
        let waitingRemoved = await model.remove(id: ids[1])
        XCTAssertTrue(waitingRemoved)
        let active = await snapshot(queue)
        XCTAssertEqual(active.items.map(\.id), [ids[0]])
        XCTAssertEqual(active.items[0].status, .transferring)
        await camera.finish(1)
        let finished = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(finished.items[0].status, .completed)
        let requests = await camera.requests
        XCTAssertEqual(requests, [1])
        let terminalRemoved = await model.remove(id: ids[0])
        XCTAssertTrue(terminalRemoved)
    }

    func testSlowSnapshotSubscribersReceiveLatestStateWithoutBacklog() async throws {
        let suite = "queue-conflation-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let first = await queue.snapshots()
        let second = await queue.snapshots()
        var a = first.makeAsyncIterator(), b = second.makeAsyncIterator()
        let initial = await a.next()
        XCTAssertEqual(initial?.items.count, 0)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "A.JPG", captureDate: nil, isProtected: false)
        for _ in 0..<100 { _ = await queue.enqueue(file) }
        let latestA = await a.next(), latestB = await b.next()
        XCTAssertEqual(latestA?.items.count, 100)
        XCTAssertEqual(latestB?.items.map(\.id), latestA?.items.map(\.id))
        _ = await queue.enqueue(file)
        let nextA = await a.next(), nextB = await b.next()
        XCTAssertEqual(nextA?.items.count, 101, "No old array snapshots may remain queued")
        XCTAssertEqual(nextB?.items.count, 101)
    }

    func testLatestTaskIndexIgnoresStatusAndUUIDOrdering() {
        let statuses: [TransferStatus] = [.waiting, .transferring, .completed, .failed, .cancelled]
        for olderStatus in statuses {
            for newerStatus in statuses {
                let older = TransferQueueItem(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                                              file: file(1), status: olderStatus)
                let other = TransferQueueItem(id: UUID(), file: file(2), status: .waiting)
                let newer = TransferQueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                              file: file(1), status: newerStatus)
                let items = [older, other, newer]
                let indices = latestTransferTaskIndices(items)
                XCTAssertEqual(indices[1], 2)
                XCTAssertEqual(indices[2], 1)
                XCTAssertNil(indices[3])
                XCTAssertEqual(indices[1].map { items[$0].id }, newer.id)
            }
        }
        XCTAssertTrue(latestTransferTaskIndices([]).isEmpty)
    }

    func testViewModelLatestTaskTracksQueuePublicationsWithdrawalAndRemoval() async throws {
        let (queue, _) = try fixture()
        let model = TransferQueueViewModel(queue: queue)
        var publicationReads = 0
        let observation = model.objectWillChange.sink {
            // Published notifies before replacing snapshot. The public lookup
            // must still be safe and consistent inside synchronous subscribers.
            XCTAssertEqual(model.task(for: 1)?.id, model.snapshot.items.last { $0.file.id == 1 }?.id)
            publicationReads += 1
        }
        defer { observation.cancel() }
        let firstID = await queue.enqueue(file(1))
        let secondID = await queue.enqueue(file(1))
        let first = try XCTUnwrap(firstID)
        let second = try XCTUnwrap(secondID)
        func waitForTask(_ id: UUID?, status: TransferStatus? = nil) async throws {
            for _ in 0..<200 {
                if model.task(for: 1)?.id == id,
                   status == nil || model.task(for: 1)?.status == status { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("The production snapshot observer did not publish the latest task")
        }
        try await waitForTask(second, status: .waiting)
        await queue.withdraw(id: second)
        try await waitForTask(second, status: .cancelled)
        XCTAssertEqual(model.snapshot.items.first?.status, .waiting)
        _ = await queue.remove(id: second)
        try await waitForTask(first, status: .waiting)
        await queue.withdraw(id: first)
        await queue.removeCleared()
        try await waitForTask(nil)
        XCTAssertTrue(model.snapshot.items.isEmpty)
        XCTAssertNil(model.task(for: 2))
        XCTAssertGreaterThanOrEqual(publicationReads, 5)
    }

    func testUnknownQueueSizeRetainsActualBytesAfterDownloadAndLocalHit() async throws {
        let (queue, directory) = try fixture()
        let unknown = CameraFile(id: 991, storageID: 1, format: 0x3801, size: UInt64(UInt32.max),
                                 fileName: "UNKNOWN.JPG", captureDate: nil, isProtected: false)
        let camera = UnknownSizeProgressCamera()
        await queue.enqueue([unknown])
        await queue.start(session: camera, directory: directory)
        let active = try await wait(queue) { $0.items.first?.downloadedBytes == 1024 }
        XCTAssertEqual(active.items.first?.status, .transferring)
        XCTAssertEqual(TransferQueueCardText(item: try XCTUnwrap(active.items.first)).fileSizeText(), "1 KB")
        await camera.finish()
        let done = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .completed }
        let item = try XCTUnwrap(done.items.first)
        let count = try Data(contentsOf: XCTUnwrap(item.outputURL)).count
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(item.downloadedBytes, UInt64(count))
        XCTAssertEqual(TransferQueueCardText(item: item).fileSizeText(), "2 KB")
        var empty = item
        empty.downloadedBytes = 0
        XCTAssertEqual(TransferQueueCardText(item: empty).fileSizeText(), "—")
        let live = TransferActiveProgress(taskID: item.id, fraction: 0, bytesPerSecond: 100,
                                         retainedBytesPerSecond: 100, downloadedBytes: 2048)
        XCTAssertEqual(TransferQueueCardText(item: empty).fileSizeText(activeProgress: live), "2 KB")
        empty.id = UUID()
        XCTAssertEqual(TransferQueueCardText(item: empty).fileSizeText(activeProgress: live), "—")
        await queue.enqueue([unknown])
        await queue.start(session: nil, directory: directory)
        let local = try await wait(queue) { !$0.isTransferring && $0.items.count == 2 && $0.items.last?.status == .completed }
        XCTAssertEqual(local.items.last?.downloadedBytes, UInt64(count))
    }

    func testQueueGenerationWaitingDistinguishesPreparingRunningPausedAndSkipped() {
        var item = TransferQueueItem(id: UUID(), file: file(1))
        XCTAssertFalse(TransferQueueCardText(item: item).generationWaiting)
        item.isGeneratingFrame = true
        XCTAssertTrue(TransferQueueCardText(item: item).generationWaiting)
        item.frameGenerationStartedAtElapsedMs = 100
        XCTAssertFalse(TransferQueueCardText(item: item).generationWaiting)
        item.frameGenerationStartedAtElapsedMs = nil
        item.frameGenerationAccumulatedMs = 500
        XCTAssertTrue(TransferQueueCardText(item: item).generationWaiting)
        item.frameGenerationSkipped = true
        XCTAssertFalse(TransferQueueCardText(item: item).generationWaiting)
        item.frameGenerationSkipped = false
        item.isGeneratingFrame = false
        XCTAssertFalse(TransferQueueCardText(item: item).generationWaiting)
    }

    func testQueueCardErrorsOverrideEffectsAndWatermarkUsesItsOwnLabel() {
        var item = TransferQueueItem(id: UUID(), file: file(1))
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        item.effects = effects
        XCTAssertEqual(TransferQueueCardText(item: item).effectText,
                       AppLocalized.resource("photo_frame_watermark_short"))
        item.status = .failed
        item.error = "download error"
        item.frameError = "render error"
        XCTAssertEqual(TransferQueueCardText(item: item).errorText,
                       AppLocalized.resource("local_photo_batch_failed") + ": render error")
        XCTAssertNil(TransferQueueCardText(item: item).effectText)
        item.frameError = nil
        XCTAssertEqual(TransferQueueCardText(item: item).errorText, "download error")
        item.error = nil
        XCTAssertEqual(TransferQueueCardText(item: item).errorText, AppLocalized.resource("transfer_failed"))
        item.status = .completed
        item.frameGenerationSkipped = true
        XCTAssertEqual(TransferQueueCardText(item: item).effectText, AppLocalized.resource("status_skipped"))
        item.effects = nil
        XCTAssertNil(TransferQueueCardText(item: item).effectText)
        item.error = "stale transfer error"
        XCTAssertNil(TransferQueueCardText(item: item).errorText)
        item.frameError = ""
        XCTAssertEqual(TransferQueueCardText(item: item).errorText,
                       AppLocalized.resource("local_photo_batch_failed") + ": ")
    }

    func testQueueActionEligibilityTracksActivityGenerationAndDepartingCards() {
        var failed = TransferQueueItem(id: UUID(), file: file(1), status: .failed)
        let waiting = TransferQueueItem(id: UUID(), file: file(2))
        func visibility(_ items: [TransferQueueItem], running: Bool = false,
                        excluded: Set<UUID> = [], clearing: Bool = false) -> TransferQueueSnapshot.ActionVisibility {
            TransferQueueSnapshot(items: items, isTransferring: running, pauseAfterCurrent: false)
                .actionVisibility(excluding: excluded, suppressAll: clearing)
        }
        XCTAssertEqual(visibility([failed, waiting]), .init(hasRetryable: true, hasClearable: true))
        XCTAssertEqual(visibility([failed, waiting], running: true), .init(hasRetryable: false, hasClearable: true))
        XCTAssertEqual(visibility([failed, waiting], excluded: [failed.id]), .init(hasRetryable: false, hasClearable: true))
        XCTAssertEqual(visibility([failed, waiting], clearing: true), .init(hasRetryable: false, hasClearable: false))
        failed.isGeneratingFrame = true
        XCTAssertEqual(visibility([failed]), .init(hasRetryable: false, hasClearable: false))
        failed.isGeneratingFrame = false
        failed.status = .cancelled
        XCTAssertEqual(visibility([failed]), .init(hasRetryable: true, hasClearable: true))
        XCTAssertEqual(visibility([failed], excluded: [failed.id]), .init(hasRetryable: false, hasClearable: false))
    }

    func testExecutionControlIncludesReservedHandoffAndLastFileStates() {
        let waiting = TransferQueueItem(id: UUID(), file: file(1))
        var active = waiting
        active.status = .transferring
        var completed = waiting
        completed.status = .completed
        var failed = waiting
        failed.status = .failed
        var cancelled = waiting
        cancelled.status = .cancelled
        var generating = completed
        generating.isGeneratingFrame = true
        for pauseRequested in [false, true] {
            for items in [[], [waiting], [active], [completed], [waiting, completed]] {
                let running = TransferQueueSnapshot(items: items, isTransferring: true,
                                                    pauseAfterCurrent: pauseRequested)
                XCTAssertEqual(running.executionControl, .pause)
            }
            for item in [waiting, active, completed, failed, cancelled, generating] {
                let idle = TransferQueueSnapshot(items: [item], isTransferring: false,
                                                 pauseAfterCurrent: pauseRequested)
                XCTAssertEqual(idle.executionControl, item.status == .waiting ? .start : nil)
            }
            XCTAssertNil(TransferQueueSnapshot(items: [], isTransferring: false,
                                               pauseAfterCurrent: pauseRequested).executionControl)
        }
    }

    func testLastFileRetainsPauseControlUntilWorkerStops() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        _ = await queue.enqueue(file(1))
        let waiting = await queue.snapshot()
        XCTAssertEqual(waiting.executionControl, .start)
        XCTAssertFalse(waiting.pauseAfterCurrent)
        await queue.start(session: camera, directory: directory)
        let running = try await wait(queue) { $0.items[0].status == .transferring }
        XCTAssertFalse(running.items.contains { $0.status == .waiting })
        XCTAssertEqual(running.executionControl, .pause)
        await queue.pauseAfterCurrentFile()
        let requested = await queue.snapshot()
        XCTAssertTrue(requested.pauseAfterCurrent)
        XCTAssertEqual(requested.executionControl, .pause)
        await camera.finish(1)
        let finished = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(finished.items[0].status, .completed)
        XCTAssertNil(finished.executionControl)
    }

    private func file(_ id: UInt32, name: String? = nil) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 10,
                   fileName: name ?? "DSC_\(id).JPG", captureDate: "20260914T120000", isProtected: false)
    }

    private func fixture(accessOperations: DirectoryAccessOperations = .system, directoryPreparation: TransferDirectoryPreparation = .shared, generationCapacity: Int = 4096, renderer: TransferQueue.FrameRenderer? = nil, cropRenderer: TransferQueue.CropRenderer? = nil) throws -> (TransferQueue, URL) {
        let suite = "TransferQueueScenarioTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        if let cropRenderer {
            return (TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), accessOperations: accessOperations, directoryPreparation: directoryPreparation, generationCapacity: generationCapacity, renderCrop: cropRenderer), directory)
        }
        if let renderer {
            return (TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), accessOperations: accessOperations, directoryPreparation: directoryPreparation, generationCapacity: generationCapacity, renderFrame: renderer), directory)
        }
        return (TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), accessOperations: accessOperations, directoryPreparation: directoryPreparation, generationCapacity: generationCapacity), directory)
    }

    private func snapshot(_ queue: TransferQueue) async -> TransferQueueSnapshot {
        await queue.snapshot()
    }

    private func wait(_ queue: TransferQueue, until predicate: (TransferQueueSnapshot) -> Bool) async throws -> TransferQueueSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let value = await snapshot(queue)
            if predicate(value) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Queue did not reach the expected state")
        throw CocoaError(.coderInvalidValue)
    }

    func testBatchDeduplicatesHandlesButSeparateClicksCreateNewAttempts() async throws {
        let (queue, _) = try fixture()
        let first = await queue.enqueue([file(1), file(1), file(2)])
        let second = await queue.enqueue([file(1), file(2)])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(Set(first).isDisjoint(with: second))
        let state = await snapshot(queue)
        XCTAssertEqual(state.items.map(\.file.id), [1, 2, 1, 2])
    }

    func testOfflineLocalHitAndMissingOriginalNeverPublishFalseDownloadState() async throws {
        let (queue, directory) = try fixture()
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)])
        let stream = await queue.snapshots()
        await queue.start(session: nil, directory: directory)
        var finished: TransferQueueSnapshot?
        for await value in stream {
            XCTAssertFalse(value.items.contains { $0.status == .transferring })
            if value.items.allSatisfy({ $0.status == .completed || $0.status == .failed }) && !value.isTransferring {
                finished = value
                break
            }
        }
        XCTAssertEqual(finished?.items[0].status, .completed)
        XCTAssertEqual(finished?.items[0].skipped, true)
        XCTAssertNil(finished?.items[0].elapsedMs)
        XCTAssertEqual(finished?.items[1].error, AppLocalized.resource("camera_not_connected"))
    }

    func testCompleteVideoPartialIsRenamedBeforeCameraStateAndRecheckedAsLocalOriginal() async throws {
        let (queue, directory) = try fixture()
        let source = CameraFile(id: 7, storageID: 1, format: 0x300D, size: 10,
                                fileName: "DSC_7.MP4", captureDate: "20260914T120000", isProtected: false)
        let partialName = transferPartialFileName(
            size: source.size, captureDate: source.captureDate, fileName: source.fileName
        )
        let partial = directory.appendingPathComponent(partialName)
        try Data(repeating: 7, count: Int(source.size)).write(to: partial)
        await queue.enqueue(source)

        let stream = await queue.snapshots()
        await queue.start(session: nil, directory: directory)
        var finished: TransferQueueSnapshot?
        for await value in stream {
            if !value.isTransferring && value.items.first?.status == .completed {
                finished = value
                break
            }
        }
        let item = try XCTUnwrap(finished?.items.first)
        XCTAssertEqual(item.status, .completed)
        XCTAssertTrue(item.skipped)
        XCTAssertEqual(item.outputURL?.lastPathComponent, source.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
    }

    func testCompleteStillPartialCannotBePublishedByOfflineQueue() async throws {
        let (queue, directory) = try fixture()
        let source = file(7)
        let partial = directory.appendingPathComponent(transferPartialFileName(
            size: source.size, captureDate: source.captureDate, fileName: source.fileName
        ))
        try Data(repeating: 7, count: Int(source.size)).write(to: partial)
        await queue.enqueue(source)
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .failed }
        XCTAssertEqual(failed.items.first?.error, AppLocalized.resource("camera_not_connected"))
        XCTAssertNil(failed.items.first?.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
    }

    func testResumeUnavailableDeletesPartAndUsesAndroidFailureText() async throws {
        let (queue, directory) = try fixture()
        let source = CameraFile(id: 8, storageID: 1, format: 0x3801,
                                size: 8 * 1024 * 1024,
                                fileName: "DSC_8.JPG", captureDate: "20260914T120000", isProtected: false)
        let partial = directory.appendingPathComponent(
            transferPartialFileName(size: source.size, captureDate: source.captureDate, fileName: source.fileName)
        )
        try Data(repeating: 8, count: 4 * 1024 * 1024).write(to: partial)
        await queue.enqueue(source)
        await queue.start(session: ResumeUnavailableCamera(), directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .failed }
        XCTAssertEqual(failed.items.first?.error, AppLocalized.resource("transfer_failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRetryKeepsCardPositionButExecutesAfterAlreadyPendingTasks() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let old = await queue.enqueue(file(9))!
        await queue.withdraw(id: old)
        await queue.enqueue([file(1), file(2)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        let attempt = await queue.retry(id: old)
        XCTAssertNotNil(attempt)
        XCTAssertNotEqual(attempt, old)
        await camera.finish(1)
        _ = try await wait(queue) { $0.items[2].status == .transferring }
        await camera.finish(2)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await camera.finish(9)
        let final = try await wait(queue) { !$0.isTransferring }
        let requests = await camera.requests
        XCTAssertEqual(requests, [1, 2, 9])
        XCTAssertEqual(final.items.map(\.file.id), [9, 1, 2])
        XCTAssertTrue(final.items.allSatisfy { $0.status == .completed })
    }

    func testPauseWaitsForCurrentFileAndRetryCannotReleaseIt() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2), file(3)])
        await queue.withdraw(id: ids[2])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.pauseAfterCurrentFile()
        // An overlapping explicit start is ignored while the worker is active.
        await queue.startPendingTransfers(session: camera, directory: directory)
        await camera.finish(1)
        let paused = try await wait(queue) { !$0.isTransferring }
        XCTAssertTrue(paused.pauseAfterCurrent)
        XCTAssertEqual(paused.items[0].status, .completed)
        let replacement = await queue.retry(id: ids[2])
        XCTAssertNotNil(replacement)
        let afterRetry = await snapshot(queue)
        XCTAssertFalse(afterRetry.isTransferring)
        XCTAssertTrue(afterRetry.pauseAfterCurrent)
        let replacementCamera = ControlledTransferCamera()
        await queue.attach(session: replacementCamera, directory: directory)
        await queue.resume()
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        await replacementCamera.finish(2)
        _ = try await wait(queue) { $0.items[2].status == .transferring }
        await replacementCamera.finish(3)
        let final = try await wait(queue) { !$0.isTransferring }
        XCTAssertFalse(final.pauseAfterCurrent)
        let oldRequests = await camera.requests
        let newRequests = await replacementCamera.requests
        XCTAssertEqual(oldRequests, [1])
        XCTAssertEqual(newRequests, [2, 3])
    }

    func testWithdrawAndRetryAllExcludeCardsAlreadyLeaving() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2), file(3)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.withdrawPending()
        await queue.retryFailed(excluding: [ids[1]])
        await queue.removeCleared()
        let during = await snapshot(queue)
        XCTAssertEqual(during.items.map(\.file.id), [1, 3])
        await camera.finish(1)
        _ = try await wait(queue) { $0.items.last?.status == .transferring }
        await camera.finish(3)
        _ = try await wait(queue) { !$0.isTransferring }
        let requests = await camera.requests
        XCTAssertEqual(requests, [1, 3])
    }

    func testDetachDoesNotReuseOldCameraAndReconnectRetryUsesNewOne() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.detach()
        await camera.finish(1)
        let disconnected = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(disconnected.items[0].status, .completed)
        XCTAssertEqual(disconnected.items[1].status, .failed)
        XCTAssertEqual(disconnected.items[1].error, AppLocalized.resource("camera_not_connected"))
        let replacement = ControlledTransferCamera()
        await queue.attach(session: replacement, directory: directory)
        await queue.retry(id: ids[1])
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        await replacement.finish(2)
        _ = try await wait(queue) { !$0.isTransferring }
        let oldRequests = await camera.requests
        let newRequests = await replacement.requests
        XCTAssertEqual(oldRequests, [1])
        XCTAssertEqual(newRequests, [2])
    }

    func testFramesUseSingleWorkerAndClearProtectsActiveAndWaitingRenders() async throws {
        let renderer = ControlledFrameRenderer()
        let (queue, directory) = try fixture { source, _, target, _ in
            try await renderer.render(source: source, directory: target)
        }
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        let files = [file(1), file(2), file(3)]
        for file in files { try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file.fileName)) }
        let ids = await queue.enqueue(files, effects: effects)
        await queue.start(session: nil, directory: directory)
        let generating = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy(\.isGeneratingFrame) }
        XCTAssertTrue(generating.items.allSatisfy { !$0.skipped })
        let removed = await queue.remove(id: ids[0])
        XCTAssertFalse(removed)
        let batchRemoved = await queue.remove(ids: Set(ids))
        XCTAssertTrue(batchRemoved.isEmpty, "Batch removal must also protect running and queued effects")
        await queue.clearFinished()
        await queue.removeCleared()
        let protected = await snapshot(queue)
        XCTAssertEqual(protected.items.count, 3)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await renderer.peak < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await renderer.releaseAll()
        let final = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame } }
        let peak = await renderer.peak
        XCTAssertEqual(peak, 1)
        XCTAssertTrue(final.items.allSatisfy { $0.status == .completed && $0.frameURL != nil })
        await queue.removeCleared()
        let cleared = await snapshot(queue)
        XCTAssertTrue(cleared.items.isEmpty)
    }

    func testQueuedLUTSurvivesEditorReplacementPruneAndCacheEviction() async throws {
        let (queue, directory) = try fixture { source, settings, target, _ in
            let image = try XCTUnwrap(UIImage(contentsOfFile: source.path))
            let rendered = try PhotoEffectsRenderer.render(image, settings: settings)
            let output = target.appendingPathComponent("owned-lut-output.jpg")
            try XCTUnwrap(rendered.jpegData(compressionQuality: 1)).write(to: output)
            return output
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let source = directory.appendingPathComponent("owned-source.jpg")
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        try jpeg.write(to: source)
        let suite = "lut-queue-prune-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoLUTStore(defaults: defaults, directory: directory.appendingPathComponent("lut"))
        let old = try CubeLUTParser.parse(Data(("TITLE queued-old\nLUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let new = try CubeLUTParser.parse(Data(("TITLE editor-new\nLUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
        weak var oldOwner: PhotoLUTSnapshotOwner?
        func enqueueOld() async throws -> UUID {
            var effects = PhotoEffectsSettings()
            effects.photoFilterEnabled = true
            effects.selectedFilter = try store.selectLUT(old, name: "Old", sourceIdentifier: "old.cube")
            effects.selectedFilter?.intensityPercent = 100
            oldOwner = effects.selectedFilter?.snapshotOwner
            let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(jpeg.count),
                                  fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
            let id = await queue.enqueue(file, effects: effects)
            return try XCTUnwrap(id)
        }
        let id = try await enqueueOld()
        _ = try store.selectLUT(new, name: "New", sourceIdentifier: "new.cube")
        await store.pruneSnapshots()
        PhotoLUTRuntime.purgeMemoryCache()
        let oldFile = store.snapshotDirectory.appendingPathComponent("\(old.digest).bin")
        XCTAssertNotNil(oldOwner, "Only the queue now holds the old recipe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        await queue.start(session: nil, directory: directory)
        func finishedOutput() async throws -> URL {
            let final = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameURL != nil }
            XCTAssertEqual(final.items[0].effects?.selectedFilter?.preset.id, "cube:\(old.digest)")
            return try XCTUnwrap(final.items[0].frameURL)
        }
        let output = try await finishedOutput()
        let rendered = try XCTUnwrap(UIImage(contentsOfFile: output.path)?.cgImage)
        // The old LUT is black, whereas the editor's replacement is white.
        let bytes = try XCTUnwrap(rendered.dataProvider?.data) as Data
        XCTAssertLessThan(bytes.prefix(3).max() ?? 255, 10)
        let removed = await queue.remove(id: id)
        XCTAssertTrue(removed)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while oldOwner != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(oldOwner)
        await store.pruneSnapshots()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertNotNil(store.restoreSelection())
    }

    func testMemoryBudgetFailurePreservesOriginalAndRetriesLockedRecipe() async throws {
        let budget = QueueRenderBudgetFixture()
        let (queue, directory) = try fixture { source, settings, target, _ in
            let available = await budget.next(settings)
            let image = try XCTUnwrap(UIImage(contentsOfFile: source.path))
            let result = try PhotoEffectsRenderer.render(image, settings: settings, availableMemory: { available })
            let output = target.appendingPathComponent("budget-output.jpg")
            try XCTUnwrap(result.jpegData(compressionQuality: 1)).write(to: output)
            return output
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let source = directory.appendingPathComponent("budget-source.jpg")
        try original.write(to: source)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(preset: settings.orderedFilters[0], intensityPercent: 40)
        let locked = effectivePhotoEffectsSettings(settings, isPro: true)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(original.count),
                              fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
        let enqueued = await queue.enqueue(file, effects: settings)
        let id = try XCTUnwrap(enqueued)
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil }
        XCTAssertNil(failed.items[0].frameURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("budget-output.jpg").path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        settings.selectedFilter?.intensityPercent = 100
        let retry = await queue.retry(id: id)
        XCTAssertNotNil(retry)
        let done = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameURL != nil }
        let attempts = await budget.selections
        XCTAssertEqual(attempts, [locked, locked])
        XCTAssertNil(done.items[0].frameError)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let input = try XCTUnwrap(UIImage(contentsOfFile: source.path))
        let expected = try PhotoEffectsRenderer.render(input, settings: locked, availableMemory: { .max })
        let actual = try Data(contentsOf: XCTUnwrap(done.items[0].frameURL))
        XCTAssertEqual(actual, expected.jpegData(compressionQuality: 1))
        XCTAssertEqual(UIImage(data: actual)?.size, image.size)
    }

    func testLUTRetryKeepsEnqueuedAdjustmentsAfterEditorChanges() async throws {
        let renderer = FailOnceFrameRenderer()
        let (queue, directory) = try fixture { source, settings, target, _ in
            let output = try await renderer.render(source: source, settings: settings, directory: target)
            let image = try XCTUnwrap(UIImage(contentsOfFile: source.path))
            let rendered = try PhotoEffectsRenderer.render(image, settings: settings)
            try XCTUnwrap(rendered.jpegData(compressionQuality: 1)).write(to: output)
            return output
        }
        let source = directory.appendingPathComponent(file(1).fileName)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: source)
        let suite = "lut-queue-retry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoLUTStore(defaults: defaults, directory: directory.appendingPathComponent("lut"))
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        try store.selectLUT(lut, name: "Queue LUT", sourceIdentifier: "original.cube")
        store.setIntensity(50)
        store.setAdjustments(.init(contrast: 20, saturation: -100, highlights: 15, shadows: -25))
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = false
        effects.photoFilterEnabled = true
        effects.selectedFilter = try XCTUnwrap(store.restoreSelection())
        let locked = effectivePhotoEffectsSettings(effects, isPro: true)
        let original = CameraFile(id: 1, storageID: 1, format: 0x3801,
                                  size: UInt64(try Data(contentsOf: source).count),
                                  fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
        let enqueued = await queue.enqueue(original, effects: effects)
        let id = try XCTUnwrap(enqueued)
        await queue.start(session: nil, directory: directory)
        _ = try await wait(queue) { !$0.isTransferring && $0.items[0].frameError != nil && !$0.items[0].isGeneratingFrame }
        store.setIntensity(100)
        store.setAdjustments(.init(contrast: -80, saturation: 100))
        effects.selectedFilter = store.restoreSelection()
        let retry = await queue.retry(id: id)
        XCTAssertNotNil(retry)
        let final = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameURL != nil }
        let selections = await renderer.selections
        XCTAssertEqual(selections, [locked, locked])
        XCTAssertEqual(final.items[0].effects, locked)
        let input = try XCTUnwrap(UIImage(contentsOfFile: source.path))
        let expected = try PhotoEffectsRenderer.render(input, settings: locked)
        let changed = try PhotoEffectsRenderer.render(input, settings: effects)
        let bytes = try Data(contentsOf: XCTUnwrap(final.items[0].frameURL))
        XCTAssertEqual(bytes, expected.jpegData(compressionQuality: 1))
        XCTAssertNotEqual(bytes, changed.jpegData(compressionQuality: 1))
    }

    func testExistingOriginalFrameFailureCanRetryOfflineWithLockedEffects() async throws {
        let renderer = FailOnceFrameRenderer()
        let (queue, directory) = try fixture { source, settings, target, _ in
            try await renderer.render(source: source, settings: settings, directory: target)
        }
        let source = directory.appendingPathComponent(file(1).fileName)
        try Data(repeating: 1, count: 10).write(to: source)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        effects.photoFramePreset = .minimal
        let id = await queue.enqueue(file(1), effects: effects)!
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && $0.items[0].frameError != nil && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(failed.items[0].status, .completed)
        XCTAssertNil(failed.items[0].error)
        XCTAssertEqual(failed.items[0].outputURL, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let replacement = await queue.retry(id: id)
        XCTAssertNotEqual(replacement, id)
        let final = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(final.items[0].effects, effectivePhotoEffectsSettings(effects, isPro: true))
        XCTAssertNotNil(final.items[0].frameURL)
        XCTAssertNil(final.items[0].error)
        let selections = await renderer.selections
        XCTAssertEqual(selections, Array(repeating: effectivePhotoEffectsSettings(effects, isPro: true), count: 2))
    }

    func testViewModelManualOfflineSingleBatchAndDeferredStart() async throws {
        for batch in [false, true] {
            for deferred in [false, true] {
                let (queue, directory) = try fixture()
                let model = TransferQueueViewModel(queue: queue)
                let files = batch ? [file(1), file(2)] : [file(1)]
                for item in files {
                    try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(item.fileName))
                }
                if deferred {
                    if batch { model.enqueue(files, storageMode: .unified) }
                    else { model.enqueue(files[0], storageMode: .unified) }
                    let waiting = try await wait(queue) { $0.items.count == files.count }
                    XCTAssertTrue(waiting.items.allSatisfy { $0.status == .waiting })
                    XCTAssertFalse(waiting.isTransferring)
                    model.start(session: nil, directory: directory)
                } else if batch {
                    model.enqueue(files, autoStart: nil, directory: directory, storageMode: .unified)
                } else {
                    model.enqueue(files[0], autoStart: nil, directory: directory, storageMode: .unified)
                }
                let final = try await wait(queue) {
                    $0.items.count == files.count && !$0.isTransferring && $0.items.allSatisfy { $0.status == .completed }
                }
                XCTAssertTrue(final.items.allSatisfy { $0.outputURL != nil && $0.skipped })
                withExtendedLifetime(model) {}
            }
        }
    }

    func testViewModelOfflineCropStartsImmediatelyOrAfterExplicitStart() async throws {
        for deferred in [false, true] {
            let (queue, directory) = try fixture()
            let model = TransferQueueViewModel(queue: queue)
            let (source, task, bytes) = try cropIntegrityFixture(in: directory)
            let original = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count),
                fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
            model.enqueueCrop(original, task: task, storageMode: .unified,
                session: nil, directory: deferred ? nil : directory)
            if deferred {
                let waiting = try await wait(queue) { $0.items.count == 1 }
                XCTAssertEqual(waiting.items[0].status, .waiting)
                XCTAssertFalse(waiting.isTransferring)
                model.start(session: nil, directory: directory)
            }
            let final = try await wait(queue) {
                $0.items.count == 1 && !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].cropURL != nil
            }
            XCTAssertEqual(final.items[0].status, .completed)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(final.items[0].cropURL).path))
            withExtendedLifetime(model) {}
        }
    }

    func testDeferredSelectionResolvesOriginalAfterOfflinePublication() async throws {
        for deferred in [false, true] {
            let (queue, directory) = try fixture()
            let model = TransferQueueViewModel(queue: queue)
            let (source, _, bytes) = try cropIntegrityFixture(in: directory)
            let original = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count),
                fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
            let selection = JpegCropSelection(bounds: .init(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), orientation: 1)
            let accepted = await model.acceptCrop(original, selection: selection, storageMode: .unified,
                session: nil, directory: deferred ? nil : directory)
            XCTAssertTrue(accepted)
            let acknowledged = await queue.snapshot()
            XCTAssertEqual(acknowledged.items.count, 1)
            XCTAssertEqual(acknowledged.items[0].cropSelection, selection)
            if deferred {
                let waiting = try await wait(queue) { $0.items.count == 1 }
                XCTAssertEqual(waiting.items[0].status, .waiting)
                XCTAssertFalse(waiting.isTransferring)
                model.start(session: nil, directory: directory)
            }
            let final = try await wait(queue) {
                $0.items.count == 1 && !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].cropURL != nil
            }
            XCTAssertEqual(final.items[0].cropSelection, selection)
            XCTAssertNil(final.items[0].cropTask)
            XCTAssertEqual(final.items[0].status, .completed)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(final.items[0].cropURL).path))
            withExtendedLifetime(model) {}
        }
    }

    func testCancelledCropAcknowledgementDoesNotCreateTask() async throws {
        let (queue, _) = try fixture()
        let model = TransferQueueViewModel(queue: queue)
        let candidate = file(1)
        let selection = JpegCropSelection(bounds: .init(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), orientation: 1)
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.acceptCrop(candidate, selection: selection, storageMode: .unified)
        }
        let accepted = await request.value
        XCTAssertFalse(accepted)
        let actorRequest = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.enqueueCrop(candidate, selection: selection, storageMode: .unified)
        }
        let actorResult = await actorRequest.value
        XCTAssertNil(actorResult)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(snapshot.isTransferring)
        withExtendedLifetime(model) {}
    }

    func testGenerationRetryKeepsOriginalDestinationAndMetricsWhileDownloadsPaused() async throws {
        for batch in [false, true] {
            for clearDirectory in [false, true] {
                let renderer = FailOnceFrameRenderer()
                let probe = DirectoryScopeProbe()
                let (queue, directory) = try fixture(accessOperations: probe.operations) { source, settings, target, _ in
                    XCTAssertEqual(source.deletingLastPathComponent(), target)
                    XCTAssertGreaterThan(probe.count(target.deletingLastPathComponent()), 0)
                    return try await renderer.render(source: source, settings: settings, directory: target)
                }
                var effects = PhotoEffectsSettings()
                effects.photoFrameEnabled = true
                effects.photoFrameBorderEnabled = false
                let id = await queue.enqueue(file(1), storageMode: .byType, effects: effects)!
                let camera = ControlledTransferCamera()
                await queue.start(session: camera, directory: directory)
                _ = try await wait(queue) { $0.items[0].status == .transferring }
                await queue.enqueue(file(2))
                await queue.pauseAfterCurrentFile()
                await camera.finish(1)
                let failed = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil }
                let old = failed.items[0]
                XCTAssertEqual(old.status, .completed)
                XCTAssertNotNil(old.elapsedMs)
                let other = directory.appendingPathComponent("new-selection", isDirectory: true)
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                await queue.attach(session: nil, directory: clearDirectory ? nil : other)
                if batch { await queue.retryFailed() }
                else { let replacement = await queue.retry(id: id); XCTAssertNotNil(replacement) }
                let result = try await wait(queue) { !$0.items[0].isGeneratingFrame && $0.items[0].frameURL != nil }
                let retried = result.items[0]
                XCTAssertNotEqual(retried.id, old.id)
                XCTAssertEqual(retried.status, .completed)
                XCTAssertEqual(retried.outputURL, old.outputURL)
                XCTAssertEqual(retried.frameURL?.deletingLastPathComponent(), old.outputURL?.deletingLastPathComponent())
                XCTAssertEqual(retried.elapsedMs, old.elapsedMs)
                XCTAssertEqual(retried.downloadMBps, old.downloadMBps)
                XCTAssertEqual(retried.bytesPerSecond, old.bytesPerSecond)
                XCTAssertEqual(retried.progress, old.progress)
                XCTAssertNil(retried.frameError)
                XCTAssertTrue(result.pauseAfterCurrent)
                XCTAssertFalse(result.isTransferring)
                XCTAssertEqual(result.items[1].status, .waiting)
                XCTAssertEqual(probe.count(directory), 0)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
            }
        }
    }

    func testNewDownloadRemainsCompletedWhenOnlyItsFrameFails() async throws {
        let (queue, directory) = try fixture { _, _, _, _ in throw CocoaError(.fileWriteUnknown) }
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        await queue.enqueue(file(1), effects: effects)
        let camera = ControlledTransferCamera()
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await camera.finish(1)
        let final = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(final.items[0].status, .completed)
        XCTAssertNil(final.items[0].error)
        XCTAssertNotNil(final.items[0].frameError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file(1).fileName).path))
    }

    func testCancellationAfterCropPublicationRetainsCompletedOriginalAndPublishedCrop() async throws {
        let (queue, directory) = try fixture(cropRenderer: { task, source, directory in
            let published = try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory)
            // Deterministic boundary: publication is complete, but the queue
            // has not yet resumed to record the URL.
            withUnsafeCurrentTask { $0?.cancel() }
            return published
        })
        let (source, task, bytes) = try cropIntegrityFixture(in: directory)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count),
                              fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
        _ = await queue.enqueueCrop(file, task: task)
        await queue.start(session: nil, directory: directory)
        let cancelled = try await wait(queue) { !$0.isTransferring && $0.items.first?.cropURL != nil && $0.items.first?.isGeneratingFrame == false }
        XCTAssertEqual(cancelled.items[0].status, .completed)
        let published = try XCTUnwrap(cancelled.items[0].cropURL)
        await queue.startPendingTransfers(session: nil, directory: directory)
        let resumed = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .completed }
        XCTAssertEqual(resumed.items[0].cropURL, published)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       [source.lastPathComponent, published.lastPathComponent].sorted())
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCropFailureKeepsOriginalAndCanRetryDerivedWorkOffline() async throws {
        let (queue, directory) = try fixture()
        let sourceFile = file(1)
        let original = directory.appendingPathComponent(sourceFile.fileName)
        // Use a valid crop recipe against malformed JPEG bytes. The native
        // bridge must convert libjpeg errors into a failed derived task.
        let encoded = Data(repeating: 1, count: 10)
        let source = CameraFile(id: sourceFile.id, storageID: sourceFile.storageID, format: sourceFile.format,
                                size: UInt64(encoded.count), fileName: sourceFile.fileName,
                                captureDate: sourceFile.captureDate, isProtected: sourceFile.isProtected)
        try encoded.write(to: original)
        let cropSource = JpegCropSource(width: 16, height: 16, mcuWidth: 16, mcuHeight: 16, orientation: 1)
        let crop = LosslessCropTask(fileID: source.id,
                                    recipe: JpegCropRecipe(source: cropSource,
                                                           rect: .init(left: 0, top: 0, right: 16, bottom: 16)))
        let queuedID = await queue.enqueueCrop(source, task: crop)
        let id = try XCTUnwrap(queuedID)
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil }
        XCTAssertEqual(failed.items[0].status, .completed)
        XCTAssertEqual(failed.items[0].outputURL, original)
        XCTAssertNil(failed.items[0].cropURL)
        XCTAssertNotNil(failed.items[0].frameError)

        let replacement = await queue.retry(id: id)
        XCTAssertNotNil(replacement)
        let retried = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil }
        XCTAssertEqual(retried.items[0].status, .completed)
        XCTAssertEqual(retried.items[0].outputURL, original)
        XCTAssertNil(retried.items[0].cropURL)
    }

    func testDeferredCropRetryReusesPublishedCropBeforeReadingOriginal() async throws {
        let renderer = FailOnceFrameRenderer()
        let (queue, directory) = try fixture { source, settings, target, _ in
            try await renderer.render(source: source, settings: settings, directory: target)
        }
        let (original, _, bytes) = try cropIntegrityFixture(in: directory)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count),
            fileName: original.lastPathComponent, captureDate: nil, isProtected: false)
        let selection = JpegCropSelection(bounds: .init(left: 0, top: 0, right: 0.75, bottom: 0.75), orientation: 1)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        let queued = await queue.enqueueCrop(file, selection: selection, storageMode: .unified, effects: effects)
        let id = try XCTUnwrap(queued)
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) {
            !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil
        }
        let published = try XCTUnwrap(failed.items[0].cropURL)
        let publishedBytes = try Data(contentsOf: published)
        // The published derivative is independently usable on retry.
        try Data(repeating: 0, count: bytes.count).write(to: original)
        let replacement = await queue.retry(id: id)
        XCTAssertNotNil(replacement)
        let completed = try await wait(queue) {
            !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameURL != nil
        }
        XCTAssertEqual(completed.items[0].cropURL, published)
        XCTAssertEqual(completed.items[0].cropSelection, selection)
        XCTAssertEqual(try Data(contentsOf: published), publishedBytes)
        XCTAssertNil(completed.items[0].frameError)
    }

    func testDeferredCropOrientationFailureRetainsSelectionAndRecoversOnRetry() async throws {
        let (queue, directory) = try fixture()
        let (original, _, bytes) = try cropIntegrityFixture(in: directory)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(bytes.count),
            fileName: original.lastPathComponent, captureDate: nil, isProtected: false)
        let selection = JpegCropSelection(bounds: .init(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9),
            orientation: 6, ratioWidth: 3, ratioHeight: 4)
        let queued = await queue.enqueueCrop(file, selection: selection, storageMode: .unified)
        let id = try XCTUnwrap(queued)
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) {
            !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].frameError != nil
        }
        XCTAssertEqual(failed.items[0].status, .completed)
        XCTAssertEqual(failed.items[0].cropSelection, selection)
        XCTAssertNil(failed.items[0].cropURL)
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        // Simulate the original becoming readable with the captured direction;
        // retry must use the frozen selection, never a new editor default.
        let image = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
        let corrected = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(corrected,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (corrected as Data).write(to: original)
        let replacement = await queue.retry(id: id)
        XCTAssertNotNil(replacement)
        let complete = try await wait(queue) {
            !$0.isTransferring && !$0.items[0].isGeneratingFrame && $0.items[0].cropURL != nil
        }
        XCTAssertEqual(complete.items[0].cropSelection, selection)
        XCTAssertNil(complete.items[0].frameError)
        XCTAssertEqual(try Data(contentsOf: original), corrected as Data)
        let source = try XCTUnwrap(parseJpegCropHeader(corrected as Data))
        let expected = try selection.resolve(source)
        let output = try XCTUnwrap(complete.items[0].cropURL)
        let result = try XCTUnwrap(parseJpegCropHeader(Data(contentsOf: output)))
        XCTAssertEqual(result.width, expected.rect.width)
        XCTAssertEqual(result.height, expected.rect.height)
        XCTAssertEqual(result.orientation, 6)
    }

    func testInvalidDestinationClearsQueueDirectoryAndDoesNotRestartOnRetry() async throws {
        let (queue, directory) = try fixture()
        let id = await queue.enqueue(file(1))!
        try FileManager.default.removeItem(at: directory)
        await queue.start(session: nil, directory: directory)
        let invalid = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(invalid.items[0].error, AppLocalized.resource("error_dir_invalid"))
        let retry = await queue.retry(id: id)
        XCTAssertNil(retry)
    }

    func testReselectedDirectoryCanRetryWithoutHistoricalErrorInvalidatingIt() async throws {
        let (queue, directory) = try fixture()
        let id = await queue.enqueue(file(1))!
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        await queue.start(session: nil, directory: missing)
        let invalid = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(invalid.invalidatedDirectory, missing)
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.attach(session: nil, directory: directory)
        let selected = await snapshot(queue)
        XCTAssertNil(selected.invalidatedDirectory)
        XCTAssertNotNil(selected.items[0].error)
        let attempt = await queue.retry(id: id)
        XCTAssertNotNil(attempt)
        let completed = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed }
        XCTAssertNil(completed.invalidatedDirectory)
        XCTAssertEqual(completed.items[0].outputURL?.deletingLastPathComponent(), directory)
    }
}

private actor UnknownSizeProgressCamera: TransferDownloading {
    private var continuation: CheckedContinuation<Void, Never>?
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraTransportError.unavailable
    }
    func downloadWithMetrics(file: CameraFile, to directory: URL,
                             progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> URL {
        progress?(.init(fraction: 0, downloaded: 1024, total: 0))
        await withCheckedContinuation { continuation = $0 }
        let output = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 1, count: 2048).write(to: output)
        return output
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor ControlledTransferCamera: TransferDownloading {
    private(set) var requests: [UInt32] = []
    private var waiting: [UInt32: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<UInt32> = []

    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        requests.append(file.id)
        if finished.remove(file.id) == nil {
            await withCheckedContinuation { waiting[file.id] = $0 }
        }
        progress?(1)
        let result = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 1, count: Int(file.size)).write(to: result)
        return result
    }

    func finish(_ id: UInt32) {
        if let continuation = waiting.removeValue(forKey: id) { continuation.resume() }
        else { finished.insert(id) }
    }
}

private actor ResumeUnavailableCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraRepositoryError.resumeUnavailable
    }
}

private actor ControlledFrameRenderer {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var active = 0
    private(set) var peak = 0

    func render(source: URL, directory: URL) async throws -> URL {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if !released { await withCheckedContinuation { waiting.append($0) } }
        let result = directory.appendingPathComponent(source.lastPathComponent + ".frame.jpg")
        try Data([1]).write(to: result)
        return result
    }

    func releaseAll() {
        released = true
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FailOnceFrameRenderer {
    private(set) var selections: [PhotoEffectsSettings] = []
    func render(source: URL, settings: PhotoEffectsSettings, directory: URL) throws -> URL {
        selections.append(settings)
        if selections.count == 1 { throw CocoaError(.fileWriteUnknown) }
        let result = directory.appendingPathComponent(source.lastPathComponent + ".frame.jpg")
        try Data([1]).write(to: result)
        return result
    }
}

extension DomainModelTests {
    func testThumbnailCacheIdentityMatchesAndroidSerialAndResponderFallbacks() {
        let validSerial = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: " 12345 ")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: validSerial,
                                                     transportIdentifier: "guid-fallback"),
                       "Nikon\u{0}Z 8\u{0}12345")

        for placeholder in ["", " ", "unknown", "NONE", "null", "n/a", "00-00"] {
            let info = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: placeholder)
            XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: info,
                                                         transportIdentifier: " responder-guid "),
                           "Nikon\u{0}Z 8\u{0}responder-guid")
        }
    }

    func testThumbnailCacheIdentityStillScopesCameraWithoutAnyPhysicalIdentifier() {
        let info = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: "0000")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: info, transportIdentifier: "---"),
                       "Nikon\u{0}Z 8\u{0}unknown-device")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: nil, transportIdentifier: "abc123"),
                       "\u{0}\u{0}abc123")
    }

    private func deviceInfo(manufacturer: String, model: String, serial: String) -> PTPDeviceInfo {
        PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
                      vendorExtensionDescription: "", functionalMode: 0,
                      manufacturer: manufacturer, model: model, version: "", serialNumber: serial,
                      operations: [], events: [], properties: [], captureFormats: [], imageFormats: [])
    }

    func testExportedOriginalIndexMatchesCopyNameSizeAndDestination() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: "20260817T120000", isProtected: false)
        let copy = URL(fileURLWithPath: "/exports/ZT2026-08-17/dsc_0001 (2).jpg")
        var index = ExportedOriginalIndex()
        XCTAssertTrue(index.add(copy, size: 100, folderName: "ZT2026-08-17"))
        XCTAssertFalse(index.add(copy, size: 100, folderName: "ZT2026-08-17"))
        XCTAssertEqual(index.original(for: file, folderName: "ZT2026-08-17"), copy)
        XCTAssertNil(index.original(for: file, folderName: nil))
        XCTAssertNil(index.original(for: file, folderName: "ZT2026-08-18"))
        let wrongSize = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 99,
                                   fileName: file.fileName, captureDate: file.captureDate, isProtected: false)
        XCTAssertNil(index.original(for: wrongSize, folderName: "ZT2026-08-17"))
        let unknown = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(UInt32.max),
                                fileName: file.fileName, captureDate: file.captureDate, isProtected: false)
        XCTAssertEqual(index.original(for: unknown, folderName: "ZT2026-08-17"), copy)
    }

    func testExportedOriginalSurvivesFrameFailureAndQueueClearing() {
        let root = URL(fileURLWithPath: "/exports", isDirectory: true)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        let output = root.appendingPathComponent(file.fileName)
        let failedFrame = TransferQueueItem(id: UUID(), file: file, status: .failed, outputURL: output)
        var index = ExportedOriginalIndex()
        XCTAssertTrue(index.record([failedFrame], root: root))
        XCTAssertFalse(index.record([], root: root))
        XCTAssertEqual(index.original(for: file, folderName: nil), output)
        XCTAssertFalse(index.record([failedFrame], root: root))
    }

    func testLateOldDirectoryOutputDoesNotPolluteNewExportIndex() {
        let oldRoot = URL(fileURLWithPath: "/old", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/new", isDirectory: true)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        let oldTask = TransferQueueItem(id: UUID(), file: file, status: .completed,
                                        outputURL: oldRoot.appendingPathComponent(file.fileName))
        var index = ExportedOriginalIndex()
        XCTAssertFalse(index.record([oldTask], root: newRoot))
        XCTAssertNil(index.original(for: file, folderName: nil))
        let changedHandle = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 100,
                                       fileName: file.fileName, captureDate: nil, isProtected: false)
        let output = newRoot.appendingPathComponent(file.fileName)
        index.add(output, size: 100, folderName: nil)
        XCTAssertEqual(index.original(for: changedHandle, folderName: nil), output)
    }
}

/// Exercises the production reservation and JPEG publisher, rather than the
/// queue's injected renderer. Android reserves names before publishing copies.
final class PhotoFramePublicationTests: XCTestCase {
    func testOverlappingReservationsAndFailureReleasePreserveExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("FRAME.JPG")
        let original = Data("existing output".utf8)
        try original.write(to: existing)
        let preferred = directory.appendingPathComponent("frame.jpg")
        let names = OutputFileNameReservations()
        enum Failure: Error { case expected }
        XCTAssertThrowsError(try names.withReservedName(preferred) { first in
            XCTAssertEqual(first.lastPathComponent, "frame (1).jpg")
            // Both names remain reserved before either output exists. This also
            // proves disk work does not hold the reservation lock.
            try names.withReservedName(preferred) { second in
                XCTAssertEqual(second.lastPathComponent, "frame (2).jpg")
                try Data("second output".utf8).write(to: second)
            }
            throw Failure.expected
        })
        try names.withReservedName(preferred) { next in
            XCTAssertEqual(next.lastPathComponent, "frame (1).jpg")
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testConcurrentRealJPEGExportsKeepExistingOutputAndSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = directory.appendingPathComponent("ZTFrames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try original.write(to: source)
        let settings = PhotoEffectsSettings()
        let existing = frames.appendingPathComponent(androidPhotoFrameOutputName(sourceName: source.lastPathComponent, settings: settings))
        let previous = Data("previous output must survive".utf8)
        try previous.write(to: existing)
        async let first = TransferQueue.renderFrameFile(source: source, settings: settings, directory: directory, metadata: nil)
        async let second = TransferQueue.renderFrameFile(source: source, settings: settings, directory: directory, metadata: nil)
        let outputs = try await [first, second]
        XCTAssertNotEqual(outputs[0], outputs[1])
        for output in outputs {
            XCTAssertNotEqual(output, existing)
            XCTAssertNotNil(UIImage(contentsOfFile: output.path)?.cgImage)
        }
        XCTAssertEqual(try Data(contentsOf: existing), previous)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: frames.path).contains { $0.hasPrefix(".nkframe_") })
    }
}

final class GalleryMatPhotoIntegrityTests: XCTestCase {
    func testOriginalExportsKeepEveryPhotoPixelAtAllRequestedWidths() throws {
        try verify(preview: false)
    }

    func testPreviewsKeepAllFourCornersAndSourceAspectAtAllRequestedWidths() throws {
        try verify(preview: true)
    }

    private func verify(preview: Bool) throws {
        for size in [CGSize(width: 1000, height: 500), CGSize(width: 500, height: 1000), CGSize(width: 1000, height: 1000)] {
            for percent in [60, 65, 100, 200] {
                try autoreleasepool {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                            color.setFill()
                            context.fill(CGRect(x: CGFloat(index % 2) * size.width / 2,
                                                y: CGFloat(index / 2) * size.height / 2,
                                                width: size.width / 2, height: size.height / 2))
                        }
                    }
                    var settings = PhotoEffectsSettings()
                    settings.photoFrameEnabled = true
                    settings.photoFramePreset = .galleryMat
                    settings.watermark.enabled = false
                    settings.metadata.widthPercent = percent
                    let full = try PhotoEffectsRenderer.render(source, settings: settings)
                    let output = try preview ? PhotoEffectsRenderer.render(source, settings: settings, previewLongEdge: 480) : full
                    let cg = try XCTUnwrap(output.cgImage)
                    let label = "\(size), width=\(percent), preview=\(preview)"
                    XCTAssertEqual(cg.width, cg.height, label)
                    if preview { XCTAssertEqual(cg.width, 480, label) }
                    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                    let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    var counts = [Int](repeating: 0, count: 4)
                    var minX = cg.width, maxX = -1, minY = cg.height, maxY = -1
                    for y in 0..<cg.height {
                        for x in 0..<cg.width {
                            let offset = (y * cg.width + x) * 4
                            let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                            let index: Int?
                            if r > 250 && g < 5 && b < 5 { index = 0 }
                            else if r < 5 && g > 250 && b < 5 { index = 1 }
                            else if r < 5 && g < 5 && b > 250 { index = 2 }
                            else if r > 250 && g > 250 && b < 5 { index = 3 }
                            else { index = nil }
                            if let index {
                                counts[index] += 1
                                minX = min(minX, x); maxX = max(maxX, x)
                                minY = min(minY, y); maxY = max(maxY, y)
                            }
                        }
                    }
                    let scale = preview ? 480 / full.size.width : 1
                    XCTAssertEqual(CGFloat(maxX - minX + 1), size.width * scale, accuracy: preview ? 2 : 0, label)
                    XCTAssertEqual(CGFloat(maxY - minY + 1), size.height * scale, accuracy: preview ? 2 : 0, label)
                    for count in counts {
                        let expected = size.width * size.height * scale * scale / 4
                        // Preview resampling blends pixels along each quadrant's
                        // perimeter. Bound that fringe in pixels, not a percentage
                        // of the area; full-resolution export stays exact.
                        let fringe = preview ? (size.width + size.height) * scale : 0
                        XCTAssertEqual(CGFloat(count), expected, accuracy: fringe, label)
                    }
                    XCTAssertGreaterThan(minX, 0, label)
                    XCTAssertGreaterThan(minY, 0, label)
                    XCTAssertLessThan(maxX, cg.width - 1, label)
                    XCTAssertLessThan(maxY, cg.height - 1, label)
                }
            }
        }
    }
}

final class LosslessCropIntegrityTests: XCTestCase {
    func testValidHeaderWithTruncatedEntropyFailsNativeAndProcessorThenRetries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.jpg")
        let directOutput = directory.appendingPathComponent("native.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image { context in
            for y in 0..<96 {
                for x in 0..<128 {
                    UIColor(red: CGFloat((x * 37 + y * 71) % 256) / 255,
                            green: CGFloat((x * 53 + y * 23) % 256) / 255,
                            blue: CGFloat((x * 13 + y * 41) % 256) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        let source = try XCTUnwrap(parseJpegCropHeader(original))
        let rect = CropRect(left: 16, top: 16, right: 80, bottom: 80)
        let task = LosslessCropTask(fileID: 1, recipe: JpegCropRecipe(source: source, rect: rect))
        let sos = try XCTUnwrap(original.range(of: Data([0xff, 0xda]))).lowerBound
        for count in [sos + 16, (sos + original.count) / 2, original.count - 2] {
            let truncated = Data(original.prefix(count))
            // The Swift header guard accepts this input; failure must come from
            // the packaged native coefficient decoder, not malformed SOF data.
            XCTAssertEqual(parseJpegCropHeader(truncated), source)
            try truncated.write(to: input)
            XCTAssertFalse(LosslessJpegBridge.crop(input: input, output: directOutput, source: source, rect: rect))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directOutput.path))
            XCTAssertThrowsError(try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory))
            XCTAssertEqual(try Data(contentsOf: input), truncated)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.jpg"])
            try original.write(to: input)
            let output = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory)
            let decoded = try XCTUnwrap(UIImage(contentsOfFile: output.path)?.cgImage)
            XCTAssertEqual(decoded.width, 64)
            XCTAssertEqual(decoded.height, 64)
            XCTAssertEqual(try Data(contentsOf: input), original)
            try FileManager.default.removeItem(at: output)
        }
    }
}

private func cropIntegrityFixture(in directory: URL) throws -> (URL, LosslessCropTask, Data) {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image { context in
        UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
    }
    let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
    let header = try XCTUnwrap(parseJpegCropHeader(bytes))
    let task = LosslessCropTask(fileID: 1, recipe: JpegCropRecipe(source: header,
        rect: CropRect(left: 16, top: 16, right: 80, bottom: 80)))
    let source = directory.appendingPathComponent("source.jpg")
    try bytes.write(to: source)
    return (source, task, bytes)
}

private final class CropTransformBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var paths: [URL] = []
    var outputs: [URL] { condition.withLock { paths } }
    func release() { condition.withLock { released = true; condition.broadcast() } }
    func transform(_ source: URL, _ output: URL, _ header: JpegCropSource, _ rect: CropRect) -> Bool {
        let result = LosslessJpegBridge.crop(input: source, output: output, source: header, rect: rect)
        condition.lock()
        paths.append(output)
        while !released { condition.wait() }
        condition.unlock()
        return result
    }
    func waitForTransforms(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while outputs.count < count {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class LosslessCropLifecycleTests: XCTestCase {
    func testConcurrentCropsOwnSeparateStagingAndPublicationNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, task, original) = try cropIntegrityFixture(in: directory)
        let barrier = CropTransformBarrier()
        defer { barrier.release() }
        let first = Task { try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory, transform: barrier.transform) }
        let second = Task { try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory, transform: barrier.transform) }
        try await barrier.waitForTransforms(2)
        XCTAssertEqual(Set(barrier.outputs).count, 2)
        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: directory), 0)
        XCTAssertTrue(barrier.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        barrier.release()
        let results = try await [first.value, second.value]
        XCTAssertNotEqual(results[0], results[1])
        for result in results { XCTAssertEqual(UIImage(contentsOfFile: result.path)?.cgImage?.width, 64) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testCancellationAfterNativeWorkRemovesOnlyOwnedStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, task, original) = try cropIntegrityFixture(in: directory)
        let existing = LosslessCropProcessor.outputURL(for: source, in: directory)
        try original.write(to: existing)
        let barrier = CropTransformBarrier()
        defer { barrier.release() }
        let operation = Task { try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory, transform: barrier.transform) }
        try await barrier.waitForTransforms(1)
        operation.cancel()
        barrier.release()
        do { _ = try await operation.value; XCTFail("Cancelled native result was published") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testPreCancelledCropDoesNotCreateStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, task, _) = try cropIntegrityFixture(in: directory)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory)
        }
        do { _ = try await operation.value; XCTFail("Pre-cancelled crop completed") }
        catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.jpg"])
    }

    func testStartupCleanupRemovesOldSessionsButPreservesActiveAndUnknownDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = try LosslessCropTemporaryFiles.create(in: directory)
        let unknown = directory.appendingPathComponent(".nkcrop_user-folder")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        for parent in [directory, directory.appendingPathComponent("ZT2026-10-15"), directory.appendingPathComponent("ZT-JPG")] {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let old = parent.appendingPathComponent(".nkcrop_crop-\(UUID().uuidString)_\(UUID().uuidString).part")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
            try Data([1]).write(to: old.appendingPathComponent("cropped.jpg"))
        }
        let legacy = directory.appendingPathComponent(".nkcrop_(UUID().uuidString).part")
        try Data([1]).write(to: legacy)
        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: directory), 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: directory), 0)
    }
}

/// Independent TIFF fixtures include a real IFD1 JPEG and opaque MakerNote/XMP
/// bytes. Merely clearing the thumbnail pointer would still fail these checks.
final class LosslessCropMetadataTests: XCTestCase {
    private struct Tag {
        let id: UInt16
        let type: UInt16
        let count: UInt32
        let bytes: [UInt8]
    }
    private func number(_ value: UInt32, _ size: Int, little: Bool) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : size - 1 - $0) * 8)) }
    }
    private func read(_ bytes: [UInt8], _ at: Int, _ size: Int, little: Bool) -> UInt32 {
        (0..<size).reduce(0) { $0 | UInt32(bytes[at + $1]) << ((little ? $1 : size - 1 - $1) * 8) }
    }
    private func jpegMarker(_ code: UInt8, _ payload: [UInt8]) -> Data {
        Data([0xff, code, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)] + payload)
    }
    private func segments(_ data: Data, code: UInt8) -> [[UInt8]] {
        var at = 2, result: [[UInt8]] = []
        while at + 4 <= data.count, data[at] == 0xff {
            let marker = data[at + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let count = Int(data[at + 2]) * 256 + Int(data[at + 3])
            guard count >= 2, at + count + 2 <= data.count else { break }
            if marker == code { result.append(Array(data[(at + 4)..<(at + count + 2)])) }
            at += count + 2
        }
        return result
    }
    private func entropyBytes(_ jpeg: Data) throws -> Data {
        var at = 2
        while at + 4 <= jpeg.count, jpeg[at] == 0xff {
            if jpeg[at + 1] == 0xda { return Data(jpeg[at...]) }
            at += Int(jpeg[at + 2]) * 256 + Int(jpeg[at + 3]) + 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func removingSourceMetadata(_ jpeg: Data) -> Data {
        var result = Data(jpeg.prefix(2)), at = 2
        while at + 4 <= jpeg.count, jpeg[at] == 0xff {
            let code = jpeg[at + 1]
            if code == 0xda || code == 0xd9 { break }
            let length = Int(jpeg[at + 2]) * 256 + Int(jpeg[at + 3])
            if code != 0xe1 && code != 0xe2 { result.append(jpeg[at..<(at + length + 2)]) }
            at += length + 2
        }
        result.append(jpeg[at...])
        return result
    }

    private func fields(_ tiff: [UInt8], at: Int, little: Bool) -> [UInt16: Tag] {
        var result: [UInt16: Tag] = [:]
        for index in 0..<Int(read(tiff, at, 2, little: little)) {
            let offset = at + 2 + index * 12
            let id = UInt16(read(tiff, offset, 2, little: little))
            let type = UInt16(read(tiff, offset + 2, 2, little: little))
            let count = read(tiff, offset + 4, 4, little: little)
            let unit = [3: 2, 4: 4, 5: 8, 9: 4, 10: 8][Int(type)] ?? 1
            let length = Int(count) * unit
            let start = length <= 4 ? offset + 8 : Int(read(tiff, offset + 8, 4, little: little))
            result[id] = Tag(id: id, type: type, count: count, bytes: Array(tiff[start..<(start + length)]))
        }
        return result
    }

    func testWhitelistRebuildRemovesThumbnailAndPreservesICCOrientationGPSAndDimensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (input, _, jpeg) = try cropIntegrityFixture(in: directory)
        let baseJPEG = removingSourceMetadata(jpeg)
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let icc = Array("ICC_PROFILE\0".utf8) + [1, 1] + Array(profile)
        for little in [false, true] {
            for dimensionsShort in [false, true] {
                for orientation in 1...8 {
                    func scalar(_ id: UInt16, _ value: UInt32, short: Bool = true) -> Tag {
                        Tag(id: id, type: short ? 3 : 4, count: 1, bytes: number(value, short ? 2 : 4, little: little))
                    }
                    func text(_ id: UInt16, _ value: String, type: UInt16 = 2) -> Tag {
                        let bytes = Array(value.utf8) + [0]
                        return Tag(id: id, type: type, count: UInt32(bytes.count), bytes: bytes)
                    }
                    func rational(_ id: UInt16, _ values: [UInt32], signed: Bool = false) -> Tag {
                        Tag(id: id, type: signed ? 10 : 5, count: UInt32(values.count / 2),
                            bytes: values.flatMap { number($0, 4, little: little) })
                    }
                    let rootTags = [text(0x010f, "Nikon"), text(0x0110, "Crop fixture"), text(0x0131, "Camera software"), text(0x0132, "2026:10:15 12:34:56")]
                    let exifTags: [Tag] = [
                        text(0x9003, "2026:10:15 12:34:56"), text(0x9004, "2026:10:15 12:34:56"), text(0x9291, "123"), text(0x9011, "+08:00"),
                        rational(0x829a, [1, 125]), rational(0x829d, [28, 10]), scalar(0x8827, 100), rational(0x920a, [50, 1]), scalar(0xa405, 75),
                        text(0xa433, "Nikon"), text(0xa434, "24-70mm"), scalar(0x8822, 3), rational(0x9204, [UInt32.max, 3], signed: true),
                        scalar(0x9207, 5), scalar(0x9209, 0), scalar(0xa403, 1), scalar(0xa001, 1)
                    ]
                    let gpsTags: [Tag] = [
                        Tag(id: 0, type: 1, count: 4, bytes: [2, 3, 0, 0]), text(1, "N"), rational(2, [31, 1, 0, 1, 0, 1]),
                        text(3, "E"), rational(4, [121, 1, 0, 1, 0, 1]), Tag(id: 5, type: 1, count: 1, bytes: [0]), rational(6, [100, 1]),
                        rational(7, [12, 1, 34, 1, 56, 1]), text(29, "2026:10:15"), text(27, "ASCII\0\0\0GPS", type: 7),
                        text(12, "K"), rational(13, [10, 1]), text(14, "T"), rational(15, [180, 1])
                    ]
                    var root = rootTags + [scalar(0x0100, 128, short: dimensionsShort), scalar(0x0101, 96, short: dimensionsShort), scalar(0x0112, UInt32(orientation))]
                    let exif = exifTags + [scalar(0xa002, 128, short: dimensionsShort), scalar(0xa003, 96, short: dimensionsShort), text(0x927c, "UNCROPPED_MAKERNOTE", type: 7)]
                    let exifAt = 8 + 2 + (root.count + 2) * 12 + 4
                    let gpsAt = exifAt + 2 + exif.count * 12 + 4
                    let thumbAt = gpsAt + 2 + gpsTags.count * 12 + 4
                    var tiff = [UInt8](repeating: 0, count: thumbAt + 2 + 2 * 12 + 4)
                    tiff.replaceSubrange(0..<8, with: (little ? [0x49, 0x49] : [0x4d, 0x4d]) + number(42, 2, little: little) + number(8, 4, little: little))
                    func put(_ values: [Tag], at: Int, next: Int = 0) {
                        tiff.replaceSubrange(at..<(at + 2), with: number(UInt32(values.count), 2, little: little))
                        for (index, tag) in values.enumerated() {
                            let offset = at + 2 + index * 12
                            let header = number(UInt32(tag.id), 2, little: little) + number(UInt32(tag.type), 2, little: little) + number(tag.count, 4, little: little)
                            tiff.replaceSubrange(offset..<(offset + 8), with: header)
                            if tag.bytes.count <= 4 { tiff.replaceSubrange((offset + 8)..<(offset + 8 + tag.bytes.count), with: tag.bytes) }
                            else {
                                tiff.replaceSubrange((offset + 8)..<(offset + 12), with: number(UInt32(tiff.count), 4, little: little))
                                tiff.append(contentsOf: tag.bytes)
                            }
                        }
                        let end = at + 2 + values.count * 12
                        tiff.replaceSubrange(end..<(end + 4), with: number(UInt32(next), 4, little: little))
                    }
                    root += [scalar(0x8769, UInt32(exifAt), short: false), scalar(0x8825, UInt32(gpsAt), short: false)]
                    put(root, at: 8, next: thumbAt); put(exif, at: exifAt); put(gpsTags, at: gpsAt)
                    let thumbnailOffset = tiff.count
                    tiff += Array(jpeg) + Array("UNCROPPED_THUMBNAIL".utf8)
                    put([scalar(0x0201, UInt32(thumbnailOffset), short: false), scalar(0x0202, UInt32(jpeg.count), short: false)], at: thumbAt)
                    // ICC precedes APP1, which defeated the old transupp-dependent rewrite.
                    let fixture = baseJPEG.prefix(2) + jpegMarker(0xe2, icc) + jpegMarker(0xe1, Array("Exif\0\0".utf8) + tiff)
                        + jpegMarker(0xe1, Array("XMP_UNCROPPED".utf8)) + jpegMarker(0xe2, Array("MPF_UNCROPPED".utf8)) + baseJPEG.dropFirst(2)
                    XCTAssertEqual(segments(fixture, code: 0xe1).filter { $0.starts(with: Array("Exif\0\0".utf8)) }.count, 1)
                    try fixture.write(to: input)
                    let source = try XCTUnwrap(parseJpegCropHeader(fixture))
                    let task = LosslessCropTask(fileID: 1, recipe: JpegCropRecipe(source: source, rect: CropRect(left: 16, top: 16, right: 80, bottom: 64)))
                    let output = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory)
                    defer { try? FileManager.default.removeItem(at: output) }
                    let encoded = try Data(contentsOf: output)
                    XCTAssertEqual(try Data(contentsOf: input), fixture)
                    let header = try XCTUnwrap(parseJpegCropHeader(encoded))
                    XCTAssertEqual(header.width, 64); XCTAssertEqual(header.height, 48); XCTAssertEqual(header.orientation, orientation)
                    let app1 = segments(encoded, code: 0xe1)
                    XCTAssertEqual(app1.count, 1)
                    let rebuilt = Array(try XCTUnwrap(app1.first).dropFirst(6))
                    let rebuiltRoot = fields(rebuilt, at: 8, little: little)
                    let rebuiltExif = fields(rebuilt, at: Int(read(try XCTUnwrap(rebuiltRoot[0x8769]).bytes, 0, 4, little: little)), little: little)
                    let rebuiltGPS = fields(rebuilt, at: Int(read(try XCTUnwrap(rebuiltRoot[0x8825]).bytes, 0, 4, little: little)), little: little)
                    for (expected, actual) in [(rootTags, rebuiltRoot), (exifTags, rebuiltExif), (gpsTags, rebuiltGPS)] {
                        for tag in expected {
                            XCTAssertEqual(actual[tag.id]?.bytes, tag.bytes, "tag \(tag.id)")
                            XCTAssertEqual(actual[tag.id]?.type, tag.type)
                        }
                    }
                    for (tag, expected) in [(UInt16(0x0100), UInt32(64)), (0x0101, 48)] { XCTAssertEqual(read(try XCTUnwrap(rebuiltRoot[tag]).bytes, 0, 4, little: little), expected) }
                    for (tag, expected) in [(UInt16(0xa002), UInt32(64)), (0xa003, 48)] { XCTAssertEqual(read(try XCTUnwrap(rebuiltExif[tag]).bytes, 0, 4, little: little), expected) }
                    XCTAssertEqual(read(rebuilt, 8 + 2 + rebuiltRoot.count * 12, 4, little: little), 0)
                    XCTAssertEqual(segments(encoded, code: 0xe2), [icc])
                    XCTAssertNil(encoded.range(of: jpeg))
                    for forbidden in ["UNCROPPED_MAKERNOTE", "UNCROPPED_THUMBNAIL", "XMP_UNCROPPED", "MPF_UNCROPPED"] {
                        XCTAssertNil(encoded.range(of: Data(forbidden.utf8)))
                    }
                    XCTAssertNotNil(UIImage(contentsOfFile: output.path)?.cgImage)
                    if !little && !dimensionsShort && orientation == 1 {
                        let native = directory.appendingPathComponent("native-coefficients.jpg")
                        let nativeResult = input.path.withCString { from in
                            native.path.withCString { to in
                                nativeCropForExifTest(from, to, Int32(source.width), Int32(source.height),
                                    Int32(source.mcuWidth), Int32(source.mcuHeight), 16, 16, 64, 48)
                            }
                        }
                        XCTAssertEqual(nativeResult, 1)
                        XCTAssertEqual(try entropyBytes(encoded), try entropyBytes(Data(contentsOf: native)),
                                       "EXIF replacement must not re-encode the coefficient crop")
                        try FileManager.default.removeItem(at: native)
                        var invalid = fixture
                        let tiffStart = 2 + jpegMarker(0xe2, icc).count + 4 + 6
                        let gpsPointer = tiffStart + 8 + 2 + (root.count - 1) * 12 + 8
                        invalid.replaceSubrange(gpsPointer..<(gpsPointer + 4), with: [255, 255, 255, 255])
                        XCTAssertEqual(parseJpegCropHeader(invalid), source)
                        try invalid.write(to: input)
                        XCTAssertFalse(LosslessJpegBridge.crop(input: input, output: native, source: source, rect: task.rect))
                        XCTAssertFalse(FileManager.default.fileExists(atPath: native.path))
                        XCTAssertEqual(try Data(contentsOf: input), invalid)
                        try fixture.write(to: input)
                    }
                }
            }
        }
    }
}

@_silgen_name("zt_lossless_jpeg_crop")
private func nativeCropForExifTest(_ input: UnsafePointer<CChar>, _ output: UnsafePointer<CChar>,
                                  _ width: Int32, _ height: Int32, _ mcuWidth: Int32, _ mcuHeight: Int32,
                                  _ x: Int32, _ y: Int32, _ cropWidth: Int32, _ cropHeight: Int32) -> Int32

final class LosslessCropResourceTests: XCTestCase {
    func testCompressedSourceLimitIsInclusiveAndHeaderReadIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, task, original) = try cropIntegrityFixture(in: directory)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(LosslessCropInput.maximumSourceBytes) + 1)
        XCTAssertThrowsError(try LosslessCropInput.sourceHeader(from: source))
        XCTAssertThrowsError(try LosslessCropProcessor.process(task: task, sourceURL: source, directory: directory, transform: { _, _, _, _ in
            XCTFail("Oversized input reached native transform")
            return false
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        try handle.truncate(atOffset: UInt64(LosslessCropInput.maximumSourceBytes))
        let header = try LosslessCropInput.sourceHeader(from: source)
        XCTAssertEqual(header.count, LosslessCropInput.maximumHeaderBytes)
        XCTAssertEqual(header.prefix(original.count), original)
        let output = try LosslessCropProcessor.process(task: task, sourceURL: source, directory: directory)
        XCTAssertEqual(UIImage(contentsOfFile: output.path)?.cgImage?.width, 64)
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, LosslessCropInput.maximumSourceBytes)
    }

    func testOversizedSOFIsRejectedBeforeStagingOrTransform() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, _, original) = try cropIntegrityFixture(in: directory)
        var mutated = original
        let sof = try XCTUnwrap(mutated.range(of: Data([0xff, 0xc0]))).lowerBound
        mutated[sof + 5] = UInt8(10000 >> 8); mutated[sof + 6] = UInt8(10000 & 255)
        mutated[sof + 7] = UInt8(10001 >> 8); mutated[sof + 8] = UInt8(10001 & 255)
        let parsed = try XCTUnwrap(parseJpegCropHeader(mutated))
        XCTAssertFalse(LosslessCropInput.accepts(parsed))
        XCTAssertTrue(LosslessCropInput.accepts(.init(width: 10000, height: 10000, mcuWidth: 16, mcuHeight: 16, orientation: 1)))
        let task = LosslessCropTask(fileID: 1, recipe: .init(source: parsed, rect: .init(left: 0, top: 0, right: 64, bottom: 64)))
        try mutated.write(to: source)
        XCTAssertThrowsError(try LosslessCropProcessor.process(task: task, sourceURL: source, directory: directory, transform: { _, _, _, _ in
            XCTFail("Oversized pixels reached native transform")
            return false
        }))
        XCTAssertEqual(try Data(contentsOf: source), mutated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }
}

private actor CropPermitLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

final class CropSerialAdmissionTests: XCTestCase {
    func testFallbackPreviewCancellationReachesDetachedWaiter() async throws {
        let gate = PhotoEffectsPreviewRenderGate.shared
        let entered = CropPermitLatch()
        let release = CropPermitLatch()
        let owner = Task {
            try await gate.withPermit {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let preview = Task {
            try await PhotoEffectsPreviewRenderGate.render {
                XCTFail("Cancelled fallback entered rendering")
                return 0
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.pendingCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let queued = await gate.pendingCount
        XCTAssertEqual(queued, 1)
        preview.cancel()
        let finished = expectation(description: "Fallback cancellation propagates without waiting for permit")
        let observer = Task {
            do { _ = try await preview.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        await release.open()
        try await owner.value
        await observer.value
        let next = try await PhotoEffectsPreviewRenderGate.render { 42 }
        XCTAssertEqual(next, 42)
    }

    func testCancelledWaiterFinishesWhileOwnerStillHoldsPermitAndNextCropSucceeds() async throws {
        let gate = CancellableSerialWorkGate()
        let entered = CropPermitLatch()
        let release = CropPermitLatch()
        let owner = Task {
            try await gate.withPermit {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let cancelled = Task {
            try await gate.withPermit {
                XCTFail("Cancelled waiter entered codec work")
            }
        }
        // Cancellation must finish independently of the still-running owner.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.pendingCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let queued = await gate.pendingCount
        XCTAssertEqual(queued, 1, "Exercise cancellation after enqueue, not just before admission")
        cancelled.cancel()
        let cancelledFinished = expectation(description: "Cancelled waiter released before owner")
        let observer = Task {
            do { try await cancelled.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            cancelledFinished.fulfill()
        }
        await fulfillment(of: [cancelledFinished], timeout: 2)
        await release.open()
        try await owner.value
        await observer.value
        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testParallelProductionCropsPublishDistinctFilesAndPreserveSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, task, original) = try cropIntegrityFixture(in: directory)
        let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await LosslessCropProcessor.processAsync(task: task, sourceURL: source, directory: directory)
                }
            }
            var result: [URL] = []
            for try await output in group { result.append(output) }
            return result
        }
        XCTAssertEqual(Set(outputs).count, 12)
        for output in outputs {
            XCTAssertEqual(UIImage(contentsOfFile: output.path)?.cgImage?.width, 64)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 13)
    }
}

private actor CropPermitCounter {
    private var active = 0
    func enter() -> Int { active += 1; return active }
    func leave() { active -= 1 }
}

extension CropSerialAdmissionTests {
    func testPermitRemainsExclusiveAcrossSuspensionAndReleasesAfterFailure() async throws {
        let gate = CancellableSerialWorkGate()
        let counter = CropPermitCounter()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    do {
                        try await gate.withPermit {
                            let active = await counter.enter()
                            XCTAssertEqual(active, 1)
                            await Task.yield()
                            await counter.leave()
                            if index.isMultiple(of: 3) { throw LosslessCropProcessorError.cropFailed }
                        }
                    } catch LosslessCropProcessorError.cropFailed {} catch {
                        XCTFail("Unexpected gate error: \(error)")
                    }
                }
            }
        }
        let remaining = await gate.pendingCount
        XCTAssertEqual(remaining, 0)
        let next = try await gate.withPermit { true }
        XCTAssertTrue(next)
    }
}

extension TransferQueueScenarioTests {
    func testInvalidTypeFoldersFailBeforeFilesystemOrCameraAccessAndValidTaskContinues() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let extensions = ["J PG", "J/PG", "J\\PG", String(repeating: "X", count: 62), "照片", "J\nPG"]
        for (index, ext) in extensions.enumerated() {
            await queue.enqueue(file(UInt32(index + 1), name: "photo." + ext), storageMode: .byType)
        }
        await queue.enqueue(file(100), storageMode: .byType)
        await camera.finish(100)
        await queue.start(session: camera, directory: directory)
        let state = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy { $0.status == .failed || $0.status == .completed } }
        for item in state.items.dropLast() {
            XCTAssertEqual(item.status, .failed)
            XCTAssertEqual(item.error, "Invalid transfer folder name: \(item.destinationFolderName!)")
            XCTAssertNil(item.outputURL)
        }
        XCTAssertEqual(state.items.last?.status, .completed)
        let requests = await camera.requests
        XCTAssertEqual(requests, [100])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ZT-JPG"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("ZT-JPG/DSC_100.JPG")), Data(repeating: 1, count: 10))
        let retry = await queue.retry(id: state.items[0].id)
        XCTAssertNotNil(retry)
        let retried = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .failed }
        XCTAssertEqual(retried.items.first?.destinationFolderName, "ZT-J PG")
        let afterRetry = await camera.requests
        XCTAssertEqual(afterRetry, [100])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ZT-JPG"])
    }

    func testSafeFolderLengthBoundaryIsAcceptedByActualWorker() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let extensionName = String(repeating: "A", count: 61)
        await queue.enqueue(file(1, name: "photo." + extensionName), storageMode: .byType)
        await camera.finish(1)
        await queue.start(session: camera, directory: directory)
        let state = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed }
        XCTAssertEqual(state.items[0].destinationFolderName?.count, 64)
        XCTAssertEqual(state.items[0].outputURL?.deletingLastPathComponent().lastPathComponent, "ZT-" + extensionName)
        for invalid in ["", "../JPG", "ZT-JPG\n", "ZT-JPG\r\n", " ZT-JPG", "ZT-JPG ", String(repeating: "A", count: 65)] {
            XCTAssertFalse(isValidTransferFolderName(invalid), "\(invalid.debugDescription)")
        }
    }
}

@MainActor
final class DirectorySelectionPerformanceTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectorySelection-\(UUID())")
        for name in ["old", "slow", "new", "denied", "failed"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let suite = "DirectorySelection-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (root, defaults)
    }

    func testStartupResolveGrantAndRenewalRunOffMainAndRegisterCleanupBeforeAdmission() async throws {
        let (root, defaults) = try fixture()
        let scope = DirectoryScopeProbe(), directory = root.appendingPathComponent("old")
        let saved = Data([1, 2]), renewed = Data([3, 4])
        defaults.set(saved, forKey: "transfer_dir")
        let entered = expectation(description: "Startup resolve entered")
        let cleanupEntered = expectation(description: "Cleanup registered before admission")
        let gate = DirectorySelectionIOGate(url: directory, entered: entered)
        let cleanupGate = CropPermitLatch()
        defer { gate.release.signal() }
        let preparation = TransferDirectoryPreparation { url in
            XCTAssertEqual(url, directory)
            cleanupEntered.fulfill()
            await cleanupGate.wait()
        }
        let operations = DirectoryAccessOperations(start: { url in
            XCTAssertFalse(Thread.isMainThread)
            return scope.operations.start(url)
        }, stop: scope.operations.stop)
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: operations, preparation: preparation,
            makeBookmark: { url in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(url, directory)
                return renewed
            }, resolveBookmark: { data in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(data, saved)
                gate.wait(directory)
                return .init(url: directory, stale: true)
            })
        XCTAssertTrue(store.isRestoring)
        XCTAssertNil(store.directoryURL)
        var admitted = false
        let startup = Task {
            try await store.waitUntilRestored()
            admitted = true
            XCTAssertEqual(store.directoryURL, directory)
            XCTAssertFalse(store.isRestoring)
        }
        await fulfillment(of: [entered], timeout: 2)
        let heartbeat = expectation(description: "Run loop during restore")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        XCTAssertFalse(admitted)
        XCTAssertEqual(defaults.data(forKey: "transfer_dir"), saved)
        gate.release.signal()
        try await startup.value
        await fulfillment(of: [cleanupEntered], timeout: 2)
        XCTAssertEqual(defaults.data(forKey: "transfer_dir"), renewed)
        var writable = false
        let queueAdmission = Task { try await preparation.waitUntilReady(directory); writable = true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while preparation.pendingWaiterCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preparation.pendingWaiterCount, 1)
        XCTAssertFalse(writable)
        await cleanupGate.open()
        try await queueAdmission.value
        store.clear()
        XCTAssertEqual(scope.count(directory), 0)
    }

    func testCancellingStartupWaiterKeepsSharedRestoreAndClearRejectsLateResult() async throws {
        for clear in [false, true] {
            let (root, defaults) = try fixture()
            let scope = DirectoryScopeProbe(), directory = root.appendingPathComponent("old")
            let saved = Data([1, 2])
            defaults.set(saved, forKey: "transfer_dir")
            let entered = expectation(description: "Startup pending")
            let returned = expectation(description: "Provider returned")
            let gate = DirectorySelectionIOGate(url: directory, entered: entered)
            defer { gate.release.signal() }
            let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations,
                preparation: TransferDirectoryPreparation(cleanup: { _ in }), resolveBookmark: { _ in
                    gate.wait(directory)
                    returned.fulfill()
                    return .init(url: directory, stale: false)
                })
            await fulfillment(of: [entered], timeout: 2)
            let registered = expectation(description: "Startup waiter entered")
            let cancelled = Task { registered.fulfill(); try await store.waitUntilRestored() }
            await fulfillment(of: [registered], timeout: 2)
            cancelled.cancel()
            do { try await cancelled.value; XCTFail("Cancelled waiter must leave promptly") }
            catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
            XCTAssertTrue(store.isRestoring)
            let surviving = Task { try await store.waitUntilRestored() }
            if clear { store.clear(); try await surviving.value; XCTAssertFalse(store.isRestoring) }
            gate.release.signal()
            await fulfillment(of: [returned], timeout: 2)
            try await surviving.value
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(store.directoryURL, clear ? nil : directory)
            XCTAssertEqual(defaults.data(forKey: "transfer_dir"), clear ? nil : saved)
            store.clear()
            XCTAssertEqual(scope.count(directory), 0)
        }
    }

    func testNewSelectionSupersedesBlockedStartupAndLateRestoreCannotReplaceIt() async throws {
        let (root, defaults) = try fixture()
        let scope = DirectoryScopeProbe(), old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        defaults.set(Data([1, 2]), forKey: "transfer_dir")
        let entered = expectation(description: "Old restore blocked")
        let returned = expectation(description: "Old restore returned")
        let gate = DirectorySelectionIOGate(url: old, entered: entered)
        defer { gate.release.signal() }
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations,
            resolveBookmark: { _ in
                gate.wait(old)
                returned.fulfill()
                return .init(url: old, stale: true)
            })
        await fulfillment(of: [entered], timeout: 2)
        let waiter = Task { try await store.waitUntilRestored() }
        await store.setDirectory(new).value
        try await waiter.value
        XCTAssertFalse(store.isRestoring)
        let selected = defaults.data(forKey: "transfer_dir")
        gate.release.signal()
        await fulfillment(of: [returned], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.directoryURL, new)
        XCTAssertEqual(defaults.data(forKey: "transfer_dir"), selected)
        XCTAssertEqual(scope.count(old), 0)
        XCTAssertEqual(scope.count(new), 1)
        store.clear()
    }

    func testRestoreFailureAndUnrenewableStaleGrantPreserveExistingRules() async throws {
        for mode in ["invalid", "denied", "renewal-failed"] {
            let (root, defaults) = try fixture()
            let scope = DirectoryScopeProbe(), saved = Data([1, 2])
            let directory = root.appendingPathComponent(mode == "denied" ? "denied" : "old")
            defaults.set(saved, forKey: "transfer_dir")
            let preparation = TransferDirectoryPreparation(cleanup: { _ in })
            let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations, preparation: preparation,
                makeBookmark: { _ in throw CocoaError(.fileWriteUnknown) }, resolveBookmark: { _ in
                    if mode == "invalid" { throw CocoaError(.fileReadCorruptFile) }
                    return .init(url: directory, stale: true)
                })
            try await store.waitUntilRestored()
            let usable = mode == "renewal-failed"
            XCTAssertEqual(store.directoryURL, usable ? directory : nil)
            XCTAssertEqual(defaults.data(forKey: "transfer_dir"), usable ? saved : nil)
            if usable { try await preparation.waitUntilReady(directory) }
            store.clear()
            XCTAssertEqual(scope.count(directory), 0)
            XCTAssertEqual(scope.stopCount(directory), usable ? 1 : 0)
        }
    }

    func testCancelledReplacementDuringStartupResumesSavedFolderRestoration() async throws {
        let (root, defaults) = try fixture()
        let scope = DirectoryScopeProbe(), old = root.appendingPathComponent("old"), replacement = root.appendingPathComponent("slow")
        let saved = Data([1, 2])
        defaults.set(saved, forKey: "transfer_dir")
        let resolving = expectation(description: "Original and resumed startup resolution")
        resolving.expectedFulfillmentCount = 2
        let preparing = expectation(description: "Replacement bookmark blocked")
        let restoreGate = DirectorySelectionIOGate(url: old, entered: resolving)
        let selectionGate = DirectorySelectionIOGate(url: replacement, entered: preparing)
        let preparation = TransferDirectoryPreparation(cleanup: { _ in })
        defer { restoreGate.release.signal(); restoreGate.release.signal(); selectionGate.release.signal() }
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations, preparation: preparation,
            makeBookmark: { url in selectionGate.wait(url); return Data([3, 4]) },
            resolveBookmark: { data in
                XCTAssertEqual(data, saved)
                restoreGate.wait(old)
                return .init(url: old, stale: false)
            })
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while restoreGate.calls < 1, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(restoreGate.calls, 1)
        let task = store.setDirectory(replacement)
        await fulfillment(of: [preparing], timeout: 2)
        task.cancel()
        selectionGate.release.signal()
        await task.value
        XCTAssertTrue(store.isRestoring, "Cancelling a replacement cannot pretend the saved startup folder is unset")
        await fulfillment(of: [resolving], timeout: 2)
        restoreGate.release.signal(); restoreGate.release.signal()
        try await store.waitUntilRestored()
        try await preparation.waitUntilReady(old)
        XCTAssertEqual(store.directoryURL, old)
        XCTAssertEqual(defaults.data(forKey: "transfer_dir"), saved)
        XCTAssertEqual(scope.count(replacement), 0)
        XCTAssertEqual(scope.stopCount(replacement), 1)
        XCTAssertEqual(scope.count(old), 1)
        store.clear()
        XCTAssertEqual(scope.count(old), 0)
    }

    func testBlockingGrantAndBookmarkLeaveMainResponsiveAndCoalescePendingSelection() async throws {
        for blockGrant in [true, false] {
            let (root, defaults) = try fixture()
            let scope = DirectoryScopeProbe()
            let old = root.appendingPathComponent("old"), slow = root.appendingPathComponent("slow")
            let entered = expectation(description: "Provider entered \(blockGrant)")
            let gate = DirectorySelectionIOGate(url: slow, entered: entered)
            defer { gate.release.signal() }
            let operations = DirectoryAccessOperations(start: { url in
                XCTAssertFalse(Thread.isMainThread)
                if blockGrant { gate.wait(url) }
                return scope.operations.start(url)
            }, stop: scope.operations.stop)
            let store = DirectoryAccessStore(defaults: defaults, accessOperations: operations, makeBookmark: { url in
                XCTAssertFalse(Thread.isMainThread)
                if !blockGrant { gate.wait(url) }
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            })
            await store.setDirectory(old).value
            let previous = defaults.data(forKey: "transfer_dir")
            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            let task = store.setDirectory(slow)
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(store.directoryURL, old)
            XCTAssertEqual(defaults.data(forKey: "transfer_dir"), previous)
            XCTAssertEqual(scope.count(old), 1)
            for _ in 0..<120 { store.setDirectory(slow) }
            let heartbeat = expectation(description: "Main run loop during blocked provider")
            DispatchQueue.main.async { heartbeat.fulfill() }
            await fulfillment(of: [heartbeat], timeout: 1)
            XCTAssertEqual(publications, 0)
            gate.release.signal()
            await task.value
            XCTAssertEqual(gate.calls, 1)
            XCTAssertEqual(store.directoryURL, slow)
            XCTAssertNotEqual(defaults.data(forKey: "transfer_dir"), previous)
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(scope.count(old), 0)
            XCTAssertEqual(scope.count(slow), 1)
            store.clear()
            XCTAssertEqual(scope.count(slow), 0)
            withExtendedLifetime(observation) {}
        }
    }

    func testReplacedOrClearedSelectionCannotCommitLateBookmarkAndReleasesGrant() async throws {
        for clear in [false, true] {
            let (root, defaults) = try fixture()
            let scope = DirectoryScopeProbe()
            let slow = root.appendingPathComponent("slow"), new = root.appendingPathComponent("new")
            let entered = expectation(description: "Blocked old selection")
            let gate = DirectorySelectionIOGate(url: slow, entered: entered)
            defer { gate.release.signal() }
            let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations, makeBookmark: { url in
                gate.wait(url)
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            })
            let obsolete = store.setDirectory(slow)
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(scope.count(slow), 1)
            if clear { store.clear() }
            else { await store.setDirectory(new).value }
            let expectedBookmark = defaults.data(forKey: "transfer_dir")
            gate.release.signal()
            await obsolete.value
            XCTAssertEqual(store.directoryURL, clear ? nil : new)
            XCTAssertEqual(defaults.data(forKey: "transfer_dir"), expectedBookmark)
            XCTAssertEqual(scope.count(slow), 0)
            XCTAssertEqual(scope.stopCount(slow), 1)
            store.clear()
            XCTAssertEqual(scope.count(new), 0)
        }
    }

    func testFailureSameFolderRevalidationAndRetryPreserveSelectionRules() async throws {
        let (root, defaults) = try fixture()
        let scope = DirectoryScopeProbe()
        let old = root.appendingPathComponent("old"), denied = root.appendingPathComponent("denied")
        let failed = root.appendingPathComponent("failed")
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations, makeBookmark: { url in
            if url.lastPathComponent == "failed" { throw CocoaError(.fileWriteUnknown) }
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        })
        await store.setDirectory(old).value
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        await store.setDirectory(old).value
        XCTAssertEqual(publications, 0, "Revalidate the grant without publishing an identical URL")
        XCTAssertEqual(scope.count(old), 1)
        XCTAssertEqual(scope.stopCount(old), 1)
        await store.setDirectory(denied).value
        XCTAssertNil(store.directoryURL)
        XCTAssertNil(defaults.data(forKey: "transfer_dir"))
        XCTAssertEqual(scope.stopCount(denied), 0)
        XCTAssertEqual(scope.count(old), 0)
        await store.setDirectory(old).value
        await store.setDirectory(failed).value
        XCTAssertNil(store.directoryURL)
        XCTAssertNil(defaults.data(forKey: "transfer_dir"))
        XCTAssertEqual(scope.count(failed), 0)
        XCTAssertEqual(scope.stopCount(failed), 1)
        await store.setDirectory(old).value
        XCTAssertEqual(store.directoryURL, old)
        XCTAssertNotNil(defaults.data(forKey: "transfer_dir"))
        store.clear()
        let clearedCount = publications
        for _ in 0..<120 { store.clear() }
        XCTAssertEqual(publications, clearedCount)
        withExtendedLifetime(observation) {}
    }

    func testCancelledSelectionCanRetryTheSameFolder() async throws {
        let (root, defaults) = try fixture()
        let scope = DirectoryScopeProbe()
        let slow = root.appendingPathComponent("slow")
        let entered = expectation(description: "Both attempts reach provider")
        entered.expectedFulfillmentCount = 2
        let gate = DirectorySelectionIOGate(url: slow, entered: entered)
        defer { gate.release.signal() }
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: scope.operations, makeBookmark: { url in
            gate.wait(url)
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        })
        let cancelled = store.setDirectory(slow)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while gate.calls == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.calls, 1)
        cancelled.cancel()
        gate.release.signal()
        await cancelled.value
        XCTAssertNil(store.directoryURL)
        XCTAssertEqual(scope.count(slow), 0)
        gate.release.signal()
        await store.setDirectory(slow).value
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(store.directoryURL, slow)
        XCTAssertEqual(scope.count(slow), 1)
        store.clear()
    }

    func testPendingProviderDoesNotRetainStoreOrPersistAfterDeinit() async throws {
        let (root, defaults) = try fixture()
        let slow = root.appendingPathComponent("slow")
        let scope = DirectoryScopeProbe()
        let entered = expectation(description: "Provider blocked until owner removed")
        let gate = DirectorySelectionIOGate(url: slow, entered: entered)
        defer { gate.release.signal() }
        var store: DirectoryAccessStore? = DirectoryAccessStore(defaults: defaults,
            accessOperations: scope.operations, makeBookmark: { url in
                gate.wait(url)
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            })
        weak var owner = store
        let task = try XCTUnwrap(store).setDirectory(slow)
        await fulfillment(of: [entered], timeout: 2)
        store = nil
        XCTAssertNil(owner)
        gate.release.signal()
        await task.value
        XCTAssertEqual(scope.count(slow), 0)
        XCTAssertEqual(scope.stopCount(slow), 1)
        XCTAssertNil(defaults.data(forKey: "transfer_dir"))
    }

    func testDocumentPickerDeliversOnceAndCancellationKeepsExistingSelection() throws {
        let (root, _) = try fixture()
        var picked: [URL] = []
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        let coordinator = DirectoryPicker.Coordinator { picked.append($0) }
        coordinator.documentPicker(controller, didPickDocumentsAt: [])
        coordinator.onPick = { picked.append($0.appendingPathComponent("latest")) }
        coordinator.documentPicker(controller, didPickDocumentsAt: [root, root.appendingPathComponent("ignored")])
        coordinator.documentPicker(controller, didPickDocumentsAt: [root])
        XCTAssertEqual(picked, [root.appendingPathComponent("latest")])
        let cancelled = DirectoryPicker.Coordinator { picked.append($0) }
        cancelled.documentPickerWasCancelled(controller)
        cancelled.documentPicker(controller, didPickDocumentsAt: [root])
        XCTAssertEqual(picked.count, 1)
    }
}

private final class DirectorySelectionIOGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let url: URL
    private let entered: XCTestExpectation
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(url: URL, entered: XCTestExpectation) { self.url = url; self.entered = entered }
    func wait(_ url: URL) {
        guard url == self.url else { return }
        lock.withLock { count += 1 }
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}

private final class DirectoryScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [URL: Int] = [:]
    private var stops: [URL: Int] = [:]
    var operations: DirectoryAccessOperations {
        DirectoryAccessOperations(start: { [self] url in
            guard url.lastPathComponent != "denied" else { return false }
            lock.withLock { active[url, default: 0] += 1 }
            return true
        }, stop: { [self] url in
            lock.withLock {
                active[url, default: 0] -= 1
                stops[url, default: 0] += 1
                XCTAssertGreaterThanOrEqual(active[url, default: 0], 0)
            }
        })
    }
    func count(_ url: URL) -> Int { lock.withLock { active[url, default: 0] } }
    func stopCount(_ url: URL) -> Int { lock.withLock { stops[url, default: 0] } }
}

extension TransferQueueScenarioTests {
    private func scopeStore(_ probe: DirectoryScopeProbe) -> DirectoryAccessStore {
        let suite = "DirectoryScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return DirectoryAccessStore(defaults: defaults, accessOperations: probe.operations)
    }

    func testDirectorySelectionChangeRetainsActiveDownloadScopeUntilPublication() async throws {
        let probe = DirectoryScopeProbe()
        let (queue, old) = try fixture(accessOperations: probe.operations)
        let new = old.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let store = scopeStore(probe)
        await store.setDirectory(old).value
        XCTAssertEqual(store.directoryURL, old)
        let camera = ControlledTransferCamera()
        await queue.enqueue(file(1))
        await queue.start(session: camera, directory: old)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        XCTAssertEqual(probe.count(old), 2)
        await store.setDirectory(new).value
        await queue.attach(session: camera, directory: new)
        XCTAssertEqual(store.directoryURL, new)
        XCTAssertEqual(probe.count(old), 1, "Running worker owns the former selection")
        await camera.finish(1)
        let finished = try await wait(queue) { !$0.isTransferring && probe.count(old) == 0 }
        XCTAssertEqual(finished.items[0].outputURL?.deletingLastPathComponent(), old)
        XCTAssertEqual(probe.stopCount(old), 2)
        await queue.enqueue(file(2))
        await camera.finish(2)
        await queue.start(session: camera, directory: new)
        let next = try await wait(queue) { !$0.isTransferring && $0.items[1].status == .completed }
        XCTAssertEqual(next.items[1].outputURL?.deletingLastPathComponent(), new)
        store.clear()
        await queue.attach(session: nil, directory: nil)
        XCTAssertEqual(probe.count(new), 0)
        XCTAssertEqual(probe.stopCount(new), 2)
    }

    func testClearingDirectoryRetainsActiveAndWaitingFrameScopesThroughSuccessAndFailure() async throws {
        let probe = DirectoryScopeProbe()
        let renderer = ControlledFrameRenderer()
        let (queue, old) = try fixture(accessOperations: probe.operations, renderer: { source, _, target, _ in
            XCTAssertGreaterThan(probe.count(target), 0)
            let output = try await renderer.render(source: source, directory: target)
            XCTAssertGreaterThan(probe.count(target), 0, "Scope must survive the suspension and disk write")
            if source.lastPathComponent == "DSC_2.JPG" { throw CocoaError(.fileWriteUnknown) }
            return output
        })
        let store = scopeStore(probe)
        await store.setDirectory(old).value
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        let files = [file(1), file(2), file(3)]
        for file in files { try Data(repeating: 1, count: 10).write(to: old.appendingPathComponent(file.fileName)) }
        await queue.enqueue(files, effects: effects)
        await queue.start(session: nil, directory: old)
        _ = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy(\.isGeneratingFrame) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await renderer.peak < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let activePeak = await renderer.peak
        XCTAssertEqual(activePeak, 1, "The compute worker must be suspended before clearing the selection")
        store.clear()
        await queue.attach(session: nil, directory: nil)
        XCTAssertNil(store.directoryURL)
        XCTAssertEqual(probe.count(old), 1, "Frame jobs retain the worker's shared root lease")
        await renderer.releaseAll()
        let finished = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame } && probe.count(old) == 0 }
        XCTAssertNotNil(finished.items[0].frameURL)
        XCTAssertNotNil(finished.items[1].frameError)
        XCTAssertNotNil(finished.items[2].frameURL)
        XCTAssertEqual(probe.stopCount(old), 2)
    }

    func testDeniedScopeIsNeverStoppedAndStoreDeinitBalancesSuccessfulScope() async throws {
        let probe = DirectoryScopeProbe()
        let (_, directory) = try fixture()
        var store: DirectoryAccessStore? = scopeStore(probe)
        await store?.setDirectory(directory).value
        XCTAssertEqual(probe.count(directory), 1)
        store = nil
        XCTAssertEqual(probe.count(directory), 0)
        XCTAssertEqual(probe.stopCount(directory), 1)
        let denied = directory.appendingPathComponent("denied")
        do {
            let lease = DirectoryAccessLease(url: denied, operations: probe.operations)
            XCTAssertFalse(lease.isSecurityScoped)
        }
        XCTAssertEqual(probe.stopCount(denied), 0)
    }
}

private actor CleanupRaceCamera: TransferDownloading {
    private(set) var part: URL?
    private let release = CropPermitLatch()
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let temporary = directory.appendingPathComponent(".nkpart_live")
        try Data(repeating: 3, count: Int(file.size)).write(to: temporary)
        part = temporary
        await release.wait()
        return try finalizeTransferTemporary(temporary: temporary, directory: directory, fileName: file.fileName)
    }
    func finish() async { await release.open() }
}

extension TransferQueueScenarioTests {
    func testRestoredCleanupBlocksProductionQueueAndCannotRunAgainOverLivePart() async throws {
        let entered = expectation(description: "Startup cleanup entered")
        let release = CropPermitLatch()
        let preparation = TransferDirectoryPreparation { root in
            entered.fulfill()
            await release.wait()
            _ = TransferDirectoryIndex.removeStaleTemporaryFiles(in: root)
        }
        let probe = DirectoryScopeProbe()
        let (queue, directory) = try fixture(accessOperations: probe.operations, directoryPreparation: preparation)
        let stale = directory.appendingPathComponent(".nkpart_old")
        try Data([8]).write(to: stale)
        let suite = "StartupCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "transfer_dir")
        let store = DirectoryAccessStore(defaults: defaults, accessOperations: probe.operations, preparation: preparation)
        try await store.waitUntilRestored()
        XCTAssertEqual(store.directoryURL, directory)
        await fulfillment(of: [entered], timeout: 2)
        let camera = CleanupRaceCamera()
        await queue.enqueue(file(1))
        await queue.start(session: camera, directory: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while preparation.pendingWaiterCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preparation.pendingWaiterCount, 1)
        let before = await camera.part
        XCTAssertNil(before, "The actual camera must not create a new part before cleanup ends")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        await release.open()
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await camera.part == nil && ContinuousClock.now < startedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let temporary = await camera.part
        let live = try XCTUnwrap(temporary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        // A second store restoration shares the completed startup work instead
        // of sweeping the file the first queue has just created.
        let restoredAgain = DirectoryAccessStore(defaults: defaults, accessOperations: probe.operations, preparation: preparation)
        try await restoredAgain.waitUntilRestored()
        try await preparation.waitUntilReady(directory)
        XCTAssertEqual(try Data(contentsOf: live), Data(repeating: 3, count: 10))
        await camera.finish()
        let finished = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(finished.items[0].outputURL)), Data(repeating: 3, count: 10))
        store.clear(); restoredAgain.clear()
        await queue.attach(session: nil, directory: nil)
        XCTAssertEqual(probe.count(directory), 0)
    }

    func testAlreadyUsedRootDoesNotStartDestructiveCleanupLater() async throws {
        let preparation = TransferDirectoryPreparation { _ in XCTFail("Late cleanup must not run") }
        let (_, directory) = try fixture()
        try await preparation.waitUntilReady(directory)
        let live = directory.appendingPathComponent(".nkpart_live")
        try Data([3]).write(to: live)
        preparation.beginCleanup(access: DirectoryAccessLease(url: directory))
        try await preparation.waitUntilReady(directory)
        XCTAssertEqual(try Data(contentsOf: live), Data([3]))
    }

    func testCleanupPreservesCurrentFrameFilesAndRemovesOldFilesInActualFrameFolders() throws {
        let (_, root) = try fixture()
        let parents = [root, root.appendingPathComponent("ZT-JPG"), root.appendingPathComponent("ZT2026-10-16")]
        var protected: [URL] = []
        for parent in parents {
            let frames = parent.appendingPathComponent(transferFrameOutputDirectoryName)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            for folder in [parent, frames] {
                let active = folder.appendingPathComponent(PhotoFrameTemporaryFiles.makeName())
                let output = folder.appendingPathComponent("keep.jpg")
                for file in [active, output] { try Data([1]).write(to: file); protected.append(file) }
                try Data([2]).write(to: folder.appendingPathComponent(".nkframe_old.jpg"))
            }
        }
        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: root), 6)
        for file in protected { XCTAssertEqual(try Data(contentsOf: file), Data([1])) }
        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: root), 0)
    }
}

extension TransferQueueScenarioTests {
    func testCancelledStartupWaiterExitsWithoutCancellingSharedCleanupOrBlockingAnotherRoot() async throws {
        let release = CropPermitLatch()
        let started = expectation(description: "Shared cleanup running")
        let preparation = TransferDirectoryPreparation { root in
            started.fulfill()
            await release.wait()
            _ = TransferDirectoryIndex.removeStaleTemporaryFiles(in: root)
        }
        let (_, directory) = try fixture()
        let stale = directory.appendingPathComponent(".nkpart_old")
        try Data([1]).write(to: stale)
        preparation.beginCleanup(access: DirectoryAccessLease(url: directory))
        await fulfillment(of: [started], timeout: 2)
        let waiter = Task { try await preparation.waitUntilReady(directory) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while preparation.pendingWaiterCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(preparation.pendingWaiterCount, 1)
        waiter.cancel()
        let cancelled = expectation(description: "Waiter exits while cleanup is held")
        let observer = Task {
            do { try await waiter.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            cancelled.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        let (otherQueue, otherRoot) = try fixture(directoryPreparation: preparation)
        let camera = ControlledTransferCamera()
        await camera.finish(1)
        await otherQueue.enqueue(file(1))
        await otherQueue.start(session: camera, directory: otherRoot)
        _ = try await wait(otherQueue) { !$0.isTransferring && $0.items[0].status == .completed }
        await release.open()
        try await preparation.waitUntilReady(directory)
        await observer.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(preparation.pendingWaiterCount, 0)
    }
}

final class PhotoGenerationQueueStateTests: XCTestCase {
    func testCapacityIncludesActiveAndPreparingEntriesAt4096Boundary() {
        var state = PhotoGenerationQueueState()
        let ids = (0..<4097).map { _ in UUID() }
        for (index, id) in ids.prefix(4096).enumerated() {
            XCTAssertEqual(state.submit(id, ready: index == 0), .accepted)
        }
        XCTAssertEqual(state.takeReady(), ids[0])
        XCTAssertEqual(state.submit(ids[0]), .duplicate)
        XCTAssertEqual(state.submit(ids[4096]), .full)
        XCTAssertEqual(state.count, 4096)
        state.finish(ids[0])
        XCTAssertEqual(state.submit(ids[4096]), .accepted)
        XCTAssertEqual(state.takeReady(), ids[4096])
    }

    func testReadyWorkBypassesPreparingHeadAndDeferralPreservesOriginalOrder() {
        var state = PhotoGenerationQueueState()
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertEqual(state.submit(first, ready: false), .accepted)
        XCTAssertEqual(state.submit(second), .accepted)
        XCTAssertEqual(state.submit(third), .accepted)
        XCTAssertEqual(state.takeReady(), second)
        XCTAssertNil(state.takeReady(), "Only one compute slot")
        state.markReady(first); state.markReady(first)
        state.finish(second)
        XCTAssertEqual(state.takeReady(), first)
        state.deferActive(first)
        XCTAssertEqual(state.takeReady(), first)
        state.finish(first)
        XCTAssertEqual(state.takeReady(), third)
        state.finish(third)
        XCTAssertEqual(state.count, 0)
    }

    func testRuntimeGateReconsiderationAndReadinessDuringDeferralAreNotLost() {
        var state = PhotoGenerationQueueState()
        let id = UUID()
        XCTAssertEqual(state.submit(id, ready: false), .accepted)
        XCTAssertNil(state.takeReady())
        XCTAssertEqual(state.takeReady(runWhilePreparing: { $0 == id }), id)
        state.markReady(id)
        state.deferActive(id)
        XCTAssertEqual(state.takeReady(), id)
        state.finish(id)
        XCTAssertNil(state.takeReady())
    }

    func testCloseAbandonsPendingExactlyOnceAndActiveCompletionRetainsOwnership() {
        var state = PhotoGenerationQueueState()
        let active = UUID(), preparing = UUID(), pending = UUID()
        XCTAssertEqual(state.submit(active), .accepted)
        XCTAssertEqual(state.takeReady(), active)
        XCTAssertEqual(state.submit(preparing, ready: false), .accepted)
        XCTAssertEqual(state.submit(pending), .accepted)
        XCTAssertEqual(state.close(), [preparing, pending])
        XCTAssertEqual(state.close(), [])
        XCTAssertEqual(state.active, active)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.submit(UUID()), .closed)
        state.finish(active)
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.takeReady())
    }
}

extension TransferQueueScenarioTests {
    func testGenerationCapacityRejectsOverflowAndRetrySucceedsAfterSlotsAreReleased() async throws {
        let renderer = ControlledFrameRenderer()
        let (queue, directory) = try fixture(generationCapacity: 2, renderer: { source, _, target, _ in
            try await renderer.render(source: source, directory: target)
        })
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        let files = [file(1), file(2), file(3)]
        for file in files { try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file.fileName)) }
        await queue.enqueue(files, effects: effects)
        await queue.start(session: nil, directory: directory)
        let rejected = try await wait(queue) { !$0.isTransferring && $0.items[2].frameError != nil }
        XCTAssertTrue(rejected.items[0].isGeneratingFrame)
        XCTAssertTrue(rejected.items[1].isGeneratingFrame)
        XCTAssertFalse(rejected.items[2].isGeneratingFrame)
        XCTAssertEqual(rejected.items[2].frameError, "Photo generation queue capacity reached")
        XCTAssertEqual(rejected.items[2].status, .completed)
        await renderer.releaseAll()
        _ = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame } }
        let retry = await queue.retry(id: rejected.items[2].id)
        XCTAssertNotNil(retry)
        let finished = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL != nil } }
        XCTAssertTrue(finished.items.allSatisfy { $0.frameError == nil })
        let peak = await renderer.peak
        XCTAssertEqual(peak, 1)
    }

    func testCancelledAndFailedGenerationReleaseSingleSlotForFollowingPhoto() async throws {
        let (queue, directory) = try fixture(renderer: { source, _, target, _ in
            if source.lastPathComponent == "DSC_1.JPG" { throw CancellationError() }
            if source.lastPathComponent == "DSC_2.JPG" { throw CocoaError(.fileWriteUnknown) }
            let output = target.appendingPathComponent("success.jpg")
            try Data([3]).write(to: output)
            return output
        })
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false
        let files = [file(1), file(2), file(3)]
        for file in files { try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file.fileName)) }
        await queue.enqueue(files, effects: effects)
        await queue.start(session: nil, directory: directory)
        let finished = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy { !$0.isGeneratingFrame } }
        XCTAssertNil(finished.items[0].frameURL)
        XCTAssertNotNil(finished.items[1].frameError)
        XCTAssertEqual(finished.items[2].frameURL?.lastPathComponent, "success.jpg")
    }
}

private actor PipelineMetadataCamera: TransferDownloading {
    let header: Data
    private let release = CropPermitLatch()
    private let identityRelease: CropPermitLatch?
    private(set) var identityRequested = false
    private(set) var metadataRequests: [UInt32] = []
    private(set) var downloads: [UInt32] = []
    init(header: Data, holdIdentity: Bool = false) {
        self.header = header
        self.identityRelease = holdIdentity ? CropPermitLatch() : nil
    }
    func photoMetadataIdentity() async -> PhotoMetadataCameraIdentity? {
        identityRequested = true
        await identityRelease?.wait()
        return nil
    }
    func finishIdentity() async { await identityRelease?.open() }
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) throws -> URL {
        downloads.append(file.id)
        let output = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 4, count: Int(file.size)).write(to: output)
        return output
    }
    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) throws -> CameraDownloadResult {
        let output = try download(file: file, to: directory, progress: nil)
        return CameraDownloadResult(url: output, bytes: file.size, transferredBytes: file.size,
                                    startedAt: .now, headerPrefix: captureHeader ? header : nil)
    }
    func frameMetadataHeader(file: CameraFile) async throws -> Data? {
        metadataRequests.append(file.id)
        if file.id == 1 { await release.wait() }
        try Task.checkCancellation()
        return header
    }
    func finishMetadata() async { await release.open() }
}

private actor PipelineRenderRecorder {
    private(set) var order: [String] = []
    func render(source: URL, directory: URL, metadata: PhotoFrameMetadata?) throws -> URL {
        XCTAssertEqual(metadata?.model, "Pipeline fixture")
        order.append(source.lastPathComponent)
        let output = directory.appendingPathComponent(source.lastPathComponent + ".frame.jpg")
        try Data([3]).write(to: output)
        return output
    }
}

extension TransferQueueScenarioTests {
    private func pipelineHeader() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let result = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Pipeline fixture"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(PhotoFrameMetadata.cameraSnapshot(result as Data)?.model, "Pipeline fixture")
        return result as Data
    }

    private func waitForMetadataRead(_ camera: PipelineMetadataCamera) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await camera.metadataRequests.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await camera.metadataRequests
        XCTAssertEqual(requests, [1])
    }

    func testSlowMetadataPreparationDoesNotBlockLaterDownloadAndCapturedHeaderGeneration() async throws {
        let recorder = PipelineRenderRecorder()
        let (queue, directory) = try fixture(renderer: { source, _, target, metadata in
            try await recorder.render(source: source, directory: target, metadata: metadata)
        })
        let camera = PipelineMetadataCamera(header: try pipelineHeader())
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: directory)
        try await waitForMetadataRead(camera)
        let bypassed = try await wait(queue) { !$0.isTransferring && $0.items[1].frameURL != nil }
        XCTAssertTrue(bypassed.items[0].isGeneratingFrame)
        XCTAssertNil(bypassed.items[0].frameURL)
        let earlyOrder = await recorder.order
        let downloaded = await camera.downloads
        XCTAssertEqual(earlyOrder, ["DSC_2.JPG"])
        XCTAssertEqual(downloaded, [2])
        await camera.finishMetadata()
        let completed = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL != nil } }
        XCTAssertTrue(completed.items.allSatisfy { $0.frameError == nil })
        let finalOrder = await recorder.order
        let reads = await camera.metadataRequests
        XCTAssertEqual(finalOrder, ["DSC_2.JPG", "DSC_1.JPG"])
        XCTAssertEqual(reads, [1], "Captured metadata must not trigger a second camera read")
    }

    func testPreparingPhotoConsumesCapacityWithoutBlockingLaterOriginalDownload() async throws {
        let recorder = PipelineRenderRecorder()
        let (queue, directory) = try fixture(generationCapacity: 1, renderer: { source, _, target, metadata in
            try await recorder.render(source: source, directory: target, metadata: metadata)
        })
        let camera = PipelineMetadataCamera(header: try pipelineHeader())
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: directory)
        try await waitForMetadataRead(camera)
        let full = try await wait(queue) { !$0.isTransferring && $0.items[1].frameError != nil }
        XCTAssertEqual(full.items[1].status, .completed)
        XCTAssertEqual(full.items[1].frameError, "Photo generation queue capacity reached")
        XCTAssertNotNil(full.items[1].outputURL)
        XCTAssertTrue(full.items[0].isGeneratingFrame)
        await camera.finishMetadata()
        _ = try await wait(queue) { $0.items[0].frameURL != nil }
        let retry = await queue.retry(id: full.items[1].id)
        XCTAssertNotNil(retry)
        _ = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL != nil } }
    }

    func testClosingGenerationClearsPreparingAndPendingWorkAndIgnoresLateMetadata() async throws {
        let recorder = PipelineRenderRecorder()
        let (queue, directory) = try fixture(renderer: { source, _, target, metadata in
            try await recorder.render(source: source, directory: target, metadata: metadata)
        })
        let camera = PipelineMetadataCamera(header: try pipelineHeader())
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        for id: UInt32 in [1, 2] { try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(id).fileName)) }
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: directory)
        try await waitForMetadataRead(camera)
        _ = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy(\.isGeneratingFrame) }
        await queue.closePhotoGeneration(); await queue.closePhotoGeneration()
        let closed = await queue.snapshot()
        XCTAssertTrue(closed.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL == nil })
        await camera.finishMetadata()
        // Queue a new original to cross the late callback's actor turn; the
        // closed generation queue must neither revive old work nor accept it.
        await queue.enqueue(file(3), effects: effects)
        await queue.start(session: camera, directory: directory)
        let final = try await wait(queue) { !$0.isTransferring && $0.items[2].status == .completed }
        XCTAssertTrue(final.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL == nil })
        let order = await recorder.order
        XCTAssertTrue(order.isEmpty)
    }
}

extension TransferQueueScenarioTests {
    func testClosingGenerationCancelsActiveComputeAndPreparingPhotoWithoutLatePublication() async throws {
        let entered = expectation(description: "Ready second photo owns compute")
        let release = CropPermitLatch()
        let (queue, directory) = try fixture(renderer: { source, _, _, _ in
            entered.fulfill()
            await release.wait()
            return source
        })
        let camera = PipelineMetadataCamera(header: try pipelineHeader())
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: directory)
        try await waitForMetadataRead(camera)
        await fulfillment(of: [entered], timeout: 2)
        await queue.closePhotoGeneration(); await queue.closePhotoGeneration()
        let closing = await queue.snapshot()
        XCTAssertFalse(closing.items[0].isGeneratingFrame)
        XCTAssertTrue(closing.items[1].isGeneratingFrame, "Active worker owns its cancellation boundary")
        await camera.finishMetadata()
        await release.open()
        let ended = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy { !$0.isGeneratingFrame } }
        XCTAssertTrue(ended.items.allSatisfy { $0.frameURL == nil })
        XCTAssertTrue(ended.items.allSatisfy { $0.outputURL != nil })
    }
}

extension TransferQueueScenarioTests {
    func testIdentityPreparationAlsoCannotHoldOriginalDownloadPipeline() async throws {
        let recorder = PipelineRenderRecorder()
        let (queue, directory) = try fixture(renderer: { source, _, target, metadata in
            try await recorder.render(source: source, directory: target, metadata: metadata)
        })
        let camera = PipelineMetadataCamera(header: try pipelineHeader(), holdIdentity: true)
        var effects = PhotoEffectsSettings(); effects.photoFrameEnabled = true; effects.photoFrameBorderEnabled = true
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)], effects: effects)
        await queue.start(session: camera, directory: directory)
        let downloaded = try await wait(queue) { !$0.isTransferring && $0.items[1].status == .completed }
        XCTAssertTrue(downloaded.items.allSatisfy(\.isGeneratingFrame))
        let readsBeforeIdentity = await camera.metadataRequests
        let downloads = await camera.downloads
        XCTAssertTrue(readsBeforeIdentity.isEmpty)
        XCTAssertEqual(downloads, [2])
        await camera.finishIdentity()
        try await waitForMetadataRead(camera)
        _ = try await wait(queue) { $0.items[1].frameURL != nil && $0.items[0].isGeneratingFrame }
        await camera.finishMetadata()
        _ = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame && $0.frameURL != nil } }
        let order = await recorder.order
        XCTAssertEqual(order, ["DSC_2.JPG", "DSC_1.JPG"])
    }
}

private actor PreviewHistogramTestGate {
    private var continuations: [CheckedContinuation<[CGFloat], Never>] = []
    var count: Int { continuations.count }
    func calculate() async -> [CGFloat] {
        await withCheckedContinuation { continuations.append($0) }
    }
    func finish(_ index: Int, bars: [CGFloat]) {
        continuations[index].resume(returning: bars)
    }
}

final class PhotoFilterCategoryParityTests: XCTestCase {
    func testChooserFavoritesPositionAndOffPreserveRecipe() throws {
        let first = try XCTUnwrap(Np3FilterCatalog.preset(id: "forest_verdure"))
        let second = try XCTUnwrap(Np3FilterCatalog.preset(id: "blue_hour"))
        var settings = PhotoEffectsSettings()
        settings.favoriteFilterIDs = [second.catalogKey, first.catalogKey]
        settings.filterIntensities[first.catalogKey] = 42
        var chooser = PhotoFilterChooserState(isPresented: true, category: .landscape)
        XCTAssertEqual(Array(chooser.items(in: settings).prefix(2).map(\.id)), [second.id, first.id])
        chooser.select(first.id, in: &settings)
        XCTAssertFalse(chooser.isPresented)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 42)
        XCTAssertEqual(chooser.initialItemID(in: settings), first.id)
        let recipe = settings.selectedFilter
        chooser.isPresented = true
        chooser.select(nil, in: &settings)
        XCTAssertFalse(settings.photoFilterEnabled)
        XCTAssertFalse(chooser.isPresented)
        XCTAssertEqual(settings.selectedFilter, recipe)
        XCTAssertEqual(chooser.initialItemID(in: settings), second.id)
        chooser.category = .favorites
        XCTAssertEqual(chooser.items(in: settings).map(\.id), [second.id, first.id])
        settings.favoriteFilterIDs = []
        XCTAssertNil(chooser.initialItemID(in: settings))
    }

    func testAllFiftyCategoriesMatchAndroidFallbackMetadata() {
        // Expected membership transcribed from Android CuratedNp3Filters and
        // PhotoFilterCategory, not derived from iOS localized display names.
        let expected: [PhotoEffectFilterCategory: [String]] = [
            .landscape: ["forest_verdure", "blue_hour", "fern_shade", "urban_green", "moss_mood", "sunset_film", "sunset_glow"],
            .cinematic: ["dusk_ember", "cinema_blue", "cinematic_dusk", "golden_dusk", "teal_and_orange"],
            .color: ["bleached_silver", "blue_memory", "calm_breeze", "cozy_autumn", "dawn_hues", "soft_harmony", "matte_blue", "green_shadows", "natural_link", "cyan_negative", "red_cyan", "teal_negative", "lemon_negative", "amber_negative", "lime_negative", "pastel_pink", "setouchi_blue", "sky_mist", "soft_glow", "cool_sun_kiss", "warm_sun_kiss", "gentle_clarity", "turquoise_blue", "warm_street", "warm_lowlight", "honey_warm"],
            .monochrome: ["british_mono"],
            .portrait: ["love_glow", "clear_portrait", "soft_portrait", "warm_portrait"],
            .film: ["darkroom_film", "classic_film", "rose_vintage", "soft_film", "vintage_color", "vintage_vibe", "vital_film"],
        ]
        XCTAssertEqual(expected.values.flatMap { $0 }.count, 50)
        XCTAssertEqual(Np3FilterCatalog.presets.count, 50)
        for preset in Np3FilterCatalog.presets {
            let category = expected.first { $0.value.contains(preset.legacyID) }?.key
            XCTAssertNotNil(category, preset.legacyID)
            for id in [preset.id, preset.catalogKey, preset.legacyID] {
                // Display language must never change catalog classification.
                for displayName in [preset.name, preset.fallbackName, "任意显示名称"] {
                    XCTAssertEqual(PhotoFilterPreset(id: id, name: displayName).category, category, preset.legacyID)
                }
            }
        }
    }
}

final class PhotoPreviewFrameCacheTests: XCTestCase {
    func testCancelledPrefetchWaiterDoesNotCancelPromotedWorkOrRepeatFiltering() async throws {
        let cache = PhotoPreviewFrameCache<Int>()
        let entered = CropPermitLatch()
        let release = CropPermitLatch()
        let prefetch = Task {
            try await cache.getOrRender {
                await entered.open()
                await release.wait()
                try Task.checkCancellation()
                return 42
            }
        }
        await entered.wait()
        prefetch.cancel()
        do { _ = try await prefetch.value; XCTFail("Cancelled waiter returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let current = Task {
            try await cache.getOrRender { XCTFail("Promoted frame repeated filtering"); return 0 }
        }
        await release.open()
        let result = try await current.value
        XCTAssertEqual(result, 42)
        let cached = try await cache.getOrRender { XCTFail("Completed hit repeated filtering"); return 0 }
        XCTAssertEqual(cached, 42)
        await cache.close()
    }

    func testFailureCanRetryAndClosedCacheRejectsLateResults() async throws {
        let cache = PhotoPreviewFrameCache<Int>()
        do { _ = try await cache.getOrRender { throw CocoaError(.fileReadCorruptFile) }; XCTFail("Expected failure") }
        catch is CocoaError {} catch { XCTFail("Unexpected error: \(error)") }
        let entered = CropPermitLatch()
        let release = CropPermitLatch()
        let retry = Task {
            try await cache.getOrRender {
                await entered.open()
                await release.wait() // Deliberately ignores cancellation.
                return 7
            }
        }
        await entered.wait()
        await cache.close()
        do { _ = try await retry.value; XCTFail("Closed cache returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await release.open()
        do { _ = try await cache.getOrRender { 9 }; XCTFail("Closed cache reopened") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

final class PhotoPreviewCacheSetTests: XCTestCase {
    func testDemandChangeCancelsObsoleteWorkAndAllowsItToBeRequestedAgain() async throws {
        let cache = PhotoPreviewCacheSet<String, Int>()
        await cache.replaceRequested(["old", "current"])
        let completed = try await cache.getOrRender(key: "current") { 42 }
        XCTAssertEqual(completed, 42)
        let entered = CropPermitLatch(), release = CropPermitLatch()
        let old = Task {
            try await cache.getOrRender(key: "old") {
                await entered.open(); await release.wait()
                return 1
            }
        }
        await entered.wait()
        await cache.replaceRequested(["current"])
        do { _ = try await old.value; XCTFail("Obsolete work returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await cache.getOrRender(key: "old") { 0 }; XCTFail("Unrequested work started") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await release.open()
        await cache.replaceRequested(["old"])
        let promoted = try await cache.getOrRender(key: "old") { 2 }
        XCTAssertEqual(promoted, 2)
        await cache.replaceRequested(["current"])
        let reused = try await cache.getOrRender(key: "current") { XCTFail("Demand changes discarded completed frame"); return 0 }
        XCTAssertEqual(reused, 42)
        await cache.close()
    }

    func testThreeFrameAccessOrderAndIndependentSourceIdentity() async throws {
        let cache = PhotoPreviewCacheSet<String, Int>()
        for (key, value) in [("a", 1), ("b", 2), ("c", 3)] {
            let result = try await cache.getOrRender(key: key) { value }
            XCTAssertEqual(result, value)
        }
        let a = try await cache.getOrRender(key: "a") { XCTFail("Hot frame rendered again"); return 0 }
        XCTAssertEqual(a, 1)
        _ = try await cache.getOrRender(key: "d") { 4 }
        let count = await cache.count
        XCTAssertEqual(count, 3)
        let b = try await cache.getOrRender(key: "b") { 22 }
        XCTAssertEqual(b, 22, "Least recently accessed frame must be evicted")
        await cache.close()
        do { _ = try await cache.getOrRender(key: "a") { 9 }; XCTFail("Closed source reused") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let replacement = PhotoPreviewCacheSet<String, Int>()
        let fresh = try await replacement.getOrRender(key: "a") { 11 }
        XCTAssertEqual(fresh, 11, "New source/decoration scope must not inherit old frame")
        await replacement.close()
    }

    func testEvictionCancelsActiveEntryAndRejectsLateResult() async throws {
        let cache = PhotoPreviewCacheSet<String, Int>(capacity: 1)
        let entered = CropPermitLatch()
        let release = CropPermitLatch()
        let old = Task {
            try await cache.getOrRender(key: "old") {
                await entered.open()
                await release.wait()
                return 1
            }
        }
        await entered.wait()
        let next = try await cache.getOrRender(key: "new") { 2 }
        XCTAssertEqual(next, 2)
        do { _ = try await old.value; XCTFail("Evicted work returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await release.open()
        let current = try await cache.getOrRender(key: "new") { XCTFail("Late old result displaced new frame"); return 0 }
        XCTAssertEqual(current, 2)
        await cache.close()
    }
}

@MainActor final class LocalPhotoPreviewCacheTests: XCTestCase {
    private final class GeometryProbe { var bodies = 0 }
    private struct GeometryHarness: View {
        let probe: GeometryProbe
        @State var geometry: PhotoEffectsGeometrySnapshot
        var body: some View {
            let _ = { probe.bodies += 1 }()
            Text("Editor").onTapGesture { _ = geometry.previewAnchor }
        }
    }

    func testScrollingKeepsLatestEventCoordinatesWithoutRebuildingEditor() async throws {
        let geometry = PhotoEffectsGeometrySnapshot(), probe = GeometryProbe()
        let host = UIHostingController(rootView: GeometryHarness(probe: probe, geometry: geometry))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initial = probe.bodies
        XCTAssertGreaterThan(initial, 0)
        for step in 1...30 {
            geometry.scrollOffset = -CGFloat(step)
            geometry.previewAnchor = CGRect(x: 20, y: CGFloat(90 - step), width: 353, height: 264.75)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.bodies, initial)
        XCTAssertEqual(geometry.scrollOffset, -30)
        let opening = PhotoEffectsExpandedPreviewSnapshot(image: UIImage(), initialComparison: nil,
                                                   anchor: geometry.previewAnchor)
        geometry.previewAnchor.origin.y = 99
        XCTAssertEqual(opening.anchor, CGRect(x: 20, y: 60, width: 353, height: 264.75))
        XCTAssertEqual(geometry.previewAnchor.minY, 99)
    }

    func testReopeningSameSourceAfterCloseRebuildsWithoutInvalidatingOpeningSnapshot() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var settings = PhotoEffectsSettings()
        settings.selectFilter(try XCTUnwrap(Np3FilterCatalog.presets.first).id)
        let cache = LocalPhotoPreviewCache()
        await cache.configure(image: image, settings: settings, metadata: nil)
        let opening = try await cache.render(image: image, settings: settings, metadata: nil)
        let snapshot = PhotoEffectsExpandedPreviewSnapshot(image: opening.filtered,
            initialComparison: opening.unfiltered, anchor: CGRect(x: 0, y: 0, width: 300, height: 225))
        cache.close()
        await cache.configure(image: image, settings: settings, metadata: nil)
        let reopened = try await cache.render(image: image, settings: settings, metadata: nil)
        XCTAssertFalse(opening.filtered === reopened.filtered)
        XCTAssertEqual(opening.filtered.cgImage?.width, reopened.filtered.cgImage?.width)
        XCTAssertEqual(opening.filtered.cgImage?.height, reopened.filtered.cgImage?.height)
        XCTAssertTrue(snapshot.image === opening.filtered)
        XCTAssertTrue(snapshot.comparison(current: reopened) === opening.unfiltered)
        let reused = try await cache.render(image: image, settings: settings, metadata: nil)
        XCTAssertTrue(reused.filtered === reopened.filtered)
        cache.close()
    }

    func testRealFramesReuseAndSourceChangesInvalidate() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var settings = PhotoEffectsSettings()
        settings.selectFilter(try XCTUnwrap(Np3FilterCatalog.presets.first).id)
        let cache = LocalPhotoPreviewCache()
        await cache.configure(image: image, settings: settings, metadata: nil)
        let first = try await cache.render(image: image, settings: settings, metadata: nil)
        let reused = try await cache.render(image: image, settings: settings, metadata: nil)
        XCTAssertTrue(first.filtered === reused.filtered, "A completed frame must return the same image")
        var neighbor = settings
        neighbor.selectedFilter = try XCTUnwrap(nextPhotoFilterSelections(for: settings).first)
        let warmed = try await cache.render(image: image, settings: neighbor, metadata: nil)
        await cache.configure(image: image, settings: neighbor, metadata: nil)
        let promoted = try await cache.render(image: image, settings: neighbor, metadata: nil)
        XCTAssertTrue(warmed.filtered === promoted.filtered, "Promoting a preheated frame must skip filtering and composition")
        await cache.configure(image: image, settings: settings, metadata: nil)
        var changed = settings
        changed.selectedFilter?.intensityPercent = 42
        await cache.configure(image: image, settings: changed, metadata: nil)
        let second = try await cache.render(image: image, settings: changed, metadata: nil)
        XCTAssertFalse(first.filtered === second.filtered)
        await cache.configure(image: image, settings: settings, metadata: nil)
        let revisited = try await cache.render(image: image, settings: settings, metadata: nil)
        XCTAssertTrue(first.filtered === revisited.filtered)
        let newSource = UIImage(cgImage: try XCTUnwrap(image.cgImage))
        await cache.configure(image: newSource, settings: settings, metadata: nil)
        let fresh = try await cache.render(image: newSource, settings: settings, metadata: nil)
        XCTAssertFalse(first.filtered === fresh.filtered)
        var decorated = settings
        decorated.photoFrameEnabled = true
        decorated.photoFramePreset = .minimal
        decorated.watermark.enabled = false
        await cache.configure(image: newSource, settings: decorated, metadata: nil)
        let frame = try await cache.render(image: newSource, settings: decorated, metadata: nil)
        var otherFrame = decorated
        otherFrame.photoFramePreset = .mist
        await cache.configure(image: newSource, settings: otherFrame, metadata: nil)
        do { _ = try await cache.render(image: newSource, settings: decorated, metadata: nil); XCTFail("Old decoration scope accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let replaced = try await cache.render(image: newSource, settings: otherFrame, metadata: nil)
        XCTAssertFalse(frame.filtered === replaced.filtered)
        cache.close()
        do { _ = try await cache.render(image: newSource, settings: settings, metadata: nil); XCTFail("Closed page rendered") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

final class PhotoOriginalTiledCompositionTests: XCTestCase {
    func testFlatWatermarkAndImmersiveMatchPrefilteredCompositionAcrossTileBoundary() throws {
        try assertTileBoundaryComposition(selection: PhotoFilterSelection(
            preset: PhotoEffectsSettings().orderedFilters[0], intensityPercent: 80))
    }

    func testCubeMatchesPrefilteredCompositionAcrossTileBoundary() throws {
        // Nonconstant channel rotation exercises interpolation on both sides of the seam.
        var rgb: [Float] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 { rgb += [Float(green), Float(blue), Float(red)] }
            }
        }
        let lut = CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                          rgb: rgb, digest: "f110-cube-seam")
        PhotoLUTRuntime.register(lut)
        try assertTileBoundaryComposition(selection: PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "cube:\(lut.digest)", name: "Seam"), intensityPercent: 60))
    }

    private func assertTileBoundaryComposition(selection: PhotoFilterSelection) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 4101), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 4101))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 4095, width: 1024, height: 6))
            UIColor.green.setFill(); context.fill(CGRect(x: 512, y: 0, width: 512, height: 4101))
        }
        var filterOnly = PhotoEffectsSettings()
        filterOnly.photoFrameEnabled = false
        filterOnly.photoFilterEnabled = true
        filterOnly.selectedFilter = selection
        let prefiltered = try PhotoEffectsRenderer.render(source, settings: filterOnly, filterExecution: .preview)
        for mode in 0..<3 {
            try autoreleasepool {
                var settings = filterOnly
                settings.photoFrameEnabled = mode != 0
                settings.photoFrameBorderEnabled = mode == 2
                settings.photoFramePreset = .immersive
                settings.watermark.enabled = mode == 1
                settings.watermark.text = "Tile boundary"
                let actual = try PhotoEffectsRenderer.render(source, settings: settings)
                settings.photoFilterEnabled = false
                let expected = try PhotoEffectsRenderer.render(prefiltered, settings: settings)
                XCTAssertEqual(actual.size, source.size)
                XCTAssertEqual(try bytes(actual), try bytes(expected), "mode=\(mode)")
            }
        }
    }

    func testCubeAndNP3PreserveAllOrientationsAndTransparentPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 11), format: format).image { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 5))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 8, y: 5, width: 9, height: 6))
        }
        let lut = CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
                          rgb: [Float](repeating: 0.25, count: 24), digest: "f110-transparency")
        PhotoLUTRuntime.register(lut)
        let selections = [
            PhotoFilterSelection(preset: PhotoEffectsSettings().orderedFilters[0], intensityPercent: 80),
            PhotoFilterSelection(preset: PhotoFilterPreset(id: "cube:\(lut.digest)", name: "Test"), intensityPercent: 60)
        ]
        let orientations: [UIImage.Orientation] = [.up, .upMirrored, .down, .downMirrored,
                                                  .left, .leftMirrored, .right, .rightMirrored]
        for selection in selections {
            for orientation in orientations {
                let source = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: orientation)
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = false
                settings.photoFilterEnabled = true
                settings.selectedFilter = selection
                let expected = try PhotoEffectsRenderer.render(source, settings: settings, filterExecution: .preview)
                let actual = try PhotoEffectsRenderer.render(source, settings: settings)
                XCTAssertEqual(actual.size, expected.size)
                XCTAssertEqual(try bytes(actual), try bytes(expected), "\(selection.preset.id), orientation=\(orientation.rawValue)")
            }
        }
    }

    func testTwelveMegapixelFrameRejectsLowBudgetThenPreservesPhotoPixels() throws {
        try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let source = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
                for y in 0..<8 {
                    for x in 0..<8 {
                        (x.isMultiple(of: 2) == y.isMultiple(of: 2) ? UIColor.red : UIColor.blue).setFill()
                        context.fill(CGRect(x: 1968 + x * 8, y: 1468 + y * 8, width: 8, height: 8))
                    }
                }
            }
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = .plaque
            settings.metadata.widthPercent = 200; settings.watermark.enabled = false
            XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty,
                availableMemory: { 64 * 1024 * 1024 })) { error in
                XCTAssertGreaterThan((error as? PhotoAllocationRejected)?.required ?? 0, 4000 * 3000 * 4)
            }
            let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty,
                availableMemory: { .max })
            XCTAssertEqual(output.cgImage?.width, 4000)
            XCTAssertEqual(output.cgImage?.height, 3960)
            let region = CGRect(x: 1968, y: 1468, width: 64, height: 64)
            let expected = UIImage(cgImage: try XCTUnwrap(source.cgImage?.cropping(to: region)))
            let actual = UIImage(cgImage: try XCTUnwrap(output.cgImage?.cropping(to: region)))
            XCTAssertEqual(try bytes(actual), try bytes(expected))
        }
    }

    func testProductionBudgetRejectsThenRetriesWithoutChangingResolution() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(preset: settings.orderedFilters[0], intensityPercent: 80)
        let original = try bytes(source)
        var queries = 0
        XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings, availableMemory: {
            queries += 1
            return 64 * 1024 * 1024
        })) { error in
            guard let rejected = error as? PhotoAllocationRejected else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertGreaterThan(rejected.required, 32 * 24 * 4)
            XCTAssertEqual(rejected.available, 64 * 1024 * 1024)
        }
        XCTAssertEqual(queries, 1)
        let output = try PhotoEffectsRenderer.render(source, settings: settings, availableMemory: {
            queries += 1
            return .max
        })
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(output.size, source.size)
        XCTAssertEqual(try bytes(source), original)
        _ = try PhotoEffectsRenderer.render(source, settings: settings, filterExecution: .preview, availableMemory: {
            XCTFail("Original export budget must not run for preview")
            return 0
        })
    }

    private func bytes(_ image: UIImage) throws -> Data {
        let source = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return Data(bytes: try XCTUnwrap(context.data), count: source.width * source.height * 4)
    }
}


final class PhotoAllocationBudgetTests: XCTestCase {
    func testOversizedMalformedPNGIsRejectedBeforeLoading() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        var data = try XCTUnwrap(image.pngData())
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "IHDR")
        // Keep the tiny compressed payload, but advertise one hundred million pixels.
        // ImageIO rejects the inconsistent dimensions before returning properties.
        for offset in [16, 20] {
            let value: UInt32 = 10_000
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (24 - byte * 8)) }
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        crc ^= 0xffff_ffff
        for byte in 0..<4 { data[29 + byte] = UInt8(truncatingIfNeeded: crc >> (24 - byte * 8)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertThrowsError(try PhotoAllocationBudget.loadOriginalImage(url, availableMemory: { 512 * 1024 * 1024 })) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
        }
    }

    func testOriginalFileBudgetRejectsBeforeLoadingAndPreservesDimensionsWhenAllowed() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 81, height: 63), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 81, height: 63))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap(original.pngData())
        try data.write(to: url)
        XCTAssertThrowsError(try PhotoAllocationBudget.loadOriginalImage(url, availableMemory: { 0 })) { error in
            let rejected = error as? PhotoAllocationRejected
            XCTAssertEqual(rejected?.required, 81 * 63 * 8 + 8 * 1024 * 1024)
            XCTAssertEqual(rejected?.available, 0)
        }
        let loaded = try PhotoAllocationBudget.loadOriginalImage(url, availableMemory: { .max })
        XCTAssertEqual(loaded.cgImage?.width, 81)
        XCTAssertEqual(loaded.cgImage?.height, 63)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testAndroidEstimatesSaturateRatherThanWrapping() {
        XCTAssertEqual(PhotoAllocationBudget.bytes(width: 6000, height: 4000), 96_000_000)
        XCTAssertEqual(PhotoAllocationBudget.bytes(width: 6000, height: 4000, copies: 2, extra: 16_000_000), 208_000_000)
        for value in [PhotoAllocationBudget.bytes(width: .max, height: 2),
                      PhotoAllocationBudget.bytes(width: 1, height: 1, copies: .max),
                      PhotoAllocationBudget.bytes(width: 1, height: 1, extra: .max),
                      PhotoAllocationBudget.bytes(width: 0, height: 4000),
                      PhotoAllocationBudget.bytes(width: -1, height: 4000),
                      PhotoAllocationBudget.bytes(width: 1, height: 1, copies: 0),
                      PhotoAllocationBudget.bytes(width: 1, height: 1, extra: -1)] {
            XCTAssertEqual(value, .max)
        }
    }

    func testAndroidNativeReserveAndBoundaryCases() {
        let mib: Int64 = 1024 * 1024
        XCTAssertTrue(PhotoAllocationBudget.fits(required: 494348528, available: 600 * mib, threshold: 100 * mib))
        XCTAssertTrue(PhotoAllocationBudget.fits(required: 3500 * mib, available: 4096 * mib, threshold: 256 * mib))
        XCTAssertTrue(PhotoAllocationBudget.fits(required: 384 * mib, available: 512 * mib, threshold: 128 * mib))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: 384 * mib + 1, available: 512 * mib, threshold: 128 * mib))
        XCTAssertTrue(PhotoAllocationBudget.fits(required: 1, available: 64 * mib + 1))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: 1, available: 64 * mib))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: 1, available: 64 * mib, threshold: .max))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: .max, available: .max))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: -1, available: 512 * mib))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: 1, available: 0))
        XCTAssertFalse(PhotoAllocationBudget.fits(required: 1, available: 512 * mib, threshold: -1))
    }
}


private actor QueueRenderBudgetFixture {
    private(set) var selections: [PhotoEffectsSettings] = []
    func next(_ settings: PhotoEffectsSettings) -> Int64 {
        selections.append(settings)
        return selections.count == 1 ? 64 * 1024 * 1024 : .max
    }
}

final class RemoteOrientationSessionTests: XCTestCase {
    func testInvalidInputAndPauseRejectOldStabilityTickets() throws {
        var session = RemoteOrientationSession<Int>()
        let old = try XCTUnwrap(session.observe(1))
        XCTAssertTrue(session.accepts(old, target: 1))
        XCTAssertNil(session.observe(nil))
        XCTAssertFalse(session.accepts(old, target: 1))
        let replacement = try XCTUnwrap(session.observe(1))
        XCTAssertFalse(session.accepts(old, target: 1))
        XCTAssertTrue(session.accepts(replacement, target: 1))
        session.pause()
        XCTAssertFalse(session.accepts(replacement, target: 1))
        let resumed = try XCTUnwrap(session.observe(1))
        XCTAssertTrue(session.accepts(resumed, target: 1))
        XCTAssertNil(session.observe(1), "Unchanged input must not restart the260ms timer")
        XCTAssertTrue(session.accepts(resumed, target: 1))
    }

    func testManualSuppressionSurvivesPauseUntilDifferentValidDirection() throws {
        var session = RemoteOrientationSession<Int>()
        let old = try XCTUnwrap(session.observe(1))
        session.suppressCurrent()
        XCTAssertFalse(session.accepts(old, target: 1))
        session.pause()
        XCTAssertNil(session.observe(1))
        XCTAssertNil(session.observe(nil))
        XCTAssertNil(session.observe(1))
        let changed = try XCTUnwrap(session.observe(2))
        XCTAssertTrue(session.accepts(changed, target: 2))
        XCTAssertNotNil(session.observe(1))
    }

    func testLatestPendingRequestIncludesReturnAndCanBeDiscardedWhenFrozen() {
        var session = RemoteOrientationSession<Int>()
        session.enqueue(2)
        session.enqueue(0)
        XCTAssertEqual(session.takePending(), 0, "Return request during fade-out must replace older queued target")
        XCTAssertNil(session.takePending())
        session.enqueue(1)
        session.discardPending()
        XCTAssertNil(session.takePending())
        session.enqueue(2)
        session.pause()
        XCTAssertEqual(session.takePending(), 2, "Android pause clears candidate but does not drain already queued rotations")
    }
}

@MainActor
final class ScreenAwakeCoordinatorTests: XCTestCase {
    func testOwnersDoNotRestoreStalePreferenceOrForegroundSnapshots() {
        var applied: [Bool] = []
        let coordinator = ScreenAwakeCoordinator { applied.append($0) }
        coordinator.setForeground(true)
        coordinator.setPreference(true)
        let first = coordinator.acquire()
        coordinator.setPreference(false)
        XCTAssertEqual(applied.last, true)
        let second = coordinator.acquire()
        coordinator.release(first)
        XCTAssertEqual(applied.last, true)
        coordinator.setForeground(false)
        XCTAssertEqual(applied.last, false)
        coordinator.release(second)
        XCTAssertEqual(applied.last, false)
        coordinator.setPreference(true)
        XCTAssertEqual(applied.last, false)
        coordinator.setForeground(true)
        XCTAssertEqual(applied.last, true)
        coordinator.release(first)
        XCTAssertEqual(applied.last, true, "Late release cannot override the latest preference")
    }

    func testTemporaryHoldEndsAgainstLatestPreferenceAndSurvivesForegroundRoundTrip() {
        var value = false
        let coordinator = ScreenAwakeCoordinator { value = $0 }
        coordinator.setForeground(true)
        let hold = coordinator.acquire()
        XCTAssertTrue(value)
        coordinator.setForeground(false)
        XCTAssertFalse(value)
        coordinator.setForeground(true)
        XCTAssertTrue(value)
        coordinator.setPreference(true)
        coordinator.release(hold)
        XCTAssertTrue(value)
        coordinator.setPreference(false)
        XCTAssertFalse(value)
    }
}

final class AppLanguageResolutionTests: XCTestCase {
    func testSystemFallbackAndExplicitChoicesUseOneResourceLanguage() {
        let cases: [([String], String)] = [
            (["fr-FR", "de-DE"], "en"), (["en-GB"], "en"),
            (["zh-CN"], "zh"), (["zh-Hans"], "zh"), (["zh-TW"], "hant"),
            (["zh-HK"], "hant"), (["zh-Hant"], "hant"),
            (["fr", "zh-Hant"], "hant"), ([], "en")
        ]
        for (preferred, expected) in cases {
            let actual = AppLocalized.resourceLanguage(tag: "system", preferredLanguages: preferred)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(AppLocalized.resource("lut_read_failed", language: actual), AndroidLocalization.byResource["lut_read_failed"]?[expected])
            XCTAssertEqual(AppLocalized.text("设置", language: actual), AndroidLocalization.byResource["settings"]?[expected])
        }
        for (tag, expected) in [("en", "en"), ("zh-Hans", "zh"), ("zh-Hant", "hant")] {
            XCTAssertEqual(AppLocalized.resourceLanguage(tag: tag, preferredLanguages: ["fr-FR"]), expected)
        }
        XCTAssertEqual(AppLocalized.resourceLanguage(tag: "fr-FR", preferredLanguages: ["zh-Hans"]), "en")
    }

    func testSwiftUILocaleTracksFallbackAndReturningToSystem() {
        let system = ["fr-FR"]
        XCTAssertEqual(AppLocalized.locale(for: "zh-Hant", preferredLanguages: system).language.script?.identifier, "Hant")
        XCTAssertEqual(AppLocalized.locale(for: "system", preferredLanguages: system).language.languageCode?.identifier, "en")
        XCTAssertEqual(AppLocalized.resourceLanguage(tag: "system", preferredLanguages: system), "en")
        XCTAssertEqual(AppLocalized.locale(for: "system", preferredLanguages: ["zh-Hans"]).language.script?.identifier, "Hans")
    }
}


final class DetentWheelPerformanceTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var hashes = 0, comparisons = 0
        func hash() { lock.lock(); hashes += 1; lock.unlock() }
        func compare() { lock.lock(); comparisons += 1; lock.unlock() }
        var snapshot: (hashes: Int, comparisons: Int) {
            lock.lock(); defer { lock.unlock() }; return (hashes, comparisons)
        }
    }
    private struct Option: Hashable {
        let id: Int
        let counts: Counts
        func hash(into hasher: inout Hasher) {
            counts.hash()
            // Deliberate collision checks that identity still compares values.
            hasher.combine(0)
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.counts.compare(); return lhs.id == rhs.id
        }
    }

    @MainActor
    func testTenThousandOptionWheelDoesNotRepeatLookupOrHashDuringStableFrames() {
        let counts = Counts()
        let options = (0..<10_000).map { Option(id: $0, counts: counts) }
        let wheel = DetentWheel(label: "LUT", options: options, selected: options.last!,
            optionLabel: { String($0.id) }, onCommit: { _ in })
        let configuration = DetentWheelConfiguration(options: options, rowHeight: 18, enabled: true, readOnly: false)
        let before = counts.snapshot
        for _ in 0..<120 {
            XCTAssertEqual(wheel.selectedIndex, 9_999)
            _ = configuration.hashValue
        }
        XCTAssertEqual(counts.snapshot.hashes, before.hashes)
        XCTAssertEqual(counts.snapshot.comparisons, before.comparisons)
        let reordered = DetentWheelConfiguration(options: Array(options.reversed()), rowHeight: 18, enabled: true, readOnly: false)
        XCTAssertEqual(configuration.hashValue, reordered.hashValue)
        XCTAssertNotEqual(configuration, reordered, "Cached fingerprints must never replace full identity equality")
        var session = DetentWheelDragSession(configuration: configuration)
        let revision = session.revision
        XCTAssertTrue(session.begin(revision: revision, selectedIndex: 9_999))
        session.update(configuration: reordered)
        XCTAssertNil(session.release(revision: revision, translation: 18))
        let replacement = DetentWheel(label: "LUT", options: Array(options.reversed()), selected: options.last!,
            optionLabel: { String($0.id) }, onCommit: { _ in })
        XCTAssertEqual(replacement.selectedIndex, 0)
    }
}

final class DetentWheelDragSessionTests: XCTestCase {
    private let original = DetentWheelConfiguration(options: [0, 1, 2, 3, 4], rowHeight: 18, enabled: true, readOnly: false)

    func testConfigurationChangesRejectOldGestureEvenAfterRestoringOriginal() {
        let changes = [
            DetentWheelConfiguration(options: [4, 3, 2, 1, 0], rowHeight: 18, enabled: true, readOnly: false),
            DetentWheelConfiguration(options: [0, 1], rowHeight: 18, enabled: true, readOnly: false),
            DetentWheelConfiguration(options: [0, 1, 2, 3, 4], rowHeight: 30, enabled: true, readOnly: false),
            DetentWheelConfiguration(options: [0, 1, 2, 3, 4], rowHeight: 18, enabled: false, readOnly: false),
            DetentWheelConfiguration(options: [0, 1, 2, 3, 4], rowHeight: 18, enabled: true, readOnly: true)
        ]
        for changed in changes {
            var session = DetentWheelDragSession(configuration: original)
            let old = session.revision
            XCTAssertTrue(session.begin(revision: old, selectedIndex: 3))
            XCTAssertEqual(session.preview(revision: old, translation: 18), 2)
            session.update(configuration: changed)
            XCTAssertNil(session.release(revision: old, translation: 18))
            if !changed.canDrag {
                XCTAssertFalse(session.begin(revision: session.revision, selectedIndex: 0))
            }
            session.update(configuration: original)
            XCTAssertFalse(session.begin(revision: old, selectedIndex: 3))
            XCTAssertNil(session.release(revision: old, translation: 18))
            let fresh = session.revision
            XCTAssertTrue(session.begin(revision: fresh, selectedIndex: 1))
            XCTAssertEqual(session.release(revision: fresh, translation: -18), 2)
            XCTAssertNil(session.release(revision: fresh, translation: -18))
        }
    }

    func testUnchangedConfigurationPreservesPreviewAndCancellationRejectsRelease() {
        var session = DetentWheelDragSession(configuration: original)
        XCTAssertNil(session.release(revision: 0, translation: 0))
        XCTAssertTrue(session.begin(revision: 0, selectedIndex: 2))
        session.update(configuration: original)
        XCTAssertEqual(session.preview(revision: 0, translation: -999), 4)
        XCTAssertEqual(session.preview(revision: 0, translation: 999), 0)
        XCTAssertEqual(session.release(revision: 0, translation: 9.2), 1)
        XCTAssertTrue(session.begin(revision: 0, selectedIndex: 4))
        session.invalidate()
        XCTAssertNil(session.release(revision: 0, translation: 18))
    }
}


extension AppLanguageResolutionTests {
    func testAndroidEscapesDecodeOnceAndPreserveLiteralBackslashes() {
        let cases: [(String, String)] = [
            (#"Don\'t"#, "Don't"),
            (#"a\nb\tc\rd"#, "a\nb\tc\rd"),
            (#"say \"yes\""#, "say \"yes\""),
            (#"\\n"#, #"\n"#),
            (#"path\\file"#, #"path\file"#),
            (#"tail\"#, #"tail\"#),
            (#"unknown\q"#, #"unknown\q"#)
        ]
        for (source, expected) in cases {
            for language in ["en", "zh", "hant"] {
                XCTAssertEqual(AppLocalized.text(source, language: language), expected)
            }
        }
    }

    func testEffectEntryAndLabelsMatchAndroidResources() {
        for (language, title, coordinates, strength, kind) in [
            ("en", "Filter · LUT · Frame · Watermark", "Coordinates", "Intensity", "Type"),
            ("zh", "滤镜·LUT·边框·水印", "坐标", "强度", "类型"),
            ("hant", "濾鏡·LUT·邊框·浮水印", "座標", "強度", "類型")
        ] {
            XCTAssertEqual(AppLocalized.resource("photo_effects", language: language), title)
            XCTAssertEqual(AppLocalized.resource("local_photo_effects_entry", language: language), title)
            XCTAssertEqual(AppLocalized.resource("photo_frame_metadata_coordinates", language: language), coordinates)
            XCTAssertEqual(AppLocalized.resource("photo_filter_intensity", language: language), strength)
            XCTAssertEqual(AppLocalized.resource("photo_frame_watermark_content", language: language), kind)
        }
    }
}


@MainActor
final class RemoteToolInputRoutingTests: XCTestCase {
    private final class Mode: ObservableObject { @Published var movie = false }
    private struct ButtonSurface: UIViewRepresentable {
        let movie: Bool
        func makeUIView(context: Context) -> UIButton {
            let view = UIButton(type: .custom)
            view.accessibilityIdentifier = movie ? "movie-action" : "photo-action"
            return view
        }
        func updateUIView(_ uiView: UIButton, context: Context) {}
    }
    private struct Host: View {
        @ObservedObject var mode: Mode
        var body: some View {
            AndroidBooleanCrossfade(selected: mode.movie) { movie in
                ButtonSurface(movie: movie).frame(width: 200, height: 60)
            }
        }
    }

    func testRealCrossfadeHitTestingBlocksOutgoingTopLayerOnReversal() async throws {
        let mode = Mode()
        let controller = UIHostingController(rootView: Host(mode: mode))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func hit() -> UIView? {
            controller.view.layoutIfNeeded()
            guard let button = descendants(controller.view).first(where: { $0 is UIButton }) else { return nil }
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: controller.view)
            return controller.view.hitTest(point, with: nil)
        }
        XCTAssertEqual(hit()?.accessibilityIdentifier, "photo-action")
        mode.movie = true
        // Wait for an actually presented nonzero movie frame, not an assumed
        // 40ms worth of simulator refreshes. Reverse while both layers exist.
        for _ in 0..<60 {
            if hit()?.accessibilityIdentifier == "movie-action" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(hit()?.accessibilityIdentifier, "movie-action")
        XCTAssertEqual(descendants(controller.view).filter { $0 is UIButton }.count, 2,
                       "The reversal must interrupt a live crossfade, not follow its completion")
        mode.movie = false
        for _ in 0..<60 {
            if hit() is RemoteToolInputShieldView { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(hit() is RemoteToolInputShieldView,
                      "Outgoing movie layer must intercept instead of hitting incoming photo")
        try await Task.sleep(for: .milliseconds(800))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(hit()?.accessibilityIdentifier, "photo-action")
    }
}


@MainActor
final class RootPresentationPerformanceTests: XCTestCase {
    private func fixture(directory: DirectoryAccessStore? = nil) throws -> RootPresentationModel {
        let suite = "RootPresentation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gps = GPSCoordinator(defaults: defaults, bluetooth: RootGPSStub(),
                                 locationManager: RootLocationStub())
        return RootPresentationModel(connection: ConnectionViewModel(discoverySource: RootUSBStub()),
            effects: PhotoEffectsStore(defaults: defaults), gps: gps,
            directory: directory ?? DirectoryAccessStore(defaults: defaults))
    }

    private func changeDetails(_ model: RootPresentationModel, index: Int) {
        model.connection.apply(.authorization(index.isMultiple(of: 2) ? .denied : .restricted))
        model.gps.applyBluetoothState(.connecting("Camera \(index)"))
        model.gps.setFrequency(index.isMultiple(of: 2) ? .oneMinute : .thirtySeconds)
        var settings = model.effects.settings
        settings.watermark.text = "Draft \(index)"
        model.effects.update(settings)
    }

    private final class GPSPanelInput: ObservableObject { @Published var expanded = false }
    private struct GPSControlHarness: View {
        let coordinator: GPSCoordinator
        @ObservedObject var input: GPSPanelInput
        let rendered: () -> Void
        var body: some View {
            var control = GPSConnectionControl(coordinator: coordinator, expanded: $input.expanded,
                showingResetPairing: .constant(false), availableHeight: 760)
            control.didRender = rendered
            return control.frame(width: 280).frame(maxHeight: .infinity, alignment: .top)
                .environment(\.scenePhase, .active)
        }
    }

    func testGPSHeaderIgnoresDetailsAndPanelReversalRetainsTheSameLiveHost() async throws {
        let model = try fixture()
        model.gps.setEnabled(true)
        model.gps.applyBluetoothState(.connecting("first"))
        let input = GPSPanelInput()
        var renders = 0
        var projection: GPSEntryPresentation? = GPSEntryPresentation(model.gps)
        weak var weakProjection = projection
        var updates = 0
        let token = projection!.objectWillChange.sink { updates += 1 }
        var host: UIHostingController<GPSControlHarness>? = UIHostingController(rootView:
            GPSControlHarness(coordinator: model.gps, input: input, rendered: { renders += 1 }))
        weak var weakHost = host
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host!.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        func find(_ view: UIView) -> GeniePopupHostView? {
            (view as? GeniePopupHostView) ?? view.subviews.lazy.compactMap(find).first
        }
        let panel = try XCTUnwrap(find(host!.view))
        XCTAssertFalse(panel.host.view.isUserInteractionEnabled)
        let baseline = renders
        for index in 0..<120 {
            model.gps.applyBluetoothState(.connecting("Camera \(index)"))
            model.gps.setFrequency(index.isMultiple(of: 2) ? .oneMinute : .thirtySeconds)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renders, baseline)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(model.gps.state.cameraName, "Camera 119")
        input.expanded = true
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(panel.host.view.isUserInteractionEnabled)
        input.expanded = false
        try await Task.sleep(for: .milliseconds(60))
        input.expanded = true
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(panel === find(host!.view))
        XCTAssertTrue(panel.host.view.isUserInteractionEnabled)
        model.gps.setEnabled(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projection!.snapshot.accent, .waiting)
        XCTAssertGreaterThan(updates, 0)
        input.expanded = false
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(panel.host.view.isUserInteractionEnabled)
        XCTAssertEqual(panel.host.view.layer.opacity, 0)
        token.cancel(); projection = nil
        XCTAssertNil(weakProjection)
        window.isHidden = true; window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(weakHost)
    }

    func testConnectionPageKeepsGPSDetailsLocalAndResumesContinuousCardAttention() async throws {
        let model = try fixture()
        model.gps.setEnabled(true)
        var observation: GPSEnabledObservation? = GPSEnabledObservation(model.gps)
        weak var weakObservation = observation
        var changes = 0
        let token = observation!.objectWillChange.sink { changes += 1 }
        var renders = 0
        var page = ConnectionPage(model: model.connection, effectsStore: model.effects,
            gpsCoordinator: model.gps, directory: model.directory, celebrationStart: nil,
            onOpenWorkspace: {}, gpsPanelPresented: .constant(false))
        page.didRender = { renders += 1 }
        let host = UIHostingController(rootView: page.environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        func attentionViews(_ view: UIView) -> [NativeAttentionHostView] {
            (view as? NativeAttentionHostView).map { [$0] } ?? view.subviews.flatMap(attentionViews)
        }
        let cards = attentionViews(host.view)
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.allSatisfy { $0.motionView.layer.animation(forKey: "attention.loop") == nil })
        let baseline = renders
        for index in 0..<120 {
            model.gps.applyBluetoothState(.connecting("Camera \(index)"))
            model.gps.setFrequency(index.isMultiple(of: 2) ? .oneMinute : .thirtySeconds)
            var settings = model.effects.settings
            settings.watermark.text = "Draft \(index)"
            model.effects.update(settings)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renders, baseline)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.gps.state.cameraName, "Camera 119")
        model.gps.setEnabled(false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(renders, baseline)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(attentionViews(host.view).map(ObjectIdentifier.init), cards.map(ObjectIdentifier.init))
        for card in cards {
            let loop = try XCTUnwrap(card.motionView.layer.animation(forKey: "attention.loop") as? CAKeyframeAnimation)
            XCTAssertEqual(loop.duration, 2.4)
            XCTAssertEqual(loop.repeatCount, .infinity)
        }
        let firstScale = try XCTUnwrap(cards.first?.motionView.layer.presentation()).transform.m11
        try await Task.sleep(for: .milliseconds(220))
        let secondScale = try XCTUnwrap(cards.first?.motionView.layer.presentation()).transform.m11
        XCTAssertNotEqual(firstScale, secondScale, "The visible native breathing animation must keep advancing")
        token.cancel(); observation = nil
        XCTAssertNil(weakObservation)
    }

    func testRootAndPagerProjectOnlyTheirOwnInputsAndReleaseSubscriptions() async throws {
        var owner: RootPresentationModel? = try fixture()
        weak var weakOwner = owner
        let connection = owner!.connection, gps = owner!.gps, effects = owner!.effects
        gps.setEnabled(true)
        var pager: HomeWorkspacePresentation? = HomeWorkspacePresentation(connection: connection, gps: gps)
        weak var weakPager = pager
        var rootChanges = 0, pagerChanges = 0, detailChanges = 0
        let rootToken = owner!.objectWillChange.sink { rootChanges += 1 }
        let pagerToken = pager!.objectWillChange.sink { pagerChanges += 1 }
        let details = gps.$state.dropFirst().sink { _ in detailChanges += 1 }
        for index in 0..<120 { changeDetails(owner!, index: index) }
        XCTAssertEqual(rootChanges, 0)
        XCTAssertEqual(pagerChanges, 0)
        XCTAssertGreaterThanOrEqual(detailChanges, 240)
        XCTAssertEqual(effects.settings.watermark.text, "Draft 119")
        XCTAssertEqual(gps.state.cameraName, "Camera 119")
        effects.setEnabled(!effects.isEnabled)
        XCTAssertEqual(rootChanges, 1)
        XCTAssertEqual(pagerChanges, 0)
        XCTAssertEqual(owner!.snapshot.effectsEnabled, effects.isEnabled)
        gps.setEnabled(false)
        XCTAssertEqual(rootChanges, 2)
        XCTAssertEqual(pagerChanges, 1)
        XCTAssertFalse(owner!.snapshot.gpsEnabled)
        XCTAssertFalse(pager!.gpsEnabled)
        connection.connectDebugSimulator()
        XCTAssertTrue(owner!.snapshot.session === connection.cameraSession)
        XCTAssertEqual(owner!.snapshot.mode, connection.state.presentationMode(transport: nil, isSTA: false))
        XCTAssertTrue(pager!.releaseLocalWorkspace)
        XCTAssertEqual(pagerChanges, 2)
        let settled = rootChanges
        connection.connectDebugSimulator()
        XCTAssertEqual(rootChanges, settled)
        rootToken.cancel(); pagerToken.cancel(); details.cancel()
        owner = nil; pager = nil
        XCTAssertNil(weakOwner)
        XCTAssertNil(weakPager)
        // The original service owners remain usable after subscriptions detach.
        effects.setEnabled(!effects.isEnabled)
        gps.setFrequency(.fiveMinutes)
    }

    func testEveryConnectionPhaseKeepsExistingWorkspaceReleaseRules() {
        let usb: [USBConnectionPhase] = [.unavailable, .waitingForCamera, .connecting, .connected, .failed("failure")]
        let wifi: [WiFiConnectionPhase] = [.unavailable, .idle, .discovering, .pairing, .connecting,
                                         .connected, .reconnecting, .failed("failure")]
        for u in usb {
            for w in wifi {
                var state = ConnectionState()
                state.usbPhase = u; state.wifiPhase = w
                let active: [WiFiConnectionPhase] = [.discovering, .pairing, .connecting, .reconnecting]
                XCTAssertEqual(HomeWorkspacePresentation.shouldRelease(state: state, hasSession: false),
                               u == .connecting || active.contains(w))
                XCTAssertTrue(HomeWorkspacePresentation.shouldRelease(state: state, hasSession: true))
            }
        }
    }

    func testRealRootRemainsStableDuringDetailUpdatesAndStillAdmitsRelevantChanges() async throws {
        let suite = "RootRestore-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(Data([1]), forKey: "transfer_dir")
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Root waits for the existing directory restoration")
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let directory = DirectoryAccessStore(defaults: defaults,
            accessOperations: .init(start: { _ in true }, stop: { _ in }),
            preparation: TransferDirectoryPreparation { _ in },
            resolveBookmark: { _ in
                entered.fulfill()
                guard release.wait(timeout: .now() + 15) == .success else { throw CancellationError() }
                return .init(url: directoryURL, stale: false)
            })
        defer {
            release.signal()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let model = try fixture(directory: directory)
        model.gps.setEnabled(true)
        await fulfillment(of: [entered], timeout: 3)
        var renders = 0
        var root = RootView(presentation: model)
        root.didRender = { renders += 1 }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var host: UIHostingController<RootView>? = UIHostingController(rootView: root)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        let baseline = renders
        for index in 0..<120 {
            changeDetails(model, index: index)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertEqual(renders, baseline)
        XCTAssertTrue(model.snapshot.directoryRestoring)
        model.effects.setEnabled(!model.effects.isEnabled)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(renders, baseline)
        // Unmount before releasing restoration so this host never starts
        // real discovery; restoration itself must still complete independently.
        window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(30))
        release.signal()
        try await directory.waitUntilRestored()
        XCTAssertFalse(model.snapshot.directoryRestoring)
        XCTAssertEqual(model.snapshot.directoryURL, directoryURL)
    }

    func testRealHomePagerIgnoresDetailsButKeepsNativePagingAndGPSLock() async throws {
        let model = try fixture()
        model.gps.setEnabled(true)
        var renders = 0
        var home = HomeWorkspacePagerIOS(connection: model.connection, effectsStore: model.effects,
            gpsCoordinator: model.gps, directory: model.directory, celebrationStart: nil)
        home.didRender = { renders += 1 }
        let host = UIHostingController(rootView: home)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        func findPager(_ controller: UIViewController) -> WorkspacePagingController? {
            if let pager = controller as? WorkspacePagingController { return pager }
            return controller.children.lazy.compactMap(findPager).first
        }
        let pager = try XCTUnwrap(findPager(host))
        XCTAssertFalse(pager.userScrollEnabled)
        let baseline = renders
        for index in 0..<120 {
            changeDetails(model, index: index)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renders, baseline)
        model.gps.setEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(pager.userScrollEnabled)
        XCTAssertGreaterThan(renders, baseline)
        pager.requestPage(1)
        for _ in 0..<100 {
            if pager.currentPage == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pager.currentPage, 1)
        model.gps.setEnabled(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(pager.userScrollEnabled, "GPS must still permit returning from the workbench")
        pager.requestPage(0)
        for _ in 0..<100 {
            if pager.currentPage == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pager.currentPage, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pager.userScrollEnabled)
    }
}

@MainActor private final class RootUSBStub: ConnectionUSBDiscoverySource {
    func currentAuthorization() -> USBAuthorizationState { .denied }
    func refreshAuthorization() {}
    func attachedDevices() -> [USBDeviceDescriptor] { [] }
}

@MainActor private final class RootGPSStub: GPSBluetoothTransport {
    var state: NikonGPSBluetoothState { .disconnected }
    var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { Empty().eraseToAnyPublisher() }
    var hasSavedPairing: Bool { false }
    func start() {}
    func stop() {}
    func clearPairing() {}
    func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) { completion(false) }
}

private final class RootLocationStub: CLLocationManager {
    // No real simulator authorization callbacks may race a scripted state.
    private weak var scriptedDelegate: CLLocationManagerDelegate?
    override var delegate: CLLocationManagerDelegate? {
        get { scriptedDelegate }
        set { scriptedDelegate = newValue }
    }
    override var authorizationStatus: CLAuthorizationStatus { .denied }
    override func requestAlwaysAuthorization() {}
    override func requestWhenInUseAuthorization() {}
    override func startUpdatingLocation() {}
    override func stopUpdatingLocation() {}
}

final class WorkspacePagingTests: XCTestCase {
    @MainActor
    func testWheelRegionTracksLayoutVisibilityAndRemovalWithoutInterceptingTouches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        let marker = WheelDragRegionView()
        marker.frame = CGRect(x: 20, y: 100, width: 120, height: 34)
        host.addSubview(marker)
        XCTAssertFalse(marker.isUserInteractionEnabled)
        XCTAssertTrue(WheelDragRegionView.contains(CGPoint(x: 40, y: 110), in: host))
        XCTAssertFalse(WheelDragRegionView.contains(CGPoint(x: 200, y: 110), in: host))
        host.isHidden = true
        XCTAssertFalse(WheelDragRegionView.contains(CGPoint(x: 40, y: 110), in: host))
        host.isHidden = false
        marker.frame.origin.y = 200
        XCTAssertFalse(WheelDragRegionView.contains(CGPoint(x: 40, y: 110), in: host))
        XCTAssertTrue(WheelDragRegionView.contains(CGPoint(x: 40, y: 210), in: host))
        marker.removeFromSuperview()
        XCTAssertFalse(WheelDragRegionView.contains(CGPoint(x: 40, y: 210), in: host))
    }

    func testInterruptedEntryUsesNewDragDistanceAndNearestBound() {
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.8, upwardVelocity: 0, dragTranslation: -20))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.8, upwardVelocity: 0, dragTranslation: -56))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.2, upwardVelocity: 0, dragTranslation: 20))
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.2, upwardVelocity: 0, dragTranslation: 56))
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.7, upwardVelocity: 0, dragTranslation: -501))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.3, upwardVelocity: 0, dragTranslation: 501))
    }

    @MainActor
    func testContainerCallbacksKeepDiscoveryPausedThroughCancelledReturn() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 0)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        var discovery = WorkspaceDiscoveryState()
        pager.began = { discovery.begin($0) }
        pager.settled = { discovery.request($0); discovery.settle($0) }
        pager.requestPage(1)
        XCTAssertTrue(discovery.shouldPause)
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 800
        XCTAssertTrue(discovery.shouldPause)
        var target = CGPoint.zero
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        scroll.contentOffset = target
        pager.scrollViewDidEndDecelerating(scroll)
        XCTAssertTrue(discovery.shouldPause)
        pager.requestPage(0)
        XCTAssertFalse(discovery.shouldPause)
        XCTAssertEqual(discovery.settledPage, 0)
    }

    @MainActor
    func testNestedAdmissionUsesTouchedScrollableAndOnlySharesItsPan() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        let observer = try XCTUnwrap(pager.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let first = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        first.contentSize.height = 600
        let touched = UIView()
        first.addSubview(touched)
        let second = UIScrollView(frame: first.frame)
        second.contentSize.height = 600
        XCTAssertTrue(pager.prepareNestedDrag(from: touched))
        XCTAssertTrue(pager.acceptsNestedDirection(CGPoint(x: 10, y: 100)))
        XCTAssertFalse(pager.acceptsNestedDirection(CGPoint(x: 100, y: 10)))
        XCTAssertFalse(pager.acceptsNestedDirection(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(pager.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: first.panGestureRecognizer))
        XCTAssertFalse(pager.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: second.panGestureRecognizer))
        XCTAssertTrue(pager.prepareNestedDrag(from: second))
        XCTAssertFalse(pager.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: first.panGestureRecognizer))
        XCTAssertTrue(pager.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: second.panGestureRecognizer))
        XCTAssertFalse(pager.prepareNestedDrag(from: UIView()))
        XCTAssertFalse(pager.acceptsNestedDirection(CGPoint(x: 0, y: 100)))
        pager.userScrollEnabled = false
        XCTAssertFalse(pager.prepareNestedDrag(from: first))
        pager.userScrollEnabled = true
        pager.requestPage(0)
        XCTAssertFalse(pager.prepareNestedDrag(from: first))
    }

    func testEntryUsesComposeVelocityDirectionAndStrictPositionBoundary() {
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.50, upwardVelocity: 0))
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.5001, upwardVelocity: 0))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.20, upwardVelocity: 399))
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.20, upwardVelocity: 400))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0.80, upwardVelocity: -400))
        XCTAssertTrue(shouldEnterWorkspace(distance: 0.80, upwardVelocity: -399))
        XCTAssertFalse(shouldEnterWorkspace(distance: 0, upwardVelocity: 5_000))
        XCTAssertTrue(shouldEnterWorkspace(distance: 1, upwardVelocity: -5_000))
    }

    @MainActor
    func testEntryContainerUsesActualDragDistance() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 0)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        for (position, expected): (CGFloat, CGFloat) in [(500, 0), (501, 1_000)] {
            pager.scrollViewWillBeginDragging(scroll)
            scroll.contentOffset.y = position
            let target = pager.endPageDrag(in: scroll, downwardVelocity: 0, translation: -position)
            XCTAssertEqual(target.y, expected)
            scroll.contentOffset = target
            pager.scrollViewDidEndDecelerating(scroll)
            pager.requestPage(0)
        }
    }

    func testReturnThresholdRequiresDistanceAndDownwardVelocity() {
        XCTAssertFalse(shouldReturnFromWorkspace(distance: 0.14, downwardVelocity: 5_000))
        XCTAssertFalse(shouldReturnFromWorkspace(distance: 0.20, downwardVelocity: 1_199))
        XCTAssertFalse(shouldReturnFromWorkspace(distance: 0.20, downwardVelocity: -2_000))
        XCTAssertTrue(shouldReturnFromWorkspace(distance: 0.15, downwardVelocity: 1_200))
        XCTAssertTrue(shouldReturnFromWorkspace(distance: 0.30, downwardVelocity: 0))
        XCTAssertFalse(shouldReturnFromWorkspace(distance: 0, downwardVelocity: 5_000))
    }

    @MainActor
    func testNestedDragConsumesChildDistanceAndRestoresOnReturnOrCancel() throws {
        for cancelled in [false, true] {
            let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
            pager.loadViewIfNeeded()
            pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
            pager.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
            let inner = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            inner.contentSize.height = 1_000
            inner.contentOffset.y = 100
            pager.beginNestedDrag(in: inner)
            pager.updateNestedDrag(translation: 90)
            XCTAssertEqual(scroll.contentOffset.y, 1_000)
            XCTAssertTrue(inner.isScrollEnabled)
            pager.updateNestedDrag(translation: 250)
            XCTAssertEqual(scroll.contentOffset.y, 850)
            XCTAssertEqual(inner.contentOffset.y, 0)
            XCTAssertFalse(inner.isScrollEnabled)
            pager.endNestedDrag(translation: 250, downwardVelocity: 1_200, cancelled: cancelled)
            XCTAssertEqual(pager.currentPage, cancelled ? 1 : 0)
            XCTAssertTrue(inner.isScrollEnabled)
            XCTAssertTrue(scroll.isScrollEnabled)
        }
    }

    @MainActor
    func testNestedResizeAndProgrammaticTakeoverRestoreChild() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let inner = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        inner.contentSize.height = 1_000
        pager.beginNestedDrag(in: inner)
        pager.updateNestedDrag(translation: 200)
        pager.view.frame.size.height = 500
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        pager.updateNestedDrag(translation: 200)
        XCTAssertEqual(scroll.contentOffset.y, 400)
        pager.requestPage(0)
        XCTAssertTrue(inner.isScrollEnabled)
        XCTAssertEqual(pager.currentPage, 0)
        pager.endNestedDrag(translation: 0, downwardVelocity: 0, cancelled: true)
        XCTAssertEqual(pager.currentPage, 0)
    }

    @MainActor
    func testResizePreservesDragFractionThenRetargetsPendingSettlement() async throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        var settlements: [Int] = []
        pager.settled = { settlements.append($0) }
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 800
        pager.view.frame.size.height = 500
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 0.01)
        var target = CGPoint.zero
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.y, 500)
        // Resize again while the native settle is pending, without completing it.
        pager.view.frame.size.height = 700
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        pager.scrollViewDidEndDecelerating(scroll)
        XCTAssertTrue(settlements.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(scroll.contentOffset.y, 700, accuracy: 0.01)
        XCTAssertEqual(pager.currentPage, 1)
        XCTAssertEqual(settlements, [1])
    }

    @MainActor
    func testQueuedResizeSettlementCannotOverrideNewDestination() async throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 800
        var target = CGPoint.zero
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        pager.view.frame.size.height = 500
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        pager.requestPage(0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pager.currentPage, 0)
        XCTAssertEqual(scroll.contentOffset.y, 0)
    }

    @MainActor
    func testProgrammaticReturnTakesOverDragAndRejectsLateDragEnd() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        var settled: [Int] = []
        pager.settled = { settled.append($0) }
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 900
        // Target matches the tentative gesture destination; still must take over now.
        pager.requestPage(0)
        XCTAssertEqual(pager.currentPage, 0)
        XCTAssertEqual(scroll.contentOffset.y, 0)
        var staleTarget = CGPoint(x: 0, y: 1_000)
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &staleTarget)
        pager.scrollViewDidEndDragging(scroll, willDecelerate: false)
        pager.scrollViewDidEndDecelerating(scroll)
        XCTAssertEqual(staleTarget.y, 0)
        XCTAssertEqual(settled, [0])
    }

    @MainActor
    func testDisablingGestureRollsBackAndDoesNotOverrideNewProgrammaticRequest() async throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 750
        pager.userScrollEnabled = false
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pager.currentPage, 1)
        XCTAssertEqual(scroll.contentOffset.y, 1_000)
        pager.userScrollEnabled = true
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 750
        pager.userScrollEnabled = false
        pager.requestPage(0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pager.currentPage, 0)
        XCTAssertEqual(scroll.contentOffset.y, 0)
        XCTAssertFalse(scroll.isScrollEnabled)
    }

    @MainActor
    func testRealContainerSettlesReturnAndProgrammaticLifecycleOnce() throws {
        let pager = WorkspacePagingController(pages: [UIViewController(), UIViewController()], initialPage: 1)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_000)
        pager.view.setNeedsLayout()
        pager.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.contentOffset.y, 1_000)
        var events: [String] = []
        pager.began = { events.append("begin:\($0)") }
        pager.settled = { events.append("settle:\($0)") }
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 700
        var target = CGPoint(x: 0, y: 900)
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.y, 0)
        scroll.contentOffset = target
        pager.scrollViewDidEndDecelerating(scroll)
        pager.scrollViewDidEndDecelerating(scroll)
        XCTAssertEqual(pager.currentPage, 0)
        XCTAssertEqual(events, ["begin:0", "settle:0"])
        pager.requestPage(1)
        XCTAssertEqual(pager.currentPage, 1)
        XCTAssertEqual(events.suffix(2), ["begin:1", "settle:1"])
        // An under-threshold return must settle back on the workbench.
        pager.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 800
        target.y = 0
        pager.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.y, 1_000)
        scroll.contentOffset = target
        pager.scrollViewDidEndDecelerating(scroll)
        XCTAssertEqual(pager.currentPage, 1)
    }
}


final class LocalExpandedPreviewSnapshotTests: XCTestCase {
    func testSnapshotKeepsOpeningImageComparisonAndAnchorAcrossReplacement() {
        let image = UIImage(), comparison = UIImage(), replacement = UIImage()
        let anchor = CGRect(x: 10, y: 20, width: 300, height: 200)
        let snapshot = PhotoEffectsExpandedPreviewSnapshot(image: image, initialComparison: comparison, anchor: anchor)
        XCTAssertTrue(snapshot.image === image)
        XCTAssertEqual(snapshot.anchor, anchor)
        XCTAssertTrue(snapshot.comparison(current: nil) === comparison)
        XCTAssertTrue(snapshot.comparison(current: LocalPhotoPreviewImages(filtered: replacement, unfiltered: UIImage())) === comparison)
    }

    func testLateComparisonOnlyAppliesToTheOpenedImageIdentity() {
        let image = UIImage(), late = UIImage()
        let snapshot = PhotoEffectsExpandedPreviewSnapshot(image: image, initialComparison: nil, anchor: .zero)
        XCTAssertNil(snapshot.comparison(current: nil))
        XCTAssertTrue(snapshot.comparison(current: LocalPhotoPreviewImages(filtered: image, unfiltered: late)) === late)
        XCTAssertNil(snapshot.comparison(current: LocalPhotoPreviewImages(filtered: UIImage(), unfiltered: late)))
        // Android falls back to the opening comparison, not a late image from another render.
        XCTAssertNil(snapshot.comparison(current: nil))
    }
}

@MainActor final class ExpandedEffectsInteractionTests: XCTestCase {
    private let imageSize = CGSize(width: 4_000, height: 6_000)
    private let viewport = CGSize(width: 400, height: 800)

    func testComparisonWaitsForCompletedLongPressAndPinchPhasePublishesOnce() {
        XCTAssertFalse(photoEffectsComparisonRequested(.first(false)))
        XCTAssertFalse(photoEffectsComparisonRequested(.first(true)))
        XCTAssertFalse(photoEffectsComparisonRequested(.second(false, nil)))
        XCTAssertTrue(photoEffectsComparisonRequested(.second(true, nil)))
        let interaction = PhotoEffectsExpandedInteraction()
        var changes = 0
        let subscription = interaction.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        interaction.setMagnifying(true)
        XCTAssertTrue(interaction.magnifying)
        XCTAssertEqual(interaction.transform, .init())
        XCTAssertEqual(changes, 1, "A stationary pinch must still hide a held comparison")
        interaction.setMagnifying(true)
        XCTAssertEqual(changes, 1)
        interaction.setMagnifying(false)
        XCTAssertFalse(interaction.magnifying)
        XCTAssertEqual(changes, 2)
    }

    func testDoubleTapUses240msCurveAndReversesFromVisibleTransform() {
        var motion = PhotoEffectsExpandedMotion()
        motion.doubleTap(at: CGPoint(x: 300, y: 500), imageSize: imageSize, viewport: viewport)
        motion.advance(0)
        XCTAssertEqual(motion.transform, .init())
        motion.advance(120_000_000)
        let fraction = CGFloat(ZTransferAndroidMotion.tween(milliseconds: 240)
            .animationSample(at: 120_000_000, from: 0, to: 1, velocity: 0).value)
        XCTAssertEqual(motion.transform.scale, 1 + 1.5 * fraction, accuracy: 0.00001)
        XCTAssertEqual(motion.transform.offset.width, -150 * fraction, accuracy: 0.00001)
        XCTAssertEqual(motion.transform.offset.height, -150 * fraction, accuracy: 0.00001)
        let visible = motion.transform
        motion.doubleTap(at: .zero, imageSize: imageSize, viewport: viewport)
        motion.advance(121_000_000)
        XCTAssertEqual(motion.transform, visible)
        motion.advance(361_000_000)
        XCTAssertEqual(motion.transform.scale, 1)
        XCTAssertEqual(motion.transform.offset, .zero)
        XCTAssertFalse(motion.isRunning)
    }

    func testDragCancelsZoomAtVisibleValueAndClampsWithoutJump() {
        var motion = PhotoEffectsExpandedMotion()
        motion.doubleTap(at: CGPoint(x: 300, y: 500), imageSize: imageSize, viewport: viewport)
        motion.advance(0); motion.advance(80_000_000)
        let visible = motion.transform
        motion.drag(translation: .zero, imageSize: imageSize, viewport: viewport)
        motion.advance(1_000_000_000)
        XCTAssertEqual(motion.transform, visible)
        XCTAssertFalse(motion.isRunning)
        motion.drag(translation: CGSize(width: 20, height: 10), imageSize: imageSize, viewport: viewport)
        XCTAssertEqual(motion.transform.offset, photoPreviewClampedOffset(
            CGSize(width: visible.offset.width + 20, height: visible.offset.height + 10),
            scale: visible.scale, imageSize: imageSize, viewportSize: viewport, rotationDegrees: 0))
        motion.drag(translation: CGSize(width: 10_000, height: -10_000), imageSize: imageSize, viewport: viewport)
        let boundary = motion.transform
        motion.endDrag()
        motion.drag(translation: .zero, imageSize: imageSize, viewport: viewport)
        XCTAssertEqual(motion.transform, boundary)
    }

    func testPinchKeepsCentroidAndOneFingerHandoffUsesOnlyNewTranslation() {
        var motion = PhotoEffectsExpandedMotion()
        motion.doubleTap(at: CGPoint(x: 200, y: 400), imageSize: imageSize, viewport: viewport)
        motion.advance(0); motion.advance(240_000_000)
        motion.drag(translation: .zero, imageSize: imageSize, viewport: viewport)
        motion.setMagnifying(true)
        let centroid = CGPoint(x: 280, y: 460)
        let pixel = CGPoint(x: (centroid.x - 200 - motion.transform.offset.width) / motion.transform.scale,
                            y: (centroid.y - 400 - motion.transform.offset.height) / motion.transform.scale)
        motion.pinch(factor: 1.2, centroid: centroid, pan: .zero, imageSize: imageSize, viewport: viewport)
        XCTAssertEqual(pixel.x * motion.transform.scale + motion.transform.offset.width, 80, accuracy: 0.00001)
        XCTAssertEqual(pixel.y * motion.transform.scale + motion.transform.offset.height, 60, accuracy: 0.00001)
        motion.drag(translation: CGSize(width: 300, height: 200), imageSize: imageSize, viewport: viewport)
        motion.pinch(factor: 1, centroid: centroid, pan: CGSize(width: 30, height: 10), imageSize: imageSize, viewport: viewport)
        motion.setMagnifying(false)
        let afterPinch = motion.transform
        motion.drag(translation: CGSize(width: 305, height: 202), imageSize: imageSize, viewport: viewport)
        XCTAssertEqual(motion.transform.offset.width, afterPinch.offset.width + 5, accuracy: 0.00001)
        XCTAssertEqual(motion.transform.offset.height, afterPinch.offset.height + 2, accuracy: 0.00001)
        motion.setMagnifying(true)
        motion.pinch(factor: 100, centroid: centroid, pan: .zero, imageSize: imageSize, viewport: viewport)
        XCTAssertEqual(motion.transform.scale, 10) // One source pixel per display point.
        motion.pinch(factor: 0.001, centroid: centroid, pan: .zero, imageSize: imageSize, viewport: viewport)
        motion.setMagnifying(false)
        XCTAssertEqual(motion.transform.scale, 1)
        XCTAssertEqual(motion.transform.offset, .zero)
    }

    func testRotationUses220msAndRetargetsFromCurrentAngleWhileResettingZoom() {
        var motion = PhotoEffectsExpandedMotion()
        motion.doubleTap(at: CGPoint(x: 300, y: 500), imageSize: imageSize, viewport: viewport)
        motion.advance(0); motion.advance(100_000_000)
        motion.rotate()
        XCTAssertEqual(motion.transform.scale, 1)
        XCTAssertEqual(motion.transform.offset, .zero)
        motion.advance(110_000_000); motion.advance(220_000_000)
        let expected = ZTransferAndroidMotion.tween(milliseconds: 220)
            .animationSample(at: 110_000_000, from: 0, to: -90, velocity: 0).value
        XCTAssertEqual(motion.transform.rotationDegrees, Double(expected), accuracy: 0.00001)
        let angle = motion.transform.rotationDegrees
        motion.rotate()
        XCTAssertEqual(motion.transform.rotationDegrees, angle)
        motion.advance(440_000_000)
        XCTAssertEqual(motion.transform.rotationDegrees, -180)
        XCTAssertFalse(motion.isRunning)
    }

    private final class BodyCounter { var value = 0 }
    private struct Host: View {
        let image: UIImage
        let counter: BodyCounter
        @State var interaction: PhotoEffectsExpandedInteraction
        var body: some View {
            let _ = counter.value += 1
            PhotoEffectsExpandedImageSurface(image: image, comparison: nil, interaction: interaction,
                closing: false, onClose: {}).frame(width: 320, height: 480)
        }
    }
    private func markerImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            UIColor.red.setFill(); context.fill(CGRect(x: 80, y: 35, width: 40, height: 30))
        }
    }
    private func redBounds(_ view: UIView) throws -> CGRect {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if bytes[i] > 200, bytes[i + 1] < 40, bytes[i + 2] < 40, bytes[i + 3] > 200 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        XCTAssertGreaterThan(maxX, minX); XCTAssertGreaterThan(maxY, minY)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testProductionImageUpdatesWithoutRebuildingParentAndClockStopsWhenHidden() async throws {
        let interaction = PhotoEffectsExpandedInteraction(), counter = BodyCounter(), image = markerImage()
        let controller = UIHostingController(rootView: Host(image: image, counter: counter, interaction: interaction))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        defer { interaction.setActive(false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        let parent = counter.value
        let viewport = CGSize(width: 320, height: 480)
        interaction.setMagnifying(true)
        interaction.pinch(factor: 2, centroid: CGPoint(x: 160, y: 240), pan: .zero,
            imageSize: image.size, viewport: viewport)
        interaction.setMagnifying(false)
        try await Task.sleep(for: .milliseconds(50))
        let before = try redBounds(controller.view)
        interaction.drag(translation: .zero, imageSize: image.size, viewport: viewport)
        for step in 1...30 {
            interaction.drag(translation: CGSize(width: CGFloat(step), height: 0), imageSize: image.size, viewport: viewport)
            try await Task.sleep(for: .milliseconds(4))
        }
        try await Task.sleep(for: .milliseconds(50))
        let after = try redBounds(controller.view)
        XCTAssertEqual(after.midX - before.midX, 30, accuracy: 1)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(counter.value, parent)
        interaction.endDrag()
        interaction.rotate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(interaction.transform.rotationDegrees, 0)
        XCTAssertGreaterThan(interaction.transform.rotationDegrees, -90)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(interaction.transform.rotationDegrees, -90)
        XCTAssertFalse(interaction.isRunning)
        let rotated = try redBounds(controller.view)
        XCTAssertGreaterThan(rotated.height, rotated.width)
        XCTAssertEqual(counter.value, parent)
        var notifications = 0
        let subscription = interaction.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<120 { interaction.setMagnifying(false) }
        XCTAssertEqual(notifications, 0)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(notifications, 0, "Settled animation must stop its display link")
        interaction.doubleTap(at: .zero, imageSize: image.size, viewport: viewport)
        try await Task.sleep(for: .milliseconds(70))
        interaction.setActive(false)
        let stopped = interaction.transform, stoppedCount = notifications
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(interaction.transform, stopped)
        XCTAssertEqual(notifications, stoppedCount)
        interaction.setActive(true)
        interaction.doubleTap(at: .zero, imageSize: image.size, viewport: viewport)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(interaction.isRunning)
        XCTAssertEqual(counter.value, parent)
    }

    func testRunningClockDoesNotRetainItsOwner() {
        weak var released: PhotoEffectsExpandedInteraction?
        autoreleasepool {
            let interaction = PhotoEffectsExpandedInteraction()
            released = interaction
            interaction.setActive(true)
            interaction.rotate()
        }
        XCTAssertNil(released)
    }
}

@MainActor final class ExpandedPreviewPresentationLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var expanded = false
        var started = 0
        var cancelled = 0
        var disappeared = 0
        var releaseComparison = false
        let image = UIImage()
        @Published var comparison: UIImage?
    }

    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            Color.clear
                .task {
                    state.started += 1
                    do {
                        while !state.releaseComparison {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        state.comparison = UIImage()
                        try await Task.sleep(for: .seconds(30))
                    }
                    catch { state.cancelled += 1 }
                }
                .onDisappear { state.disappeared += 1 }
                .fullScreenCover(isPresented: $state.expanded) {
                    PhotoEffectsExpandedPreview(image: state.image, comparison: state.comparison,
                        initialAnchor: CGRect(x: 10, y: 20, width: 300, height: 225)) {
                        state.expanded = false
                    }
                }
        }
    }

    func testFullScreenPresentationKeepsUnderlyingTaskRunning() async throws {
        let state = State()
        let controller = UIHostingController(rootView: Host(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where state.started == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.started, 1)
        state.expanded = true
        for _ in 0..<100 where controller.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.presentedViewController)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(state.cancelled, 0, "Opening a photo must not cancel its pending comparison")
        XCTAssertEqual(state.disappeared, 0, "Opening a photo must not close the underlying preview cache")
        state.releaseComparison = true
        for _ in 0..<100 where state.comparison == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(state.comparison, "Comparison work must finish while the preview is presented")
        state.expanded = false
        for _ in 0..<100 where controller.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(controller.presentedViewController)
        XCTAssertEqual(state.started, 1)
        XCTAssertEqual(state.cancelled, 0)
        XCTAssertEqual(state.disappeared, 0)
    }
}


final class RemoteExposureMeterReadingTests: XCTestCase {
    func testMissingAndInvalidSamplesHaveNoPointer() {
        for value in [nil, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
            let reading = RemoteExposureMeterReading(ev: value)
            XCTAssertNil(reading.fraction)
            XCTAssertEqual(reading.overflowDirection, 0)
            XCTAssertFalse(reading.isBalanced)
            XCTAssertEqual(reading.accessibilityValue, "—")
        }
    }

    func testScaleAndOverflowDirectionPreserveActualValue() {
        for (ev, fraction, direction) in [(-4.0, 1.0, 1), (-3, 1, 0), (-1.5, 0.75, 0),
                                         (0, 0.5, 0), (1.5, 0.25, 0), (3, 0, 0), (4, 0, -1)] {
            let reading = RemoteExposureMeterReading(ev: ev)
            XCTAssertEqual(reading.fraction, CGFloat(fraction))
            XCTAssertEqual(reading.overflowDirection, direction)
        }
        XCTAssertEqual(RemoteExposureMeterReading(ev: 4).accessibilityValue, "+4.0 EV")
        XCTAssertEqual(RemoteExposureMeterReading(ev: -4).accessibilityValue, "-4.0 EV")
        XCTAssertEqual(RemoteExposureMeterReading(ev: -0.0).accessibilityValue, "+0.0 EV")
    }

    func testBalancedRangeUsesAndroidStrictBoundary() {
        XCTAssertTrue(RemoteExposureMeterReading(ev: 0).isBalanced)
        XCTAssertTrue(RemoteExposureMeterReading(ev: -0.08).isBalanced)
        XCTAssertFalse(RemoteExposureMeterReading(ev: 1.0 / 12).isBalanced)
        XCTAssertFalse(RemoteExposureMeterReading(ev: -1.0 / 12).isBalanced)
    }
}


@MainActor final class QueuePerformanceRenderingTests: XCTestCase {
    private final class Counters {
        var parent = 0
        var leaf = 0
        var appearances = 0
    }
    private final class Generation: ObservableObject {
        @Published var running = false
    }
    private struct GenerationHost: View {
        @ObservedObject var generation: Generation
        let counters: Counters
        var body: some View {
            let _ = counters.parent += 1
            TimelineView(QueueGenerationTimelineSchedule(running: generation.running)) { _ in
                let _ = counters.leaf += 1
                Text("elapsed").onAppear { counters.appearances += 1 }
            }
        }
    }
    private struct AccentHost: View {
        @State var animator: QueueCardAccentAnimator
        let counters: Counters
        var body: some View {
            let _ = counters.parent += 1
            Text("unchanged filename and actions")
                .background {
                    QueueCardAccentScope(animator: animator, fallback: 0xFF000000) { color in
                        let _ = counters.leaf += 1
                        color
                    }
                }
        }
    }
    private struct PillHost: View {
        @State var animator: TransferPillResponseAnimator
        let counters: Counters
        var body: some View {
            let _ = counters.parent += 1
            Text("123 MB/s").padding(7)
                .modifier(TransferPillAnimatedLayout(response: animator,
                    fill: LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom),
                    edge: LinearGradient(colors: [.black, .gray], startPoint: .top, endPoint: .bottom)))
        }
    }
    private struct CountedMark: View {
        let counters: Counters
        var body: some View {
            let _ = counters.leaf += 1
            DoubleZMark(tint: .black)
        }
    }
    private struct WidthHost: View {
        @State var clock: QueuePillWidthClock
        let counters: Counters
        var body: some View {
            let _ = counters.parent += 1
            Color.clear.frame(width: 300, height: 40).overlay(alignment: .trailing) {
                QueuePillAnimatedSize(clock: clock) {
                    Color.red
                    Text("123 MB/s  99").fixedSize().hidden()
                }
            }
        }
    }
    private func mount<V: View>(_ root: V) throws -> (UIWindow, UIHostingController<V>, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host, previous)
    }
    private func unmount(_ window: UIWindow, previous: UIWindow?) {
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func testGenerationTimelineStopsWhenIdleAndResumesWithoutRemounting() async throws {
        let counters = Counters(), generation = Generation()
        let (window, _, previous) = try mount(GenerationHost(generation: generation, counters: counters))
        defer { unmount(window, previous: previous) }
        try await Task.sleep(for: .milliseconds(120))
        let idle = counters.leaf, idleParent = counters.parent, appearances = counters.appearances
        XCTAssertGreaterThan(idle, 0)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(counters.leaf, idle, "Completed effect rows must not wake at 5Hz")
        XCTAssertEqual(counters.parent, idleParent)
        for _ in 0..<2 {
            generation.running = true
            try await Task.sleep(for: .milliseconds(100))
            let running = counters.leaf, parent = counters.parent
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertGreaterThanOrEqual(counters.leaf - running, 2)
            XCTAssertEqual(counters.parent, parent)
            generation.running = false
            try await Task.sleep(for: .milliseconds(100))
            let stopped = counters.leaf
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(counters.leaf, stopped)
            XCTAssertEqual(counters.appearances, appearances, "Retained pill transitions must keep identity")
        }
    }

    func testCardColorFramesOnlyInvalidateDrawingLeavesAndStopAfterTween() async throws {
        let counters = Counters(), animator = QueueCardAccentAnimator()
        animator.mount(0xFFFF0000)
        let (window, _, previous) = try mount(AccentHost(animator: animator, counters: counters))
        defer { animator.stop(); unmount(window, previous: previous) }
        try await Task.sleep(for: .milliseconds(100))
        let parent = counters.parent, leaf = counters.leaf
        animator.update(0xFF0000FF)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(counters.leaf, leaf)
        XCTAssertNotEqual(animator.value, 0xFFFF0000)
        animator.update(0xFF00FF00) // Interrupt from the current displayed Oklab color.
        try await Task.sleep(for: .milliseconds(430))
        XCTAssertEqual(animator.value, 0xFF00FF00)
        XCTAssertEqual(counters.parent, parent)
        let settled = counters.leaf
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(counters.leaf, settled)
    }

    func testPillAnimationKeepsContentStableAndIgnoresUnchangedMeasurements() async throws {
        let counters = Counters(), animator = TransferPillResponseAnimator(responding: false)
        animator.measureWidth(65, scale: 3)
        let (window, _, previous) = try mount(PillHost(animator: animator, counters: counters))
        defer { animator.unmount(); unmount(window, previous: previous) }
        try await Task.sleep(for: .milliseconds(100))
        let parent = counters.parent
        var notifications = 0
        let subscription = animator.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<120 {
            animator.measureWidth(65.01, scale: 3) // Same physical pixel target.
            animator.update(false)
        }
        XCTAssertEqual(notifications, 0)
        animator.measureWidth(106, scale: 3)
        animator.update(true)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertLessThan(animator.motion.scale.value, 1)
        XCTAssertGreaterThan(try XCTUnwrap(animator.widthMotion.width), 65)
        XCTAssertEqual(counters.parent, parent)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(animator.widthMotion.width, 106)
        XCTAssertEqual(animator.motion.scale.value, 1)
        XCTAssertEqual(counters.parent, parent)
        let settled = notifications
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(notifications, settled)
        animator.unmount()
        animator.measureWidth(65, scale: 3)
        XCTAssertEqual(animator.widthMotion.width, 65, "Remount must not reuse old measurement state")
    }

    func testCapsuleWidthFramesDoNotRebuildContentsAndRetargetWithoutReset() async throws {
        let counters = Counters(), clock = QueuePillWidthClock()
        clock.update(width: 40, scale: 3)
        let (window, _, previous) = try mount(WidthHost(clock: clock, counters: counters))
        defer { clock.reset(); unmount(window, previous: previous) }
        try await Task.sleep(for: .milliseconds(100))
        let parent = counters.parent
        clock.update(width: 180, scale: 3)
        try await Task.sleep(for: .milliseconds(80))
        let expanding = try XCTUnwrap(clock.motion.width)
        XCTAssertGreaterThan(expanding, 40)
        XCTAssertLessThan(expanding, 180)
        clock.update(width: 90, scale: 3)
        XCTAssertEqual(try XCTUnwrap(clock.motion.width), expanding, accuracy: 0.4)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while clock.motion.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(clock.motion.width, 90)
        XCTAssertFalse(clock.motion.isRunning)
        XCTAssertEqual(counters.parent, parent)
    }

    func testNativeEmptyMarkRetainsCurveContentAndStopsAcrossPageLifecycle() async throws {
        let (window, controller, previous) = try mount(QueueEmptyMarkSurface()
            .frame(width: 58 * DoubleZMark.aspectRatio, height: 58))
        defer { unmount(window, previous: previous) }
        let native = try XCTUnwrap(find(QueueEmptyMarkNativeView.self, in: controller.view))
        let loop = try XCTUnwrap(native.motionView.layer.animation(forKey: "queue.breathe") as? CAAnimationGroup)
        XCTAssertEqual(loop.duration, 4.8)
        XCTAssertTrue(loop.repeatCount.isInfinite)
        XCTAssertEqual(loop.animations?.count, 2)
        let reveal = try XCTUnwrap(native.layer.animation(forKey: "queue.reveal") as? CABasicAnimation)
        XCTAssertEqual(reveal.duration, 0.34)
        let counters = Counters()
        native.host.rootView = AnyView(CountedMark(counters: counters))
        try await Task.sleep(for: .milliseconds(180))
        let bodyCount = counters.leaf
        XCTAssertGreaterThan(bodyCount, 0)
        func checkPresentation() throws {
            let elapsed = native.motionView.layer.convertTime(CACurrentMediaTime(), from: nil) - loop.beginTime
            let expected = QueueEmptyMarkMotion.sample(elapsedNanos: Int64(elapsed * 1_000_000_000))
            let presented = try XCTUnwrap(native.motionView.layer.presentation())
            let revealAlpha = try XCTUnwrap(native.layer.presentation()).opacity
            XCTAssertEqual(presented.opacity * revealAlpha, expected.opacity, accuracy: elapsed < 0.34 ? 0.025 : 0.0035)
            XCTAssertEqual(Float(presented.transform.m11), expected.scale, accuracy: 0.003)
        }
        try checkPresentation()
        try await Task.sleep(for: .milliseconds(550))
        try checkPresentation()
        XCTAssertEqual(counters.leaf, bodyCount, "Continuous breathing must not rebuild the vector mark")
        try await Task.sleep(for: .milliseconds(3500))
        try checkPresentation() // Reverse leg must retrace the asymmetric easing.
        XCTAssertEqual(counters.leaf, bodyCount)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: native.host.view.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(native.host.view.bounds)
            native.host.view.drawHierarchy(in: native.host.view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let darkPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 60 && pixels[$0 + 1] < 60 && pixels[$0 + 2] < 60 && pixels[$0 + 3] > 200
        }.count
        XCTAssertGreaterThan(darkPixels, 200, "The live vector mark must not become blank")
        XCTAssertLessThan(darkPixels, cg.width * cg.height / 2, "The transparent host must not become an opaque block")
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p11-empty-mark.png"))
        native.configure(active: false)
        XCTAssertNil(native.motionView.layer.animation(forKey: "queue.breathe"))
        XCTAssertNil(native.layer.animation(forKey: "queue.reveal"))
        native.configure(active: true)
        let restarted = try XCTUnwrap(native.motionView.layer.animation(forKey: "queue.breathe"))
        XCTAssertGreaterThan(restarted.beginTime, loop.beginTime)
        native.configure(active: true)
        XCTAssertEqual(native.motionView.layer.animation(forKey: "queue.breathe")?.beginTime, restarted.beginTime)
        native.removeFromSuperview()
        XCTAssertNil(native.motionView.layer.animation(forKey: "queue.breathe"))
    }
}

@MainActor final class QueueProgressInvalidationTests: XCTestCase {
    private final class Selection: ObservableObject {
        @Published var activeIndex: Int? = 0
    }
    private final class Evaluations {
        var page = 0
        var rows = Array(repeating: 0, count: 40)
    }
    private struct Host: View {
        @ObservedObject var selection: Selection
        let progress: TransferQueueProgressViewModel
        let evaluations: Evaluations
        var body: some View {
            let _ = evaluations.page += 1
            VStack(spacing: 0) {
                ForEach(0..<40, id: \.self) { index in
                    QueueProgressScope(model: progress, active: selection.activeIndex == index) { _ in
                        let _ = evaluations.rows[index] += 1
                        Color.clear.frame(height: 2)
                    }
                }
            }
        }
    }

    func testOnlyActiveScopeReevaluatesAndSubscriptionMovesWithTask() async throws {
        let selection = Selection(), evaluations = Evaluations()
        let progress = TransferQueueProgressViewModel()
        let controller = UIHostingController(rootView: Host(selection: selection,
            progress: progress, evaluations: evaluations))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(evaluations.rows.allSatisfy { $0 > 0 })
        for active in [0, 17, -1] {
            selection.activeIndex = active < 0 ? nil : active
            try await Task.sleep(for: .milliseconds(100))
            let before = evaluations.rows, pageBefore = evaluations.page
            // Use the actual ObservableObject invalidation channel; no setter
            // exposure or synthetic queue state is needed to measure view scope.
            for _ in 0..<5 {
                progress.objectWillChange.send()
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(evaluations.page, pageBefore)
            for row in 0..<40 {
                if row == active { XCTAssertGreaterThan(evaluations.rows[row], before[row]) }
                else { XCTAssertEqual(evaluations.rows[row], before[row], "Inactive row \(row) reevaluated") }
            }
        }
    }
}


@MainActor final class PhotoPreviewDecodeCancellationTests: XCTestCase {
    func testCancellationDuringSynchronousDecodeDiscardsLateImageAndAllowsReplacement() async throws {
        let entered = expectation(description: "Background codec entered")
        let release = DispatchSemaphore(value: 0)
        let old = Task {
            try await loadCameraPhotoPreviewContent(Data([1])) { _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    XCTFail("Codec gate was not released")
                    return nil
                }
                // Model ImageIO returning pixels even after cancellation.
                return CameraPhotoPreviewContent(image: UIImage(), histogram: nil, orientation: 6)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        old.cancel()
        let replacement = try await loadCameraPhotoPreviewContent(Data([2])) { _ in
            XCTAssertFalse(Thread.isMainThread)
            return CameraPhotoPreviewContent(image: UIImage(), histogram: nil, orientation: 3)
        }
        XCTAssertEqual(replacement?.orientation, 3)
        release.signal()
        do {
            _ = try await old.value
            XCTFail("Cancelled codec result escaped into the caller")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

@MainActor final class PhotoPreviewRetentionLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var entries: [PhotoPreviewEntry]
        @Published var index = 1
        var cached: Set<UInt32> = []
        var evictions = 0
        init(entries: [PhotoPreviewEntry]) { self.entries = entries }
    }
    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            Color.clear.modifier(PhotoPreviewRetentionObserver(
                retainedIDs: retainedPhotoPreviewIDs(entries: state.entries, currentIndex: state.index),
                trim: {
                    state.cached.formIntersection(retainedPhotoPreviewIDs(entries: state.entries, currentIndex: state.index))
                    state.evictions += 1
                }))
        }
    }

    func testProductionRetentionObserverHandlesPagingBurstChangesAndInvalidPage() async throws {
        let files = (1...7).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let group = BurstPhotoGroup(id: "lifecycle", files: Array(files[2...4]))
        let collapsed: [PhotoPreviewEntry] = [.photo(files[0]), .photo(files[1]), .burst(group), .photo(files[5]), .photo(files[6])]
        let state = State(entries: collapsed)
        let all = Set(files.map(\.id))
        state.cached = all
        let controller = UIHostingController(rootView: Host(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.cached, [1, 2, 6])
        state.cached = all
        state.entries = expandPhotoPreviewBurst(collapsed, at: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.cached, [1, 2, 3])
        state.cached = all
        state.index = 5
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.cached, [3, 4, 5, 6, 7])
        state.cached = all
        state.entries = collapsed; state.index = 1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.cached, [1, 2, 6])
        state.index = -1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.cached.isEmpty)
        XCTAssertGreaterThanOrEqual(state.evictions, 5)
    }
}

@MainActor
final class DetentWheelAcceptedValueRenderingTests: XCTestCase {
    private final class Selection: ObservableObject {
        @Published var options = [0, 1, 2, 3]
        @Published var selected = 0
    }
    private struct Host: View {
        @ObservedObject var selection: Selection
        var body: some View {
            DetentWheel(label: "", options: selection.options, selected: selection.selected,
                optionLabel: { ["AAAA", "BBBB", "CCCC", "DDDD"][$0] },
                onCommit: { _ in }, showDragHint: false)
                .frame(width: 200, height: 50)
                .environment(\.colorScheme, .light)
        }
    }

    func testAcceptedIdentityRendersAfterExternalSelectionAndReorder() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let selection = Selection()
        let host = UIHostingController(rootView: Host(selection: selection))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        func capture(_ view: UIView) throws -> Data {
            view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
                XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
            }
            return try XCTUnwrap(image.pngData())
        }
        try await Task.sleep(for: .milliseconds(100))
        let initial = try capture(host.view)
        selection.selected = 2
        try await Task.sleep(for: .milliseconds(30))
        let accepted = try capture(host.view)
        XCTAssertNotEqual(initial, accepted)
        selection.options = [2, 3, 0, 1]
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try capture(host.view), accepted,
            "Reordering must keep the accepted identity visible, not the old numeric index")
        let reference = Selection()
        reference.selected = 2
        let referenceHost = UIHostingController(rootView: Host(selection: reference))
        window.rootViewController = referenceHost
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(accepted, try capture(referenceHost.view),
            "Updated wheel must render the same accepted label as a fresh wheel")
    }
}

/// Uses the complete production overlay, including its preference/hosting-size
/// handoff. A fixed-frame Genie host alone cannot detect a late outer resize.
@MainActor
final class PopupLifetimePerformanceTests: XCTestCase {
    func testSettledPopupHasNoFrameWorkAndDetachingDuringMotionReleasesHost() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let root = UIViewController()
        window.rootViewController = root; window.isHidden = false
        defer { window.isHidden = true }
        for gentle in [false, true] {
            var popup: GeniePopupHostView? = GeniePopupHostView(frame: CGRect(x: 20, y: 80, width: 260, height: 160))
            weak var released = popup
            popup!.host.rootView = AnyView(Color.red.frame(width: 260, height: 160))
            var frames: [CGFloat] = []
            popup!.onProgress = { frames.append($0) }
            root.view.addSubview(popup!)
            popup!.configure(target: 1, anchorX: 0.2, anchorWidth: 0.1, anchorGap: 8, gentleMotion: gentle)
            popup!.layoutIfNeeded()
            for _ in 0..<100 {
                if frames.last == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(frames.last, 1)
            XCTAssertTrue(popup!.host.view.isUserInteractionEnabled)
            let settledFrames = frames.count
            for _ in 0..<120 {
                popup!.configure(target: 1, anchorX: 0.2, anchorWidth: 0.1, anchorGap: 8, gentleMotion: gentle)
                popup!.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(frames.count, settledFrames)
            XCTAssertTrue(popup!.subviews.last!.layer.sublayers!.allSatisfy { $0.sublayers?.first?.contents == nil })
            popup!.configure(target: 0, anchorX: 0.2, anchorWidth: 0.1, anchorGap: 8, gentleMotion: gentle)
            popup!.layoutIfNeeded()
            for _ in 0..<100 {
                if frames.last != 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(frames.last! > 0 && frames.last! < 1)
            popup!.removeFromSuperview()
            GeniePopupPanel<EmptyView>.dismantleUIView(popup!, coordinator: ())
            popup = nil
            let detachedFrames = frames.count
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertNil(released, "A display link must not retain a dismissed popup")
            XCTAssertEqual(frames.count, detachedFrames)
        }
    }
}

@MainActor
final class SettingsPopupLayoutTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var presented = false
    }

    private struct Harness: View {
        @ObservedObject var state: State
        let effects: PhotoEffectsStore
        let directory: DirectoryAccessStore
        let showEffects: Bool
        var effectsOnly = false
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.1)
                Color.clear.frame(width: 44, height: 36)
                    .geniePopupAnchor(.settings)
                    .padding(.leading, 12).padding(.top, 20)
            }
            .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
                if let anchor = anchors[.settings] {
                    SettingsPopupOverlay(isPresented: $state.presented, showPhotoEffectsEntry: showEffects,
                        effectsStore: effects, directory: directory, anchor: anchor, effectsOnly: effectsOnly)
                }
            }
        }
    }

    private func descendants<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        (root as? T).map { [$0] } ?? [] + root.subviews.flatMap { descendants(type, in: $0) }
    }

    private func verifyOpening(_ root: UIView, state: State) async throws -> GeniePopupHostView {
        state.presented = true
        var visibleHeights: [CGFloat] = []
        var popup: GeniePopupHostView?
        for _ in 0..<80 {
            root.layoutIfNeeded()
            if let current = descendants(GeniePopupHostView.self, in: root).first {
                popup = current
                let meshVisible = current.subviews.last.map { !$0.isHidden && $0.alpha > 0.01 } ?? false
                if meshVisible || current.host.view.layer.opacity > 0.01 {
                    visibleHeights.append(current.bounds.height)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try XCTUnwrap(popup)
        XCTAssertGreaterThan(visibleHeights.count, 10)
        XCTAssertLessThanOrEqual((visibleHeights.max() ?? 0) - (visibleHeights.min() ?? 0), 0.5,
            "No provisional full-height shell may appear before the measured column: \(visibleHeights)")
        XCTAssertTrue(result.host.view.isUserInteractionEnabled)
        XCTAssertEqual(result.host.view.layer.opacity, 1)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: result.host.view).first)
        let viewport = scroll.convert(scroll.bounds, to: result.host.view)
        XCTAssertEqual(viewport.minY, 0, accuracy: 0.5, "The title must belong to the scroll column")
        XCTAssertEqual(viewport.height, result.bounds.height, accuracy: 0.5,
                       "There must be no pinned header outside a smaller inner scroll viewport")
        XCTAssertLessThanOrEqual(result.bounds.height, scroll.contentSize.height + 0.5,
                                 "Short settings should wrap their content without an empty outer shell")
        XCTAssertFalse(scroll.showsVerticalScrollIndicator)
        return result
    }

    func testWholeColumnUsesFinalHeightFromFirstVisibleFrameOnBothEntrypoints() async throws {
        for showEffects in [false, true] {
            try await withOverlay(size: CGSize(width: 393, height: 852), showEffects: showEffects) { root, state, _ in
                let popup = try await self.verifyOpening(root, state: state)
                let scroll = try XCTUnwrap(self.descendants(UIScrollView.self, in: popup.host.view).first)
                if !showEffects {
                    XCTAssertEqual(popup.bounds.height, scroll.contentSize.height, accuracy: 0.5)
                }
            }
        }
    }

    func testRenderedSettingsMeshMatchesLivePanelAndDoesNotBounce() async throws {
        try await withOverlay(size: CGSize(width: 393, height: 852), showEffects: true) { root, state, _ in
            state.presented = true
            var popup: GeniePopupHostView?
            func snapshot(_ view: UIView) -> UIImage {
                let format = UIGraphicsImageRendererFormat(); format.scale = view.window?.screen.scale ?? UIScreen.main.scale
                return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
                    view.layer.render(in: context.cgContext)
                }
            }
            for _ in 0..<50 {
                root.layoutIfNeeded()
                if let current = self.descendants(GeniePopupHostView.self, in: root).first,
                   let texture = current.subviews.last?.layer.sublayers?.first?.sublayers?.first,
                   texture.contents != nil {
                    popup = current
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let panel = try XCTUnwrap(popup)
            panel.stop()
            // Use the production mesh drawing routine at its exact endpoint.
            // Repeated screenshots can themselves miss the final display tick.
            panel.renderFrame(at: 1)
            let mesh = snapshot(try XCTUnwrap(panel.subviews.last))
            panel.setNeedsLayout()
            panel.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(panel.host.view.layer.opacity, 1)
            let live = snapshot(panel.host.view)
            let scroll = try XCTUnwrap(self.descendants(UIScrollView.self, in: panel.host.view).first)
            print("[SettingsRendering] panel=\(panel.bounds) scroll=\(scroll.bounds) content=\(scroll.contentSize) bounce=\(scroll.bounces) always=\(scroll.alwaysBounceVertical)")
            let attachment = XCTAttachment(image: mesh); attachment.name = "settings-final-mesh"; attachment.lifetime = .keepAlways; self.add(attachment)
            let liveAttachment = XCTAttachment(image: live); liveAttachment.name = "settings-live-panel"; liveAttachment.lifetime = .keepAlways; self.add(liveAttachment)
            XCTAssertFalse(scroll.bounces, "Settings must not rubber-band a separate content layer inside its surface")
            func rgba(_ image: UIImage) throws -> [UInt8] {
                let image = try XCTUnwrap(image.cgImage)
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return bytes
            }
            XCTAssertEqual(mesh.size, live.size)
            let a = try rgba(mesh), b = try rgba(live)
            var difference = 0
            for i in a.indices { difference += abs(Int(a[i]) - Int(b[i])) }
            let mean = Double(difference) / Double(a.count)
            print("[SettingsRendering] transformed_mesh_to_live_mean_difference=\(mean)")
            XCTAssertLessThan(mean, 3, "The actual transformed panel, not only its source bands, must match the live handoff")
        }
    }

    func testCompactColumnScrollsAsAWholeAndReopenDoesNotUseStaleHeight() async throws {
        try await withOverlay(size: CGSize(width: 393, height: 450), showEffects: true) { root, state, window in
            let popup = try await self.verifyOpening(root, state: state)
            let scroll = try XCTUnwrap(self.descendants(UIScrollView.self, in: popup.host.view).first)
            XCTAssertGreaterThan(scroll.contentSize.height, popup.bounds.height + 40)
            let height = popup.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(scroll.contentOffset.y, 40, accuracy: 0.5)
            XCTAssertEqual(popup.bounds.height, height, accuracy: 0.5)
            state.presented = false
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(popup.host.view.layer.opacity, 0)
            // A new presentation after a viewport change must measure anew,
            // without showing the preceding short/scrolling shell first.
            window.frame.size.height = 852
            root.frame = window.bounds
            root.setNeedsLayout()
            _ = try await self.verifyOpening(root, state: state)
        }
    }

    func testPreviewEffectsMountsPresentedWithoutSheetAndClosesToSameHost() async throws {
        try await withOverlay(size: CGSize(width: 393, height: 852), showEffects: true,
                              effectsOnly: true, initiallyPresented: true) { root, state, _ in
            try await Task.sleep(for: .milliseconds(500))
            root.layoutIfNeeded()
            let popup = try XCTUnwrap(self.descendants(GeniePopupHostView.self, in: root).first)
            XCTAssertEqual(popup.host.view.layer.opacity, 1)
            XCTAssertTrue(popup.host.view.isUserInteractionEnabled)
            XCTAssertGreaterThan(popup.bounds.height, 600)
            let scroll = try XCTUnwrap(self.descendants(UIScrollView.self, in: popup.host.view).first)
            XCTAssertGreaterThan(scroll.contentSize.height, 300, "Controls must exist even before the preview source arrives")
            XCTAssertNil(popup.host.presentedViewController, "The editor is an in-place popup, not a system sheet")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: root.bounds.size, format: format).image { root.layer.render(in: $0.cgContext) }
            try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ztransfer-preview-effects-popup.png"))
            state.presented = false
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(popup.host.view.layer.opacity, 0)
            XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
            XCTAssertNotNil(root.window, "Closing effects must leave its presenting preview mounted")
            state.presented = true
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(popup.host.view.layer.opacity, 1)
        }
    }

    private func withOverlay(size: CGSize, showEffects: Bool, effectsOnly: Bool = false, initiallyPresented: Bool = false,
        body: @MainActor (UIView, State, UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let suite = "SettingsPopupLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = State()
        state.presented = initiallyPresented
        let host = UIHostingController(rootView: Harness(state: state,
            effects: PhotoEffectsStore(defaults: defaults), directory: DirectoryAccessStore(defaults: defaults),
            showEffects: showEffects, effectsOnly: effectsOnly).defaultAppStorage(defaults).environment(\.colorScheme, .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            descendants(GeniePopupHostView.self, in: host.view).forEach { $0.stop() }
            window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(50))
        try await body(host.view, state, window)
    }
}

@MainActor
final class QueuePillRenderingTests: XCTestCase {
    func testCountStartsRollingWithoutWaitingForGeometryPreference() throws {
        let clock = QueuePillCountClock(count: 10)
        defer { clock.unmount() }
        clock.update(9)
        let motion = try XCTUnwrap(clock.motion)
        XCTAssertTrue(motion.isRunning)
        XCTAssertEqual(motion.layers.map(\.count), [10, 9])
        XCTAssertGreaterThan(try XCTUnwrap(motion.layers.last).motion.displayedOffsetPixels, 0)
        clock.update(12)
        XCTAssertEqual(clock.motion?.current, 12)
        XCTAssertLessThan(try XCTUnwrap(clock.motion?.layers.last).motion.displayedOffsetPixels, 0)
    }

    func testCountMountScaleAndRemountUseFixedLineBox() throws {
        let clock = QueuePillCountClock(count: 100)
        defer { clock.unmount() }
        clock.measure(height: ZTransferTypography.labelLarge.lineHeight, scale: 3)
        clock.update(99)
        XCTAssertEqual(try XCTUnwrap(clock.motion?.layers.last).motion.displayedOffsetPixels, 30)
        clock.unmount()
        clock.update(8)
        clock.measure(height: ZTransferTypography.labelLarge.lineHeight, scale: 2)
        XCTAssertEqual(clock.motion?.layers.map(\.count), [8])
        XCTAssertFalse(try XCTUnwrap(clock.motion).isRunning)
        clock.update(7)
        XCTAssertEqual(try XCTUnwrap(clock.motion?.layers.last).motion.displayedOffsetPixels, 20)
    }

    func testAnimatedWidthsRemainPinnedToTrailingViewportIncludingOverflow() throws {
        for width: CGFloat in [40, 95, 180, 340] {
            let clock = QueuePillWidthClock()
            clock.update(width: width, scale: 1)
            defer { clock.reset() }
            let content = Color.clear.frame(width: 300, height: 40)
                .overlay(alignment: .trailing) {
                    QueuePillAnimatedSize(clock: clock) {
                        Color.red
                        Color.clear.frame(width: 340, height: 40).hidden()
                    }
                }
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: 300 * 40 * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 300, height: 40,
                bitsPerComponent: 8, bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 300, height: 40))
            let red = (0..<300).filter { x in bytes[(20 * 300 + x) * 4] > 200 }
            XCTAssertEqual(red.last, 299, "Right edge must not move at width \(width)")
            XCTAssertEqual(red.first, 300 - Int(min(width, 300)))
        }
    }
}

@MainActor
final class PhotoListPerformanceRegressionTests: XCTestCase {
    private final class BodyProbe { var count = 0 }
    private struct ScrollHarness: View {
        let probe: BodyProbe
        @State var geometry: PhotoListGeometryCache
        @State var feedback: PhotoPreviewPageFeedback
        var body: some View {
            let _ = { probe.count += 1 }()
            Color.blue.frame(width: 100, height: 100)
                .modifier(PhotoPreviewInformationFade(feedback: feedback, base: 1))
        }
    }

    func testScrollGeometryAndPageOffsetDoNotRebuildParentHierarchy() async throws {
        let geometry = PhotoListGeometryCache()
        let feedback = PhotoPreviewPageFeedback()
        let probe = BodyProbe()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let host = UIHostingController(rootView: ScrollHarness(probe: probe, geometry: geometry, feedback: feedback))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initial = probe.count
        XCTAssertGreaterThan(initial, 0)
        for frame in 1...30 {
            geometry.cellBounds = [.photo(1): CGRect(x: 0, y: -frame, width: 100, height: 100)]
            geometry.scrollItemFrames = ["photo_1": CGRect(x: 0, y: -frame, width: 100, height: 100)]
            feedback.offset = CGFloat(frame) / 100
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.count, initial, "Only the information fade may observe each pager frame")
        XCTAssertEqual(geometry.cellBounds[.photo(1)]?.minY, -30, "Interaction geometry must remain current")
    }

    func testRepeatedScrollCollapseDoesNotPublishUnchangedState() {
        let controller = RemoteEntryIntroController()
        var publications = 0
        let token = controller.objectWillChange.sink { publications += 1 }
        for _ in 0..<240 { controller.collapse() }
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(token) {}
    }

    func testGentlePreviewPopupUsesAndroidScaleOpacityAndSourcePivot() {
        let panel = GeniePopupHostView()
        panel.bounds = CGRect(x: 0, y: 0, width: 360, height: 700)
        panel.configure(target: 1, anchorX: 1, anchorWidth: 0.1, anchorGap: 0,
                        gentleMotion: true, gentleAnchorY: 1)
        panel.renderGentleFrame(at: 0.5)
        let transform = panel.host.view.layer.affineTransform()
        XCTAssertEqual(transform.a, 0.97, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 0.97, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 5.4, accuracy: 0.0001)
        XCTAssertEqual(transform.ty, 10.5, accuracy: 0.0001)
        XCTAssertEqual(panel.host.view.layer.opacity, 0.5)
        panel.stop()
    }
}

@MainActor
final class PhotoPreviewCropRenderingTests: XCTestCase {
    func testCropInitialPlacementAndRatioReturnMatchAndroidWithoutRefit() throws {
        var geometry = CropEditorGeometry(source: .init(width: 1620, height: 1080, mcuWidth: 1, mcuHeight: 1, orientation: 1))
        let image = CGRect(x: 40, y: 800, width: 1000, height: 1000 / 1.5)
        try geometry.initialize(CGSize(width: 1080, height: 2400), placement: image)
        XCTAssertEqual(geometry.image, image)
        XCTAssertEqual(geometry.frame.minX, image.minX, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.minY, image.minY, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.width, image.width, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.height, image.height, accuracy: 1e-9)
        geometry.select(.fixed(1, 1))
        XCTAssertEqual(geometry.image, image)
        XCTAssertEqual(geometry.frame.width, geometry.frame.height, accuracy: 0.001)
        try geometry.transform(centroid: CGPoint(x: geometry.frame.midX, y: geometry.frame.midY), pan: CGSize(width: 12, height: -5), zoom: 2)
        geometry.reset()
        XCTAssertEqual(geometry.image, image)
        XCTAssertEqual(geometry.frame.minX, image.minX, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.minY, image.minY, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.width, image.width, accuracy: 1e-9)
        XCTAssertEqual(geometry.frame.height, image.height, accuracy: 1e-9)
        var zoomed = CropEditorGeometry(source: geometry.source)
        let large = CGRect(x: -540, y: 200, width: 2160, height: 1440)
        try zoomed.initialize(CGSize(width: 1080, height: 2400), placement: large)
        XCTAssertEqual(zoomed.image, large)
        XCTAssertEqual(zoomed.frame, CGRect(x: 0, y: 200, width: 1080, height: 1440))
        XCTAssertEqual(zoomed.selection(orientation: 1).bounds.left, 0.25, accuracy: 1e-9)
        XCTAssertEqual(zoomed.selection(orientation: 1).bounds.right, 0.75, accuracy: 1e-9)
    }

    func testFHDNormalPortraitLandscapeCropAndRotationUseAndroidPlacement() {
        let viewport = CGSize(width: 400, height: 800)
        let portrait = CGSize(width: 400, height: 600)
        let normal = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 80, cropTop: 110)
        XCTAssertEqual(normal.center.y, 428, accuracy: 0.001)
        XCTAssertEqual(normal.size, CGSize(width: 360, height: 540))
        let crop = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 80, cropTop: 110, cropProgress: 1)
        XCTAssertEqual(crop.center.y - crop.size.height / 2, 110, accuracy: 0.001)
        let landscape = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: -90, infoBottom: 80, cropTop: 110, cropProgress: 1)
        XCTAssertEqual(landscape.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(landscape.center.y, (440 + 170 + landscape.size.height / 2) / 2, accuracy: 0.001)
        let protected = photoPreviewPlacement(imageSize: portrait, viewportSize: viewport,
            rotationDegrees: 0, infoBottom: 122, cropTop: 110)
        XCTAssertGreaterThan(protected.center.y, normal.center.y)
        for p in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let small = photoPreviewPlacement(imageSize: portrait, viewportSize: CGSize(width: 280, height: 300),
                rotationDegrees: 0, infoBottom: 100, cropTop: 110, cropProgress: p)
            XCTAssertGreaterThan(small.scale, 0)
            XCTAssertGreaterThanOrEqual(small.center.y - small.size.height / 2, 99.99)
            XCTAssertLessThanOrEqual(small.center.y + small.size.height / 2, 300.001)
        }
    }

    func testActualFHDModifierRendersAboveCropControlsWithoutCentering() async throws {
        let viewport = CGSize(width: 400, height: 800)
        let imageSize = CGSize(width: 400, height: 600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: imageSize))
        }
        let view = Image(uiImage: image).resizable().scaledToFit()
            .frame(width: 400, height: 800)
            .modifier(PreviewRotationTransform(rotationDegrees: 0, targetRotationDegrees: 0,
                imageSize: imageSize, viewportSize: viewport, infoBottom: 80, cropTop: 110, cropProgress: 1))
            .background(.black)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let pixels = try XCTUnwrap(renderer.uiImage?.cgImage)
        var bytes = [UInt8](repeating: 0, count: 400 * 800 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 400, height: 800, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(origin: .zero, size: viewport))
        // ImageRenderer CGImage is top-first in this buffer. Test the visible
        // colored rows, rather than just reasserting the geometry helper.
        let redRows = (0..<800).filter { bytes[($0 * 400 + 200) * 4] > 200 }
        XCTAssertEqual(redRows.first, 110)
        XCTAssertEqual(redRows.last, 649)
    }

    func testTransparentCropControlsRenderOverExistingImage() async throws {
        let preview = CropPreview(source: .init(width: 600, height: 400, mcuWidth: 1, mcuHeight: 1, orientation: 1),
            imageWidth: 600, imageHeight: 400, originalOrientation: 1,
            content: .init(left: 0, top: 0, right: 600, bottom: 400), displayOrientation: 1, canonicalOrientation: 1)
        let editor = PhotoCropEditingState()
        try editor.begin(preview: preview, placement: .init(image: CGRect(x: 12, y: 240, width: 369, height: 246),
            viewport: CGSize(width: 393, height: 730), rotation: 0))
        editor.update { $0.select(.fixed(1, 1)) }
        var cancels = 0
        let root = ZStack {
            Color.black
            Rectangle().fill(Color(red: 0.2, green: 0.5, blue: 0.7)).frame(width: 369, height: 246).position(x: 196.5, y: 363)
            PhotoCropEditor(editor: editor, confirming: false, loading: false, failure: nil,
                bottomClearance: 66, onRetry: {}, onCancel: { cancels += 1 })
            PhotoPreviewQueueAction(editor: editor, editing: true, confirming: false, enabled: true, action: {})
                .padding(.trailing, 20).padding(.bottom, 66)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }.frame(width: 393, height: 852).environment(\.colorScheme, .dark)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: root.ignoresSafeArea())
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(editor.selection?.hasCrop == true)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let screenshot = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        let cg = try XCTUnwrap(screenshot.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let colored = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 2] > 50 && pixels[$0 + 1] > 50 }.count
        XCTAssertGreaterThan(colored, 40_000, "The existing image and transparent controls must actually render")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ztransfer-inline-crop-controls.png")
        try screenshot.pngData()?.write(to: path)
        print("CROP_SCREENSHOT=\(path.path)")
        XCTAssertEqual(cancels, 0)
    }

    func testNativeFlightPreservesImageLayerIdentityAndStopsClockOnDetach() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let surface = QueueFlightLayerSurface()
        let parent = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        parent.addSubview(surface)
        let start = CGPoint(x: 100, y: 500), end = CGPoint(x: 330, y: 70)
        surface.configure(startedAt: Date().addingTimeInterval(0.032), duration: 0.56,
            specs: [.init(image: image, size: CGSize(width: 200, height: 150))]) { elapsed in
            let p = min(max(CGFloat(elapsed / 0.56), 0), 1)
            return [.init(center: queueFlightPoint(progress: p, start: start, end: end), scale: 1 - p * 0.9,
                          alpha: CropAnimationTiming.ghostAlpha(progress: Double(p)))]
        }
        let layer = try XCTUnwrap(surface.imageLayers.first)
        let contents = layer.contents as AnyObject?
        XCTAssertNotNil(surface.displayLink)
        for frame in 0...120 { surface.render(elapsed: Double(frame) / 120 * 0.56) }
        XCTAssertTrue(surface.imageLayers.first === layer)
        XCTAssertTrue((layer.contents as AnyObject?) === contents)
        XCTAssertEqual(layer.position, end)
        XCTAssertEqual(layer.opacity, 0)
        XCTAssertEqual(layer.affineTransform().a, 0.1, accuracy: 0.00001)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true, "No implicit animations accumulate each frame")
        surface.removeFromSuperview()
        XCTAssertNil(surface.displayLink)
    }

    func testFlightWithoutCachedThumbnailKeepsPlaceholderAcrossReattachment() throws {
        let surface = QueueFlightLayerSurface()
        let parent = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        parent.addSubview(surface)
        surface.configure(startedAt: Date().addingTimeInterval(1), duration: 0.56,
            specs: [.init(image: nil, size: CGSize(width: 44, height: 44), background: .blue, showsPlaceholder: true)]) { _ in
            [.init(center: CGPoint(x: 30, y: 40))]
        }
        let icon = try XCTUnwrap(surface.imageLayers.first?.sublayers?.first)
        XCTAssertNotNil(icon.contents)
        XCTAssertEqual(icon.frame, CGRect(x: 12, y: 12, width: 20, height: 20))
        surface.removeFromSuperview(); XCTAssertNil(surface.displayLink)
        parent.addSubview(surface); XCTAssertNotNil(surface.displayLink)
        surface.stop()
    }

    private final class Probe { var count = 0 }
    private struct MotionHarness: View {
        let probe: Probe
        @State var motion: PhotoPreviewQueueMotion
        @State var editor: PhotoCropEditingState
        var body: some View {
            let _ = { probe.count += 1 }()
            Color.red.frame(width: 200, height: 300)
                .modifier(PhotoPreviewQueueMotionTransform(motion: motion))
                .modifier(PhotoCropImageTransform(editor: editor, active: true))
        }
    }
    func testSwipeAndCropFramesDoNotRebuildPreviewParent() async throws {
        let probe = Probe(), motion = PhotoPreviewQueueMotion(), editor = PhotoCropEditingState()
        let preview = CropPreview(source: .init(width: 600, height: 400, mcuWidth: 1, mcuHeight: 1, orientation: 1),
            imageWidth: 600, imageHeight: 400, originalOrientation: 1,
            content: .init(left: 0, top: 0, right: 600, bottom: 400), displayOrientation: 1, canonicalOrientation: 1)
        try editor.begin(preview: preview, placement: .init(image: CGRect(x: 0, y: 200, width: 300, height: 200),
            viewport: CGSize(width: 300, height: 700), rotation: 0))
        editor.update { $0.select(.fixed(1, 1)) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 700))
        let host = UIHostingController(rootView: MotionHarness(probe: probe, motion: motion, editor: editor))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initial = probe.count
        for step in 1...30 {
            motion.offset = -CGFloat(step)
            editor.update { try $0.transform(centroid: CGPoint(x: 150, y: 300), pan: .zero, zoom: 1.01) }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.count, initial)
        XCTAssertEqual(motion.offset, -30)
        XCTAssertTrue(editor.selection?.hasCrop == true)
    }
}

@MainActor
final class PhotoPreviewProjectionPerformanceTests: XCTestCase {
    private func file(_ id: UInt32, suffix: String = "JPG") -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100, fileName: "IMG_\(id).\(suffix)",
                   captureDate: "20261018T120000", isProtected: false)
    }

    func testOpeningAndPagesShareLargeImmutableProjectionButInvalidateMetadataAndReviewIdentity() {
        let files = (1...3000).map { file(UInt32($0)) }
        let burstIDs = Dictionary(uniqueKeysWithValues: files.map { ($0.id, "burst\($0.id / 10)") })
        let expanded: Set<String> = ["burst1", "burst3", "burst200"]
        let cache = PhotoPreviewProjectionCache()
        // Independent old insertion order, not a second call to the optimized builder.
        var reference = collapsedPhotoPreviewEntries(files: files, burstIDByFile: burstIDs)
        for position in reference.indices.reversed() {
            if case .burst(let group) = reference[position], expanded.contains(group.id) {
                reference = expandPhotoPreviewBurst(reference, at: position)
            }
        }
        for id in 1...120 {
            let opening = cache.opening(files: files, burstIDByFile: burstIDs, collapseBursts: true,
                expandedBurstIDs: expanded, selectedFileID: UInt32(id))
            XCTAssertEqual(opening.entries, reference)
            XCTAssertEqual(opening.index, reference.firstIndex { $0.file?.id == UInt32(id) } ?? 0)
            let pages = cache.pages(opening.entries, captureByHandle: [:])
            XCTAssertEqual(pages.values.map(\.id), reference.map(\.id))
            XCTAssertEqual(pages.loadIDs, reference.map(\.id))
        }
        XCTAssertEqual(cache.openingBuildCount, 1)
        XCTAssertEqual(cache.pageBuildCount, 1)
        let flat = cache.opening(files: files, burstIDByFile: burstIDs, collapseBursts: false,
            expandedBurstIDs: expanded, selectedFileID: 102)
        XCTAssertEqual(flat.entries.count, files.count)
        XCTAssertEqual(flat.index, 101)
        var replacements = files
        replacements[1] = file(2, suffix: "NEF")
        let modified = cache.opening(files: replacements, burstIDByFile: burstIDs, collapseBursts: false,
            expandedBurstIDs: [], selectedFileID: 2)
        XCTAssertEqual(modified.entries[1].file?.fileExtension, ".nef")
        let review = cache.pages([.photo(file(2))], captureByHandle: [2: 1])
        let replacement = cache.pages([.photo(file(3))], captureByHandle: [3: 1])
        XCTAssertEqual(review.values.map(\.id), replacement.values.map(\.id))
        XCTAssertNotEqual(review.loadIDs, replacement.loadIDs, "Late JPEG keeps page identity but must reload its own handle")
        XCTAssertEqual(replacement.values.first?.entry.file?.id, 3)
        cache.clear()
        let empty = cache.opening(files: [], burstIDByFile: [:], collapseBursts: true,
            expandedBurstIDs: [], selectedFileID: nil)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.index, 0)
        XCTAssertTrue(cache.pages([], captureByHandle: [:]).values.isEmpty)
    }

    func testSameHistogramSourceSharesPendingAndFinishedWorkAndClearStillCancels() async throws {
        let gate = PreviewHistogramTestGate()
        let model = PhotoPreviewHistogramModel { _ in PhotoPreviewHistogram(luma: await gate.calculate()) }
        let source = UIImage()
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel(); model.clear() }
        for _ in 0..<120 { model.load(fileID: 1, image: source) }
        while await gate.count < 1 { await Task.yield() }
        let pending = await gate.count
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(updates, 0)
        await gate.finish(0, bars: [0.2, 0.8])
        for _ in 0..<1000 where model.fileID == nil { await Task.yield() }
        XCTAssertEqual(updates, 1, "Result and identity publish atomically")
        for _ in 0..<120 { model.load(fileID: 1, image: source) }
        let completed = await gate.count
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(updates, 1)
        model.load(fileID: 1, image: UIImage())
        while await gate.count < 2 { await Task.yield() }
        XCTAssertEqual(updates, 2)
        let cached = PhotoPreviewHistogram(luma: [1, 0], rgb: [[1, 0], [0, 1], [0.5, 0.5]])
        model.show(fileID: 1, cached: cached)
        for _ in 0..<120 { model.show(fileID: 1, cached: cached) }
        XCTAssertEqual(updates, 3)
        await gate.finish(1, bars: [0.9])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.result, cached)
        for _ in 0..<120 { model.clear() }
        XCTAssertEqual(updates, 4)
        XCTAssertNil(model.fileID)
        model.load(fileID: 1, image: source)
        while await gate.count < 3 { await Task.yield() }
        model.clear()
        await gate.finish(2, bars: [0.7])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.fileID)
        XCTAssertTrue(model.result.luma.isEmpty)
    }

    private final class Frames { var parent = 0; var visible: [Bool] = [] }
    private struct Harness: View {
        let model: PhotoPreviewHistogramModel
        let photo: CameraFile
        let feedback: PhotoPreviewPageFeedback
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            var overlay = PhotoPreviewHistogramLayer(model: model, mode: .rgb, currentPhoto: photo,
                cropPresented: false, alpha: 1, feedback: feedback)
            overlay.didRender = { frames.visible.append($0) }
            return overlay
        }
    }
    func testActualHistogramLeafUpdatesAndHidesWithoutRebuildingPagerOwner() async throws {
        let model = PhotoPreviewHistogramModel(), frames = Frames(), feedback = PhotoPreviewPageFeedback()
        var host: UIHostingController<Harness>? = UIHostingController(rootView: Harness(
            model: model, photo: file(1), feedback: feedback, frames: frames))
        weak var weakHost = host
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let parent = frames.parent
        for i in 1...120 {
            let values = [CGFloat(i) / 120, 1, 0]
            model.show(fileID: 1, cached: PhotoPreviewHistogram(luma: values, rgb: [values, values, values]))
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.visible.last, true)
        XCTAssertEqual(model.result.rgb, [[1, 1, 0], [1, 1, 0], [1, 1, 0]])
        XCTAssertEqual(frames.parent, parent)
        let rendered = frames.visible.count
        for i in 1...30 { feedback.offset = CGFloat(i) / 100; await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.visible.count, rendered, "Paging opacity must not rebuild histogram paths")
        model.clear()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(frames.visible.last, false)
        XCTAssertEqual(frames.parent, parent)
        window.isHidden = true; window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakHost)
    }
}

@MainActor
final class PhotoCropPresentationPerformanceTests: XCTestCase {
    private final class Frames { var parent = 0; var controls = 0 }
    private struct Harness: View {
        let editor: PhotoCropEditingState
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            var controls = PhotoCropEditor(editor: editor, confirming: false, loading: false, failure: nil,
                bottomClearance: 40, onRetry: {}, onCancel: {})
            controls.didRender = { frames.controls += 1 }
            return ZStack {
                Color.blue.modifier(PhotoCropImageTransform(editor: editor, active: true))
                controls
                PhotoPreviewQueueAction(editor: editor, editing: true, confirming: false, enabled: true, action: {})
            }
        }
    }
    private func begin(_ editor: PhotoCropEditingState) throws {
        let preview = CropPreview(source: .init(width: 600, height: 400, mcuWidth: 1, mcuHeight: 1, orientation: 1),
            imageWidth: 600, imageHeight: 400, originalOrientation: 1,
            content: .init(left: 0, top: 0, right: 600, bottom: 400), displayOrientation: 1, canonicalOrientation: 1)
        try editor.begin(preview: preview, placement: .init(image: CGRect(x: 0, y: 150, width: 300, height: 200),
            viewport: CGSize(width: 300, height: 600), rotation: 0))
    }
    func testContinuousCropGeometryLeavesRatioControlsAndParentStaticWithExactSelection() async throws {
        let editor = PhotoCropEditingState(), frames = Frames()
        try begin(editor)
        editor.update { $0.select(.fixed(1, 1)) }
        var reference = try XCTUnwrap(editor.geometry)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        var host: UIHostingController<Harness>? = UIHostingController(rootView: Harness(editor: editor, frames: frames))
        weak var weakHost = host
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let parent = frames.parent, controls = frames.controls
        var geometryChanges = 0, controlChanges = 0
        let geometryObservation = editor.objectWillChange.sink { geometryChanges += 1 }
        let controlObservation = editor.controls.objectWillChange.sink { controlChanges += 1 }
        defer { geometryObservation.cancel(); controlObservation.cancel() }
        for _ in 0..<120 {
            let centroid = CGPoint(x: 150, y: 250), pan = CGSize(width: 0.25, height: -0.1)
            try reference.transform(centroid: centroid, pan: pan, zoom: 1.002)
            editor.update { try $0.transform(centroid: centroid, pan: pan, zoom: 1.002) }
            XCTAssertEqual(editor.geometry, reference)
            XCTAssertEqual(editor.selection, reference.selection(orientation: 1))
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(geometryChanges, 120)
        XCTAssertEqual(controlChanges, 0)
        XCTAssertEqual(frames.parent, parent)
        XCTAssertEqual(frames.controls, controls)
        XCTAssertTrue(editor.controls.snapshot.hasCrop)
        editor.update { $0.select(.fixed(9, 16)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.controls.snapshot.ratio, .fixed(9, 16))
        XCTAssertEqual(controlChanges, 1)
        XCTAssertGreaterThan(frames.controls, controls)
        editor.update { $0.reset() }
        XCTAssertFalse(editor.controls.snapshot.hasCrop)
        editor.reset()
        XCTAssertNil(editor.controls.snapshot.ratio)
        XCTAssertNil(editor.selection)
        window.isHidden = true; window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakHost)
    }

    func testNoOpCropAndPreparationResetsDoNotPublishButResetStillClearsSelection() throws {
        let editor = PhotoCropEditingState(), preparation = PhotoCropPreparation()
        var updates = 0, controls = 0, preparationChanges = 0
        let a = editor.objectWillChange.sink { updates += 1 }
        let b = editor.controls.objectWillChange.sink { controls += 1 }
        let c = preparation.objectWillChange.sink { preparationChanges += 1 }
        defer { a.cancel(); b.cancel(); c.cancel() }
        for _ in 0..<120 { editor.reset(); preparation.reset() }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(controls, 0)
        XCTAssertEqual(preparationChanges, 0)
        try begin(editor)
        let initial = editor.geometry
        for _ in 0..<120 {
            editor.update { try $0.transform(centroid: CGPoint(x: 150, y: 250), pan: .zero, zoom: 1) }
        }
        XCTAssertEqual(editor.geometry, initial)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(controls, 1)
        editor.update { try $0.transform(centroid: CGPoint(x: CGFloat.nan, y: CGFloat.nan), pan: .zero, zoom: 1) }
        XCTAssertEqual(updates, 1)
        editor.reset()
        XCTAssertEqual(updates, 2)
        XCTAssertEqual(controls, 2)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.initialImage, .zero)
    }
}

@MainActor
final class DisconnectedPhotoListTests: XCTestCase {
    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }
    func testEvictionWithoutDisconnectMakesRetainedModelTerminal() async {
        let session = CameraSession(repository: CameraRepository(debugData: .shared))
        let retired = PhotoListViewModel.cached(session: session)
        PhotoListViewModel.evict(session: session)
        XCTAssertFalse(retired.transportAvailable)
        retired.load()
        await retired.reload()
        retired.wakeThumbnailFill()
        XCTAssertFalse(retired.isLoadingFiles)
        XCTAssertEqual(retired.loadState, .idle)
        let replacement = PhotoListViewModel.cached(session: session)
        XCTAssertFalse(retired === replacement)
        XCTAssertTrue(replacement.transportAvailable)
        PhotoListViewModel.evict(session: session)
    }

    func testDisconnectRejectsLateCacheReconciliationCompletion() async throws {
        let entered = expectation(description: "cache reconciliation entered")
        let release = CropPermitLatch()
        let file = CameraFile(id: 77, storageID: 1, format: 0x3801, size: 100,
            fileName: "DSC_0077.JPG", captureDate: "20261019T120000", isProtected: false)
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [file], removedHandles: [], addedHandles: [], handleQueriesSucceeded: true,
                metadataComplete: true, filterStorageIDs: [1])
        }, reconcileCache: { _, _ in
            entered.fulfill()
            await release.wait() // Disk work may finish after protocol cancellation.
        }, setRemoteGate: { _ in })
        let loading = Task { await model.reload() }
        await fulfillment(of: [entered], timeout: 2)
        model.transportDidDisconnect()
        await release.open()
        await loading.value
        XCTAssertFalse(model.transportAvailable)
        XCTAssertFalse(model.isLoadingFiles)
        XCTAssertFalse(model.hasCompletedFileScan, "A disconnected scan cannot publish completion")
        XCTAssertEqual(model.availableFiles.map(\.id), [77], "Retain the already received catalog")
    }

    func testDisconnectRejectsLateLoadingRangeSnapshot() async throws {
        let previous = PhotoFilterPersistence.loadPhotoLoadingRange()
        PhotoFilterPersistence.savePhotoLoadingRange(.five)
        defer { PhotoFilterPersistence.savePhotoLoadingRange(previous) }
        let entered = expectation(description: "resume snapshot entered")
        let release = CropPermitLatch()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [], removedHandles: [], addedHandles: [], handleQueriesSucceeded: true,
                metadataComplete: true, filterStorageIDs: [1], stoppedAtLoadingRange: true)
        }, resumeSnapshotProvider: {
            entered.fulfill()
            await release.wait()
            return nil
        }, setRemoteGate: { _ in })
        await model.reload()
        XCTAssertTrue(model.hasCompletedFileScan)
        model.setPhotoLoadingRange(.all)
        await fulfillment(of: [entered], timeout: 2)
        model.transportDidDisconnect()
        let restarted = expectation(description: "offline loading must not restart")
        restarted.isInverted = true
        let observation = model.$isLoadingFiles.sink { if $0 { restarted.fulfill() } }
        defer { observation.cancel() }
        await release.open()
        await fulfillment(of: [restarted], timeout: 0.1)
        XCTAssertFalse(model.isLoadingFiles)
    }

    func testDisconnectedCatalogStopsAllRemoteWorkButRetainsRows() async throws {
        for sequential in [false, true] {
            let scans = Counter(), fills = Counter()
            let file = CameraFile(id: 77, storageID: 1, format: 0x3801, size: 100,
                fileName: "DSC_0077.JPG", captureDate: "20261019T120000", isProtected: false)
            let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
                await scans.increment()
                return PhotoScanResult(files: [file], removedHandles: [], addedHandles: [], handleQueriesSucceeded: true,
                    metadataComplete: true, filterStorageIDs: [1])
            }, prefetchBatch: { files in
                await fills.increment()
                return ThumbnailBatchResult(settled: Set(files.map(\.id)), cached: [])
            }, setRemoteGate: { _ in }, sequentialLoading: sequential)
            model.load()
            for _ in 0..<100 {
                if model.hasCompletedFileScan { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.hasCompletedFileScan)
            model.transportDidDisconnect()
            try await Task.sleep(for: .milliseconds(30))
            let before = await fills.count
            for _ in 0..<10 {
                model.wakeThumbnailFill(); model.setTransferBusy(true); model.setTransferBusy(false)
                model.pauseForPreview(); model.resumeAfterPreview()
                await model.pauseForRemote(); await model.resumeAfterRemote(isConnected: true)
                model.load(); await model.reload()
                await model.applyCatalogUpdate([])
            }
            try await Task.sleep(for: .milliseconds(100))
            let scanCount = await scans.count, fillCount = await fills.count
            XCTAssertEqual(scanCount, 1); XCTAssertEqual(fillCount, before)
            XCTAssertFalse(model.transportAvailable); XCTAssertFalse(model.isLoadingFiles)
            XCTAssertEqual(model.availableFiles.map(\.id), [77])
        }
    }

    func testCancellingIdleThumbnailWorkerDoesNotTerminateFutureWakeWaits() async throws {
        let queue = PhotoThumbnailFillQueue(), counter = Counter()
        let first = Task { await queue.waitForWake() }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel(); _ = await first.value
        let replacement = Task {
            await queue.waitForWake()
            await counter.increment()
        }
        defer { replacement.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let idleCount = await counter.count
        XCTAssertEqual(idleCount, 0, "After transfer pauses the worker, the next empty wait must SUSPEND, not spin")
        await queue.wake()
        _ = await replacement.value
        let awakeCount = await counter.count
        XCTAssertEqual(awakeCount, 1)
    }
}
