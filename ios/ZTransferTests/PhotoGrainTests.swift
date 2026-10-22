import XCTest
import UIKit
import SwiftUI
import CryptoKit
import PhotosUI
@testable import ZTransfer

final class PhotoGrainTests: XCTestCase {
    func testStyleMemoryOffZeroAndLateRelease() {
        let memories = normalizedPhotoGrainIntensities(["medium": 67, "coarse": 0])
        XCTAssertEqual(memories, ["fine": 50, "medium": 67, "coarse": 0])
        let fine = PhotoGrainSettings(intensityPercent: 31, enabled: true)
        let medium = fine.selecting(.medium, memories: memories)
        XCTAssertEqual(medium.intensityPercent, 67)
        XCTAssertEqual(medium.changingIntensity(99, for: .fine), medium)
        XCTAssertEqual(fine.selecting(nil, memories: memories).selecting(.fine, memories: memories), fine)
        let coarse = fine.selecting(.coarse, memories: memories)
        XCTAssertTrue(coarse.enabled)
        XCTAssertFalse(coarse.isEnabled)
        XCTAssertEqual(coarse.changingIntensity(120, for: .coarse).intensityPercent, 100)
        XCTAssertEqual(coarse.selecting(nil, memories: memories).changingIntensity(40, for: .coarse).intensityPercent, 0)
    }

    func testSeedUsesLeafNameCaseAndExtension() {
        XCTAssertEqual(photoGrainSeed("/tmp/session/DSC_0001.JPG"), photoGrainSeed("C:\\card\\dsc_0001.jpg"))
        XCTAssertNotEqual(photoGrainSeed("DSC_0001.JPG"), photoGrainSeed("DSC_0001.JPEG"))
        XCTAssertEqual(photoGrainSeed(""), Int32(bitPattern: 0x811c9dc5))
        XCTAssertEqual(photoGrainSeed("a"), Int32(bitPattern: 0xe40c292c))
    }

    func testPreferenceLegacyMigrationCorruptTypesAndNamespaces() throws {
        let suite = "GrainPreferences-\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(" 73 ", forKey: "photo_grain_intensity")
        let legacy = try XCTUnwrap(PhotoGrainPreferences.restore(prefs, prefix: "photo_grain"))
        XCTAssertEqual(legacy.settings, PhotoGrainSettings(intensityPercent: 73, enabled: true))
        XCTAssertNil(PhotoGrainPreferences.restore(prefs, prefix: "grain"))
        prefs.set("unknown", forKey: "photo_grain_style")
        prefs.set(true, forKey: "photo_grain_intensity_fine")
        prefs.set(42.5, forKey: "photo_grain_intensity_medium")
        prefs.set("-1", forKey: "photo_grain_intensity_coarse")
        let recovered = try XCTUnwrap(PhotoGrainPreferences.restore(prefs, prefix: "photo_grain"))
        XCTAssertFalse(recovered.settings.enabled)
        XCTAssertEqual(recovered.intensities, ["fine": 73, "medium": 40, "coarse": 0])
    }

    @MainActor func testCameraDraftMemoriesDoNotCommitRecipeOrResetOnHide() throws {
        let suite = "GrainDraft-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoEffectsStore(defaults: defaults)
        var initial = store.settings
        initial.photoGrain = .init(intensityPercent: 28, enabled: true)
        store.update(initial)
        var draft = store.beginDraft()
        draft.photoGrain.intensityPercent = 87
        draft.grainIntensities["fine"] = 87
        store.persistEditorPreferences(from: draft)
        XCTAssertEqual(store.settings.photoGrain.intensityPercent, 28)
        XCTAssertEqual(store.settings.grainIntensities["fine"], 87)
        draft.applyModuleVisibility(allPhotoEffectModules ^ PhotoEffectModule.grain.rawValue)
        store.persistEditorPreferences(from: draft)
        let restored = PhotoEffectsStore(defaults: defaults)
        XCTAssertFalse(restored.settings.photoGrain.enabled)
        XCTAssertEqual(restored.settings.grainIntensities["fine"], 87)
        XCTAssertFalse(photoEffectModuleIsVisible(restored.settings.photoEffectModules, .grain))
    }

    @MainActor func testModuleUpgradeRunsOnceAndLocalScopeIsIndependent() {
        let suite = "GrainModule-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "photo_effect_modules")
        let camera = PhotoEffectsStore(defaults: defaults)
        XCTAssertEqual(camera.settings.photoEffectModules, 17)
        var value = camera.settings
        value.photoGrain = .init(intensityPercent: 0, enabled: true, style: .medium)
        camera.update(value)
        let local = PhotoEffectsStore(defaults: defaults, scope: .localPhotos)
        XCTAssertEqual(local.settings.photoGrain, .off)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults).settings.photoGrain, value.photoGrain)
        value.applyModuleVisibility(1)
        camera.update(value)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults).settings.photoEffectModules, 1)
        XCTAssertEqual(togglePhotoEffectModule(16, module: .grain, isPro: true), 16)
    }

    func testCodableQueueSnapshotAndZeroPixelIdentity() throws {
        var value = PhotoEffectsSettings()
        value.photoGrain = .init(intensityPercent: 62, enabled: true, style: .coarse)
        let saved = try JSONEncoder().encode(value)
        value.photoGrain = .off
        let snapshot = try JSONDecoder().decode(PhotoEffectsSettings.self, from: saved)
        XCTAssertTrue(snapshot.hasEffect)
        XCTAssertEqual(snapshot.photoGrain.style, .coarse)
        var zero = snapshot
        zero.photoGrain.intensityPercent = 0
        XCTAssertEqual(photoEffectsPreviewPixelSettings(zero), photoEffectsPreviewPixelSettings(value))
        let first = PhotoEffectsSettingsPreview.makeRenderKey(settings: snapshot, source: nil, metadata: nil, sourceName: "A.JPG")
        let second = PhotoEffectsSettingsPreview.makeRenderKey(settings: snapshot, source: nil, metadata: nil, sourceName: "B.JPG")
        XCTAssertNotEqual(first, second)
    }

    func testShortNamesAndRecipeIdentityPreserveOffButSeparateStyles() {
        var settings = PhotoEffectsSettings()
        let legacy = androidPhotoFrameOutputName(sourceName: "DSC.JPG", settings: settings).lowercased()
        let expected = SHA256.hash(data: Data(legacy.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings), expected)
        settings.photoGrain = .init(intensityPercent: 40, enabled: true)
        XCTAssertEqual(photoEffectOutputName(sourceName: "DSC.JPG", settings: settings), "DSC_g.jpg")
        let fine = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
        settings.photoGrain.style = .medium
        XCTAssertNotEqual(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings), fine)
        settings.photoFrameEnabled = true
        XCTAssertEqual(photoEffectOutputName(sourceName: "DSC_c.JPG", settings: settings), "DSC_c_f_g.jpg")
        settings.photoGrain.intensityPercent = 0
        settings.photoFrameEnabled = false
        XCTAssertEqual(photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings), expected)
    }

    func testGrainOffReturnsSameCGImageAndHonorsAlphaAndColorHeadroom() throws {
        let input = try makeImage(width: 600, height: 400)
        let pixels = try XCTUnwrap(input.cgImage)
        XCTAssertTrue(try PhotoGrainRenderer.apply(pixels, settings: .off, seed: 42) === pixels)
        let output = try PhotoGrainRenderer.apply(pixels, settings: .init(intensityPercent: 100, enabled: true), seed: 42)
        let before = try rgba(pixels), after = try rgba(output)
        XCTAssertNotEqual(before, after)
        for i in stride(from: 0, to: before.count, by: 4) {
            XCTAssertEqual(before[i + 3], after[i + 3])
            XCTAssertEqual(Int(after[i]) - Int(before[i]), Int(after[i + 1]) - Int(before[i + 1]))
            XCTAssertEqual(Int(after[i]) - Int(before[i]), Int(after[i + 2]) - Int(before[i + 2]))
        }
    }

    func testTiledOriginalMatchesWholeNoiseFieldAcrossBoundaries() throws {
        let input = try makeImage(width: 1024, height: 1031)
        let source = try XCTUnwrap(input.cgImage)
        for style in PhotoGrainStyle.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoGrain = .init(intensityPercent: 80, enabled: true, style: style)
            let whole = try PhotoGrainRenderer.apply(source, settings: settings.photoGrain, seed: photoGrainSeed("DSC.JPG"))
            let tiled = try XCTUnwrap(PhotoEffectsRenderer.render(input, settings: settings, sourceName: "DSC.JPG", availableMemory: { Int64.max }).cgImage)
            XCTAssertEqual(try rgba(whole), try rgba(tiled), "\(style)")
        }
    }

    func testFrameBackdropAndDecorationStayClean() throws {
        let input = try makeImage(width: 320, height: 240)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .mist
        settings.watermark.enabled = false
        settings.metadata = .defaults(for: .mist)
        let clean = try XCTUnwrap(PhotoEffectsRenderer.render(input, settings: settings, sourceName: "DSC.JPG", availableMemory: { Int64.max }).cgImage)
        settings.photoGrain = .init(intensityPercent: 100, enabled: true, style: .coarse)
        let grain = try XCTUnwrap(PhotoEffectsRenderer.render(input, settings: settings, sourceName: "DSC.JPG", availableMemory: { Int64.max }).cgImage)
        let a = try rgba(clean), b = try rgba(grain)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(clean.width, grain.width)
        // The outermost rows and columns are backdrop/decoration, not photo.
        for y in 0..<clean.height {
            for x in [0, 1, clean.width - 2, clean.width - 1] {
                let i = (y * clean.width + x) * 4
                XCTAssertEqual(Array(a[i..<i+4]), Array(b[i..<i+4]))
            }
        }
        XCTAssertEqual(Array(a.prefix(clean.width * 8)), Array(b.prefix(clean.width * 8)))
        XCTAssertEqual(Array(a.suffix(clean.width * 8)), Array(b.suffix(clean.width * 8)))
    }

    func testGrainOnlyPreviewHasCleanComparison() async throws {
        let source = try makeImage(width: 320, height: 240)
        var settings = PhotoEffectsSettings()
        settings.photoGrain = .init(intensityPercent: 100, enabled: true, style: .coarse)
        let preview = try await LocalPhotoOutput.preview(image: source, settings: settings, sourceName: "A.JPG")
        let comparison = try await LocalPhotoOutput.unfilteredPreview(image: source, settings: settings)
        XCTAssertNotEqual(try rgba(XCTUnwrap(preview.filtered.cgImage)), try rgba(XCTUnwrap(comparison.cgImage)))
        XCTAssertEqual(try rgba(XCTUnwrap(comparison.cgImage)), try rgba(XCTUnwrap(source.cgImage)))
    }

    func testCancellationStopsPixelWork() async throws {
        let source = try XCTUnwrap(makeImage(width: 4096, height: 2048).cgImage)
        let task = Task.detached { () throws -> CGImage in
            try PhotoGrainRenderer.apply(source, settings: .init(intensityPercent: 100, enabled: true), seed: 42)
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled pixel work published") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    @MainActor func testActualCameraPreviewPublishesGrainForNamedSource() async throws {
        let image = try makeImage(width: 320, height: 240)
        var settings = PhotoEffectsSettings()
        settings.photoGrain = .init(intensityPercent: 100, enabled: true, style: .coarse)
        let ready = expectation(description: "named source renders rather than being rejected by cache demand")
        var rendered: UIImage?
        var preview = PhotoEffectsSettingsPreview(source: image, metadata: nil, settings: settings, onRequest: {}, sourceName: "DSC_1234.JPG")
        preview.renderedImageObserver = { result in
            guard rendered == nil else { return }
            rendered = result; ready.fulfill()
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.rootViewController = UIHostingController(rootView: preview)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(try rgba(XCTUnwrap(rendered?.cgImage)), try rgba(XCTUnwrap(image.cgImage)))
    }

    @MainActor func testQueueCapturesGrainAndRejectsRawVideo() async throws {
        let suite = "GrainQueue-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await queue.attach(session: nil, directory: directory)
        var settings = PhotoEffectsSettings()
        settings.photoGrain = .init(intensityPercent: 180, enabled: true, style: .coarse)
        let files = ["A.JPG", "B.NEF", "C.MOV"].enumerated().map { index, name in
            CameraFile(id: UInt32(index + 1), storageID: 1, format: 0x3801, size: 10,
                fileName: name, captureDate: "20261021T120000", isProtected: false)
        }
        _ = await queue.enqueue(files, effects: settings)
        settings.photoGrain = .off
        let items = await queue.snapshot().items
        XCTAssertEqual(items.first?.effects?.photoGrain, .init(intensityPercent: 100, enabled: true, style: .coarse))
        XCTAssertEqual(items[1].effects?.photoGrain, .off)
        XCTAssertEqual(items[2].effects?.photoGrain, .off)
        await queue.withdrawPending()
        let retry = await queue.retry(id: items[0].id)
        XCTAssertNotNil(retry)
        let retried = await queue.snapshot().items.first { $0.id == retry }
        XCTAssertEqual(retried?.effects?.photoGrain, items[0].effects?.photoGrain)
    }

    func testJPEGIdentityRoundTripRejectsWrongAndMalformedHeaders() throws {
        let image = try makeImage(width: 48, height: 32)
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let identity = String(repeating: "a", count: 64)
        let tagged = try XCTUnwrap(PhotoEffectIdentityJPEG.inserting(identity, into: jpeg))
        XCTAssertNotNil(UIImage(data: tagged))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try tagged.write(to: url)
        XCTAssertEqual(PhotoEffectIdentityJPEG.read(from: url), identity)
        try Data(tagged.prefix(9)).write(to: url)
        XCTAssertNil(PhotoEffectIdentityJPEG.read(from: url))
        XCTAssertNil(PhotoEffectIdentityJPEG.inserting("bad", into: jpeg))
        XCTAssertNil(PhotoEffectIdentityJPEG.inserting(identity, into: Data([0xff, 0xd8, 0xff, 0xe0, 0, 1])))
    }

    func testGrainOnlyRealExportDedupAndChangedStyle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("DSC.JPG")
        try XCTUnwrap(makeImage(width: 128, height: 96).jpegData(compressionQuality: 1)).write(to: source)
        var settings = PhotoEffectsSettings()
        settings.photoGrain = .init(intensityPercent: 72, enabled: true)
        let output = try await TransferQueue.renderFrameFile(source: source, settings: settings, directory: directory, metadata: nil)
        XCTAssertEqual(output.lastPathComponent, "DSC_g.jpg")
        XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: directory), output)
        settings.photoGrain.style = .coarse
        XCTAssertNil(TransferQueue.existingFrameURL(source: source, settings: settings, in: directory))
        let changed = try await TransferQueue.renderFrameFile(source: source, settings: settings, directory: directory, metadata: nil)
        XCTAssertNotEqual(output, changed)
        XCTAssertEqual(TransferQueue.existingFrameURL(source: source, settings: settings, in: directory), changed)
    }

    func testGrainPreviewUsesSmoothPhotoScalingWithoutTileSeams() throws {
        // Android renderPreview applies grain before renderFrame's filtered
        // bitmap scaling. Compare that independent composition with our path.
        let source = patternedImage(width: 1024, height: 769)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .minimal
        settings.watermark.enabled = false
        settings.photoGrain = .init(intensityPercent: 81, enabled: true, style: .coarse)
        let grained = UIImage(cgImage: try PhotoGrainRenderer.apply(XCTUnwrap(source.cgImage),
            settings: settings.photoGrain, seed: photoGrainSeed("Preview.JPG")))
        let actual = try PhotoEffectsRenderer.render(source, settings: settings,
            previewPlaceholders: true, backdropSource: source, previewLongEdge: 1_920,
            sourceName: "Preview.JPG", filterExecution: .preview)
        settings.photoGrain = .off
        let expected = try PhotoEffectsRenderer.render(grained, settings: settings,
            previewPlaceholders: true, backdropSource: source, previewLongEdge: 1_920,
            filterExecution: .preview)
        let a = try rgba(XCTUnwrap(actual.cgImage)), b = try rgba(XCTUnwrap(expected.cgImage))
        XCTAssertTrue(a == b, "Grain preview must use the same smooth scaling as a prepared photo")
    }

    func testCombinedFilterGrainCrossesTilesAndPreservesEveryEXIFOrientation() throws {
        let lut = CubeLUT(size: 2, domainMin: .zero, domainMax: SIMD3(repeating: 1),
            rgb: [0,0,0, 0,0,1, 1,0,0, 1,0,1, 0,1,0, 0,1,1, 1,1,0, 1,1,1], digest: "grain-audit-cube")
        PhotoLUTRuntime.register(lut)
        let selections = [PhotoFilterSelection(preset: PhotoEffectsSettings().orderedFilters[0], intensityPercent: 73),
            PhotoFilterSelection(preset: .init(id: "cube:\(lut.digest)", name: "Audit"), intensityPercent: 67)]
        for selection in selections {
            for orientation in [UIImage.Orientation.up, .upMirrored, .down, .downMirrored, .left, .leftMirrored, .right, .rightMirrored] {
                try autoreleasepool {
                    let raw = patternedImage(width: orientation == .up ? 1024 : 97, height: orientation == .up ? 4101 : 61)
                    let image = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: orientation)
                    var settings = PhotoEffectsSettings()
                    settings.photoFilterEnabled = true; settings.selectedFilter = selection
                    let filtered = try PhotoEffectsRenderer.render(image, settings: settings, filterExecution: .preview)
                    settings.photoGrain = .init(intensityPercent: 100, enabled: true, style: .medium)
                    let expected = try PhotoGrainRenderer.apply(XCTUnwrap(filtered.cgImage),
                        settings: settings.photoGrain, seed: photoGrainSeed("EXIF.JPG"))
                    let actual = try PhotoEffectsRenderer.render(image, settings: settings, sourceName: "EXIF.JPG", availableMemory: { Int64.max })
                    XCTAssertTrue(try rgba(XCTUnwrap(actual.cgImage)) == rgba(expected),
                        "\(selection.preset.id), EXIF \(orientation.rawValue)")
                }
            }
        }
    }

    @MainActor func testGrainCacheReusesFramesAndInvalidatesSourceSeedAndRecipe() async throws {
        let cache = LocalPhotoPreviewCache()
        defer { cache.close() }
        let source = patternedImage(width: 257, height: 193)
        var settings = PhotoEffectsSettings()
        settings.photoGrain = .init(intensityPercent: 73, enabled: true, style: .coarse)
        await cache.configure(image: source, settings: settings, metadata: nil, sourceName: "A.JPG")
        let first = try await cache.render(image: source, settings: settings, metadata: nil)
        let repeated = try await cache.render(image: source, settings: settings, metadata: nil)
        XCTAssertTrue(first.filtered === repeated.filtered, "Unchanged UI must not redo pixel work")
        await cache.configure(image: source, settings: settings, metadata: nil, sourceName: "B.JPG")
        let renamed = try await cache.render(image: source, settings: settings, metadata: nil)
        XCTAssertFalse(first.filtered === renamed.filtered)
        XCTAssertTrue(try rgba(XCTUnwrap(first.filtered.cgImage)) != rgba(XCTUnwrap(renamed.filtered.cgImage)))
        let stale = settings
        settings.photoGrain.intensityPercent = 31
        await cache.configure(image: source, settings: settings, metadata: nil, sourceName: "B.JPG")
        do { _ = try await cache.render(image: source, settings: stale, metadata: nil); XCTFail("Stale recipe accepted") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        _ = try await cache.render(image: source, settings: settings, metadata: nil)
    }

    private func patternedImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            for y in stride(from: 0, to: height, by: 7) {
                UIColor(red: CGFloat((y * 13) % 255) / 255, green: 0.43, blue: 0.67,
                        alpha: y % 3 == 0 ? 0.5 : 1).setFill()
                ctx.fill(CGRect(x: 0, y: y, width: width, height: min(7, height - y)))
            }
        }
    }

    func testJPEGIdentityBufferedReadsAreBoundedAndHandlePartialStreams() throws {
        let identity = String(repeating: "c", count: 64)
        let tagged = try XCTUnwrap(PhotoEffectIdentityJPEG.inserting(identity, into: Data([0xff, 0xd8, 0xff, 0xda])))
        var normalReads = 0
        XCTAssertEqual(PhotoEffectIdentityJPEG.read { count in
            normalReads += 1
            return Data(tagged.prefix(count))
        }, identity)
        XCTAssertEqual(normalReads, 1, "A normal fingerprint lookup needs one buffered read")

        // Valid unrelated metadata spans several buffers; providers may return
        // short chunks. The fingerprint and JPEG scan bytes remain untouched.
        var extended = Data([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff])
        extended.append(Data(repeating: 7, count: 65_533))
        extended.append(tagged.dropFirst(2))
        var offset = 0
        XCTAssertEqual(PhotoEffectIdentityJPEG.read { count in
            let end = min(extended.count, offset + min(count, 137))
            defer { offset = end }
            return extended[offset..<end]
        }, identity)

        var supplied = 0
        XCTAssertNil(PhotoEffectIdentityJPEG.read { count in
            defer { supplied += count }
            var bytes = Data(repeating: 0xff, count: count)
            if supplied == 0 { bytes[1] = 0xd8 }
            return bytes
        })
        XCTAssertEqual(supplied, 4 * 1024 * 1024, "Malformed fill markers must respect the hard header limit")
        var malformed = tagged
        malformed[6 + Data("ZTransfer.PhotoEffectIdentity\0v1\0".utf8).count] = 0x7a
        malformed.append(tagged.dropFirst(2))
        XCTAssertNil(PhotoEffectIdentityJPEG.read { count in Data(malformed.prefix(count)) },
                     "Like Android, a corrupt matching identity does not accept a later marker")
    }

    @MainActor func testRepeatedGrainPreviewEditsReleaseObsoleteImagesAndMeasureCost() async throws {
        final class WeakImage {
            weak var value: UIImage?
            init(_ value: UIImage) { self.value = value }
        }
        let cache = LocalPhotoPreviewCache()
        let source = patternedImage(width: 1280, height: 853)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .minimal
        settings.watermark.enabled = false
        var images: [WeakImage] = []
        var times: [Double] = []
        let initialMemory = try previewTestPhysicalFootprint()
        var peakMemory = initialMemory
        func renderOnce(_ recipe: PhotoEffectsSettings) async throws -> WeakImage {
            await cache.configure(image: source, settings: recipe, metadata: nil,
                                  prefetchEnabled: false, sourceName: "PERF.JPG")
            let frame = try await cache.render(image: source, settings: recipe, metadata: nil)
            return WeakImage(frame.filtered)
        }
        for index in 0..<18 {
            settings.photoGrain = .init(intensityPercent: 30 + index * 3, enabled: true,
                                       style: PhotoGrainStyle.allCases[index % 3])
            let start = ContinuousClock.now
            images.append(try await renderOnce(settings))
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            peakMemory = max(peakMemory, try previewTestPhysicalFootprint())
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(images.filter { $0.value != nil }.count, 1, "Only the current grain frame may remain cached")
        cache.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(images.allSatisfy { $0.value == nil }, "Leaving the editor must release grain frames")
        let pending = await PhotoEffectsPreviewRenderGate.shared.pendingCount
        XCTAssertEqual(pending, 0)
        print("GRAIN_AUDIT preview18 ms=\(times.map { Int($0 * 1000) }) footprintBytes initial=\(initialMemory) peak=\(peakMemory) closed=\(try previewTestPhysicalFootprint())")
    }

    func testTwentyFourMegapixelGrainBudgetAndRenderCost() throws {
        try autoreleasepool {
            let image = try makeImage(width: 6000, height: 4000)
            var settings = PhotoEffectsSettings()
            settings.photoGrain = .init(intensityPercent: 73, enabled: true, style: .coarse)
            XCTAssertThrowsError(try PhotoEffectsRenderer.render(image, settings: settings, availableMemory: { 0 })) {
                XCTAssertTrue($0 is PhotoAllocationRejected)
            }
            let before = try previewTestPhysicalFootprint()
            let started = ContinuousClock.now
            let output = try PhotoEffectsRenderer.render(image, settings: settings, sourceName: "24MP.JPG", availableMemory: { Int64.max })
            XCTAssertEqual(output.cgImage?.width, 6000)
            XCTAssertEqual(output.cgImage?.height, 4000)
            print("GRAIN_AUDIT 24MP duration=\(started.duration(to: .now)) footprintBytes before=\(before) output=\(try previewTestPhysicalFootprint())")
        }
    }

    private func makeImage(width: Int, height: Int) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(red: 0.40, green: 0.48, blue: 0.56, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

/// Third-pass integration checks: use the real preview owners and pixel/export
/// paths, holding only the filter/authorization boundary to expose races.
@MainActor
final class PhotoGrainLifecycleTests: XCTestCase {
    func testNewLocalPreviewWaiterRecoversFromCancelledOldFilterDependency() async throws {
        let cache = PhotoPreviewFrameCache<Int>(), probe = GrainFilterProbe()
        let old = Task { try await cache.getOrRender { await probe.begin(); throw CancellationError() } }
        try await waitUntil { await probe.calls == 1 }
        old.cancel()
        do { _ = try await old.value; XCTFail("Cancelled consumer returned") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        let current = Task { try await cache.getOrRender { 42 } }
        try await Task.sleep(for: .milliseconds(30))
        await probe.release()
        let result = try await current.value
        XCTAssertEqual(result, 42)
        await cache.close()
        let fresh = PhotoPreviewFrameCache<Int>()
        do { _ = try await fresh.getOrRender { throw CancellationError() }; XCTFail("Unrelated cancellation swallowed") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        let recovered = try await fresh.getOrRender { 7 }
        XCTAssertEqual(recovered, 7)
        await fresh.close()
    }

    func testGrainEditsReuseAnInFlightFilterAndOnlyPublishNewestRecipe() async throws {
        let probe = GrainFilterProbe()
        let cache = makeCache(probe)
        defer { cache.close() }
        let image = makeImage()
        var settings = filteredGrainSettings()
        await cache.configure(image: image, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        let initial = settings
        let first = Task { try await cache.render(image: image, settings: initial, metadata: nil) }
        try await waitUntil { await probe.calls == 1 }
        // Grain changes replace completed frames, but cannot invalidate the
        // source/filter computation shared with the next frame on Android.
        settings.photoGrain = .init(intensityPercent: 91, enabled: true, style: .coarse)
        await cache.configure(image: image, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        let final = settings
        let latest = Task { try await cache.render(image: image, settings: final, metadata: nil) }
        await probe.release()
        do { _ = try await first.value; XCTFail("Obsolete grain recipe was published") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let rendered = try await latest.value
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "Changing only grain must not cancel and repeat an in-flight filter")
        let filtered = try await LocalPhotoOutput.filteredSource(image: image, selection: XCTUnwrap(final.selectedFilter))
        let expected = try await LocalPhotoOutput.preview(image: image, settings: final, filteredSource: filtered, sourceName: "A.JPG")
        XCTAssertEqual(rendered.filtered.pngData(), expected.filtered.pngData())
    }

    func testClosingDuringSharedFilteringCancelsWorkerAndReentryStartsFresh() async throws {
        let probe = GrainFilterProbe()
        let cache = makeCache(probe)
        defer { cache.close() }
        let image = makeImage(), settings = filteredGrainSettings()
        await cache.configure(image: image, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        let old = Task { try await cache.render(image: image, settings: settings, metadata: nil) }
        try await waitUntil { await probe.calls == 1 }
        cache.close()
        do { _ = try await old.value; XCTFail("Closed editor published a frame") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        await probe.release()
        try await waitUntil { await probe.finished == 1 }
        let cancelled = await probe.cancelled
        XCTAssertEqual(cancelled, 1)
        await cache.configure(image: image, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        _ = try await cache.render(image: image, settings: settings, metadata: nil)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testReplacingSourceCancelsSharedFilterButChangingOnlyNameDoesNot() async throws {
        let probe = GrainFilterProbe()
        let cache = makeCache(probe)
        defer { cache.close() }
        let firstImage = makeImage(), secondImage = makeImage()
        let settings = filteredGrainSettings()
        await cache.configure(image: firstImage, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        let obsolete = Task { try await cache.render(image: firstImage, settings: settings, metadata: nil) }
        try await waitUntil { await probe.calls == 1 }
        await cache.configure(image: secondImage, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "A.JPG")
        do { _ = try await obsolete.value; XCTFail("Old source was published") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        await probe.release()
        let current = try await cache.render(image: secondImage, settings: settings, metadata: nil)
        await cache.configure(image: secondImage, settings: settings, metadata: nil, prefetchEnabled: false, sourceName: "B.JPG")
        let renamed = try await cache.render(image: secondImage, settings: settings, metadata: nil)
        XCTAssertNotEqual(current.filtered.pngData(), renamed.filtered.pngData(), "New source name changes the grain seed")
        let calls = await probe.calls
        XCTAssertEqual(calls, 2, "The new seed must reuse the same filtered pixels")
    }

    func testLocalBatchFreezesGrainAcrossAuthorizationAndLaterEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("DSC.JPG")
        try XCTUnwrap(makeImage().jpegData(compressionQuality: 1)).write(to: source)
        let permission = GrainFilterProbe()
        let model = LocalPhotoBatchViewModel(premiumAccess: PremiumAccess(.lifetime), requestAuthorization: {
            await permission.begin()
            return .authorized
        }, generatePhoto: { item, settings in
            let data = try await LocalPhotoOutput.render(sourceURL: source, settings: settings)
            try data.write(to: directory.appendingPathComponent("\(item.itemIdentifier!).jpg"))
        })
        let photos = (0..<3).map { PhotosPickerItem(itemIdentifier: "batch-\($0)") }
        model.select(photos)
        var settings = filteredGrainSettings()
        let expected = try await LocalPhotoOutput.render(sourceURL: source, settings: settings)
        let identity = photoEffectOutputIdentity(sourceName: "DSC.JPG", settings: settings)
        model.generate(settings: settings)
        try await waitUntil { await permission.calls == 1 }
        settings.photoGrain = .off
        model.generate(settings: settings)
        model.select([PhotosPickerItem(itemIdentifier: "replacement")])
        await permission.release()
        try await waitUntil { !model.state.generating }
        XCTAssertEqual(model.state.progress, PhotoEffectsBatchProgress(total: 3, completed: 3, saved: 3))
        for index in 0..<3 {
            let file = directory.appendingPathComponent("batch-\(index).jpg")
            XCTAssertEqual(try Data(contentsOf: file), expected)
            XCTAssertEqual(PhotoEffectIdentityJPEG.read(from: file), identity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replacement.jpg").path))
        model.select(photos) // Cancel the existing terminal-result timer.
    }

    private func makeCache(_ probe: GrainFilterProbe) -> LocalPhotoPreviewCache {
        LocalPhotoPreviewCache { image, selection in
            await probe.begin()
            do {
                try Task.checkCancellation()
                let result = try await LocalPhotoOutput.filteredSource(image: image, selection: selection)
                await probe.finish(cancelled: false)
                return result
            } catch {
                await probe.finish(cancelled: error is CancellationError)
                throw error
            }
        }
    }

    private func filteredGrainSettings() -> PhotoEffectsSettings {
        var settings = PhotoEffectsSettings()
        settings.photoFilterEnabled = true
        settings.selectedFilter = .init(preset: settings.orderedFilters[0], intensityPercent: 77)
        settings.photoGrain = .init(intensityPercent: 53, enabled: true, style: .medium)
        return settings
    }

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { renderer in
            UIColor(red: 0.35, green: 0.43, blue: 0.55, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.validationMissingMandatoryProperty) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor GrainFilterProbe {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    func begin() async {
        calls += 1
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func finish(cancelled: Bool) { finished += 1; if cancelled { self.cancelled += 1 } }
}
